----------------------------------------------------------------------------------
-- SPI Register Interface Module
-- Translates SPI transactions to register reads/writes
-- Implements the register map for FPGA status and configuration
--
-- Register Map:
--   0x00: ORDER_COUNT  (32-bit, read-only) - Total orders processed
--   0x01: BBO_COUNT    (32-bit, read-only) - BBO updates generated
--   0x02: LATENCY_P50  (32-bit, read-only) - P50 latency in nanoseconds
--   0x03: STATUS       (32-bit, read-only) - Status flags (bit 0: running)
--   0x04: SYMBOL_EN    (8-bit, read-write) - Symbol enable mask (8 symbols)
--   0x05: THRESHOLD    (32-bit, read-write) - BBO spread threshold
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_register_if is
    Port (
        -- System clock (100 MHz)
        clk         : in  std_logic;
        reset       : in  std_logic;
        
        -- SPI interface (from master)
        spi_sck     : in  std_logic;
        spi_mosi    : in  std_logic;
        spi_miso    : out std_logic;
        spi_cs_n    : in  std_logic;
        
        -- Status inputs (from order book)
        order_count_in    : in  std_logic_vector(31 downto 0);
        bbo_count_in      : in  std_logic_vector(31 downto 0);
        latency_p50_in    : in  std_logic_vector(31 downto 0);
        
        -- Configuration outputs (to order book)
        symbol_enable_out : out std_logic_vector(7 downto 0);
        threshold_out     : out std_logic_vector(31 downto 0);
        
        -- Debug
        debug_state : out std_logic_vector(2 downto 0);
        
        -- UART Debug Output (TEMPORARY - for debugging SPI issues)
        uart_debug_tx_data  : out std_logic_vector(7 downto 0);
        uart_debug_tx_start : out std_logic;
        uart_debug_tx_busy  : in  std_logic
    );
end spi_register_if;

architecture Behavioral of spi_register_if is
    
    -- SPI core interface signals
    signal cmd_byte            : std_logic_vector(7 downto 0);
    signal addr_byte           : std_logic_vector(7 downto 0);
    signal data_rd             : std_logic_vector(31 downto 0);
    signal data_wr             : std_logic_vector(31 downto 0);
    signal transaction_complete : std_logic;
    signal is_read             : std_logic;
    signal is_write            : std_logic;
    
    -- Register bank
    type reg_array_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal registers : reg_array_t := (others => (others => '0'));
    
    -- Register addresses
    constant REG_ORDER_COUNT  : integer := 0;
    constant REG_BBO_COUNT    : integer := 1;
    constant REG_LATENCY_P50  : integer := 2;
    constant REG_STATUS       : integer := 3;
    constant REG_SYMBOL_EN    : integer := 4;
    constant REG_THRESHOLD    : integer := 5;
    
    -- UART Debug signals (TEMPORARY)
    type uart_debug_state_t is (IDLE, SEND_CMD, SEND_ADDR, SEND_DATA_BYTE0, SEND_DATA_BYTE1, SEND_DATA_BYTE2, SEND_DATA_BYTE3, SEND_CR, SEND_LF);
    signal uart_debug_state : uart_debug_state_t := IDLE;
    signal uart_debug_char_index : integer range 0 to 15 := 0;
    signal uart_debug_tx_start_int : std_logic := '0';
    signal uart_debug_cmd_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_debug_addr_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_debug_data_word : std_logic_vector(31 downto 0) := (others => '0');
    signal uart_debug_trigger : std_logic := '0';
    signal uart_debug_trigger_prev : std_logic := '0';
    signal transaction_complete_prev : std_logic := '0';
    
    -- Function to convert nibble to hex ASCII
    function nibble_to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        if unsigned(nibble) < 10 then
            result := std_logic_vector(to_unsigned(to_integer(unsigned(nibble)) + 48, 8));
        else
            result := std_logic_vector(to_unsigned(to_integer(unsigned(nibble)) + 55, 8));
        end if;
        return result;
    end function;
    
