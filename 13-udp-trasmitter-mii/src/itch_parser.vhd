--------------------------------------------------------------------------------
-- Module: itch_parser
-- Description: ITCH 5.0 protocol parser for Nasdaq market data
--              Parses binary ITCH messages from UDP payload stream
--              Uses ODD byte_counter values (1,3,5,7...) due to MII timing
--
-- Message Format:
--   [Type:1][Fields:variable]
--
-- Implemented Message Types:
--   'A' (0x41): Add Order - no MPID (36 bytes)
--   'E' (0x45): Order Executed (31 bytes)
--   'X' (0x58): Order Cancel (23 bytes)
--   'S' (0x53): System Event (12 bytes)
--   'R' (0x52): Stock Directory (39 bytes)
--   'D' (0x44): Order Delete (19 bytes)
--   'U' (0x55): Order Replace (35 bytes)
--   'P' (0x50): Trade (non-cross) (44 bytes)
--   'Q' (0x51): Cross Trade (40 bytes)
--
-- Additional message types can be added following the same odd byte_counter pattern.
-- All multi-byte fields are big-endian (network byte order).
--
-- MII Timing Note:
--   MII outputs bytes every 2 clock cycles. When transitioning from IDLE to
--   COUNT_BYTES, the type byte remains visible for 1 extra cycle. Therefore,
--   all data byte extraction uses ODD byte_counter values (1,3,5,7...).
--   Formula: Physical byte N = byte_counter = 2*N - 1
--------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.symbol_filter_pkg.all;

entity itch_parser is
    Port (
        clk                 : in  std_logic;
        rst                 : in  std_logic;
        
        -- UDP payload interface (from udp_parser)
        udp_payload_valid   : in  std_logic;  -- UDP payload byte valid
        udp_payload_data    : in  std_logic_vector(7 downto 0);  -- Payload byte
        udp_payload_start   : in  std_logic;  -- First byte of UDP payload
        udp_payload_end     : in  std_logic;  -- Last byte of UDP payload
        
        -- Parsed message outputs
        msg_valid           : out std_logic;  -- Complete message parsed
        msg_type            : out std_logic_vector(7 downto 0);  -- Message type
        msg_error           : out std_logic;  -- Parse error (unknown type, truncated)
        
        -- Add Order ('A') fields
        add_order_valid     : out std_logic;
        stock_locate        : out std_logic_vector(15 downto 0);  -- Stock locate (bytes 1-2)
        tracking_number     : out std_logic_vector(15 downto 0);  -- Tracking number (bytes 3-4)
        timestamp           : out std_logic_vector(47 downto 0);  -- Timestamp (bytes 5-10, 6 bytes)
        order_ref           : out std_logic_vector(63 downto 0);  -- Order reference number
        buy_sell            : out std_logic;  -- '1'=Buy, '0'=Sell
        shares              : out std_logic_vector(31 downto 0);  -- Share quantity
        stock_symbol        : out std_logic_vector(63 downto 0);  -- 8-char symbol
        price               : out std_logic_vector(31 downto 0);  -- Price (1/10000 dollars)
        
        -- Order Executed ('E') fields
        order_executed_valid : out std_logic;
        exec_shares          : out std_logic_vector(31 downto 0);  -- Executed shares
        match_number         : out std_logic_vector(63 downto 0);  -- Match number
        
        -- Order Cancel ('X') fields
        order_cancel_valid  : out std_logic;
        cancel_shares       : out std_logic_vector(31 downto 0);  -- Cancelled shares

        -- System Event ('S') fields
        system_event_valid      : out std_logic;
        event_code              : out std_logic_vector(7 downto 0);

        -- Stock Directory ('R') fields
        stock_directory_valid   : out std_logic;
        market_category         : out std_logic_vector(7 downto 0);  -- Market category
        financial_status        : out std_logic_vector(7 downto 0);  -- Financial status
        round_lot_size          : out std_logic_vector(31 downto 0);  -- Round lot size (bytes 11-14)

        -- Order Delete ('D') fields
        order_delete_valid      : out std_logic;
        -- Uses order_ref from common fields (bytes 11-18)

        -- Order Replace ('U') fields
        order_replace_valid     : out std_logic;
        original_order_ref      : out std_logic_vector(63 downto 0);  -- Original order ref (bytes 11-18)
        new_order_ref           : out std_logic_vector(63 downto 0);  -- New order ref (bytes 27-34)
        new_shares              : out std_logic_vector(31 downto 0);  -- New shares (bytes 19-22)
        new_price               : out std_logic_vector(31 downto 0);  -- New price (bytes 23-26)

        -- Trade ('P') fields
        trade_valid             : out std_logic;
        trade_price             : out std_logic_vector(31 downto 0);  -- Trade price (bytes 32-35)
        -- Uses order_ref, buy_sell, shares, stock_symbol, match_number from common fields

        -- Cross Trade ('Q') fields
        cross_trade_valid       : out std_logic;
        cross_shares            : out std_logic_vector(63 downto 0);  -- Shares (bytes 11-18, 8 bytes!)
        cross_price             : out std_logic_vector(31 downto 0);  -- Cross price (bytes 27-30)
        cross_type              : out std_logic_vector(7 downto 0);  -- Cross type (byte 39)
        -- Uses stock_symbol, match_number from common fields

        -- Symbol filtering statistics (v5 feature)
        total_messages          : out std_logic_vector(31 downto 0);  -- Total messages parsed (before filtering)
        filtered_messages       : out std_logic_vector(31 downto 0);  -- Messages that passed symbol filter
        symbol_match            : out std_logic  -- Current message symbol matched filter

    );
