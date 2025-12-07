----------------------------------------------------------------------------------
-- MII Ethernet Receiver - Top Level
-- Arty A7-100 with TI DP83848J PHY (MII Interface)
-- 
-- Receives Ethernet frames via MII interface and displays statistics on LEDs
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.itch_msg_pkg.all;
use work.order_book_pkg.all;

library UNISIM;
use UNISIM.VComponents.all;

entity mii_eth_top is
    Generic (
        BUILD_VERSION : integer := 0  -- Auto-incremented by build script
    );
    Port (
        -- System Clock (100 MHz)
        CLK        : in  STD_LOGIC;
        
        -- Reset button (active HIGH when pressed per Arty manual)
        reset_btn  : in  STD_LOGIC;
        reset_n    : in  STD_LOGIC;  -- Active-low CPU reset button

        -- Buttons (active low on Arty A7)
        debug_btn  : in STD_LOGIC;   -- BTN3 for debug mode
        -- MII Interface to PHY
        eth_ref_clk : out STD_LOGIC;                      -- 25 MHz reference to PHY
        eth_rstn    : out STD_LOGIC;                      -- Reset to PHY (active LOW)
        eth_rx_clk  : in  STD_LOGIC;                      -- RX clock from PHY (25 MHz)
        eth_rxd     : in  STD_LOGIC_VECTOR(3 downto 0);  -- RX data from PHY
        eth_rx_dv   : in  STD_LOGIC;                      -- RX data valid from PHY
        eth_rx_er   : in  STD_LOGIC;                      -- RX error from PHY
        eth_tx_clk  : in  STD_LOGIC;                      -- TX clock from PHY (25 MHz)
        eth_txd     : out STD_LOGIC_VECTOR(3 downto 0);  -- TX data to PHY
        eth_tx_en   : out STD_LOGIC;                      -- TX enable to PHY
        eth_col     : in  STD_LOGIC;                      -- Collision detect
        eth_crs     : in  STD_LOGIC;                      -- Carrier sense
        eth_mdc     : out STD_LOGIC;                      -- MDIO clock (optional)
        eth_mdio    : inout STD_LOGIC;                    -- MDIO data (optional)
        
        -- LEDs
        led         : out STD_LOGIC_VECTOR(3 downto 0);  -- Frame counter
        led_rgb     : out std_logic_vector(8 downto 0);  -- RGB LEDs for status

        -- UART
        uart_txd_in : in STD_LOGIC;              -- RX: PC -> FPGA (confusing naming!)
        uart_rxd_out : out STD_LOGIC;            -- TX: FPGA -> PC
        
        -- SPI Slave Interface (PY32F030)
        spi_sck  : in  STD_LOGIC;   -- SPI clock from PY32
        spi_mosi : in  STD_LOGIC;   -- Master Out Slave In
        spi_miso : out STD_LOGIC;   -- Master In Slave Out
        spi_cs_n : in  STD_LOGIC    -- Chip select (active low)
    );
end mii_eth_top;

