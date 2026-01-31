library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity arinc_z2_rx is
  generic (
    N_BITS : integer := 32
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;

    start : in  std_logic;  -- pulse 1 clk to arm receiver

    syn_in: in  std_logic;  -- SYN1 from Z2
    d_in  : in  std_logic;  -- D1   from Z2

    busy  : out std_logic;
    done  : out std_logic;  -- pulse 1 clk when N_BITS captured
    word_o: out std_logic_vector(N_BITS-1 downto 0)
  );
end entity;

architecture rtl of arinc_z2_rx is
  signal syn1, syn2 : std_logic := '0';
  signal d1, d2     : std_logic := '0';

  signal syn2_d     : std_logic := '0';
  signal syn_rise   : std_logic := '0';

  signal busy_r : std_logic := '0';
  signal done_r : std_logic := '0';

  signal cnt    : integer range 0 to N_BITS := 0;
  signal buf    : std_logic_vector(N_BITS-1 downto 0) := (others => '0');
begin
  busy  <= busy_r;
  done  <= done_r;
  word_o<= buf;

  -- 2FF sync for SYN and D
  process(clk) begin
    if rising_edge(clk) then
      if rst='1' then
        syn1 <= '0'; syn2 <= '0';
        d1   <= '0'; d2   <= '0';
        syn2_d <= '0';
      else
        syn1 <= syn_in;
        syn2 <= syn1;
        d1   <= d_in;
        d2   <= d1;
        syn2_d <= syn2;
      end if;
    end if;
  end process;

  syn_rise <= '1' when (syn2='1' and syn2_d='0') else '0';

  process(clk) begin
    if rising_edge(clk) then
      if rst='1' then
        busy_r <= '0';
        done_r <= '0';
        cnt    <= 0;
        buf    <= (others => '0');
      else
        done_r <= '0';

        if start='1' then
          busy_r <= '1';
          cnt    <= 0;
          buf    <= (others => '0');
        end if;

        if (busy_r='1') and (syn_rise='1') then
          -- bit 0 received -> store to MSB (N_BITS-1), MSB-first
          buf(N_BITS-1-cnt) <= d2;

          if cnt = N_BITS-1 then
            busy_r <= '0';
            done_r <= '1';
            cnt    <= 0;
          else
            cnt <= cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
