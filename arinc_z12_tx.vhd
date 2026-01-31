library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity arinc_z12_tx is
  generic (
    CLK_HZ          : integer := 50_000_000;
    BITRATE_HZ      : integer := 100_000;
    IDLE_BITS       : integer := 4;  -- 
    POST_GUARD_BITS : integer := 1   --
  );
  port (
    clk   : in  std_logic;

    start : in  std_logic;                 -- xung 1 clk
    word_i: in  std_logic_vector(31 downto 0);

    ready : out std_logic;                 -- =1 khi có thể nhận start
    busy  : out std_logic;                 -- =1 khi đang phát
    done  : out std_logic;                 -- xung 1 clk khi phát xong

    d6    : out std_logic;
    syn6  : out std_logic;
    ce6_n : out std_logic
  );
end entity;

architecture rtl of arinc_z12_tx is
  constant HALF_TICKS    : integer := CLK_HZ / (2*BITRATE_HZ);
  constant TICKS_PER_BIT : integer := CLK_HZ / BITRATE_HZ;

  constant N_BITS : integer := 32;

  type state_t is (IDLE_WAIT, RUN, POST_GUARD);
  signal st : state_t := IDLE_WAIT;

  -- outputs registered
  signal syn6_r : std_logic := '0';
  signal d6_r   : std_logic := '0';
  signal ce_r   : std_logic := '1';

  -- IDLE gap counter
  signal idle_tick : integer range 0 to TICKS_PER_BIT-1 := 0;
  signal idle_cnt  : integer range 0 to IDLE_BITS := 0;

  -- RUN timing
  signal run_cnt   : integer range 0 to HALF_TICKS-1 := 0;
  signal bits_sent : integer range 0 to N_BITS := 0;

  -- shift reg MSB-first
  signal shreg : std_logic_vector(31 downto 0) := (others => '0');

  -- POST_GUARD timing
  signal pg_tick : integer range 0 to TICKS_PER_BIT-1 := 0;
  signal pg_cnt  : integer range 0 to POST_GUARD_BITS := 0;

  signal stop_pending : std_logic := '0';
  signal done_r : std_logic := '0';
begin
  syn6  <= syn6_r;
  d6    <= d6_r;
  ce6_n <= ce_r;

  done  <= done_r;
  busy  <= '1' when st /= IDLE_WAIT else '0';
  ready <= '1' when (st = IDLE_WAIT and idle_cnt = IDLE_BITS) else '0';

  process(clk)
    variable next_syn : std_logic;
  begin
    if rising_edge(clk) then
      done_r <= '0';

      case st is
        when IDLE_WAIT =>
          ce_r   <= '1';
          syn6_r <= '0';
          d6_r   <= '0';

          -- đếm gap IDLE_BITS bit-time
          if idle_cnt < IDLE_BITS then
            if idle_tick = TICKS_PER_BIT-1 then
              idle_tick <= 0;
              idle_cnt  <= idle_cnt + 1;
            else
              idle_tick <= idle_tick + 1;
            end if;
          else
            idle_tick <= 0;
          end if;

          -- nhận start khi ready
          if (start = '1') and (idle_cnt = IDLE_BITS) then
            shreg        <= word_i;
            d6_r         <= word_i(31);   -- MSB trước
            bits_sent    <= 0;
            stop_pending <= '0';

            ce_r   <= '0';
            syn6_r <= '0';
            run_cnt<= 0;

            -- reset gap cho lần sau
            idle_cnt  <= 0;
            idle_tick <= 0;

            st <= RUN;
          end if;

        when RUN =>
          ce_r <= '0';

          if run_cnt = HALF_TICKS-1 then
            run_cnt <= 0;

            next_syn := not syn6_r;
            syn6_r   <= next_syn;

            if next_syn = '1' then
              -- cạnh lên: Z12 chốt D6 => gửi xong 1 bit
              bits_sent <= bits_sent + 1;

              -- shift sau khi gửi MSB
              shreg <= shreg(30 downto 0) & '0';

              if bits_sent = N_BITS-1 then
                stop_pending <= '1'; -- dừng ở cạnh xuống kế tiếp
              end if;

            else
              -- cạnh xuống: cập nhật bit kế
              d6_r <= shreg(31);

              if stop_pending = '1' then
                stop_pending <= '0';

                -- vào post-guard, giữ NULL và dừng clock ở LOW
                syn6_r <= '0';
                d6_r   <= '0';
                ce_r   <= '0';

                pg_tick <= 0;
                pg_cnt  <= 0;
                st      <= POST_GUARD;
              end if;
            end if;

          else
            run_cnt <= run_cnt + 1;
          end if;

        when POST_GUARD =>
          ce_r   <= '0';
          syn6_r <= '0';
          d6_r   <= '0';

          if pg_tick = TICKS_PER_BIT-1 then
            pg_tick <= 0;
            if pg_cnt < POST_GUARD_BITS then
              pg_cnt <= pg_cnt + 1;
            end if;
          else
            pg_tick <= pg_tick + 1;
          end if;

          if pg_cnt = POST_GUARD_BITS then
            ce_r   <= '1';
            syn6_r <= '0';
            d6_r   <= '0';

            done_r <= '1';      -- báo “đã phát xong”
            st     <= IDLE_WAIT;
          end if;
      end case;
    end if;
  end process;
end architecture;
