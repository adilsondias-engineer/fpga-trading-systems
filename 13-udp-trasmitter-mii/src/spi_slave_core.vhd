----------------------------------------------------------------------------------
-- Generic SPI Slave Core Module
-- SPI Mode 0 (CPOL=0, CPHA=0)
-- Handles low-level SPI protocol: command byte, address byte, 32-bit data
--
-- Protocol:
--   Command byte: 0x01 = READ, 0x02 = WRITE
--   Address byte: Address (0-255)
--   Data: 32-bit read/write (MSB first)
--
-- Generic module handles SPI protocol only.
-- Register mapping handled by application layer.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_slave_core is
    Port (
        -- System clock (100 MHz)
        clk         : in  std_logic;
        reset       : in  std_logic;
        
        -- SPI interface (from master)
        spi_sck     : in  std_logic;   -- SPI clock from master
        spi_mosi    : in  std_logic;   -- Master Out Slave In
        spi_miso    : out std_logic;   -- Master In Slave Out
        spi_cs_n    : in  std_logic;   -- Chip select (active low)
        
        -- Transaction interface (to application layer)
        cmd_byte        : out std_logic_vector(7 downto 0);
        addr_byte       : out std_logic_vector(7 downto 0);
        data_rd         : in  std_logic_vector(31 downto 0);  -- Data to send for READ
        data_wr         : out std_logic_vector(31 downto 0);  -- Data received for WRITE
        
        -- Transaction control
        transaction_complete : out std_logic;  -- Pulse when transaction completes
        is_read              : out std_logic;  -- '1' for READ, '0' for WRITE
        is_write             : out std_logic   -- '1' for WRITE, '0' for READ
    );
end spi_slave_core;

architecture Behavioral of spi_slave_core is
    
    -- SPI clock domain signals (synchronized)
    signal spi_sck_sync1, spi_sck_sync2 : std_logic := '0';
    signal spi_cs_n_sync1, spi_cs_n_sync2 : std_logic := '1';
    signal spi_mosi_sync1, spi_mosi_sync2 : std_logic := '0';
    
    -- Edge detection
    signal spi_sck_prev : std_logic := '0';
    signal spi_sck_rising : std_logic;
    signal spi_sck_falling : std_logic;
    
    -- SPI state machine
    type spi_state_t is (IDLE, RECEIVE_CMD, RECEIVE_ADDR, SEND_DATA, RECEIVE_DATA);
    signal state : spi_state_t := IDLE;
    
    -- Shift registers
    signal cmd_shift : std_logic_vector(7 downto 0) := (others => '0');
    signal addr_shift : std_logic_vector(7 downto 0) := (others => '0');
    signal data_shift : std_logic_vector(31 downto 0) := (others => '0');
    signal bit_count : integer range 0 to 35 := 0;
    
    -- Internal command (address uses output port directly)
    signal cmd_byte_int : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Control commands
    constant CMD_READ  : std_logic_vector(7 downto 0) := x"01";
    constant CMD_WRITE : std_logic_vector(7 downto 0) := x"02";
    
