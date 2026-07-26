library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Seta E90 S2D serial memory used by Magical Tetris.  The wire protocol is
-- I2C-like, but sends the seven-bit memory address MSB first followed by R/W,
-- then transfers each data byte LSB first.  The address counter wraps at 128.
entity AT24C01 is
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

      nv_addr     : in  std_logic_vector(5 downto 0);
      nv_data_in  : in  std_logic_vector(15 downto 0);
      nv_wren     : in  std_logic;
      nv_data_out : out std_logic_vector(15 downto 0);

      scl         : in  std_logic;
      sda_out     : in  std_logic;
      sda_oe      : in  std_logic;
      sda_in      : out std_logic;
      changed     : out std_logic := '0'
   );
end entity;

architecture arch of AT24C01 is
   type tSerialState is
   (
      ST_IDLE,
      ST_HEADER,
      ST_HEADER_ACK_RISE,
      ST_HEADER_ACK_FALL,
      ST_READ,
      ST_READ_ACK_RISE,
      ST_READ_ACK_FALL,
      ST_WRITE,
      ST_WRITE_ACK_RISE,
      ST_WRITE_ACK_FALL
   );

   signal serial_state      : tSerialState := ST_IDLE;
   signal scl_last          : std_logic := '0';
   signal sda_out_last      : std_logic := '0';
   signal serial_drive_low  : std_logic := '0';
   signal serial_addr       : unsigned(6 downto 0) := (others => '0');
   signal serial_header     : std_logic_vector(7 downto 0) := (others => '0');
   signal serial_data       : std_logic_vector(7 downto 0) := (others => '0');
   signal serial_bit        : integer range 0 to 7 := 0;
   signal serial_read       : std_logic := '0';
   signal serial_wren       : std_logic := '0';

   signal mem_addr          : std_logic_vector(5 downto 0);
   signal mem_data_in       : std_logic_vector(15 downto 0);
   signal mem_byteena       : std_logic_vector(1 downto 0);
   signal mem_wren          : std_logic;
   signal mem_data_out      : std_logic_vector(15 downto 0);
   signal serial_byte_out   : std_logic_vector(7 downto 0);
