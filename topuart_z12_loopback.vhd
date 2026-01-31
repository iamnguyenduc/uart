-- File: 1 phat 2 thu
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity topuart is
  generic (
    CLK_HZ     : integer := 50_000_000;
    BAUD       : integer := 115_200;
    BITRATE_HZ : integer := 100_000
  );
  port (
    clk     : in  std_logic;
    fpga_rx : in  std_logic;
    fpga_tx : out std_logic;

    -- to Z12
    d6      : out std_logic;
    syn6    : out std_logic;
    ce6_n   : out std_logic;

    -- from Z2 (fan-out into 2 FPGA pin pairs)
    z2_syn1_a : in  std_logic;
    z2_d1_a   : in  std_logic;

    z2_syn1_b : in  std_logic;
    z2_d1_b   : in  std_logic;

    z2_ce1  : out std_logic
  );
end entity;

architecture rtl of topuart is
  constant PASS_BYTE : std_logic_vector(7 downto 0) := x"4B"; -- 'K'
  constant FAIL_BYTE : std_logic_vector(7 downto 0) := x"45"; -- 'E'

  signal rst_i   : std_logic := '1';
  signal por_cnt : unsigned(19 downto 0) := (others => '0');

  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;

  signal tx_send  : std_logic := '0';
  signal tx_busy  : std_logic;
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');

  signal idx  : integer range 0 to 3 := 0;
  signal wtmp : std_logic_vector(31 downto 0) := (others => '0');

  signal tx_word   : std_logic_vector(31 downto 0) := (others => '0');
  signal rx_word_a : std_logic_vector(31 downto 0) := (others => '0');
  signal rx_word_b : std_logic_vector(31 downto 0) := (others => '0');

  signal st1_byte  : std_logic_vector(7 downto 0) := FAIL_BYTE;
  signal st2_byte  : std_logic_vector(7 downto 0) := FAIL_BYTE;

  signal arinc_start : std_logic := '0';
  signal arinc_ready : std_logic;
  signal arinc_done  : std_logic;

  signal rx_start  : std_logic := '0';
  signal z2_done_a : std_logic;
  signal z2_done_b : std_logic;

  signal tx_done_seen   : std_logic := '0';
  signal rx_done_a_seen : std_logic := '0';
  signal rx_done_b_seen : std_logic := '0';

  type sys_state_t is (WAIT_WORD, START_IO, WAIT_BOTH, SEND_RESP);
  signal sys_st : sys_state_t := WAIT_WORD;

  subtype byte_t is std_logic_vector(7 downto 0);
  type byte_arr_t is array (0 to 13) of byte_t;
  signal resp_buf : byte_arr_t := (others => (others => '0'));
  signal resp_ptr : integer range 0 to 13 := 0;

  type resp_state_t is (RESP_IDLE, RESP_LOAD, RESP_WAIT_START, RESP_WAIT_DONE);
  signal resp_st : resp_state_t := RESP_IDLE;