begin
    
    -- ========================================================================
    -- Clock Domain Crossing: SPI signals to 100 MHz domain
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            spi_sck_sync1 <= spi_sck;
            spi_sck_sync2 <= spi_sck_sync1;
            
            spi_cs_n_sync1 <= spi_cs_n;
            spi_cs_n_sync2 <= spi_cs_n_sync1;
            
            spi_mosi_sync1 <= spi_mosi;
            spi_mosi_sync2 <= spi_mosi_sync1;
            
            spi_sck_prev <= spi_sck_sync2;
        end if;
    end process;
    
    spi_sck_rising  <= '1' when spi_sck_sync2 = '1' and spi_sck_prev = '0' else '0';
    spi_sck_falling <= '1' when spi_sck_sync2 = '0' and spi_sck_prev = '1' else '0';
    
    -- ========================================================================
    -- MISO Output (Combinational - always driven)
    -- ========================================================================
    spi_miso <= data_shift(31) when (state = SEND_DATA and spi_cs_n_sync2 = '0') else '0';
    
    -- ========================================================================
    -- SPI Slave State Machine
    -- ========================================================================
    process(clk)
        variable addr_complete : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                bit_count <= 0;
                cmd_shift <= (others => '0');
                addr_shift <= (others => '0');
                data_shift <= (others => '0');
                cmd_byte_int <= (others => '0');
                addr_byte <= (others => '0');
                transaction_complete <= '0';
                is_read <= '0';
                is_write <= '0';
            else
                transaction_complete <= '0';
                is_read <= '0';
                is_write <= '0';
                
                case state is
                    
                    when IDLE =>
                        bit_count <= 0;
                        cmd_shift <= (others => '0');
                        addr_shift <= (others => '0');
                        
                        if spi_cs_n_sync2 = '0' then
                            state <= RECEIVE_CMD;
                        end if;
                    
                    when RECEIVE_CMD =>
                        if spi_cs_n_sync2 = '1' then
                            state <= IDLE;
                        elsif spi_sck_rising = '1' then
                            cmd_shift <= cmd_shift(6 downto 0) & spi_mosi_sync2;
                            bit_count <= bit_count + 1;
                            
                            if bit_count = 7 then
                                cmd_byte_int <= cmd_shift(6 downto 0) & spi_mosi_sync2;
                                bit_count <= 0;
                                state <= RECEIVE_ADDR;
                            end if;
                        end if;
                    
                    when RECEIVE_ADDR =>
                        if spi_cs_n_sync2 = '1' then
                            state <= IDLE;
                        elsif spi_sck_rising = '1' then
                            addr_shift <= addr_shift(6 downto 0) & spi_mosi_sync2;
                            bit_count <= bit_count + 1;

                            if bit_count = 7 then
                                addr_complete := addr_shift(6 downto 0) & spi_mosi_sync2;
                                addr_byte <= addr_complete;
                                bit_count <= 0;

                                -- Determine next state based on command
                                if cmd_byte_int = CMD_READ then
                                    -- For reads, we need to wait for data_rd to be available
                                    -- addr_byte will be valid next cycle (combinational)
                                    -- data_rd will be valid the cycle after that (sequential read)
                                    -- So we stay in RECEIVE_ADDR for one more cycle
                                    state <= SEND_DATA;
                                    is_read <= '1';

                                elsif cmd_byte_int = CMD_WRITE then
                                    data_shift <= (others => '0');
                                    state <= RECEIVE_DATA;
                                    is_write <= '1';

                                else
                                    state <= IDLE;
                                end if;
                            end if;
                        end if;
                    
                    when SEND_DATA =>
                        if spi_cs_n_sync2 = '1' then
                            state <= IDLE;
                            transaction_complete <= '1';
                        else
                            -- Setup phase: load data unconditionally, ignore falling edges
                            if bit_count = 0 then
                                -- First cycle: wait for addr_byte->data_rd pipeline
                                bit_count <= 1;
                            elsif bit_count = 1 then
                                -- Second cycle: data_rd is now valid, load it
                                data_shift <= data_rd;
                                bit_count <= 2;
                            -- After setup: respond to falling edges only
                            elsif bit_count >= 2 then
                                if spi_sck_falling = '1' then
                                    if bit_count = 2 then
                                        -- Skip address byte's trailing falling edge
                                        bit_count <= 3;
                                    elsif bit_count >= 3 then
                                        -- Shift data on falling edge (MSB first)
                                        data_shift <= data_shift(30 downto 0) & '0';
                                        bit_count <= bit_count + 1;

                                        if bit_count = 34 then
                                            transaction_complete <= '1';
                                            state <= IDLE;
                                        end if;
                                    end if;
                                end if;
                            end if;
                        end if;
                    
                    when RECEIVE_DATA =>
                        if spi_cs_n_sync2 = '1' then
                            state <= IDLE;
                            transaction_complete <= '1';
                        elsif spi_sck_rising = '1' then
                            data_shift <= data_shift(30 downto 0) & spi_mosi_sync2;
                            bit_count <= bit_count + 1;
                            
                            if bit_count = 31 then
                                transaction_complete <= '1';
                                state <= IDLE;
                            end if;
                        end if;
                    
                    when others =>
                        state <= IDLE;
                        
                end case;
            end if;
        end if;
    end process;
    
    -- Direct output connection for cmd_byte (addr_byte used directly in process)
    cmd_byte <= cmd_byte_int;

    -- Capture write data on transaction complete
    process(clk)
    begin
        if rising_edge(clk) then
            if state = RECEIVE_DATA and bit_count = 31 and spi_sck_rising = '1' then
                data_wr <= data_shift(30 downto 0) & spi_mosi_sync2;
            end if;
        end if;
    end process;

end Behavioral;