architecture structural of mii_eth_top is

    -- Clock generation signals
    signal clk_25mhz_unbuf : STD_LOGIC;
    signal clk_25mhz       : STD_LOGIC;
    signal pll_locked      : STD_LOGIC;
    signal pll_clkfb       : STD_LOGIC;
    
    -- PHY reset generation
    signal reset_counter   : unsigned(23 downto 0) := (others => '0');
    signal phy_reset_n     : STD_LOGIC := '0';
    signal phy_ready       : STD_LOGIC := '0';
    
    -- Interconnect signals
    signal rx_data         : STD_LOGIC_VECTOR(7 downto 0);
    signal rx_valid        : STD_LOGIC;
    signal rx_error        : STD_LOGIC;
    signal frame_start     : STD_LOGIC;
    signal frame_end       : STD_LOGIC;
    signal frame_valid     : STD_LOGIC;
    signal frame_valid_sync1 : STD_LOGIC := '0';
    signal frame_valid_sync2 : STD_LOGIC := '0';
    
    -- MAC address
    constant MY_MAC_ADDR : STD_LOGIC_VECTOR(47 downto 0) := x"00183E045DE7"; -- x"000A3502AF9A";
    constant PHY_ADDR    : std_logic_vector(4 downto 0) := "00001";  -- DP83848J address
    constant CLK_FREQ_HZ : integer := 100_000_000;  -- 100 MHz system clock

    -- ITCH UDP port filtering (defense in depth)
    constant ITCH_UDP_PORT : unsigned(15 downto 0) := to_unsigned(12345, 16);


    -- Reset signals
    signal mdio_rst    : std_logic;
    signal reset_sync  : std_logic_vector(2 downto 0) := (others => '1');

    -- MDIO controller interface signals (connect between sequencer and controller)
    signal mdio_start      : std_logic := '0';
    signal mdio_busy       : std_logic;
    signal mdio_done       : std_logic;
    signal mdio_rw         : std_logic := '0';
    signal mdio_phy_addr   : std_logic_vector(4 downto 0) := PHY_ADDR;
    signal mdio_reg_addr   : std_logic_vector(4 downto 0) := (others => '0');
    signal mdio_write_data : std_logic_vector(15 downto 0) := (others => '0');
    signal mdio_read_data  : std_logic_vector(15 downto 0);

    -- MDIO physical interface signals (tristate buffer)
    signal mdio_i : std_logic;
    signal mdio_o : std_logic;
    signal mdio_t : std_logic;

    -- Test sequencer signals
    signal reg_display_sel : std_logic_vector(1 downto 0);
    signal reg_values      : std_logic_vector(63 downto 0);
    signal sequence_active : std_logic;
    
    -- Display signals
    signal current_reg     : std_logic_vector(15 downto 0);

    -- Debug/display control
    signal debug_state_sig : std_logic_vector(3 downto 0);
    signal debug_mode : unsigned(1 downto 0) := "00";
    -- Debug mode controls both LED display and UART output:
    -- "00" = Frame stats on LEDs, BBO formatter on UART (default for Project 9 gateway)
    -- "01" = MDIO debug on LEDs, Debug formatter (MAC/IP/UDP) on UART
    -- "10" = IP protocol on LEDs, ITCH formatter on UART
    -- "11" = ITCH stats on LEDs, Reserved for future use

    -- Intermediate signals to avoid multiple drivers
    signal frame_count_leds : std_logic_vector(3 downto 0);
    signal frame_activity   : std_logic;
    signal stats_error      : std_logic;  -- Error output from stats_counter

    -- Button signals
    signal debug_btn_db: STD_LOGIC;
    signal debug_btn_rise : STD_LOGIC;
    signal debug_btn_fall : STD_LOGIC;
    signal reset_btn_db: STD_LOGIC;
    signal reset_btn_rise : STD_LOGIC;
    signal reset_btn_fall : STD_LOGIC;
    
    -- Reset signal
    signal reset : STD_LOGIC := '0';

    -- UART signals
    signal tx_data : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_start : STD_LOGIC := '0';
    signal tx_busy : STD_LOGIC := '0';

    signal send_second_hex : std_logic := '0';  -- Flag: need to send second hex character
    signal tx_started : std_logic := '0';  -- Flag: transmission has started (tx_busy seen as '1')

        -- Helper function to convert 4-bit nibble to ASCII hex character
    function nibble_to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case nibble is
            when X"0" => return X"30";  -- '0'
            when X"1" => return X"31";  -- '1'
            when X"2" => return X"32";  -- '2'
            when X"3" => return X"33";  -- '3'
            when X"4" => return X"34";  -- '4'
            when X"5" => return X"35";  -- '5'
            when X"6" => return X"36";  -- '6'
            when X"7" => return X"37";  -- '7'
            when X"8" => return X"38";  -- '8'
            when X"9" => return X"39";  -- '9'
            when X"A" => return X"41";  -- 'A'
            when X"B" => return X"42";  -- 'B'
            when X"C" => return X"43";  -- 'C'
            when X"D" => return X"44";  -- 'D'
            when X"E" => return X"45";  -- 'E'
            when X"F" => return X"46";  -- 'F'
            when others => return X"3F";  -- '?'
        end case;
    end function;
    
    -- UART state machine
    type uart_state_type is (
        UART_IDLE,        -- Waiting for data to trasmit
        UART_ECHO_TX,     -- Transmitting echo/response
        UART_IP_INFO      -- IP info
    );
    signal uart_state : uart_state_type := UART_IDLE;
    signal uart_msg_counter: integer range 0 to 5 := 0;
    -- UART formatter signals
    signal uart_fmt_tx_data  : std_logic_vector(7 downto 0);
    signal uart_fmt_tx_start : std_logic;
    signal uart_fmt_tx_busy  : std_logic;

    -- IP Parser input
    signal data_in : std_logic_vector(7 downto 0) := (others => '0');
    signal byte_counter : integer range 0 to 1023 := 0;

    -- IP Parser outputs (25 MHz domain)
    signal ip_valid : std_logic;
    signal ip_src : std_logic_vector(31 downto 0);
    signal ip_dst : std_logic_vector(31 downto 0);
    signal ip_protocol : std_logic_vector(7 downto 0);
    signal ip_total_length : std_logic_vector(15 downto 0);
    signal ip_checksum_ok : std_logic;
    signal ip_version_err : std_logic;
    signal ip_ihl_err : std_logic;
    signal ip_checksum_err : std_logic;
    signal ip_version_ihl_byte : std_logic_vector(7 downto 0);

    -- IP signals synchronized to 100 MHz
    signal ip_valid_sync1, ip_valid_sync2         : std_logic := '0';
    signal ip_protocol_sync1, ip_protocol_sync2   : std_logic_vector(7 downto 0) := (others => '0');
    signal ip_checksum_ok_sync1, ip_checksum_ok_sync2 : std_logic := '0';
    signal ip_version_err_sync1, ip_version_err_sync2 : std_logic := '0';
    signal ip_ihl_err_sync1, ip_ihl_err_sync2 : std_logic := '0';
    signal ip_checksum_err_sync1, ip_checksum_err_sync2 : std_logic := '0';
    signal ip_version_ihl_byte_sync : std_logic_vector(7 downto 0) := (others => '0');
    signal ip_src_sync          : std_logic_vector(31 downto 0) := (others => '0');
    signal ip_dst_sync          : std_logic_vector(31 downto 0) := (others => '0');
    signal ip_total_length_sync : std_logic_vector(15 downto 0) := (others => '0');

    -- Reset synchronizer for 25 MHz domain
    signal mdio_rst_rxclk_sync1, mdio_rst_rxclk_sync2 : std_logic := '1';
    signal mdio_rst_rxclk : std_logic;

    -- MAC parser outputs
    signal mac_data_out    : std_logic_vector(7 downto 0);
    signal mac_dest_match  : std_logic;
    signal mac_byte_counter : unsigned(10 downto 0);

    -- UDP parser outputs (25 MHz domain - eth_rx_clk)
    signal udp_valid       : std_logic;
    signal udp_src_port    : std_logic_vector(15 downto 0);
    signal udp_dst_port    : std_logic_vector(15 downto 0);
    signal udp_length      : std_logic_vector(15 downto 0);
    signal udp_checksum_ok : std_logic;
    signal udp_length_err  : std_logic;
    signal udp_protocol_ok : std_logic;  -- Debug
    signal udp_length_ok   : std_logic;  -- Debug

    -- Debug: capture in_frame when ip_valid pulses
    signal in_frame_at_ip_valid : std_logic := '0';

    -- Synchronized to 100 MHz (clk domain)
    signal udp_valid_sync1, udp_valid_sync2           : std_logic;
    signal udp_src_port_sync                          : std_logic_vector(15 downto 0);
    signal udp_dst_port_sync                          : std_logic_vector(15 downto 0);
    signal udp_length_err_sync1, udp_length_err_sync2 : std_logic;

    -- UDP payload outputs (25 MHz domain - eth_rx_clk)
    signal payload_valid  : std_logic;
    signal payload_data   : std_logic_vector(7 downto 0);
    signal payload_length : std_logic_vector(15 downto 0);
    signal payload_start  : std_logic;
    signal payload_end    : std_logic;

    -- Frame tracking signal
    signal in_frame : std_logic := '0';

    -- Multi-symbol order book signals
    signal bbo_symbol : std_logic_vector(63 downto 0);  
    signal bbo_update : std_logic;
    signal bbo_data : bbo_t;

    -- UDP port filtering signals
    signal port_match : std_logic := '0';  -- Latched flag: does packet match ITCH port?
    signal payload_valid_filtered : std_logic;
    signal payload_start_filtered : std_logic;
    signal payload_end_filtered : std_logic;

    -- Payload capture for debug (capture first 16 bytes)
    type payload_capture_type is array (0 to 15) of std_logic_vector(7 downto 0);
    signal payload_capture : payload_capture_type := (others => (others => '0'));
    signal payload_capture_count : integer range 0 to 16 := 0;
    signal payload_capture_valid : std_logic := '0';
    signal payload_last_byte_index : integer range 0 to 1023 := 0;  -- Track last captured byte_index to prevent duplicates
    signal payload_capture_valid_sync1, payload_capture_valid_sync2 : std_logic := '0';
    signal payload_capture_sync : payload_capture_type := (others => (others => '0'));
    signal payload_capture_vector : std_logic_vector(127 downto 0) := (others => '0');

    -- ITCH parser outputs (25 MHz domain - eth_rx_clk)
    signal itch_msg_valid           : std_logic;
    signal itch_msg_type            : std_logic_vector(7 downto 0);
    signal itch_msg_error           : std_logic;
    signal itch_add_order_valid     : std_logic;
    signal itch_stock_locate        : std_logic_vector(15 downto 0);
    signal itch_tracking_number     : std_logic_vector(15 downto 0);
    signal itch_timestamp           : std_logic_vector(47 downto 0);
    signal itch_order_ref           : std_logic_vector(63 downto 0);
    signal itch_buy_sell            : std_logic;
    signal itch_side                : std_logic;  -- Converted buy_sell to side (0=Buy, 1=Sell)
    signal itch_shares              : std_logic_vector(31 downto 0);
    signal itch_stock_symbol        : std_logic_vector(63 downto 0);
    signal itch_price               : std_logic_vector(31 downto 0);
    signal itch_order_executed_valid: std_logic;
    signal itch_exec_shares         : std_logic_vector(31 downto 0);
    signal itch_match_number        : std_logic_vector(63 downto 0);
    signal itch_order_cancel_valid  : std_logic;
    signal itch_cancel_shares       : std_logic_vector(31 downto 0);
    signal itch_system_event_valid  : std_logic;
    signal itch_event_code          : std_logic_vector(7 downto 0);
    signal itch_stock_directory_valid : std_logic;
    signal itch_financial_status    : std_logic_vector(7 downto 0);
    signal itch_round_lot_size      : std_logic_vector(31 downto 0);
    signal itch_market_category     : std_logic_vector(7 downto 0);
    signal itch_order_delete_valid  : std_logic;
    signal itch_order_replace_valid : std_logic;
    signal itch_trade_valid         : std_logic;
    signal itch_cross_trade_valid   : std_logic;

    -- New message type fields
    signal itch_original_order_ref  : std_logic_vector(63 downto 0);
    signal itch_new_order_ref       : std_logic_vector(63 downto 0);
    signal itch_new_shares          : std_logic_vector(31 downto 0);
    signal itch_new_price           : std_logic_vector(31 downto 0);
    signal itch_trade_price         : std_logic_vector(31 downto 0);
    signal itch_cross_shares        : std_logic_vector(63 downto 0);
    signal itch_cross_price         : std_logic_vector(31 downto 0);
    signal itch_cross_type          : std_logic_vector(7 downto 0);

    -- Symbol filtering statistics (v5)
    signal itch_total_messages      : std_logic_vector(31 downto 0);
    signal itch_filtered_messages   : std_logic_vector(31 downto 0);
    signal itch_symbol_match        : std_logic;

    -- Dummy signal for legacy stats counter (v5: parse_errors removed)
    signal itch_parse_errors        : std_logic_vector(15 downto 0) := (others => '0');

    -- Order Book signals (Project 8 - Multi-symbol)
    signal ob_bbo               : bbo_t;
    signal ob_bbo_update        : std_logic;
    signal ob_bbo_symbol        : std_logic_vector(63 downto 0);  -- Symbol name from multi-symbol wrapper
    signal ob_stats             : order_book_stats_t;
    signal ob_ready             : std_logic;

    -- ITCH formatter signals
    signal itch_uart_tx_data  : std_logic_vector(7 downto 0);
    signal itch_uart_tx_valid : std_logic;
    signal itch_uart_tx_ready : std_logic;  -- Inverse of tx_busy
    signal itch_send_stats    : std_logic := '0';
    
    -- UART multiplexer signals (select between ITCH, debug, BBO formatters, config STATUS, and SPI debug)
    signal uart_tx_data_sel  : std_logic_vector(7 downto 0);
    signal uart_tx_valid_sel : std_logic;
    signal uart_config_tx_data  : std_logic_vector(7 downto 0);
    signal uart_config_tx_start : std_logic;
    signal uart_config_tx_busy  : std_logic;
    signal spi_debug_tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_debug_tx_start : std_logic := '0';
    signal spi_debug_tx_busy  : std_logic := '0';

    -- BBO formatter signals
    signal bbo_uart_tx_data  : std_logic_vector(7 downto 0);
    signal bbo_uart_tx_valid : std_logic;
    signal bbo_uart_tx_ready : std_logic;

    -- BBO CDC synchronizers (25 MHz -> 100 MHz)
    signal ob_bbo_update_sync1 : std_logic := '0';
    signal ob_bbo_update_sync2 : std_logic := '0';
    signal ob_bbo_valid_sync1  : std_logic := '0';
    signal ob_bbo_valid_sync2  : std_logic := '0';
    signal ob_bbo_sync         : bbo_t;
    signal ob_bbo_symbol_sync  : std_logic_vector(63 downto 0);  -- Symbol CDC
    signal ob_stats_sync       : order_book_stats_t;
    
    -- Status tracking for SPI/UART (100 MHz domain)
    signal order_count_reg : unsigned(31 downto 0) := (others => '0');
    signal bbo_count_reg : unsigned(31 downto 0) := (others => '0');
    -- Latency is a static placeholder (not measured yet)
    -- Real latency measurement requires timestamp capture at packet arrival and BBO output
    -- For now, keep as constant placeholder value
    signal latency_p50_reg : unsigned(31 downto 0) := to_unsigned(170, 32);  -- 170 ns placeholder (static, not incremented)
    signal order_count_status : std_logic_vector(31 downto 0);
    signal bbo_count_status   : std_logic_vector(31 downto 0);
    signal latency_p50_status : std_logic_vector(31 downto 0);
    
    -- ITCH message valid synchronizer (25 MHz -> 100 MHz) for order count
    signal itch_msg_valid_sync1 : std_logic := '0';
    signal itch_msg_valid_sync2 : std_logic := '0';
    signal itch_msg_valid_sync3 : std_logic := '0';

    -- ITCH stats counter signals
    signal itch_add_count     : unsigned(31 downto 0) := (others => '0');
    signal itch_exec_count    : unsigned(31 downto 0) := (others => '0');
    signal itch_cancel_count  : unsigned(31 downto 0) := (others => '0');
    signal itch_display_mode  : std_logic_vector(2 downto 0) := "110";  -- Default: activity mode
    signal itch_led_out       : std_logic_vector(3 downto 0);
    signal itch_led_activity  : std_logic;
    signal itch_system_event_count : unsigned(31 downto 0) := (others => '0');
    signal itch_stock_directory_count : unsigned(31 downto 0) := (others => '0');
    -- CDC synchronizers for ITCH parser signals (25 MHz -> 100 MHz)
    signal itch_add_order_valid_sync1 : std_logic := '0';
    signal itch_add_order_valid_sync2 : std_logic := '0';
    signal itch_order_executed_valid_sync1 : std_logic := '0';
    signal itch_order_executed_valid_sync2 : std_logic := '0';
    signal itch_order_cancel_valid_sync1 : std_logic := '0';
    signal itch_order_cancel_valid_sync2 : std_logic := '0';
    signal itch_system_event_valid_sync1 : std_logic := '0';
    signal itch_system_event_valid_sync2 : std_logic := '0';
    signal itch_stock_directory_valid_sync1 : std_logic := '0';
    signal itch_stock_directory_valid_sync2 : std_logic := '0';

    -- Async FIFO signals (CDC boundary: 25 MHz -> 100 MHz)
    -- Write side (25 MHz domain - eth_rx_clk)
    signal fifo_wr_en   : std_logic;
    signal fifo_wr_data : std_logic_vector(MSG_FIFO_WIDTH-1 downto 0);
    signal fifo_wr_full : std_logic;

    -- Read side (100 MHz domain - clk)
    signal fifo_rd_en   : std_logic;
    signal fifo_rd_data : std_logic_vector(MSG_FIFO_WIDTH-1 downto 0);
    signal fifo_rd_empty : std_logic;

    -- Decoded message signals from decoder (100 MHz domain)
    signal decoded_msg_type       : msg_type_t;
    signal decoded_order_ref      : std_logic_vector(63 downto 0);
    signal decoded_buy_sell       : std_logic;
    signal decoded_shares         : std_logic_vector(31 downto 0);
    signal decoded_stock_symbol   : std_logic_vector(63 downto 0);
    signal decoded_price          : std_logic_vector(31 downto 0);
    signal decoded_stock_locate   : std_logic_vector(15 downto 0);
    signal decoded_tracking_number: std_logic_vector(15 downto 0);
    signal decoded_timestamp      : std_logic_vector(47 downto 0);
    signal decoded_match_number   : std_logic_vector(63 downto 0);
    signal decoded_event_code     : std_logic_vector(7 downto 0);
    signal decoded_market_category: std_logic_vector(7 downto 0);
    signal decoded_financial_status: std_logic_vector(7 downto 0);
    signal decoded_round_lot_size : std_logic_vector(31 downto 0);
    signal decoded_original_order_ref : std_logic_vector(63 downto 0);
    signal decoded_new_order_ref  : std_logic_vector(63 downto 0);
    signal decoded_new_shares     : std_logic_vector(31 downto 0);
    signal decoded_new_price      : std_logic_vector(31 downto 0);
    signal decoded_trade_price    : std_logic_vector(31 downto 0);
    signal decoded_cross_shares   : std_logic_vector(63 downto 0);
    signal decoded_cross_price    : std_logic_vector(31 downto 0);
    signal decoded_cross_type     : std_logic_vector(7 downto 0);

    -- Encoder overflow diagnostics (25 MHz domain)
    signal encoder_overflow_error : std_logic;
    signal encoder_overflow_count : std_logic_vector(15 downto 0);

    -- Encoder overflow synchronized to 100 MHz domain
    signal encoder_overflow_sync1 : std_logic := '0';
    signal encoder_overflow_sync2 : std_logic := '0';
    signal encoder_overflow_latch : std_logic := '0';  -- Latched until reset

    -- ========================================================================
    -- UDP TX Signals (SystemVerilog eth_udp_send module)
    -- ========================================================================
    -- BBO UDP formatter signals
    signal udp_wr_en   : std_logic;
    signal udp_wr_d    : std_logic_vector(3 downto 0);
    signal udp_wr_busy : std_logic;
    signal udp_packets_sent : std_logic_vector(31 downto 0);

    -- eth_udp_send module signals
    signal udp_tx_busy : std_logic;  -- mac_busy from eth_udp_send
    signal udp_tx_rdy  : std_logic;  -- rdy from eth_udp_send

    -- ========================================================================
    -- UART RX and Configuration Signals
    -- ========================================================================
    signal uart_rx_data  : std_logic_vector(7 downto 0);
    signal uart_rx_valid : std_logic;

    -- Dynamic UDP configuration (from UART commands)
    signal cfg_dst_ip   : std_logic_vector(31 downto 0);
    signal cfg_dst_mac  : std_logic_vector(47 downto 0);
    signal cfg_dst_port : std_logic_vector(15 downto 0);
    signal cfg_updated  : std_logic;

        -- Shared configuration registers (from UART or SPI)
    signal threshold_config     : std_logic_vector(31 downto 0);
    signal symbol_enable_config : std_logic_vector(7 downto 0);