end itch_parser;

architecture Behavioral of itch_parser is

    -- State machine
    type state_type is (IDLE, READ_TYPE, COUNT_BYTES, COMPLETE, ERROR);
    signal state : state_type := IDLE;

    -- Message type constants
    constant MSG_ADD_ORDER        : std_logic_vector(7 downto 0) := x"41";  -- 'A'
    constant MSG_ORDER_EXECUTED_WITH_PRICE : std_logic_vector(7 downto 0) := x"43";  -- 'C'
    constant MSG_ORDER_DELETE     : std_logic_vector(7 downto 0) := x"44";  -- 'D'
    constant MSG_ORDER_EXECUTED   : std_logic_vector(7 downto 0) := x"45";  -- 'E'
    constant MSG_ADD_ORDER_WITH_MPID : std_logic_vector(7 downto 0) := x"46";  -- 'F'
    constant MSG_TRADE            : std_logic_vector(7 downto 0) := x"50";  -- 'P'
    constant MSG_CROSS_TRADE      : std_logic_vector(7 downto 0) := x"51";  -- 'Q'
    constant MSG_STOCK_DIR        : std_logic_vector(7 downto 0) := x"52";  -- 'R'
    constant MSG_SYSTEM_EVENT     : std_logic_vector(7 downto 0) := x"53";  -- 'S'
    constant MSG_ORDER_REPLACE    : std_logic_vector(7 downto 0) := x"55";  -- 'U'
    constant MSG_ORDER_CANCEL     : std_logic_vector(7 downto 0) := x"58";  -- 'X'
    
        -- Message size constants (bytes)
    constant SIZE_SYSTEM_EVENT    : integer := 12;
    constant SIZE_STOCK_DIR       : integer := 39;
    constant SIZE_ADD_ORDER       : integer := 36;
    constant SIZE_ORDER_EXECUTED  : integer := 31;
    constant SIZE_ORDER_CANCEL    : integer := 23;
    constant SIZE_ORDER_DELETE    : integer := 19;
    constant SIZE_ORDER_REPLACE   : integer := 35;
    constant SIZE_TRADE           : integer := 44;
    constant SIZE_CROSS_TRADE     : integer := 40;
    constant SIZE_ADD_ORDER_WITH_MPID : integer := 40;
    constant SIZE_ORDER_EXECUTED_WITH_PRICE : integer := 36;
    
    -- Message parsing
    signal current_msg_type     : std_logic_vector(7 downto 0) := (others => '0');
    signal expected_length      : integer range 0 to 255 := 0;
    signal byte_counter         : integer range 0 to 255 := 0;

    signal payload_bytes_seen     : integer range 0 to 255 := 0;  -- Tracks payload bytes seen

    -- Field extraction registers
    signal stock_locate_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal tracking_number_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal timestamp_reg        : std_logic_vector(47 downto 0) := (others => '0');
    signal order_ref_reg        : std_logic_vector(63 downto 0) := (others => '0');
    signal buy_sell_reg         : std_logic := '0';
    signal shares_reg           : std_logic_vector(31 downto 0) := (others => '0');
    signal stock_symbol_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal price_reg            : std_logic_vector(31 downto 0) := (others => '0');
    signal exec_shares_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal match_number_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal cancel_shares_reg    : std_logic_vector(31 downto 0) := (others => '0');
    signal event_code_reg       : std_logic_vector(7 downto 0) := (others => '0');
    signal market_category_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal financial_status_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal round_lot_size_reg   : std_logic_vector(31 downto 0) := (others => '0');

    -- Order Replace ('U') specific fields
    signal original_order_ref_reg : std_logic_vector(63 downto 0) := (others => '0');
    signal new_order_ref_reg    : std_logic_vector(63 downto 0) := (others => '0');
    signal new_shares_reg       : std_logic_vector(31 downto 0) := (others => '0');
    signal new_price_reg        : std_logic_vector(31 downto 0) := (others => '0');

    -- Trade ('P') specific fields
    signal trade_price_reg      : std_logic_vector(31 downto 0) := (others => '0');

    -- Cross Trade ('Q') specific fields
    signal cross_shares_reg     : std_logic_vector(63 downto 0) := (others => '0');
    signal cross_price_reg      : std_logic_vector(31 downto 0) := (others => '0');
    signal cross_type_reg       : std_logic_vector(7 downto 0) := (others => '0');

    -- Statistics
    signal msg_counter          : unsigned(31 downto 0) := (others => '0');
    signal error_counter        : unsigned(15 downto 0) := (others => '0');

    -- Symbol filtering statistics (v5)
    signal total_msg_counter    : unsigned(31 downto 0) := (others => '0');
    signal filtered_msg_counter : unsigned(31 downto 0) := (others => '0');
    signal symbol_match_reg     : std_logic := '0';
            
    -- Function: Get expected message length based on type
    function get_msg_length(msg_type: std_logic_vector(7 downto 0)) return integer is
    begin
        case msg_type is
            when MSG_SYSTEM_EVENT => return SIZE_SYSTEM_EVENT;  -- 'S' System Event
            when MSG_STOCK_DIR => return SIZE_STOCK_DIR;  -- 'R' Stock Directory
            when MSG_ADD_ORDER => return SIZE_ADD_ORDER;  -- 'A' Add Order (no MPID)
            when MSG_ADD_ORDER_WITH_MPID => return SIZE_ADD_ORDER_WITH_MPID;  -- 'F' Add Order (with MPID)
            when MSG_ORDER_EXECUTED => return SIZE_ORDER_EXECUTED;  -- 'E' Order Executed
            when MSG_ORDER_CANCEL => return SIZE_ORDER_CANCEL;  -- 'X' Order Cancel
            when MSG_ORDER_DELETE => return SIZE_ORDER_DELETE;  -- 'D' Order Delete
            when MSG_ORDER_REPLACE => return SIZE_ORDER_REPLACE;  -- 'U' Order Replace
            when MSG_TRADE => return SIZE_TRADE;  -- 'P' Trade (non-cross)
            when MSG_CROSS_TRADE => return SIZE_CROSS_TRADE;  -- 'Q' Cross Trade
            when MSG_ORDER_EXECUTED_WITH_PRICE => return SIZE_ORDER_EXECUTED_WITH_PRICE;  -- 'C' Order Executed with Price
            when others => return 0;  -- Unknown message type
        end case;
    end function;

