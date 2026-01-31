-- khoi xu ly TX from FPGA


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uarttx is
  generic (
    CLK_HZ : integer := 50_000_000;
    BAUD   : integer := 115_200
  );
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;

    send : in  std_logic; -- pulse 1 clk to start gui 1 byte
    data : in  std_logic_vector(7 downto 0);    -- data can gui from FPGA

    tx   : out std_logic;
    busy : out std_logic
  );
end entity;

architecture rtl of uarttx is
  constant BIT_TICKS : integer := CLK_HZ / BAUD;

  type state_t is (IDLE, START, DATA, STOP);
  signal state : state_t := IDLE;

  signal tick_cnt : integer range 0 to BIT_TICKS-1 := 0;
  signal bit_idx  : integer range 0 to 7 := 0;
  signal shreg    : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_r     : std_logic := '1';
begin
  tx <= tx_r;
  busy <= '1' when state /= IDLE else '0';

  process(clk) begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= IDLE;
        tick_cnt <= 0;
        bit_idx <= 0;
        shreg <= (others => '0');
        tx_r <= '1';
      else
        case state is
          when IDLE =>
            tx_r <= '1';             -- tx = 1 => IDLE (ko phat)
            tick_cnt <= 0;
            bit_idx <= 0;
            if send = '1' then
              shreg <= data;
              state <= START;
            end if;

          when START =>
            tx_r <= '0';
            if tick_cnt = BIT_TICKS-1 then
              tick_cnt <= 0;
              state <= DATA;
              bit_idx <= 0;
            else
              tick_cnt <= tick_cnt + 1;
            end if;

          when DATA =>                          -- gui 8 bit data trong 1 bit-time
            -- LSB-first
            tx_r <= shreg(bit_idx);
            if tick_cnt = BIT_TICKS-1 then
              tick_cnt <= 0;
              if bit_idx = 7 then
                state <= STOP;
              else
                bit_idx <= bit_idx + 1;
              end if;
            else
              tick_cnt <= tick_cnt + 1;
            end if;

          when STOP =>
            tx_r <= '1';
            if tick_cnt = BIT_TICKS-1 then
              tick_cnt <= 0;
              state <= IDLE;
            else
              tick_cnt <= tick_cnt + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