begin
   -- The device only pulls SDA low.  When the CPU owns the pin, reads echo
   -- its output; when released, the board pull-up supplies a one.
   sda_in <= '0' when serial_drive_low = '1' else
             sda_out when sda_oe = '1' else
             '1';

   mem_addr <= std_logic_vector(serial_addr(6 downto 1))
                  when serial_state /= ST_IDLE else nv_addr;
   mem_data_in <= serial_data & serial_data
                  when serial_state /= ST_IDLE else nv_data_in;
   mem_byteena <= "01" when serial_state /= ST_IDLE and serial_addr(0) = '0' else
                  "10" when serial_state /= ST_IDLE else
                  "11";
   mem_wren <= serial_wren when serial_state /= ST_IDLE else nv_wren;

   serial_byte_out <= mem_data_out(7 downto 0) when serial_addr(0) = '0' else
                      mem_data_out(15 downto 8);
   nv_data_out <= mem_data_out;

   iMemory : entity work.dpram_dif_be
   generic map
   (
      addr_width_a    => 6,
      data_width_a    => 16,
      addr_width_b    => 6,
      data_width_b    => 16,
      width_byteena_a => 2,
      width_byteena_b => 2
   )
   port map
   (
      clock_a   => clk,
      address_a => mem_addr,
      data_a    => mem_data_in,
      byteena_a => mem_byteena,
      wren_a    => mem_wren,
      q_a       => mem_data_out,
      clock_b   => clk,
      address_b => (others => '0'),
      data_b    => (others => '0'),
      byteena_b => "00",
      wren_b    => '0',
      q_b       => open
   );

   process(clk)
      variable next_header : std_logic_vector(7 downto 0);
      variable next_data   : std_logic_vector(7 downto 0);
      variable rise_scl    : boolean;
      variable fall_scl    : boolean;
      variable start_bus   : boolean;
      variable stop_bus    : boolean;
   begin
      if rising_edge(clk) then
         rise_scl  := scl_last = '0' and scl = '1';
         fall_scl  := scl_last = '1' and scl = '0';
         start_bus := scl = '1' and sda_oe = '1' and
                      sda_out_last = '1' and sda_out = '0';
         stop_bus  := scl = '1' and sda_oe = '1' and
                      sda_out_last = '0' and sda_out = '1';

         scl_last     <= scl;
         sda_out_last <= sda_out;
         serial_wren  <= '0';
         changed      <= '0';

         if reset = '1' then
            serial_state     <= ST_IDLE;
            serial_header    <= (others => '0');
            serial_data      <= (others => '0');
            serial_bit       <= 0;
            serial_read      <= '0';
            serial_drive_low <= '0';
         elsif start_bus then
            serial_state     <= ST_HEADER;
            serial_header    <= (others => '0');
            serial_bit       <= 0;
            serial_drive_low <= '0';
         elsif stop_bus then
            serial_state     <= ST_IDLE;
            serial_drive_low <= '0';
         else
            case serial_state is
               when ST_IDLE =>
                  serial_drive_low <= '0';

               when ST_HEADER =>
                  if rise_scl then
                     next_header := serial_header(6 downto 0) & sda_out;
                     serial_header <= next_header;
                     if serial_bit = 7 then
                        serial_addr      <= unsigned(next_header(7 downto 1));
                        serial_read      <= next_header(0);
                        serial_bit       <= 0;
                        serial_drive_low <= '1';
                        serial_state     <= ST_HEADER_ACK_RISE;
                     else
                        serial_bit <= serial_bit + 1;
                     end if;
                  end if;

               -- Ignore the falling edge which ends the R/W data clock;
               -- release ACK only after its own complete high pulse.
               when ST_HEADER_ACK_RISE =>
                  if rise_scl then
                     serial_state <= ST_HEADER_ACK_FALL;
                  end if;

               when ST_HEADER_ACK_FALL =>
                  if fall_scl then
                     serial_drive_low <= '0';
                     serial_bit <= 0;
                     if serial_read = '1' then
                        if serial_byte_out(0) = '0' then
                           serial_drive_low <= '1';
                        end if;
                        serial_state <= ST_READ;
                     else
                        serial_data  <= (others => '0');
                        serial_state <= ST_WRITE;
                     end if;
                  end if;

               when ST_READ =>
                  if fall_scl then
                     if serial_bit = 7 then
                        serial_drive_low <= '0';
                        serial_addr <= serial_addr + 1;
                        serial_bit <= 0;
                        serial_state <= ST_READ_ACK_RISE;
                     else
                        serial_bit <= serial_bit + 1;
                        if serial_byte_out(serial_bit + 1) = '0' then
                           serial_drive_low <= '1';
                        else
                           serial_drive_low <= '0';
                        end if;
                     end if;
                  end if;

               when ST_READ_ACK_RISE =>
                  if rise_scl then
                     serial_state <= ST_READ_ACK_FALL;
                  end if;

               when ST_READ_ACK_FALL =>
                  if fall_scl then
                     if serial_byte_out(0) = '0' then
                        serial_drive_low <= '1';
                     else
                        serial_drive_low <= '0';
                     end if;
                     serial_state <= ST_READ;
                  end if;

               when ST_WRITE =>
                  if rise_scl then
                     next_data := serial_data;
                     next_data(serial_bit) := sda_out;
                     serial_data <= next_data;
                     if serial_bit = 7 then
                        serial_bit <= 0;
                        serial_wren <= '1';
                        changed <= '1';
                        serial_drive_low <= '1';
                        serial_state <= ST_WRITE_ACK_RISE;
                     else
                        serial_bit <= serial_bit + 1;
                     end if;
                  end if;

               when ST_WRITE_ACK_RISE =>
                  if rise_scl then
                     serial_state <= ST_WRITE_ACK_FALL;
                  end if;

               when ST_WRITE_ACK_FALL =>
                  if fall_scl then
                     serial_addr <= serial_addr + 1;
                     serial_data <= (others => '0');
                     serial_bit <= 0;
                     serial_drive_low <= '0';
                     serial_state <= ST_WRITE;
                  end if;
            end case;
         end if;
      end if;
   end process;
end architecture;
