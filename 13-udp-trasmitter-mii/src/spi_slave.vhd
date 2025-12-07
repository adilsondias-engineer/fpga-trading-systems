----------------------------------------------------------------------------------
-- SPI Slave Wrapper (Backward Compatibility)
-- This module wraps spi_register_if to maintain the original interface
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity spi_slave is
    Port (
        -- System clock (100 MHz)
        clk         : in  std_logic;
        reset       : in  std_logic;
        
        -- SPI interface (from PY32F030)
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
end spi_slave;

architecture Behavioral of spi_slave is
begin
    
    -- Instantiate register interface module
    spi_reg_if_inst : entity work.spi_register_if
        port map (
            clk                 => clk,
            reset               => reset,
            spi_sck             => spi_sck,
            spi_mosi            => spi_mosi,
            spi_miso            => spi_miso,
            spi_cs_n            => spi_cs_n,
            order_count_in      => order_count_in,
            bbo_count_in        => bbo_count_in,
            latency_p50_in      => latency_p50_in,
            symbol_enable_out   => symbol_enable_out,
            threshold_out       => threshold_out,
            debug_state         => debug_state,
            uart_debug_tx_data  => uart_debug_tx_data,
            uart_debug_tx_start => uart_debug_tx_start,
            uart_debug_tx_busy  => uart_debug_tx_busy
        );

end Behavioral;