begin

    -- Main parser state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                current_msg_type <= (others => '0');
                expected_length <= 0;
                byte_counter <= 0;
                payload_bytes_seen <= 0;
                msg_valid <= '0';
                msg_error <= '0';
                add_order_valid <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                system_event_valid <= '0';
                stock_directory_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';
                trade_valid <= '0';
                cross_trade_valid <= '0';
                msg_counter <= (others => '0');
                error_counter <= (others => '0');


            else
                -- Default outputs (but hold valid signals during CDC hold period)
                msg_valid <= '0';
                msg_error <= '0';


                -- Default: clear valid signals (will be set in COMPLETE state for 1 cycle)
                add_order_valid <= '0';
                order_executed_valid <= '0';
                order_cancel_valid <= '0';
                system_event_valid <= '0';
                stock_directory_valid <= '0';
                order_delete_valid <= '0';
                order_replace_valid <= '0';
                trade_valid <= '0';
                cross_trade_valid <= '0';

                case state is
                    when IDLE =>
                        -- Wait for start of UDP payload (ONLY use direct pulse)
                        if udp_payload_start = '1' and udp_payload_valid = '1' then
                            -- udp_payload_data is byte 0 (type byte) on this cycle
                            current_msg_type <= udp_payload_data;
                            expected_length <= get_msg_length(udp_payload_data);
                            byte_counter <= 0;  -- Will process first data byte (byte 1) on next cycle

                            -- DO NOT clear field registers here - they must remain stable for CDC
                            -- Registers will be overwritten with new data during COUNT_BYTES
                            -- Data remains stable for 3-4 cycles after valid pulse
                            -- allowing 100 MHz CDC synchronizer to sample correctly

                            -- Check if valid message type
                            if get_msg_length(udp_payload_data) = 0 then
                                state <= ERROR;
                            else
                                state <= COUNT_BYTES;
                            end if;
                        end if;

                    when READ_TYPE =>
                        -- This state is now unused - handled in IDLE
                        state <= IDLE;
                    
                    when COUNT_BYTES =>
                        -- Count remaining bytes and extract fields
                        -- payload_data is combinational from UDP parser, aligned with byte_index
                       
                        
                        -- Process all payload bytes
                        -- CRITICAL FIX: MII outputs bytes every 2 cycles, data stable for 2 cycles
                        -- When transitioning from IDLE to COUNT_BYTES, type byte is still visible for 1 more cycle
                        -- byte_counter=0: Still showing type byte (SKIP!)
                        -- byte_counter=1: Stock Locate MSB appears
                        -- byte_counter=3: Stock Locate LSB appears
                        -- byte_counter=5: Tracking MSB appears
                        -- Solution: Process on ODD byte_counter values starting from 1 (1, 3, 5, 7...)
                        if udp_payload_valid = '1' then
                            -- Extract fields ONLY on odd byte_counter >= 1 (to skip type byte repetition)
                            -- byte_counter=1 = byte 1 (Stock Loc high)
                            -- byte_counter=3 = byte 2 (Stock Loc low)
                            -- byte_counter=5 = byte 3 (Track high)
                            -- byte_counter=7 = byte 4 (Track low)
                            if current_msg_type = MSG_ADD_ORDER and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Stock Locate: bytes 1-2 (2 bytes, big-endian)
                                if byte_counter = 1 then
                                    stock_locate_reg(15 downto 8) <= udp_payload_data;

                                elsif byte_counter = 3 then
                                    stock_locate_reg(7 downto 0) <= udp_payload_data;


                                -- Tracking Number: bytes 3-4 (2 bytes, big-endian)
                                elsif byte_counter = 5 then
                                    tracking_number_reg(15 downto 8) <= udp_payload_data;

                                elsif byte_counter = 7 then
                                    tracking_number_reg(7 downto 0) <= udp_payload_data;


                                -- Timestamp: bytes 5-10 (6 bytes, big-endian)
                                elsif byte_counter = 9 then
                                    timestamp_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 11 then
                                    timestamp_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 13 then
                                    timestamp_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 15 then
                                    timestamp_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 17 then
                                    timestamp_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 19 then
                                    timestamp_reg(7 downto 0) <= udp_payload_data;

                                -- Order Reference: bytes 11-18 (8 bytes, big-endian)
                                elsif byte_counter = 21 then
                                    order_ref_reg(63 downto 56) <= udp_payload_data;
                                    -- Capture debug info for FIRST byte of order_ref
                                elsif byte_counter = 23 then
                                    order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    order_ref_reg(7 downto 0) <= udp_payload_data;
  

                                -- Buy/Sell: byte 19 ('B'=Buy, 'S'=Sell)
                                elsif byte_counter = 37 then

                                    if udp_payload_data = x"42" then  -- 'B'
                                        buy_sell_reg <= '1';
                                    else  -- 'S' or other
                                        buy_sell_reg <= '0';
                                    end if;

                                -- Shares: bytes 20-23 (4 bytes, big-endian)
                                elsif byte_counter = 39 then
                                    shares_reg(31 downto 24) <= udp_payload_data;


                                elsif byte_counter = 41 then
                                    shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 45 then
                                    shares_reg(7 downto 0) <= udp_payload_data;



                                -- Symbol: bytes 24-31 (8 bytes, ASCII)
                                elsif byte_counter = 47 then
                                    stock_symbol_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 49 then
                                    stock_symbol_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 51 then
                                    stock_symbol_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 53 then
                                    stock_symbol_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 55 then
                                    stock_symbol_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 57 then
                                    stock_symbol_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 59 then
                                    stock_symbol_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 61 then
                                    stock_symbol_reg(7 downto 0) <= udp_payload_data;



                                -- Price: bytes 32-35 (4 bytes, big-endian, 1/10000 dollars)
                                elsif byte_counter = 63 then
                                    price_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 65 then
                                    price_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 67 then
                                    price_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 69 then
                                    price_reg(7 downto 0) <= udp_payload_data;

                                end if;

                            -- Order Executed ('E' = 0x45) field extraction
                            elsif current_msg_type = MSG_ORDER_EXECUTED and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Order Reference: bytes 11-18 (8 bytes, big-endian)
                                if byte_counter = 21 then
                                    order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    order_ref_reg(7 downto 0) <= udp_payload_data;

                                -- Executed Shares: bytes 19-22 (4 bytes, big-endian)
                                elsif byte_counter = 37 then
                                    exec_shares_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 39 then
                                    exec_shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 41 then
                                    exec_shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    exec_shares_reg(7 downto 0) <= udp_payload_data;

                                -- Match Number: bytes 23-30 (8 bytes, big-endian)
                                elsif byte_counter = 45 then
                                    match_number_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 47 then
                                    match_number_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 49 then
                                    match_number_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 51 then
                                    match_number_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 53 then
                                    match_number_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 55 then
                                    match_number_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 57 then
                                    match_number_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 59 then
                                    match_number_reg(7 downto 0) <= udp_payload_data;
                                end if;

                            -- Order Cancel ('X' = 0x58) field extraction
                            elsif current_msg_type = MSG_ORDER_CANCEL and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Order Reference: bytes 11-18 (8 bytes, big-endian)
                                if byte_counter = 21 then
                                    order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    order_ref_reg(7 downto 0) <= udp_payload_data;

                                -- Cancelled Shares: bytes 19-22 (4 bytes, big-endian)
                                elsif byte_counter = 37 then
                                    cancel_shares_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 39 then
                                    cancel_shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 41 then
                                    cancel_shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    cancel_shares_reg(7 downto 0) <= udp_payload_data;
                                end if;

                            -- System Event ('S' = 0x53) field extraction
                            -- System Event Message Layout (12 bytes):
                            -- Offset 0: Message Type 'S' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11: Event Code (char)
                            elsif current_msg_type = MSG_SYSTEM_EVENT and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                if byte_counter = 1 then
                                    stock_locate_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 3 then
                                    stock_locate_reg(7 downto 0) <= udp_payload_data;
                                elsif byte_counter = 5 then
                                    tracking_number_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 7 then
                                    tracking_number_reg(7 downto 0) <= udp_payload_data;
                                end if;
                                if byte_counter = 9 then
                                    timestamp_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 11 then
                                    timestamp_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 13 then
                                    timestamp_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 15 then
                                    timestamp_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 17 then
                                    timestamp_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 19 then
                                    timestamp_reg(7 downto 0) <= udp_payload_data;
                                elsif byte_counter = 21 then
                                    event_code_reg <= udp_payload_data;
                                end if;

                            -- Stock Directory ('R' = 0x52) field extraction
                            -- Stock Directory Message Layout (39 bytes):
                            -- Offset 0: Message Type 'R' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11-18: Stock Symbol (8 chars)
                            -- Offset 19: Market Category (char)
                            -- Offset 20: Financial Status (char)
                            -- Offset 21-24: Round Lot Size (uint32) 
                            -- Offset 25-38: Other fields (skip for now)
                            elsif current_msg_type = MSG_STOCK_DIR and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                    
                                    if byte_counter = 1 then
                                        stock_locate_reg(15 downto 8) <= udp_payload_data;
                                    elsif byte_counter = 3 then
                                        stock_locate_reg(7 downto 0) <= udp_payload_data;
                                    elsif byte_counter = 5 then
                                        tracking_number_reg(15 downto 8) <= udp_payload_data;
                                    elsif byte_counter = 7 then
                                        tracking_number_reg(7 downto 0) <= udp_payload_data;
                                    elsif byte_counter = 9 then
                                        timestamp_reg(47 downto 40) <= udp_payload_data;
                                    elsif byte_counter = 11 then
                                        timestamp_reg(39 downto 32) <= udp_payload_data;
                                    elsif byte_counter = 13 then
                                        timestamp_reg(31 downto 24) <= udp_payload_data;
                                    elsif byte_counter = 15 then
                                        timestamp_reg(23 downto 16) <= udp_payload_data;
                                    elsif byte_counter = 17 then
                                        timestamp_reg(15 downto 8) <= udp_payload_data;
                                    elsif byte_counter = 19 then
                                        timestamp_reg(7 downto 0) <= udp_payload_data;
                                    elsif byte_counter = 21 then
                                        stock_symbol_reg(63 downto 56) <= udp_payload_data;
                                    elsif byte_counter = 23 then
                                        stock_symbol_reg(55 downto 48) <= udp_payload_data;
                                    elsif byte_counter = 25 then
                                        stock_symbol_reg(47 downto 40) <= udp_payload_data;
                                    elsif byte_counter = 27 then
                                        stock_symbol_reg(39 downto 32) <= udp_payload_data;
                                    elsif byte_counter = 29 then
                                        stock_symbol_reg(31 downto 24) <= udp_payload_data;
                                    elsif byte_counter = 31 then
                                        stock_symbol_reg(23 downto 16) <= udp_payload_data;
                                    elsif byte_counter = 33 then
                                        stock_symbol_reg(15 downto 8) <= udp_payload_data;
                                    elsif byte_counter = 35 then
                                        stock_symbol_reg(7 downto 0) <= udp_payload_data;
                                    elsif byte_counter = 37 then
                                        market_category_reg <= udp_payload_data;
                                    elsif byte_counter = 39 then
                                        financial_status_reg <= udp_payload_data;
                                    elsif byte_counter = 41 then
                                        round_lot_size_reg(31 downto 24) <= udp_payload_data;
                                    elsif byte_counter = 43 then
                                        round_lot_size_reg(23 downto 16) <= udp_payload_data;
                                    elsif byte_counter = 45 then
                                        round_lot_size_reg(15 downto 8) <= udp_payload_data;
                                    elsif byte_counter = 47 then
                                        round_lot_size_reg(7 downto 0) <= udp_payload_data;
                                    end if;

                            -- Order Delete ('D' = 0x44) field extraction
                            -- Order Delete Message Layout (19 bytes):
                            -- Offset 0: Message Type 'D' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11-18: Order Reference Number (uint64)
                            elsif current_msg_type = MSG_ORDER_DELETE and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Order Reference: bytes 11-18 (8 bytes, big-endian)
                                if byte_counter = 21 then
                                    order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    order_ref_reg(7 downto 0) <= udp_payload_data;
                                end if;

                            -- Order Replace ('U' = 0x55) field extraction
                            -- Order Replace Message Layout (35 bytes):
                            -- Offset 0: Message Type 'U' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11-18: Original Order Reference (uint64)
                            -- Offset 19-22: New Shares (uint32)
                            -- Offset 23-26: New Price (uint32)
                            -- Offset 27-34: New Order Reference (uint64)
                            elsif current_msg_type = MSG_ORDER_REPLACE and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Original Order Reference: bytes 11-18 (8 bytes, big-endian)
                                if byte_counter = 21 then
                                    original_order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    original_order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    original_order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    original_order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    original_order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    original_order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    original_order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    original_order_ref_reg(7 downto 0) <= udp_payload_data;

                                -- New Shares: bytes 19-22 (4 bytes, big-endian)
                                elsif byte_counter = 37 then
                                    new_shares_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 39 then
                                    new_shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 41 then
                                    new_shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    new_shares_reg(7 downto 0) <= udp_payload_data;

                                -- New Price: bytes 23-26 (4 bytes, big-endian)
                                elsif byte_counter = 45 then
                                    new_price_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 47 then
                                    new_price_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 49 then
                                    new_price_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 51 then
                                    new_price_reg(7 downto 0) <= udp_payload_data;

                                -- New Order Reference: bytes 27-34 (8 bytes, big-endian)
                                elsif byte_counter = 53 then
                                    new_order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 55 then
                                    new_order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 57 then
                                    new_order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 59 then
                                    new_order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 61 then
                                    new_order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 63 then
                                    new_order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 65 then
                                    new_order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 67 then
                                    new_order_ref_reg(7 downto 0) <= udp_payload_data;
                                end if;

                            -- Trade ('P' = 0x50) field extraction
                            -- Trade Message Layout (44 bytes):
                            -- Offset 0: Message Type 'P' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11-18: Order Reference (uint64)
                            -- Offset 19: Buy/Sell Indicator (char 'B' or 'S')
                            -- Offset 20-23: Shares (uint32)
                            -- Offset 24-31: Stock Symbol (8 chars)
                            -- Offset 32-35: Price (uint32)
                            -- Offset 36-43: Match Number (uint64)
                            elsif current_msg_type = MSG_TRADE and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Order Reference: bytes 11-18 (8 bytes, big-endian)
                                if byte_counter = 21 then
                                    order_ref_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    order_ref_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    order_ref_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    order_ref_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    order_ref_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    order_ref_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    order_ref_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    order_ref_reg(7 downto 0) <= udp_payload_data;

                                -- Buy/Sell: byte 19 ('B'=Buy, 'S'=Sell)
                                elsif byte_counter = 37 then
                                    if udp_payload_data = x"42" then  -- 'B'
                                        buy_sell_reg <= '1';
                                    else  -- 'S' or other
                                        buy_sell_reg <= '0';
                                    end if;

                                -- Shares: bytes 20-23 (4 bytes, big-endian)
                                elsif byte_counter = 39 then
                                    shares_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 41 then
                                    shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 45 then
                                    shares_reg(7 downto 0) <= udp_payload_data;

                                -- Symbol: bytes 24-31 (8 bytes, ASCII)
                                elsif byte_counter = 47 then
                                    stock_symbol_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 49 then
                                    stock_symbol_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 51 then
                                    stock_symbol_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 53 then
                                    stock_symbol_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 55 then
                                    stock_symbol_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 57 then
                                    stock_symbol_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 59 then
                                    stock_symbol_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 61 then
                                    stock_symbol_reg(7 downto 0) <= udp_payload_data;

                                -- Price: bytes 32-35 (4 bytes, big-endian, 1/10000 dollars)
                                elsif byte_counter = 63 then
                                    trade_price_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 65 then
                                    trade_price_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 67 then
                                    trade_price_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 69 then
                                    trade_price_reg(7 downto 0) <= udp_payload_data;

                                -- Match Number: bytes 36-43 (8 bytes, big-endian)
                                elsif byte_counter = 71 then
                                    match_number_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 73 then
                                    match_number_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 75 then
                                    match_number_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 77 then
                                    match_number_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 79 then
                                    match_number_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 81 then
                                    match_number_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 83 then
                                    match_number_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 85 then
                                    match_number_reg(7 downto 0) <= udp_payload_data;
                                end if;

                            -- Cross Trade ('Q' = 0x51) field extraction
                            -- Cross Trade Message Layout (40 bytes):
                            -- Offset 0: Message Type 'Q' [already read]
                            -- Offset 1-2: Stock Locate (uint16)
                            -- Offset 3-4: Tracking Number (uint16)
                            -- Offset 5-10: Timestamp (uint48)
                            -- Offset 11-18: Shares (uint64) - NOTE: 8 bytes, not 4!
                            -- Offset 19-26: Stock Symbol (8 chars)
                            -- Offset 27-30: Cross Price (uint32)
                            -- Offset 31-38: Match Number (uint64)
                            -- Offset 39: Cross Type (char)
                            elsif current_msg_type = MSG_CROSS_TRADE and byte_counter >= 1 and (byte_counter mod 2) = 1 then
                                -- Shares: bytes 11-18 (8 bytes, big-endian) - DIFFERENT from other messages!
                                if byte_counter = 21 then
                                    cross_shares_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 23 then
                                    cross_shares_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 25 then
                                    cross_shares_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 27 then
                                    cross_shares_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 29 then
                                    cross_shares_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 31 then
                                    cross_shares_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 33 then
                                    cross_shares_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 35 then
                                    cross_shares_reg(7 downto 0) <= udp_payload_data;

                                -- Symbol: bytes 19-26 (8 bytes, ASCII)
                                elsif byte_counter = 37 then
                                    stock_symbol_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 39 then
                                    stock_symbol_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 41 then
                                    stock_symbol_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 43 then
                                    stock_symbol_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 45 then
                                    stock_symbol_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 47 then
                                    stock_symbol_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 49 then
                                    stock_symbol_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 51 then
                                    stock_symbol_reg(7 downto 0) <= udp_payload_data;

                                -- Cross Price: bytes 27-30 (4 bytes, big-endian)
                                elsif byte_counter = 53 then
                                    cross_price_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 55 then
                                    cross_price_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 57 then
                                    cross_price_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 59 then
                                    cross_price_reg(7 downto 0) <= udp_payload_data;

                                -- Match Number: bytes 31-38 (8 bytes, big-endian)
                                elsif byte_counter = 61 then
                                    match_number_reg(63 downto 56) <= udp_payload_data;
                                elsif byte_counter = 63 then
                                    match_number_reg(55 downto 48) <= udp_payload_data;
                                elsif byte_counter = 65 then
                                    match_number_reg(47 downto 40) <= udp_payload_data;
                                elsif byte_counter = 67 then
                                    match_number_reg(39 downto 32) <= udp_payload_data;
                                elsif byte_counter = 69 then
                                    match_number_reg(31 downto 24) <= udp_payload_data;
                                elsif byte_counter = 71 then
                                    match_number_reg(23 downto 16) <= udp_payload_data;
                                elsif byte_counter = 73 then
                                    match_number_reg(15 downto 8) <= udp_payload_data;
                                elsif byte_counter = 75 then
                                    match_number_reg(7 downto 0) <= udp_payload_data;

                                -- Cross Type: byte 39 (char)
                                elsif byte_counter = 77 then
                                    cross_type_reg <= udp_payload_data;
                                end if;

                            end if;

                            -- ALWAYS increment byte counter for EVERY valid payload byte
                            -- Ensures byte_counter tracks absolute position, even for bytes not extracted
                            -- Check completion BEFORE increment (check if next value will complete message)
                            -- MII outputs bytes every 2 cycles, byte_counter increments every cycle
                            -- For a 36-byte message: expected_length=36 (type + 35 data bytes)
                            -- byte_counter goes 0,1,2,3,4,5...67,68,69,70 (process on odd: 1,3,5...67,69)
                            -- Byte 35 (last data byte) is processed at counter=69 (odd)
                            -- After processing: check if (byte_counter + 1) >= 2*(expected_length - 1) = 70
                            -- If yes, increment to 70 and complete; if no, just increment
                            if (byte_counter + 1) >= 2 * (expected_length - 1) then
                                -- Next increment will complete the message
                                byte_counter <= byte_counter + 1;
                                state <= COMPLETE;
                            else
                                -- Not complete yet, just increment
                                byte_counter <= byte_counter + 1;
                            end if;

                        end if;
                        -- Check for premature end
                        -- byte_counter starts at 0, so after increment it goes 1, 2, 3, ..., expected_length-1
                        -- For a 36-byte message: expected_length=36, bytes are 0-35
                        -- After processing byte 35, byte_counter will be 35, then increment to 36
                        -- If payload_end comes when (byte_counter + 1) < expected_length, not all bytes processed
                        if udp_payload_end = '1' and (byte_counter + 1) < expected_length then
                            state <= ERROR;
                        end if;

                       
                    
                    when COMPLETE =>
                        -- Message successfully parsed
                        -- Increment total message counter (before filtering)
                        total_msg_counter <= total_msg_counter + 1;

                        -- v5 Symbol Filtering Logic
                        -- Check if this message type contains a symbol field
                        -- Message types with symbols: A (Add Order), R (Stock Directory), P (Trade), Q (Cross Trade)
                        -- Message types without symbols: S (System Event), E (Executed), X (Cancel), D (Delete), U (Replace)

                        -- Determine if symbol passes filter (if applicable)
                        if current_msg_type = MSG_ADD_ORDER or
                           current_msg_type = MSG_STOCK_DIR or
                           current_msg_type = MSG_TRADE or
                           current_msg_type = MSG_CROSS_TRADE then
                            -- Message has symbol field, check filter
                            if is_symbol_filtered(stock_symbol_reg) then
                                symbol_match_reg <= '1';
                                -- Symbol passed filter, assert valid signals
                                msg_valid <= '1';
                                msg_counter <= msg_counter + 1;
                                filtered_msg_counter <= filtered_msg_counter + 1;

                                -- Set type-specific valid signals
                                if current_msg_type = MSG_ADD_ORDER then
                                    add_order_valid <= '1';
                                elsif current_msg_type = MSG_STOCK_DIR then
                                    stock_directory_valid <= '1';
                                elsif current_msg_type = MSG_TRADE then
                                    trade_valid <= '1';
                                elsif current_msg_type = MSG_CROSS_TRADE then
                                    cross_trade_valid <= '1';
                                end if;
                            else
                                symbol_match_reg <= '0';
                                -- Symbol filtered out, don't assert valid signals
                                msg_valid <= '0';
                            end if;
                        else
                            -- Message type has no symbol (always pass through)
                            symbol_match_reg <= '1';  -- No symbol means "match" (pass through)
                            msg_valid <= '1';
                            msg_counter <= msg_counter + 1;
                            filtered_msg_counter <= filtered_msg_counter + 1;

                            -- Set type-specific valid signals for non-symbol messages
                            if current_msg_type = MSG_ORDER_EXECUTED then
                                order_executed_valid <= '1';
                            elsif current_msg_type = MSG_ORDER_CANCEL then
                                order_cancel_valid <= '1';
                            elsif current_msg_type = MSG_SYSTEM_EVENT then
                                system_event_valid <= '1';
                            elsif current_msg_type = MSG_ORDER_DELETE then
                                order_delete_valid <= '1';
                            elsif current_msg_type = MSG_ORDER_REPLACE then
                                order_replace_valid <= '1';
                            end if;
                        end if;

                        -- Check for next message start immediately (handle back-to-back messages)
                        -- If next payload_start arrives in same cycle as completion, start parsing immediately
                        if udp_payload_start = '1' and udp_payload_valid = '1' then
                            -- Next message already started, begin parsing immediately
                            current_msg_type <= udp_payload_data;
                            expected_length <= get_msg_length(udp_payload_data);
                            byte_counter <= 0;
                            
                            if get_msg_length(udp_payload_data) = 0 then
                                state <= ERROR;
                            else
                                state <= COUNT_BYTES;
                            end if;
                        else
                            -- No next message yet, return to IDLE
                            state <= IDLE;
                        end if;
                    
                    when ERROR =>
                        -- Parse error occurred
                        msg_error <= '1';
                        error_counter <= error_counter + 1;
                        state <= IDLE;
                    
                    when others =>
                        state <= IDLE;
                end case;

                -- Force return to IDLE on UDP payload end (but not if just completed)
                if udp_payload_end = '1' then
                    if state /= COMPLETE and state /= IDLE and state /= ERROR then
                        -- Check if completing this cycle (avoid race condition)
                        -- Completes when (byte_counter + 1) >= expected_length (after processing all data bytes 1 to expected_length-1)
                        if not (state = COUNT_BYTES and (byte_counter + 1) >= expected_length) then
                            msg_error <= '1';
                            error_counter <= error_counter + 1;
                            state <= IDLE;
                        end if;
                    elsif state = IDLE then
                        state <= IDLE;
                    end if;
                end if;
                
            end if;
        end if;
    end process;
    
    -- Output assignments
    msg_type <= current_msg_type;  -- Always show current message type (even if not complete)
    stock_locate <= stock_locate_reg;
    tracking_number <= tracking_number_reg;
    timestamp <= timestamp_reg;
    order_ref <= order_ref_reg;
    buy_sell <= buy_sell_reg;
    shares <= shares_reg;
    stock_symbol <= stock_symbol_reg;
    price <= price_reg;
    exec_shares <= exec_shares_reg;
    match_number <= match_number_reg;
    cancel_shares <= cancel_shares_reg;
    market_category <= market_category_reg;
    financial_status <= financial_status_reg;
    round_lot_size <= round_lot_size_reg;
    event_code <= event_code_reg;

    -- Order Replace ('U') outputs
    original_order_ref <= original_order_ref_reg;
    new_order_ref <= new_order_ref_reg;
    new_shares <= new_shares_reg;
    new_price <= new_price_reg;

    -- Trade ('P') outputs
    trade_price <= trade_price_reg;

    -- Cross Trade ('Q') outputs
    cross_shares <= cross_shares_reg;
    cross_price <= cross_price_reg;
    cross_type <= cross_type_reg;

    -- Symbol filtering statistics (v5)
    total_messages <= std_logic_vector(total_msg_counter);
    filtered_messages <= std_logic_vector(filtered_msg_counter);
    symbol_match <= symbol_match_reg;
    
    

end Behavioral;