begin

    -- =========================================================================
    -- UART Module Instantiation
    -- =========================================================================
    -- Instantiate UART transmitter
    uart_tx_inst : entity work.uart_tx
        port map (
            clk => clk,
            reset => reset,
            tx_data   => uart_tx_data_sel,    -- FROM multiplexer
            tx_start  => uart_tx_valid_sel,  -- FROM multiplexer
            tx_busy   => uart_fmt_tx_busy,    -- TO both formatters
            tx_serial => uart_rxd_out          -- Note: confusing Xilinx naming!
        );

    -- Instantiate UART receiver
    uart_rx_inst : entity work.uart_rx
        generic map (
            CLK_FREQ => 100_000_000,
            BAUD_RATE => 115_200
        )
        port map (
            clk => clk,
            reset => reset,
            rx_serial => uart_txd_in,      -- Note: confusing Xilinx naming!
            rx_data => uart_rx_data,
            rx_valid => uart_rx_valid
        );


    
    -- Instantiate UART configuration module (Extended for Project 21)
    uart_config_inst : entity work.uart_config
        generic map (
            DEFAULT_IP   => x"C0A8005D",        -- 192.168.0.93
            DEFAULT_MAC  => x"FFFFFFFFFFFF",    -- Broadcast
            DEFAULT_PORT => x"1388"             -- 5000
        )
        port map (
            clk => clk,
            rst => reset,
            rx_data  => uart_rx_data,
            rx_valid => uart_rx_valid,
            dst_ip   => cfg_dst_ip,
            dst_mac  => cfg_dst_mac,
            dst_port => cfg_dst_port,
            threshold_out     => threshold_config,
            symbol_enable_out => symbol_enable_config,
            order_count_in  => order_count_status,
            bbo_count_in    => bbo_count_status,
            latency_p50_in  => latency_p50_status,
            uart_tx_data  => uart_config_tx_data,
            uart_tx_start => uart_config_tx_start,
            uart_tx_busy  => uart_config_tx_busy,
            config_updated => cfg_updated
        );
    
    -- Instantiate SPI Slave (PY32F030 interface)
    spi_slave_inst : entity work.spi_slave
        port map (
            clk                 => clk,
            reset               => reset,
            spi_sck             => spi_sck,
            spi_mosi            => spi_mosi,
            spi_miso            => spi_miso,
            spi_cs_n            => spi_cs_n,
            order_count_in      => order_count_status,
            bbo_count_in        => bbo_count_status,
            latency_p50_in      => latency_p50_status,
            symbol_enable_out   => open,  -- Use UART version (priority)
            threshold_out       => open,  -- Use UART version (priority)
            debug_state         => open,
            uart_debug_tx_data  => spi_debug_tx_data,
            uart_debug_tx_start => spi_debug_tx_start,
            uart_debug_tx_busy  => spi_debug_tx_busy
        );

    -- =========================================================================
    -- UART Multiplexer: Switch between BBO, Debug, ITCH formatters, Config STATUS, and SPI Debug
    -- =========================================================================
    -- Priority: STATUS response > debug_mode selection
    -- debug_mode = "00": BBO formatter (default for Project 9 gateway)
    -- debug_mode = "01": Debug formatter (MAC/IP/UDP frame info)
    -- debug_mode = "10": ITCH formatter (for ITCH message debugging)
    -- debug_mode = "11": SPI debug formatter (TEMPORARY - for debugging SPI issues)
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                uart_tx_data_sel <= (others => '0');
                uart_tx_valid_sel <= '0';
            else
                -- Priority: STATUS response (from uart_config) has highest priority
                if uart_config_tx_start = '1' then
                    -- STATUS response is being sent
                    uart_tx_data_sel <= uart_config_tx_data;
                    uart_tx_valid_sel <= uart_config_tx_start;
                elsif debug_mode = "01" then
                    -- Debug mode 1: Use debug formatter (MAC/IP/UDP info)
                    uart_tx_data_sel <= uart_fmt_tx_data;
                    uart_tx_valid_sel <= uart_fmt_tx_start;
                elsif debug_mode = "10" then
                    -- Debug mode 2: Use ITCH formatter (ITCH message debugging)
                    uart_tx_data_sel <= itch_uart_tx_data;
                    uart_tx_valid_sel <= itch_uart_tx_valid;
                elsif debug_mode = "11" then
                    -- Debug mode 3: Use SPI debug formatter (TEMPORARY)
                    uart_tx_data_sel <= spi_debug_tx_data;
                    uart_tx_valid_sel <= spi_debug_tx_start;
                else
                    -- Default mode "00": Use BBO formatter
                    uart_tx_data_sel <= bbo_uart_tx_data;
                    uart_tx_valid_sel <= bbo_uart_tx_valid;
                end if;

            end if;
        end if;
    end process;
    
    -- Wire UART TX busy signal back to uart_config and SPI debug
    uart_config_tx_busy <= uart_fmt_tx_busy;
    spi_debug_tx_busy <= uart_fmt_tx_busy;

    -- UART message formatter
    uart_fmt_inst: entity work.uart_formatter
        generic map (
            CLK_FREQ => 100_000_000
        )
        port map (
        clk   => clk,
        reset => reset,
        
        -- Packet triggers (use synchronized signals)
        frame_valid => frame_valid_sync2,
        ip_valid    => ip_valid_sync2,
        udp_valid   => udp_valid_sync2,
        
        -- IP packet info (use synchronized signals)
        ip_protocol     => ip_protocol_sync2,
        ip_src          => ip_src_sync,
        ip_dst          => ip_dst_sync,
        ip_total_length => ip_total_length_sync,
        ip_checksum_ok  => ip_checksum_ok_sync2,

        -- IP error signals (for debugging)
        ip_version_err  => ip_version_err_sync2,
        ip_ihl_err      => ip_ihl_err_sync2,
        ip_checksum_err => ip_checksum_err_sync2,
        ip_version_ihl_byte => ip_version_ihl_byte_sync,

        -- UDP packet info (use synchronized signals)
        udp_src_port    => udp_src_port_sync,
        udp_dst_port    => udp_dst_port_sync,
        udp_length      => udp_length,       -- Already stable when udp_valid
        udp_checksum_ok => udp_checksum_ok,  -- Already stable when udp_valid
        udp_length_err  => udp_length_err_sync2,
        udp_protocol_ok => udp_protocol_ok,  -- Debug
        udp_length_ok   => udp_length_ok,    -- Debug
        in_frame_at_ip_valid => in_frame_at_ip_valid,  -- Debug
        
        -- Payload capture for debug (128-bit vector)
        payload_capture => payload_capture_vector,
        payload_capture_valid => payload_capture_valid_sync2,

        -- UART TX interface
        tx_data  => uart_fmt_tx_data,
        tx_start => uart_fmt_tx_start,
        tx_busy  => uart_fmt_tx_busy  -- Shared with ITCH formatter via multiplexer
    );
    -- =========================================================================
    -- Button Debouncing and Edge Detection
    -- =========================================================================

    -- Reset button (active low on Arty A7)
    reset_btn_debouncer: entity work.button_debouncer
        generic map (
            CLK_FREQ => 100_000_000,
            DEBOUNCE_MS => 20
        )
        port map (
            clk => clk,
            btn_in => reset_btn,
            btn_out => reset_btn_db
        );

    reset_btn_edge: entity work.edge_detector
        port map (
            clk => clk,
            sig_in => reset_btn_db,
            rising => reset_btn_rise,
            falling => reset_btn_fall
        );

    -- Debug button (BTN3) debouncing and edge detection
    debug_btn_debouncer: entity work.button_debouncer
        generic map (
            CLK_FREQ => 100_000_000,
            DEBOUNCE_MS => 20
        )
        port map (
            clk => clk,
            btn_in => debug_btn,
            btn_out => debug_btn_db
        );

    debug_btn_edge: entity work.edge_detector
        port map (
            clk => clk,
            sig_in => debug_btn_db,
            rising => debug_btn_rise,
            falling => debug_btn_fall
        );

    -- Debug mode control: Toggle on BTN3 press
    -- Cycles: 00 -> 01 -> 10 -> 11 -> 00 (4 modes)
    process(clk)
    begin
        if rising_edge(clk) then
           if debug_btn_rise = '1' then
                if debug_mode = "10" then
                    debug_mode <= "00";  -- Wrap around after mode 2 (ITCH mode)
                else
                    debug_mode <= debug_mode + 1;
                end if;
           end if;
        end if;
    end process;
    ------------------------------------------------------------------------
    -- Reset synchronization (active high internally)
    -- MDIO reset generation based on reset button and CPU reset
    ------------------------------------------------------------------------
    process(CLK)
    begin
        if rising_edge(CLK) then
            if reset_btn_rise = '1' then
                reset <= '1';  -- Assert reset for one cycle
            else
                reset <= '0';
            end if;
            reset_sync <= reset_sync(1 downto 0) & (not reset_n);

       end if;

    end process;
    
    mdio_rst <= reset or reset_sync(2);

    ------------------------------------------------------------------------
    -- MDIO Sequencer Instance
    ------------------------------------------------------------------------
    mdio_seq_inst : entity work.mdio_phy_monitor
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            PHY_ADDR    => PHY_ADDR
        )
        port map (
            clk             => CLK,
            reset           => mdio_rst,
            mdio_start      => mdio_start,
            mdio_busy       => mdio_busy,
            mdio_done       => mdio_done,
            mdio_rw         => mdio_rw,
            mdio_phy_addr   => mdio_phy_addr,
            mdio_reg_addr   => mdio_reg_addr,
            mdio_write_data => mdio_write_data,
            mdio_read_data  => mdio_read_data,
            reg_display_sel => reg_display_sel,
            reg_values      => reg_values,
            sequence_active => sequence_active,
            debug_state     => debug_state_sig  -- Connect to internal signal   
            -- link_up         => link_up,
            -- phy_status_reg  => phy_status_reg
        );

    ------------------------------------------------------------------------
    -- MDIO Tristate Buffer
    -- IOBUF: Single-ended Bi-directional Buffer 7 Series
    -- Xilinx HDL Language Template, version 2025.1
    ------------------------------------------------------------------------
    mdio_iobuf : IOBUF
    port map (
        IO => eth_mdio,  -- Buffer inout port (connect to top-level port)
        O  => mdio_i,    -- Buffer output (from pad to FPGA)
        I  => mdio_o,    -- Buffer input (from FPGA to pad)
        T  => mdio_t     -- 3-state enable ('1' = high-Z/input, '0' = drive output)
    );

    -- End of mdio_iobuf instantiation
    ----------------------------------------------------------------------------------
    -- Clock Generation: 100 MHz -> 25 MHz Reference Clock for PHY
    -- Using PLLE2_BASE (simpler than MMCM for this application)
    ----------------------------------------------------------------------------------
    
    ref_clock_gen : PLLE2_BASE
        generic map (
            BANDWIDTH        => "OPTIMIZED",
            CLKFBOUT_MULT    => 8,           -- 100 MHz × 8 = 800 MHz (VCO)
            CLKOUT0_DIVIDE   => 32,          -- 800 MHz ÷ 32 = 25 MHz
            CLKIN1_PERIOD    => 10.0,        -- 100 MHz input (10 ns period)
            DIVCLK_DIVIDE    => 1,
            STARTUP_WAIT     => "FALSE"
        )
        port map (
            CLKIN1   => CLK,
            CLKOUT0  => clk_25mhz_unbuf,
            LOCKED   => pll_locked,
            PWRDWN   => '0',
            RST      => '0',
            CLKFBOUT => pll_clkfb,
            CLKFBIN  => pll_clkfb
        );
    
    -- Buffer 25 MHz clock
    ref_clk_bufg : BUFG
        port map (
            I => clk_25mhz_unbuf,
            O => clk_25mhz
        );
    
    -- Drive reference clock to PHY
    eth_ref_clk <= clk_25mhz;
    


    ------------------------------------------------------------------------
    -- MDIO Controller
    ------------------------------------------------------------------------
    mdio_ctrl_inst : entity work.mdio_controller
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            MDC_FREQ_HZ => 2_500_000
        )
        port map (
            clk        => CLK,
            reset      => mdio_rst,
            start      => mdio_start,
            rw         => mdio_rw,
            phy_addr   => mdio_phy_addr,
            reg_addr   => mdio_reg_addr,
            write_data => mdio_write_data,
            busy       => mdio_busy,
            done       => mdio_done,
            read_data  => mdio_read_data,
            mdc        => eth_mdc,
            mdio_i     => mdio_i,
            mdio_o     => mdio_o,
            mdio_t     => mdio_t
        );

    ----------------------------------------------------------------------------------
    -- PHY Reset Generation
    -- Minimum 10ms reset pulse (per manual), uses 20ms for margin
    -- Reset is active LOW
    ----------------------------------------------------------------------------------
    
    process(CLK)
    begin
        if rising_edge(CLK) then
            if reset_counter < 2_000_000 then  -- 20ms at 100 MHz
                reset_counter <= reset_counter + 1;
                phy_reset_n   <= '0';  -- Hold PHY in reset
                phy_ready     <= '0';
            else
                phy_reset_n   <= '1';  -- Release reset
                phy_ready     <= '1';  -- PHY is ready
            end if;
        end if;
    end process;
    
    eth_rstn <= phy_reset_n;
    
    ----------------------------------------------------------------------------------
    -- Transmit Interface - Controlled by eth_udp_send module (SystemVerilog)
    ----------------------------------------------------------------------------------
    -- eth_txd and eth_tx_en are connected to eth_udp_send module below
    
    ----------------------------------------------------------------------------------
    -- Reset Synchronizer for 25 MHz domain (eth_rx_clk)
    ----------------------------------------------------------------------------------
    process(eth_rx_clk)
    begin
        if rising_edge(eth_rx_clk) then
            mdio_rst_rxclk_sync1 <= mdio_rst;
            mdio_rst_rxclk_sync2 <= mdio_rst_rxclk_sync1;
        end if;
    end process;

    mdio_rst_rxclk <= mdio_rst_rxclk_sync2;
    
    -- In-frame flag: asserted between frame_start and frame_end (eth_rx_clk domain)
    process(eth_rx_clk)
    begin
        if rising_edge(eth_rx_clk) then
            if mdio_rst_rxclk = '1' then
                in_frame <= '0';
            else
                if frame_start = '1' then
                    in_frame <= '1';
                elsif frame_end = '1' then
                    in_frame <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Debug: Capture in_frame when ip_valid pulses
    process(eth_rx_clk)
    begin
        if rising_edge(eth_rx_clk) then
            if mdio_rst_rxclk = '1' then
                in_frame_at_ip_valid <= '0';
            else
                if ip_valid = '1' then
                    in_frame_at_ip_valid <= in_frame;
                end if;
            end if;
        end if;
    end process;
    
    -- Payload capture: Capture first 16 bytes of UDP payload for debug
    process(eth_rx_clk)
    begin
        if rising_edge(eth_rx_clk) then
            if mdio_rst_rxclk = '1' then
                payload_capture <= (others => (others => '0'));
                payload_capture_count <= 0;
                payload_capture_valid <= '0';
                payload_last_byte_index <= 0;
            else
                -- Clear valid flag after one cycle
                if payload_capture_valid = '1' then
                    payload_capture_valid <= '0';
                end if;
                
                -- Reset capture counter on payload start (new payload begins)
                if payload_start = '1' then
                    payload_capture_count <= 0;
                    payload_last_byte_index <= to_integer(mac_byte_counter);  -- Initialize to current byte_index
                    -- Capture first byte using mac_data_out directly (registered, no combinational delay)
                    -- Ensures byte 0 captured correctly without timing issues
                    payload_capture(0) <= mac_data_out;  -- Use registered data directly
                    payload_capture_count <= 1;
                -- Capture subsequent bytes when payload is valid
                elsif payload_valid = '1' and payload_capture_count > 0 and payload_capture_count < 16 then
                    -- Only capture if byte_index has changed (new byte)
                    if to_integer(mac_byte_counter) /= payload_last_byte_index then
                        payload_capture(payload_capture_count) <= payload_data;
                        payload_capture_count <= payload_capture_count + 1;
                        payload_last_byte_index <= to_integer(mac_byte_counter);
                        
                        -- Check if 16 bytes captured (after increment)
                        if payload_capture_count = 15 then
                            -- Just captured the 15th byte (count was 14, now 15), signal ready
                            payload_capture_valid <= '1';
                        end if;
                    end if;
                end if;
                
                -- End of payload: signal ready even if less than 16 bytes
                if payload_end = '1' and payload_capture_count > 0 then
                    payload_capture_valid <= '1';
                end if;
                
                -- Reset capture on frame end (for next frame)
                if frame_end = '1' then
                    payload_capture_count <= 0;
                end if;
            end if;
        end if;
    end process;
    
    -- Synchronize payload capture to 100 MHz domain
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                payload_capture_valid_sync1 <= '0';
                payload_capture_valid_sync2 <= '0';
                payload_capture_sync <= (others => (others => '0'));
                payload_capture_vector <= (others => '0');
            else
                payload_capture_valid_sync1 <= payload_capture_valid;
                payload_capture_valid_sync2 <= payload_capture_valid_sync1;
                
                -- Latch payload on first sync stage (when valid goes high)
                if payload_capture_valid_sync1 = '1' and payload_capture_valid_sync2 = '0' then
                    payload_capture_sync <= payload_capture;
                    -- Pack array into vector: byte 15 (MSB) to byte 0 (LSB)
                    payload_capture_vector <= payload_capture(15) & payload_capture(14) & payload_capture(13) & payload_capture(12) &
                                              payload_capture(11) & payload_capture(10) & payload_capture(9) & payload_capture(8) &
                                              payload_capture(7) & payload_capture(6) & payload_capture(5) & payload_capture(4) &
                                              payload_capture(3) & payload_capture(2) & payload_capture(1) & payload_capture(0);
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------------
    -- MII Receiver
    ----------------------------------------------------------------------------------

    mii_receiver : entity work.mii_rx
        port map (
            mii_rx_clk  => eth_rx_clk,  -- 25 MHz from PHY
            mii_rxd     => eth_rxd,
            mii_rx_dv   => eth_rx_dv,
            mii_rx_er   => eth_rx_er,
            rx_data     => rx_data,
            rx_valid    => rx_valid,
            rx_error    => rx_error,
            frame_start => frame_start,
            frame_end   => frame_end
        );
    
    ----------------------------------------------------------------------------------
    -- MAC Frame Parser
    -- Runs on eth_rx_clk domain (25 MHz from PHY)
    ----------------------------------------------------------------------------------
    
    mac_frame_parser : entity work.mac_parser
        generic map (
            MAC_ADDR => MY_MAC_ADDR
        )
        port map (
            clk         => eth_rx_clk,  -- 25 MHz from PHY
            reset       => mdio_rst_rxclk,  -- Use synchronized reset
            rx_data     => rx_data,
            rx_valid    => rx_valid,
            frame_start => frame_start,
            frame_end   => frame_end,
            frame_valid => frame_valid,
            dest_mac    => open,
            src_mac     => open,
            ethertype   => open,
            frame_count => open,
            data_out     => mac_data_out,      -- NEW
            byte_counter => mac_byte_counter   -- NEW
        );
    
    ----------------------------------------------------------------------------------
    -- Statistics Counter
    -- Runs on IP parser clock domain (25 MHz)
    ----------------------------------------------------------------------------------
    
    stats_inst: entity work.stats_counter
        generic map (
            CLK_FREQ => 100_000_000
        )
        port map (
            clk   => clk,
            reset => reset,
            
            -- MAC frame statistics
            frame_valid => frame_valid_sync2,
            
            -- IP statistics
            ip_valid        => ip_valid_sync2,
            ip_protocol     => ip_protocol_sync2,
            ip_checksum_ok  => ip_checksum_ok_sync2,
            ip_version_err  => ip_version_err_sync2,
            ip_checksum_err => ip_checksum_err_sync2,
            
            -- UDP statistics
            udp_valid      => udp_valid_sync2,
            udp_dst_port   => udp_dst_port_sync,
            udp_length_err => udp_length_err_sync2,
            
            -- Display control
            debug_mode      => debug_btn_rise,
            mdio_reg_values => reg_values,
            mdio_seq_done   => sequence_active,
            
            -- Outputs
            led          => frame_count_leds,
            led_activity => frame_activity,
            led_error    => stats_error
        );


     -- Instantiate IP Parser
    ip_parser_inst: entity work.ip_parser
        port map (
            clk => eth_rx_clk, -- Run in same domain as data
            reset => mdio_rst_rxclk,  -- Use synchronized reset
            -- From MAC parser
            frame_valid => in_frame,
            data_in     => mac_data_out,
            byte_index  => to_integer(mac_byte_counter),

            -- Outputs
            ip_valid        => ip_valid,
            ip_src          => ip_src,
            ip_dst          => ip_dst,
            ip_protocol     => ip_protocol,
            ip_total_length => ip_total_length,
            ip_checksum_ok  => ip_checksum_ok,
            ip_version_err  => ip_version_err,
            ip_ihl_err      => ip_ihl_err,
            ip_checksum_err => ip_checksum_err,
            ip_version_ihl_byte => ip_version_ihl_byte
        );

    -- Instantiate UDP Parser
    udp_parser_inst: entity work.udp_parser
        port map (
            clk => eth_rx_clk, -- Run in same domain as data
            reset => mdio_rst_rxclk,  -- Use synchronized reset
            -- From IP parser
            ip_valid => ip_valid,
            ip_protocol => ip_protocol,
            ip_total_length => ip_total_length,
            data_in => mac_data_out,
            byte_index => to_integer(mac_byte_counter),
            frame_valid => in_frame,
            -- Outputs
            udp_valid => udp_valid,
            udp_src_port => udp_src_port,
            udp_dst_port => udp_dst_port,
            udp_length => udp_length,
            udp_checksum_ok => udp_checksum_ok,
            udp_length_err => udp_length_err,
            payload_valid => payload_valid,
            payload_data => payload_data,
            payload_length => payload_length,
            payload_start => payload_start,
            payload_end => payload_end,
            -- Debug
            udp_protocol_ok => udp_protocol_ok,
            udp_length_ok => udp_length_ok
        );

    ------------------------------------------------------------------------
    -- UDP Port Filtering (Defense in Depth)
    -- Latch port match flag when UDP header validated, use for entire packet
    -- Prevents spurious ITCH message detection from other UDP traffic
    ------------------------------------------------------------------------
    process(eth_rx_clk)
    begin
        if rising_edge(eth_rx_clk) then
            if mdio_rst_rxclk = '1' then
                port_match <= '0';
            else
                -- Latch port match when UDP header is validated
                if udp_valid = '1' then
                    if unsigned(udp_dst_port) = ITCH_UDP_PORT then
                        port_match <= '1';
                    else
                        port_match <= '0';
                    end if;
                end if;

                -- Clear flag at end of packet
                if payload_end = '1' then
                    port_match <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Combinational filtering (no registered delay - preserves alignment)
    -- Pass through if: (1) latched flag set OR (2) current cycle matches (for first cycle)
    payload_valid_filtered <= payload_valid when (port_match = '1' or
                                                   (udp_valid = '1' and unsigned(udp_dst_port) = ITCH_UDP_PORT))
                              else '0';
    payload_start_filtered <= payload_start when (port_match = '1' or
                                                   (udp_valid = '1' and unsigned(udp_dst_port) = ITCH_UDP_PORT))
                              else '0';
    payload_end_filtered   <= payload_end when (port_match = '1' or
                                                 (udp_valid = '1' and unsigned(udp_dst_port) = ITCH_UDP_PORT))
                              else '0';

    -- Instantiate ITCH Parser
    itch_parser_inst: entity work.itch_parser
        port map (
            clk => eth_rx_clk,  -- Run in same domain as UDP parser
            rst => mdio_rst_rxclk,  -- Use synchronized reset
            -- UDP payload interface (port-filtered)
            udp_payload_valid => payload_valid_filtered,
            udp_payload_data => payload_data,
            udp_payload_start => payload_start_filtered,
            udp_payload_end => payload_end_filtered,
            -- Parsed message outputs
            msg_valid => itch_msg_valid,
            msg_type => itch_msg_type,
            msg_error => itch_msg_error,
            -- Add Order ('A') fields
            add_order_valid => itch_add_order_valid,
            stock_locate => itch_stock_locate,
            tracking_number => itch_tracking_number,
            timestamp => itch_timestamp,
            order_ref => itch_order_ref,
            buy_sell => itch_buy_sell,
            shares => itch_shares,
            stock_symbol => itch_stock_symbol,
            price => itch_price,
            -- Order Executed ('E') fields
            order_executed_valid => itch_order_executed_valid,
            exec_shares => itch_exec_shares,
            match_number => itch_match_number,
            -- Order Cancel ('X') fields
            order_cancel_valid => itch_order_cancel_valid,
            cancel_shares => itch_cancel_shares,

            -- System Event ('S') fields
            system_event_valid => itch_system_event_valid,
            event_code => itch_event_code,


            -- Stock Directory ('R') fields
            stock_directory_valid => itch_stock_directory_valid,
            round_lot_size          => itch_round_lot_size,
            market_category => itch_market_category,
            financial_status => itch_financial_status,

            -- New message types
            order_delete_valid => itch_order_delete_valid,
            order_replace_valid => itch_order_replace_valid,
            trade_valid => itch_trade_valid,
            cross_trade_valid => itch_cross_trade_valid,
            original_order_ref => itch_original_order_ref,
            new_order_ref => itch_new_order_ref,
            new_shares => itch_new_shares,
            new_price => itch_new_price,
            trade_price => itch_trade_price,
            cross_shares => itch_cross_shares,
            cross_price => itch_cross_price,
            cross_type => itch_cross_type,
            -- Symbol filtering statistics
            total_messages => itch_total_messages,
            filtered_messages => itch_filtered_messages,
            symbol_match => itch_symbol_match
        );

    -- DISABLED: Single-symbol order book manager (replaced by multi-symbol version)
    -- order_book_manager_inst: entity work.order_book_manager
    --     port map (
    --         clk => eth_rx_clk,
    --         rst => mdio_rst_rxclk,
    --         -- ITCH parser interface
    --         itch_valid          => itch_msg_valid,
    --         itch_msg_type       => itch_msg_type,
    --         itch_order_ref      => itch_order_ref,
    --         itch_symbol         => itch_stock_symbol,
    --         itch_side           => itch_side,
    --         itch_price          => itch_price,
    --         itch_shares         => itch_shares,
    --         itch_exec_shares    => itch_exec_shares,
    --         itch_cancel_shares  => itch_cancel_shares,
    --         itch_new_order_ref  => itch_new_order_ref,
    --         itch_new_price      => itch_new_price,
    --         itch_new_shares     => itch_new_shares,
    --         -- BBO output
    --         bbo                 => ob_bbo,
    --         bbo_update          => ob_bbo_update,
    --         -- Statistics
    --         stats               => ob_stats,
    --         -- Ready signal
    --         ready               => ob_ready
    --     );

    -- Multi-symbol order book (8 symbols: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA)
    -- Runs in 25 MHz domain (same as ITCH parser)
    multi_symbol_order_book_inst: entity work.multi_symbol_order_book
        port map (
            clk => eth_rx_clk,
            reset => mdio_rst_rxclk,

            -- ITCH message inputs (direct from parser - no CDC needed, same clock domain)
            msg_valid     => itch_msg_valid,
            msg_type      => itch_msg_type,
            stock_symbol  => itch_stock_symbol,
            order_ref     => itch_order_ref,
            buy_sell      => itch_side,
            shares        => itch_shares,
            price         => itch_price,

            -- BBO outputs (with symbol name)
            bbo_update    => ob_bbo_update,
            bbo_symbol    => ob_bbo_symbol,
            bbo_valid     => ob_bbo.valid,
            bid_price     => ob_bbo.bid_price,
            bid_shares    => ob_bbo.bid_shares,
            ask_price     => ob_bbo.ask_price,
            ask_shares    => ob_bbo.ask_shares,
            spread        => ob_bbo.spread
        );

    -- CDC: Synchronize BBO signals from 25 MHz to 100 MHz domain
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ob_bbo_update_sync1 <= '0';
                ob_bbo_update_sync2 <= '0';
                ob_bbo_valid_sync1 <= '0';
                ob_bbo_valid_sync2 <= '0';
                -- Initialize BBO to invalid state
                ob_bbo_sync <= (
                    bid_price => (others => '0'),
                    bid_shares => (others => '0'),
                    ask_price => (others => '1'),
                    ask_shares => (others => '0'),
                    spread => (others => '1'),
                    valid => '0'
                );
                ob_stats_sync <= (
                    total_orders => (others => '0'),
                    bid_order_count => (others => '0'),
                    ask_order_count => (others => '0'),
                    bid_level_count => (others => '0'),
                    ask_level_count => (others => '0'),
                    add_count => (others => '0'),
                    execute_count => (others => '0'),
                    cancel_count => (others => '0'),
                    delete_count => (others => '0'),
                    replace_count => (others => '0')
                );
                -- Initialize status counters
                order_count_reg <= (others => '0');
                bbo_count_reg <= (others => '0');
                latency_p50_reg <= to_unsigned(170, 32);  -- 170 ns placeholder
                itch_msg_valid_sync1 <= '0';
                itch_msg_valid_sync2 <= '0';
                itch_msg_valid_sync3 <= '0';
            else
                -- Two-stage synchronizer for bbo_update strobe (for edge detection)
                ob_bbo_update_sync1 <= ob_bbo_update;
                ob_bbo_update_sync2 <= ob_bbo_update_sync1;

                -- Two-stage synchronizer for bbo.valid bit (single-bit CDC)
                ob_bbo_valid_sync1 <= ob_bbo.valid;
                ob_bbo_valid_sync2 <= ob_bbo_valid_sync1;

                -- Continuously sample BBO data (quasi-static, changes slowly)
                -- BBO data is safe to sample continuously across clock domains
                -- because it only changes when bbo_update pulses, and we have
                -- sufficient setup/hold time due to slow update rate
                ob_bbo_sync.bid_price <= ob_bbo.bid_price;
                ob_bbo_sync.bid_shares <= ob_bbo.bid_shares;
                ob_bbo_sync.ask_price <= ob_bbo.ask_price;
                ob_bbo_sync.ask_shares <= ob_bbo.ask_shares;
                ob_bbo_sync.spread <= ob_bbo.spread;
                -- Use synchronized valid bit (proper CDC for single bit)
                ob_bbo_sync.valid <= ob_bbo_valid_sync2;
                -- Symbol is stable during bbo_update pulse, safe to sample
                ob_bbo_symbol_sync <= ob_bbo_symbol;
                ob_stats_sync <= ob_stats;
                
                -- Synchronize ITCH message valid for order count (edge detection)
                itch_msg_valid_sync1 <= itch_msg_valid;
                itch_msg_valid_sync2 <= itch_msg_valid_sync1;
                itch_msg_valid_sync3 <= itch_msg_valid_sync2;
                
                -- Increment order count on rising edge of itch_msg_valid
                if itch_msg_valid_sync2 = '1' and itch_msg_valid_sync3 = '0' then
                    order_count_reg <= order_count_reg + 1;
                end if;
                
                -- Increment BBO count on rising edge of ob_bbo_update_sync2
                if ob_bbo_update_sync2 = '1' and ob_bbo_update_sync1 = '0' then
                    bbo_count_reg <= bbo_count_reg + 1;
                end if;
                
                -- Update status outputs (convert to std_logic_vector)
                order_count_status <= std_logic_vector(order_count_reg);
                bbo_count_status <= std_logic_vector(bbo_count_reg);
                latency_p50_status <= std_logic_vector(latency_p50_reg);
            end if;
        end if;
    end process;

    -- Instantiate BBO UART Formatter (100 MHz domain - Project 8, Multi-symbol)
    uart_bbo_formatter_inst: entity work.uart_bbo_formatter
        port map (
            clk => clk,
            rst => reset,
            -- BBO input (synchronized from 25 MHz domain)
            bbo             => ob_bbo_sync,
            bbo_update      => ob_bbo_update_sync2,
            bbo_symbol      => ob_bbo_symbol_sync,  -- Synchronized symbol name
            stats           => ob_stats_sync,
            -- UART TX interface
            uart_tx_data    => bbo_uart_tx_data,
            uart_tx_valid   => bbo_uart_tx_valid,
            uart_tx_ready   => bbo_uart_tx_ready
        );

    -- BBO UART ready signal (inverse of UART busy)
     bbo_uart_tx_ready <= not uart_fmt_tx_busy;

    -- Convert ITCH buy_sell to order_book side signal
    -- ITCH parser: 'B' (0x42) -> buy_sell='1' (Buy), 'S' (0x53) -> buy_sell='0' (Sell)
    -- Order book: 0=Buy (bid), 1=Sell (ask)
    -- Inversion needed: itch_side = NOT itch_buy_sell
    itch_side <= not itch_buy_sell;

    -- Instantiate ITCH Message Encoder (25 MHz domain)
    itch_msg_encoder_inst: entity work.itch_msg_encoder
        port map (
            clk => eth_rx_clk,
            rst => mdio_rst_rxclk,
            -- From itch_parser
            add_order_valid => itch_add_order_valid,
            order_executed_valid => itch_order_executed_valid,
            order_cancel_valid => itch_order_cancel_valid,
            system_event_valid => itch_system_event_valid,
            stock_directory_valid => itch_stock_directory_valid,
            -- Message data
            stock_locate => itch_stock_locate,
            tracking_number => itch_tracking_number,
            timestamp => itch_timestamp,
            order_ref => itch_order_ref,
            buy_sell => itch_buy_sell,
            shares => itch_shares,
            stock_symbol => itch_stock_symbol,
            price => itch_price,
            exec_shares => itch_exec_shares,
            match_number => itch_match_number,
            cancel_shares => itch_cancel_shares,
            event_code => itch_event_code,
            market_category => itch_market_category,
            financial_status => itch_financial_status,
            round_lot_size => itch_round_lot_size,
            --New message types
            order_delete_valid => itch_order_delete_valid,
            order_replace_valid => itch_order_replace_valid,
            trade_valid => itch_trade_valid,
            cross_trade_valid => itch_cross_trade_valid,
            original_order_ref => itch_original_order_ref,
            new_order_ref => itch_new_order_ref,
            new_shares => itch_new_shares,
            new_price => itch_new_price,
            trade_price => itch_trade_price,
            cross_shares => itch_cross_shares,
            cross_price => itch_cross_price,
            cross_type => itch_cross_type,
            -- To async FIFO
            fifo_wr_en => fifo_wr_en,
            fifo_wr_data => fifo_wr_data,
            fifo_wr_full => fifo_wr_full,
            -- Overflow diagnostics
            overflow_error => encoder_overflow_error,
            overflow_count => encoder_overflow_count
        );

    -- Instantiate Async FIFO (CDC: 25 MHz -> 100 MHz)
    -- Increased depth to 16 to handle message bursts (formatter can be slower than parser)
    async_fifo_inst: entity work.async_fifo
        generic map (
            DATA_WIDTH => MSG_FIFO_WIDTH,
            FIFO_DEPTH => 512
        )
        port map (
            -- Write clock domain (25 MHz)
            wr_clk => eth_rx_clk,
            wr_rst => mdio_rst_rxclk,
            wr_en => fifo_wr_en,
            wr_data => fifo_wr_data,
            wr_full => fifo_wr_full,
            -- Read clock domain (100 MHz)
            rd_clk => clk,
            rd_rst => reset,
            rd_en => fifo_rd_en,
            rd_data => fifo_rd_data,
            rd_empty => fifo_rd_empty
        );

    -- Instantiate ITCH Message Decoder (100 MHz domain)
    itch_msg_decoder_inst: entity work.itch_msg_decoder
        port map (
            clk => clk,
            rst => reset,
            -- From async FIFO
            fifo_rd_data => fifo_rd_data,
            fifo_rd_en => fifo_rd_en,
            -- Decoded message type
            msg_type => decoded_msg_type,
            -- Decoded message data
            order_ref => decoded_order_ref,
            buy_sell => decoded_buy_sell,
            shares => decoded_shares,
            stock_symbol => decoded_stock_symbol,
            price => decoded_price,
            stock_locate => decoded_stock_locate,
            tracking_number => decoded_tracking_number,
            timestamp => decoded_timestamp,
            match_number => decoded_match_number,
            event_code => decoded_event_code,
            market_category => decoded_market_category,
            financial_status => decoded_financial_status,
            round_lot_size => decoded_round_lot_size,
            -- New message type fields
            original_order_ref => decoded_original_order_ref,
            new_order_ref => decoded_new_order_ref,
            new_shares => decoded_new_shares,
            new_price => decoded_new_price,
            trade_price => decoded_trade_price,
            cross_shares => decoded_cross_shares,
            cross_price => decoded_cross_price,
            cross_type => decoded_cross_type
        );

    -- Instantiate ITCH UART Formatter (100 MHz domain)
    uart_itch_formatter_inst: entity work.uart_itch_formatter
        generic map (
            BUILD_VERSION => BUILD_VERSION
        )
        port map (
            clk => clk,
            rst => reset,
            -- From async FIFO (via decoder)
            fifo_rd_en => fifo_rd_en,
            fifo_rd_data => fifo_rd_data,
            fifo_rd_empty => fifo_rd_empty,
            -- Decoded message data (from decoder)
            msg_type => decoded_msg_type,
            order_ref => decoded_order_ref,
            buy_sell => decoded_buy_sell,
            shares => decoded_shares,
            stock_symbol => decoded_stock_symbol,
            price => decoded_price,
            stock_locate => decoded_stock_locate,
            tracking_number => decoded_tracking_number,
            timestamp => decoded_timestamp,
            match_number => decoded_match_number,
            event_code => decoded_event_code,
            market_category => decoded_market_category,
            financial_status => decoded_financial_status,
            round_lot_size => decoded_round_lot_size,
            -- New message type fields
            original_order_ref => decoded_original_order_ref,
            new_order_ref => decoded_new_order_ref,
            new_shares => decoded_new_shares,
            new_price => decoded_new_price,
            trade_price => decoded_trade_price,
            cross_shares => decoded_cross_shares,
            cross_price => decoded_cross_price,
            cross_type => decoded_cross_type,
            -- Statistics trigger
           -- send_stats => itch_send_stats,
          --  total_messages => itch_total_messages,
          --  add_count => std_logic_vector(itch_add_count),
         --   exec_count => std_logic_vector(itch_exec_count),
         --   cancel_count => std_logic_vector(itch_cancel_count),
         --   error_count => itch_parse_errors,
            -- UART TX interface
            uart_tx_data => itch_uart_tx_data,
            uart_tx_valid => itch_uart_tx_valid,
            uart_tx_ready => itch_uart_tx_ready
        );

    -- UART ready signal (inverse of busy) - shared between both formatters
    itch_uart_tx_ready <= not uart_fmt_tx_busy;

    -- Instantiate ITCH Stats Counter
    itch_stats_counter_inst: entity work.itch_stats_counter
        port map (
            clk => clk,
            rst => reset,
            -- From ITCH parser (use synchronized signals)
            msg_valid => '0',  -- Not used
            msg_type => itch_msg_type,
            add_order_valid => itch_add_order_valid_sync2,
            order_executed_valid => itch_order_executed_valid_sync2,
            order_cancel_valid => itch_order_cancel_valid_sync2,
            parse_errors => itch_parse_errors,
            total_messages => itch_total_messages,
            system_event_valid      => itch_system_event_valid_sync2,
            stock_directory_valid    => itch_stock_directory_valid_sync2,
            -- Display mode selection
            display_mode => itch_display_mode,
            -- LED outputs
            led_out => itch_led_out,
            led_activity => itch_led_activity
        );

    -- Count messages by type (for stats reporting) - use synchronized signals
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                itch_add_count <= (others => '0');
                itch_exec_count <= (others => '0');
                itch_cancel_count <= (others => '0');
                itch_system_event_count <= (others => '0');
                itch_stock_directory_count <= (others => '0');
            else
                if itch_add_order_valid_sync2 = '1' then
                    itch_add_count <= itch_add_count + 1;
                end if;
                if itch_order_executed_valid_sync2 = '1' then
                    itch_exec_count <= itch_exec_count + 1;
                end if;
                if itch_order_cancel_valid_sync2 = '1' then
                    itch_cancel_count <= itch_cancel_count + 1;
                end if;
                if itch_system_event_valid_sync2 = '1' then
                    itch_system_event_count <= itch_system_event_count + 1;
                end if;
                if itch_stock_directory_valid_sync2 = '1' then
                    itch_stock_directory_count <= itch_stock_directory_count + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------------
    -- UDP TX for BBO Data (replaces UART for BBO messages in Project 9)
    --------------------------------------------------------------------------------
    -- Instantiate BBO-to-UDP formatter
    -- Converts BBO struct to 256-byte UDP payload, writes nibbles to eth_udp_send
    bbo_udp_formatter_inst: entity work.bbo_udp_formatter
        port map (
            clk => clk,
            rst => reset,
            -- BBO input (synchronized from 25 MHz)
            bbo => ob_bbo_sync,
            bbo_update => ob_bbo_update_sync2,
            bbo_symbol => ob_bbo_symbol_sync,
            -- UDP TX FIFO interface
            wr_en => udp_wr_en,
            wr_d => udp_wr_d,
            wr_busy => udp_wr_busy,
            -- Status
            packets_sent => udp_packets_sent
        );

    -- Instantiate eth_udp_send wrapper (SystemVerilog with flattened interfaces)
    -- Sends UDP packets with BBO data to 192.168.0.93:5000
    eth_udp_send_inst: entity work.eth_udp_send_wrapper
        generic map (
            CLK_RATIO => 4,              -- 100 MHz / 25 MHz = 4
            MIN_DATA_BYTES => 256,       -- Match bbo_udp_formatter packet size
            MAX_DATA_BYTES => 256,
            POWER_UP_CYCLES => 5_000_000,  -- 50ms @ 100MHz
            WORD_SIZE_BYTES => 1
        )
        port map (
            -- Standard clocks
            clk => clk,
            rst => reset,
            clk25 => clk_25mhz,
            -- Writing data from formatter
            wr_en => udp_wr_en,
            wr_d => udp_wr_d,
            wr_rst_busy => open,  -- Not used
            wr_full => udp_wr_busy,
            -- Ethernet PHY interface
            eth_ref_clk => open,  -- Drives eth_ref_clk separately from PLL
            eth_rstn => open,     -- Drives eth_rstn from PHY reset logic
            eth_tx_clk => eth_tx_clk,
            eth_tx_en => eth_tx_en,
            eth_txd => eth_txd,
            -- IP/MAC configuration (dynamically configurable via UART)
            ip_src => x"C0A800D4",        -- 192.168.0.212 (fixed source)
            ip_dst => cfg_dst_ip,         -- Configured via UART
            mac_src => MY_MAC_ADDR,       -- Arty A7-100T MAC (fixed source)
            mac_dst => cfg_dst_mac,       -- Configured via UART
            udp_src_port => x"1388",      -- 5000 (fixed source)
            udp_dst_port => cfg_dst_port, -- Configured via UART
            -- Control
            flush => '0',
            -- Status
            mac_busy => udp_tx_busy,
            rdy => udp_tx_rdy
        );

    ----------------------------------------------------------------------------------
    -- Clock Domain Crossing: 25 MHz -> 100 MHz
    -- 2-stage synchronizer for frame_valid signal
    ----------------------------------------------------------------------------------
    
    process(CLK)
    begin
        if rising_edge(CLK) then
            frame_valid_sync1 <= frame_valid;
            frame_valid_sync2 <= frame_valid_sync1;
        end if;
    end process;


    -- Clock domain crossing: IP parser signals (25 MHz -> 100 MHz)
    -- FIX: Use synchronized ip_valid pulse to gate multi-bit captures
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ip_valid_sync1 <= '0';
                ip_valid_sync2 <= '0';
                ip_protocol_sync1 <= (others => '0');
                ip_protocol_sync2 <= (others => '0');
                ip_checksum_ok_sync1 <= '0';
                ip_checksum_ok_sync2 <= '0';
                ip_version_err_sync1 <= '0';
                ip_version_err_sync2 <= '0';
                ip_ihl_err_sync1 <= '0';
                ip_ihl_err_sync2 <= '0';
                ip_checksum_err_sync1 <= '0';
                ip_checksum_err_sync2 <= '0';
                ip_version_ihl_byte_sync <= (others => '0');
                ip_src_sync <= (others => '0');
                ip_dst_sync <= (others => '0');
                ip_total_length_sync <= (others => '0');
               -- itch_system_event_valid_sync <= '0';
               -- itch_stock_directory_valid_sync <= '0';
            else
                -- 2FF synchronizer for single-bit signals
                ip_valid_sync1 <= ip_valid;
                ip_valid_sync2 <= ip_valid_sync1;

                ip_checksum_ok_sync1 <= ip_checksum_ok;
                ip_checksum_ok_sync2 <= ip_checksum_ok_sync1;

                ip_version_err_sync1 <= ip_version_err;
                ip_version_err_sync2 <= ip_version_err_sync1;

                ip_ihl_err_sync1 <= ip_ihl_err;
                ip_ihl_err_sync2 <= ip_ihl_err_sync1;

                ip_checksum_err_sync1 <= ip_checksum_err;
                ip_checksum_err_sync2 <= ip_checksum_err_sync1;

                -- Latch multi-bit fields when synchronized valid pulse observed
                -- FIX: Use ip_valid_sync1 (synchronized) instead of ip_valid (async)
                if ip_valid_sync1 = '1' then
                    ip_protocol_sync1        <= ip_protocol;
                    ip_version_ihl_byte_sync <= ip_version_ihl_byte;
                    ip_src_sync              <= ip_src;
                    ip_dst_sync              <= ip_dst;
                    ip_total_length_sync     <= ip_total_length;
                end if;
                ip_protocol_sync2 <= ip_protocol_sync1;
            end if;
        end if;
    end process;
   
       -- CDC: UDP signals (25 MHz -> 100 MHz)
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                udp_valid_sync1 <= '0';
                udp_valid_sync2 <= '0';
                udp_length_err_sync1 <= '0';
                udp_length_err_sync2 <= '0';
            else
                -- 2FF synchronizer for single-bit signals
                udp_valid_sync1 <= udp_valid;
                udp_valid_sync2 <= udp_valid_sync1;

                udp_length_err_sync1 <= udp_length_err;
                udp_length_err_sync2 <= udp_length_err_sync1;

                -- Multi-bit signals: sample when synchronized valid pulse observed
                if udp_valid_sync1 = '1' then
                    udp_src_port_sync <= udp_src_port;
                    udp_dst_port_sync <= udp_dst_port;
                end if;
            end if;
        end if;
    end process;

    -- CDC: ITCH valid signals for stats counter (25 MHz -> 100 MHz)
    -- Note: Message data now transferred via async FIFO, only valid signals
    -- need synchronization for stats counting
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                itch_add_order_valid_sync1 <= '0';
                itch_add_order_valid_sync2 <= '0';
                itch_order_executed_valid_sync1 <= '0';
                itch_order_executed_valid_sync2 <= '0';
                itch_order_cancel_valid_sync1 <= '0';
                itch_order_cancel_valid_sync2 <= '0';
                itch_system_event_valid_sync1 <= '0';
                itch_system_event_valid_sync2 <= '0';
                itch_stock_directory_valid_sync1 <= '0';
                itch_stock_directory_valid_sync2 <= '0';
                encoder_overflow_sync1 <= '0';
                encoder_overflow_sync2 <= '0';
                encoder_overflow_latch <= '0';
            else
                -- 2FF synchronizer for valid signals (for stats counter only)
                itch_add_order_valid_sync1 <= itch_add_order_valid;
                itch_add_order_valid_sync2 <= itch_add_order_valid_sync1;

                itch_order_executed_valid_sync1 <= itch_order_executed_valid;
                itch_order_executed_valid_sync2 <= itch_order_executed_valid_sync1;

                itch_order_cancel_valid_sync1 <= itch_order_cancel_valid;
                itch_order_cancel_valid_sync2 <= itch_order_cancel_valid_sync1;

                itch_system_event_valid_sync1 <= itch_system_event_valid;
                itch_system_event_valid_sync2 <= itch_system_event_valid_sync1;

                itch_stock_directory_valid_sync1 <= itch_stock_directory_valid;
                itch_stock_directory_valid_sync2 <= itch_stock_directory_valid_sync1;

                -- 2FF synchronizer for encoder overflow error
                encoder_overflow_sync1 <= encoder_overflow_error;
                encoder_overflow_sync2 <= encoder_overflow_sync1;

                -- Latch overflow error (stays on until reset - critical error indicator)
                if encoder_overflow_sync2 = '1' then
                    encoder_overflow_latch <= '1';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Display Logic
    ------------------------------------------------------------------------
    -- Select which register to display on LEDs
    with reg_display_sel select
        current_reg <= reg_values(15 downto 0)  when "00",  -- Register 0x01
                      reg_values(31 downto 16) when "01",  -- Register 0x10
                      reg_values(47 downto 32) when "10",  -- Register 0x02
                      reg_values(63 downto 48) when "11",  -- Register 0x03
                      (others => '0') when others;

    -- LED Multiplexer: Select between different debug displays
    -- debug_mode = "00": Show frame count from stats_counter (BBO mode on UART)
    -- debug_mode = "01": Show MDIO register values cycling every 2 seconds
    -- debug_mode = "10": Show IP protocol info (ITCH mode on UART)
    -- debug_mode = "11": Reserved (unused)
    led <= ip_protocol_sync2(3 downto 0) when debug_mode = "10" else
        current_reg(3 downto 0) when debug_mode = "01" else
        frame_count_leds;

    ----------------------------------------------------------------------------------
    -- Status LEDs
    ----------------------------------------------------------------------------------

    -- LED[3:0]: Multiplexed between frame count and MDIO registers (see above)

    -- RGB LEDs:
    -- LD4 (RGB0-2): System status
    led_rgb(2) <= rx_error;             -- LD4 Red: MII RX error (PHY level)
    led_rgb(1) <= frame_activity;       -- LD4 Green: Activity from stats_counter
    led_rgb(0) <= phy_ready;            -- LD4 Blue: PHY ready after reset

    -- LD5 (RGB3-5): Protocol errors and MDIO status
    -- Red should be OFF during reset, ON when any error bit asserted, auto-clears when errors clear
    led_rgb(5) <= '0' when reset = '1' else
                  '1' when (ip_checksum_err_sync2 = '1' or
                            ip_version_err_sync2  = '1' or
                            ip_ihl_err_sync2      = '1' or
                            udp_length_err_sync2  = '1') else
                  '0';          -- LD5 Red: IP/UDP protocol errors (IP checksum, version, UDP length)
    led_rgb(4) <= mdio_busy;            -- LD5 Green: MDIO transaction in progress
    led_rgb(3) <= encoder_overflow_latch;  -- LD5 Blue: CRITICAL - Encoder overflow (latched until reset)

    -- RGB LEDs: Indicate status
    -- LD6 (RGB): DEBUG mode indicator
    led_rgb(8) <= sequence_active when debug_mode /= "00" else '0';       -- Red (off)
    led_rgb(7) <= sequence_active when debug_mode /= "00" else '0';       -- Green (on during sequence)
    led_rgb(6) <= not sequence_active when debug_mode /= "00" else '0';   -- Blue (on when complete)


    -- =========================================================================
    -- UART State Machine
    -- =========================================================================
    -- Handles UART transmission for debug commands
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                uart_state <= UART_IDLE;
                tx_start <= '0';
                send_second_hex <= '0';
                tx_started <= '0';
                uart_msg_counter <= 0;

            else
                -- Default: no transmission
                tx_start <= '0';
                case uart_state is

                    when UART_IDLE =>
                        if ip_valid_sync1 = '1' then  -- Higher priority
                            uart_state <= UART_IP_INFO;
                        elsif debug_mode /= "00" then  -- Lower priority: Send MDIO state
                            case uart_msg_counter is
                                when 0 => tx_data <=  nibble_to_hex(debug_state_sig(3 downto 0));
                                when 1 => tx_data <= X"0A"; -- '\n'
                                when 2 => tx_data <= X"0D"; -- '\r'
                                when  others => tx_data <= X"00";
                            end case;
                            tx_start <= '1';
                            uart_state <= UART_ECHO_TX;
                            if(uart_msg_counter >= 2) then
                                uart_msg_counter <= 0;
                            else
                                uart_msg_counter <= uart_msg_counter + 1;
                            end if;
                        end if;
                    when UART_ECHO_TX =>
                        -- Wait for transmission to start, then wait for it to complete
                        if tx_busy = '1' then
                            tx_started <= '1';  -- Transmission start detected
                        elsif tx_started = '1' and tx_busy = '0' then
                            -- Transmission has completed
                            tx_started <= '0';  -- Clear flag
                            uart_state <= UART_IDLE;
                        end if;
                    when UART_IP_INFO =>
                        -- send IP Parser info to UART
                        case uart_msg_counter is
                            when 0 => tx_data <= nibble_to_hex(ip_src(3 downto 0));
                            when 1 => tx_data <= nibble_to_hex(ip_src(7 downto 4));
                            when 2 => tx_data <= nibble_to_hex(ip_dst(3 downto 0));
                            when 3 => tx_data <= nibble_to_hex(ip_dst(7 downto 4));
                            when 4 => tx_data <= nibble_to_hex(ip_protocol(3 downto 0));
                            when 5 => tx_data <= nibble_to_hex(ip_protocol(7 downto 4));
                        end case;
                        tx_start <= '1';
                        uart_state <= UART_ECHO_TX;
                        if(uart_msg_counter >= 5) then
                            uart_msg_counter <= 0;
                        else
                            uart_msg_counter <= uart_msg_counter + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end structural;