begin
    
    -- ========================================================================
    -- Instantiate Generic SPI Slave Core
    -- ========================================================================
    spi_core_inst : entity work.spi_slave_core
        port map (
            clk                 => clk,
            reset               => reset,
            spi_sck             => spi_sck,
            spi_mosi            => spi_mosi,
            spi_miso            => spi_miso,
            spi_cs_n            => spi_cs_n,
            cmd_byte            => cmd_byte,
            addr_byte           => addr_byte,
            data_rd             => data_rd,
            data_wr             => data_wr,
            transaction_complete => transaction_complete,
            is_read             => is_read,
            is_write            => is_write
        );
    
    -- ========================================================================
    -- Register Read Logic
    -- ========================================================================
    process(clk)
        variable reg_addr : unsigned(3 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                data_rd <= (others => '0');
            else
                -- Read register based on address
                reg_addr := unsigned(addr_byte(3 downto 0));
                if reg_addr < 6 then
                    data_rd <= registers(to_integer(reg_addr));
                else
                    data_rd <= (others => '0');
                end if;
            end if;
        end if;
    end process;
    
    -- ========================================================================
    -- Register Write Logic
    -- ========================================================================
    process(clk)
        variable reg_addr : unsigned(3 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Default values for configuration registers
                registers(REG_SYMBOL_EN) <= x"000000FF";  -- All symbols enabled
                registers(REG_THRESHOLD) <= x"000003E8";  -- 1000 (0x3E8) default threshold
            else
                if transaction_complete = '1' and is_write = '1' then
                    reg_addr := unsigned(addr_byte(3 downto 0));
                    if reg_addr = REG_SYMBOL_EN then
                        registers(REG_SYMBOL_EN)(7 downto 0) <= data_wr(7 downto 0);
                    elsif reg_addr = REG_THRESHOLD then
                        registers(REG_THRESHOLD) <= data_wr;
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    -- ========================================================================
    -- Register Bank Update (read-only registers)
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                registers(REG_ORDER_COUNT) <= (others => '0');
                registers(REG_BBO_COUNT)   <= (others => '0');
                registers(REG_LATENCY_P50) <= (others => '0');
                registers(REG_STATUS)      <= (others => '0');
            else
                -- Connect to actual input signals
                registers(REG_ORDER_COUNT) <= order_count_in;
                registers(REG_BBO_COUNT)   <= bbo_count_in;
                registers(REG_LATENCY_P50) <= latency_p50_in;
                registers(REG_STATUS)(0) <= '1';  -- Running flag
                registers(REG_STATUS)(1) <= '0';  -- Reserved
                registers(REG_STATUS)(31 downto 2) <= (others => '0');
            end if;
        end if;
    end process;
    
    -- Output configuration registers
    symbol_enable_out <= registers(REG_SYMBOL_EN)(7 downto 0);
    threshold_out <= registers(REG_THRESHOLD);
    
    -- Debug state (from SPI core - not used here, pass through)
    debug_state <= "000";
    
    -- ========================================================================
    -- UART Debug Output (TEMPORARY)
    -- ========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                uart_debug_state <= IDLE;
                uart_debug_tx_start_int <= '0';
                uart_debug_tx_data <= (others => '0');
                uart_debug_trigger <= '0';
                uart_debug_trigger_prev <= '0';
                transaction_complete_prev <= '0';
            else
                transaction_complete_prev <= transaction_complete;
                uart_debug_trigger_prev <= uart_debug_trigger;
                
                -- Detect transaction completion
                if transaction_complete = '1' and transaction_complete_prev = '0' then
                    uart_debug_trigger <= not uart_debug_trigger;
                    uart_debug_cmd_byte <= cmd_byte;
                    uart_debug_addr_byte <= addr_byte;
                    if is_read = '1' then
                        uart_debug_data_word <= data_rd;
                    elsif is_write = '1' then
                        uart_debug_data_word <= data_wr;
                    end if;
                end if;
                
                -- UART debug state machine (same as before)
                case uart_debug_state is
                    when IDLE =>
                        uart_debug_tx_start_int <= '0';
                        if uart_debug_trigger /= uart_debug_trigger_prev then
                            uart_debug_state <= SEND_CMD;
                            uart_debug_char_index <= 0;
                        end if;
                    
                    when SEND_CMD =>
                        if uart_debug_tx_busy = '0' then
                            case uart_debug_char_index is
                                when 0 => uart_debug_tx_data <= x"53"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 1;
                                when 1 => uart_debug_tx_data <= x"50"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 2;
                                when 2 => uart_debug_tx_data <= x"49"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 3;
                                when 3 => uart_debug_tx_data <= x"3A"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 4;
                                when 4 => uart_debug_tx_data <= x"20"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 5;
                                when 5 => uart_debug_tx_data <= x"43"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 6;
                                when 6 => uart_debug_tx_data <= x"4D"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 7;
                                when 7 => uart_debug_tx_data <= x"44"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 8;
                                when 8 => uart_debug_tx_data <= x"3D"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 9;
                                when 9 => uart_debug_tx_data <= nibble_to_hex(uart_debug_cmd_byte(7 downto 4)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 10;
                                when 10 => uart_debug_tx_data <= nibble_to_hex(uart_debug_cmd_byte(3 downto 0)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_ADDR; uart_debug_char_index <= 0;
                                when others => null;
                            end case;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_ADDR =>
                        if uart_debug_tx_busy = '0' then
                            case uart_debug_char_index is
                                when 0 => uart_debug_tx_data <= x"20"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 1;
                                when 1 => uart_debug_tx_data <= x"41"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 2;
                                when 2 => uart_debug_tx_data <= x"44"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 3;
                                when 3 => uart_debug_tx_data <= x"52"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 4;
                                when 4 => uart_debug_tx_data <= x"3D"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 5;
                                when 5 => uart_debug_tx_data <= nibble_to_hex(uart_debug_addr_byte(7 downto 4)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 6;
                                when 6 => uart_debug_tx_data <= nibble_to_hex(uart_debug_addr_byte(3 downto 0)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_DATA_BYTE0; uart_debug_char_index <= 0;
                                when others => null;
                            end case;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_DATA_BYTE0 =>
                        if uart_debug_tx_busy = '0' then
                            case uart_debug_char_index is
                                when 0 => uart_debug_tx_data <= x"20"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 1;
                                when 1 => uart_debug_tx_data <= x"44"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 2;
                                when 2 => uart_debug_tx_data <= x"41"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 3;
                                when 3 => uart_debug_tx_data <= x"54"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 4;
                                when 4 => uart_debug_tx_data <= x"41"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 5;
                                when 5 => uart_debug_tx_data <= x"3D"; uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 6;
                                when 6 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(31 downto 28)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 7;
                                when 7 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(27 downto 24)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_DATA_BYTE1; uart_debug_char_index <= 0;
                                when others => null;
                            end case;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_DATA_BYTE1 =>
                        if uart_debug_tx_busy = '0' then
                            uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(23 downto 20)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_DATA_BYTE2;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_DATA_BYTE2 =>
                        if uart_debug_tx_busy = '0' then
                            uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(19 downto 16)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_DATA_BYTE3;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_DATA_BYTE3 =>
                        if uart_debug_tx_busy = '0' then
                            case uart_debug_char_index is
                                when 0 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(15 downto 12)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 1;
                                when 1 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(11 downto 8)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 2;
                                when 2 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(7 downto 4)); uart_debug_tx_start_int <= '1'; uart_debug_char_index <= 3;
                                when 3 => uart_debug_tx_data <= nibble_to_hex(uart_debug_data_word(3 downto 0)); uart_debug_tx_start_int <= '1'; uart_debug_state <= SEND_CR; uart_debug_char_index <= 0;
                                when others => null;
                            end case;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_CR =>
                        if uart_debug_tx_busy = '0' then
                            uart_debug_tx_data <= x"0D";
                            uart_debug_tx_start_int <= '1';
                            uart_debug_state <= SEND_LF;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                    
                    when SEND_LF =>
                        if uart_debug_tx_busy = '0' then
                            uart_debug_tx_data <= x"0A";
                            uart_debug_tx_start_int <= '1';
                            uart_debug_state <= IDLE;
                        else
                            uart_debug_tx_start_int <= '0';
                        end if;
                end case;
            end if;
        end if;
    end process;
    
    uart_debug_tx_start <= uart_debug_tx_start_int;

end Behavioral;

