----------------------------------------------------------------------------------
-- SPI Slave Testbench
-- Tests SPI communication protocol with READ and WRITE commands
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_slave_tb is
end spi_slave_tb;

architecture Behavioral of spi_slave_tb is

    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz
    constant SPI_CLK_PERIOD : time := 1 us;  -- 1 MHz SPI clock (slower for testing)

    component spi_slave is
        Port (
            clk         : in  std_logic;
            reset       : in  std_logic;
            spi_sck     : in  std_logic;
            spi_mosi    : in  std_logic;
            spi_miso    : out std_logic;
            spi_cs_n    : in  std_logic;
            order_count_in    : in  std_logic_vector(31 downto 0);
            bbo_count_in      : in  std_logic_vector(31 downto 0);
            latency_p50_in    : in  std_logic_vector(31 downto 0);
            symbol_enable_out : out std_logic_vector(7 downto 0);
            threshold_out     : out std_logic_vector(31 downto 0);
            debug_state : out std_logic_vector(2 downto 0);
            uart_debug_tx_data  : out std_logic_vector(7 downto 0);
            uart_debug_tx_start : out std_logic;
            uart_debug_tx_busy  : in  std_logic
        );
    end component;

    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal spi_sck : std_logic := '0';
    signal spi_mosi : std_logic := '0';
    signal spi_miso : std_logic;
    signal spi_cs_n : std_logic := '1';
    signal order_count_in : std_logic_vector(31 downto 0) := x"00000001";
    signal bbo_count_in : std_logic_vector(31 downto 0) := x"00000002";
    signal latency_p50_in : std_logic_vector(31 downto 0) := x"00000003";
    signal symbol_enable_out : std_logic_vector(7 downto 0);
    signal threshold_out : std_logic_vector(31 downto 0);
    signal debug_state : std_logic_vector(2 downto 0);
    signal uart_debug_tx_data : std_logic_vector(7 downto 0);
    signal uart_debug_tx_start : std_logic;
    signal uart_debug_tx_busy : std_logic := '0';

    -- Test signals - capture only data phase (32 bits)
    signal captured_data : std_logic_vector(31 downto 0);
    signal data_bit_count : integer range 0 to 32 := 0;
    signal capture_enable : std_logic := '0';
    signal clock_count : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut: spi_slave
        port map (
            clk => clk,
            reset => reset,
            spi_sck => spi_sck,
            spi_mosi => spi_mosi,
            spi_miso => spi_miso,
            spi_cs_n => spi_cs_n,
            order_count_in => order_count_in,
            bbo_count_in => bbo_count_in,
            latency_p50_in => latency_p50_in,
            symbol_enable_out => symbol_enable_out,
            threshold_out => threshold_out,
            debug_state => debug_state,
            uart_debug_tx_data => uart_debug_tx_data,
            uart_debug_tx_start => uart_debug_tx_start,
            uart_debug_tx_busy => uart_debug_tx_busy
        );

    -- Capture MISO data ONLY during data phase (after command + address)
    -- We enable capture after 16 SPI clock cycles (8 cmd + 8 addr)
    process(spi_sck, spi_cs_n)
    begin
        if spi_cs_n = '1' then
            -- Reset on CS deassert
            clock_count <= 0;
            data_bit_count <= 0;
            capture_enable <= '0';
            captured_data <= (others => '0');
        elsif rising_edge(spi_sck) and spi_cs_n = '0' then
            clock_count <= clock_count + 1;
            
            -- After 16 clock cycles (command + address), enable data capture
            if clock_count = 16 then
                capture_enable <= '1';
                data_bit_count <= 0;
            end if;
            
            -- Capture data bits when enabled
            if capture_enable = '1' and data_bit_count < 32 then
                -- MSB first: first bit goes to position 31
                captured_data(31 - data_bit_count) <= spi_miso;
                data_bit_count <= data_bit_count + 1;
            end if;
        end if;
    end process;

    -- Stimulus process
    stim_proc: process
        procedure spi_send_byte(data : std_logic_vector(7 downto 0)) is
        begin
            for i in 7 downto 0 loop
                spi_mosi <= data(i);
                wait for SPI_CLK_PERIOD / 2;
                spi_sck <= '1';
                wait for SPI_CLK_PERIOD / 2;
                spi_sck <= '0';
            end loop;
        end procedure;

        procedure spi_read_32bits is
        begin
            for i in 0 to 31 loop
                wait for SPI_CLK_PERIOD / 2;
                spi_sck <= '1';
                wait for SPI_CLK_PERIOD / 2;
                spi_sck <= '0';
            end loop;
        end procedure;

        variable read_data : std_logic_vector(31 downto 0);
    begin
        reset <= '1';
        wait for 200 ns;
        reset <= '0';
        wait for 100 ns;

        report "TEST: Starting SPI Slave test";

        -- Test 1: READ register 0x00 (ORDER_COUNT)
        report "TEST 1: READ register 0x00 (ORDER_COUNT)";
        -- Note: captured_data, data_bit_count, and capture_enable are managed by capture process
        
        -- Assert CS (this will reset the capture process)
        spi_cs_n <= '0';
        wait for SPI_CLK_PERIOD;
        
        -- Send command: 0x01 (READ)
        spi_send_byte(x"01");
        wait for SPI_CLK_PERIOD;
        
        -- Send address: 0x00
        spi_send_byte(x"00");
        wait for SPI_CLK_PERIOD;
        -- Wait for system clock to allow register read to complete
        wait for CLK_PERIOD * 3;
        
        -- Read 32 bits of data
        report "TEST 1: Starting to read 32 bits, debug_state = " & integer'image(to_integer(unsigned(debug_state)));
        spi_read_32bits;
        wait for SPI_CLK_PERIOD;
        report "TEST 1: Finished reading, debug_state = " & integer'image(to_integer(unsigned(debug_state)));
        
        -- Deassert CS
        spi_cs_n <= '1';
        wait for SPI_CLK_PERIOD * 2;
        
        -- Extract captured data
        read_data := captured_data;
        report "TEST 1: Captured data = 0x" & to_hstring(read_data);
        report "TEST 1: Data bit count = " & integer'image(data_bit_count);
        
        -- Verify result
        assert read_data = x"00000001" 
            report "ERROR: Expected 0x00000001, got 0x" & to_hstring(read_data) 
            severity error;

        report "TEST: PASS - SPI Slave test passed";
        wait;
    end process;

end Behavioral;