begin
  z2_ce1 <= '1';

  -- POR ~20ms
  process(clk)
  begin
    if rising_edge(clk) then
      if rst_i = '1' then
        if por_cnt = to_unsigned(1_000_000, por_cnt'length) then
          rst_i <= '0';
        else
          por_cnt <= por_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  u_rx: entity work.uartrx
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => clk, rst => rst_i, rx => fpga_rx,
              data => rx_data, valid => rx_valid, frame_error => open);

  u_tx: entity work.uarttx
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (clk => clk, rst => rst_i,
              send => tx_send, data => tx_data, tx => fpga_tx, busy => tx_busy);

  u_z12tx: entity work.arinc_z12_tx
    generic map (CLK_HZ => CLK_HZ, BITRATE_HZ => BITRATE_HZ, IDLE_BITS => 4, POST_GUARD_BITS => 1)
    port map (clk => clk, start => arinc_start, word_i => tx_word,
              ready => arinc_ready, busy => open, done => arinc_done,
              d6 => d6, syn6 => syn6, ce6_n => ce6_n);

  u_z2rx_a: entity work.arinc_z2_rx
    generic map (N_BITS => 32)
    port map (clk => clk, rst => rst_i, start => rx_start,
              syn_in => z2_syn1_a, d_in => z2_d1_a,
              busy => open, done => z2_done_a, word_o => rx_word_a);

  u_z2rx_b: entity work.arinc_z2_rx
    generic map (N_BITS => 32)
    port map (clk => clk, rst => rst_i, start => rx_start,
              syn_in => z2_syn1_b, d_in => z2_d1_b,
              busy => open, done => z2_done_b, word_o => rx_word_b);

  process(clk)
  begin
    if rising_edge(clk) then
      tx_send     <= '0';
      arinc_start <= '0';
      rx_start    <= '0';

      if rst_i='1' then
        sys_st <= WAIT_WORD;
        idx <= 0;
        wtmp <= (others=>'0');
        tx_word <= (others=>'0');
        tx_done_seen <= '0';
        rx_done_a_seen <= '0';
        rx_done_b_seen <= '0';
        st1_byte <= FAIL_BYTE;
        st2_byte <= FAIL_BYTE;
        resp_ptr <= 0;
        resp_st  <= RESP_IDLE;

      else
        case sys_st is
          when WAIT_WORD =>
            if rx_valid='1' then
              case idx is
                when 0 => wtmp(31 downto 24) <= rx_data; idx <= 1;
                when 1 => wtmp(23 downto 16) <= rx_data; idx <= 2;
                when 2 => wtmp(15 downto 8)  <= rx_data; idx <= 3;
                when others =>
                  wtmp(7 downto 0) <= rx_data;
                  idx <= 0;
                  tx_word <= wtmp(31 downto 8) & rx_data;
                  sys_st  <= START_IO;
              end case;
            end if;

          when START_IO =>
            tx_done_seen   <= '0';
            rx_done_a_seen <= '0';
            rx_done_b_seen <= '0';

            if arinc_ready='1' then
              rx_start    <= '1';
              arinc_start <= '1';
              sys_st      <= WAIT_BOTH;
            end if;

          when WAIT_BOTH =>
            if arinc_done='1' then tx_done_seen <= '1'; end if;
            if z2_done_a='1' then  rx_done_a_seen <= '1'; end if;
            if z2_done_b='1' then  rx_done_b_seen <= '1'; end if;

            if (tx_done_seen='1') and (rx_done_a_seen='1') and (rx_done_b_seen='1') then
              if rx_word_a = tx_word then st1_byte <= PASS_BYTE; else st1_byte <= FAIL_BYTE; end if;
              if rx_word_b = tx_word then st2_byte <= PASS_BYTE; else st2_byte <= FAIL_BYTE; end if;

              resp_buf(0)  <= tx_word(31 downto 24);
              resp_buf(1)  <= tx_word(23 downto 16);
              resp_buf(2)  <= tx_word(15 downto 8);
              resp_buf(3)  <= tx_word(7 downto 0);

              resp_buf(4)  <= rx_word_a(31 downto 24);
              resp_buf(5)  <= rx_word_a(23 downto 16);
              resp_buf(6)  <= rx_word_a(15 downto 8);
              resp_buf(7)  <= rx_word_a(7 downto 0);

              resp_buf(8)  <= rx_word_b(31 downto 24);
              resp_buf(9)  <= rx_word_b(23 downto 16);
              resp_buf(10) <= rx_word_b(15 downto 8);
              resp_buf(11) <= rx_word_b(7 downto 0);

              resp_buf(12) <= st1_byte;
              resp_buf(13) <= st2_byte;

              resp_ptr <= 0;
              resp_st  <= RESP_LOAD;
              sys_st   <= SEND_RESP;
            end if;

          when SEND_RESP =>
            case resp_st is
              when RESP_IDLE =>
                sys_st <= WAIT_WORD;

              when RESP_LOAD =>
                if tx_busy='0' then
                  tx_data <= resp_buf(resp_ptr);
                  tx_send <= '1';
                  resp_st <= RESP_WAIT_START;
                end if;

              when RESP_WAIT_START =>
                if tx_busy='1' then
                  resp_st <= RESP_WAIT_DONE;
                end if;

              when RESP_WAIT_DONE =>
                if tx_busy='0' then
                  if resp_ptr = 13 then
                    resp_st <= RESP_IDLE;
                    sys_st  <= WAIT_WORD;
                  else
                    resp_ptr <= resp_ptr + 1;
                    resp_st  <= RESP_LOAD;
                  end if;
                end if;
            end case;

        end case;
      end if;
    end if;
  end process;

end architecture;
