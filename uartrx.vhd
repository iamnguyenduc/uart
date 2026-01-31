-- khoi xu ly RX from FPGA


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uartrx is
  generic (
    CLK_HZ : integer := 50_000_000;
    BAUD   : integer := 115_200
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    rx    : in  std_logic;

    data  : out std_logic_vector(7 downto 0);  -- 8 bit data
    valid : out std_logic;                     -- xung clock report vua nhan xong 1 byte
    frame_error : out std_logic                -- bao loi stop bit
  );
end entity;

architecture rtl of uartrx is
  constant OVERSAMPLE : integer := 16;
  constant INC        : integer := BAUD * OVERSAMPLE; -- tick16 rate = BAUD*16

  -- tick16 generator accumulator (0 .. CLK_HZ-1)
  signal acc    : integer range 0 to CLK_HZ-1 := 0;
  signal tick16 : std_logic := '0';

  type state_t is (IDLE, START, DATA, STOP); -- may trang thai
  signal state : state_t := IDLE;

  signal sample_cnt : integer range 0 to 15 := 0; -- 0..15 ticks within a bit
  signal bit_idx    : integer range 0 to 7  := 0;
  signal shreg      : std_logic_vector(7 downto 0) := (others => '0');

  -- RX synchronizer
  signal rx_sync1, rx_sync2 : std_logic := '1';
begin
  -- 2FF sync for RX
  process(clk) begin
    if rising_edge(clk) then
      rx_sync1 <= rx;
      rx_sync2 <= rx_sync1;
    end if;
  end process;

  -- Generate tick16 using phase accumulator (average frequency = BAUD*16)
  process(clk) 
    variable tmp : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        acc    <= 0;
        tick16 <= '0';
      else
        tmp := acc + INC;
        if tmp >= CLK_HZ then
          acc    <= tmp - CLK_HZ;
          tick16 <= '1';
        else
          acc    <= tmp;
          tick16 <= '0';
        end if;
      end if;
    end if;
  end process;

  -- UART RX FSM with 16x oversampling
  process(clk) begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= IDLE;
        sample_cnt <= 0;
        bit_idx <= 0;
        shreg <= (others => '0');
        data <= (others => '0');
        valid <= '0';
        frame_error <= '0';
      else
        valid <= '0';
        frame_error <= '0';

        if tick16 = '1' then
          case state is
            when IDLE =>
              sample_cnt <= 0;
              bit_idx <= 0;
              if rx_sync2 = '0' then
                -- start edge detected
                state <= START;
                sample_cnt <= 0;
              end if;

            when START =>
              -- confirm start at mid-bit (after 8 ticks)
              if sample_cnt = 7 then
                if rx_sync2 = '0' then
                  state <= DATA;           -- phat hien xuong 0, bat dau START
                  sample_cnt <= 0;
                  bit_idx <= 0;
                else
                  state <= IDLE; -- false start
                end if;
              else
                sample_cnt <= sample_cnt + 1;
              end if;

            when DATA =>
              if sample_cnt = 15 then
                sample_cnt <= 0;
                -- sample data bit in middle; UART is LSB-first
                shreg(bit_idx) <= rx_sync2;

                if bit_idx = 7 then
                  state <= STOP;
                else
                  bit_idx <= bit_idx + 1;
                end if;
              else
                sample_cnt <= sample_cnt + 1;
              end if;

            when STOP =>
              if sample_cnt = 15 then
                sample_cnt <= 0;
                -- stop bit should be '1'
                if rx_sync2 = '1' then       -- kiem tra stop-bit ? 1 : valid = 1 :
                  data <= shreg;
                  valid <= '1';
                else
                  frame_error <= '1';
                end if;
                state <= IDLE;
              else
                sample_cnt <= sample_cnt + 1;
              end if;

          end case;
        end if;
      end if;
    end if;
  end process;

end architecture;
