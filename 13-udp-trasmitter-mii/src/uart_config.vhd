----------------------------------------------------------------------------------
-- UART Configuration Module
-- Allows dynamic configuration of UDP destination IP, MAC, and port via UART
-- Extended for Project 21: Adds order book configuration commands
--
-- Command Protocol (ASCII, newline-terminated):
--   IP:192.168.0.93\n       - Set destination IP address
--   MAC:AA:BB:CC:DD:EE:FF\n - Set destination MAC address
--   PORT:5000\n             - Set destination UDP port
--   THRESHOLD:1000\n        - Set BBO spread threshold (32-bit value)
--   SYMBOL:AAPL:1\n         - Enable/disable symbol (symbol name + 0/1)
--   STATUS\n                - Query FPGA status (acknowledge only)
--   ?\n                     - Query current configuration
--
-- Examples:
--   IP:192.168.0.93\n
--   MAC:FF:FF:FF:FF:FF:FF\n
--   PORT:5000\n
--   THRESHOLD:1000\n
--   SYMBOL:AAPL:1\n
--   SYMBOL:TSLA:0\n
--   STATUS\n
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_config is
    Generic (
        DEFAULT_IP   : std_logic_vector(31 downto 0) := x"C0A8005D";  -- 192.168.0.93
        DEFAULT_MAC  : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF";  -- Broadcast
        DEFAULT_PORT : std_logic_vector(15 downto 0) := x"1388"  -- 5000
    );
    Port (
        clk : in STD_LOGIC;
        rst : in STD_LOGIC;

        -- UART RX interface
        rx_data  : in STD_LOGIC_VECTOR(7 downto 0);
        rx_valid : in STD_LOGIC;

        -- Configuration outputs
        dst_ip   : out STD_LOGIC_VECTOR(31 downto 0);
        dst_mac  : out STD_LOGIC_VECTOR(47 downto 0);
        dst_port : out STD_LOGIC_VECTOR(15 downto 0);

        -- NEW: Configuration outputs for order book
        threshold_out     : out STD_LOGIC_VECTOR(31 downto 0);
        symbol_enable_out : out STD_LOGIC_VECTOR(7 downto 0);

        -- NEW: Status inputs for query response (for "STATUS\n" command)
        order_count_in  : in STD_LOGIC_VECTOR(31 downto 0);
        bbo_count_in    : in STD_LOGIC_VECTOR(31 downto 0);
        latency_p50_in  : in STD_LOGIC_VECTOR(31 downto 0);

        -- NEW: UART TX interface for STATUS response
        uart_tx_data  : out STD_LOGIC_VECTOR(7 downto 0);
        uart_tx_start : out STD_LOGIC;
        uart_tx_busy  : in  STD_LOGIC;

        -- Status
        config_updated : out STD_LOGIC  -- Pulse when config changes
    );
end uart_config;

architecture Behavioral of uart_config is

    -- Command buffer (max command: "MAC:AA:BB:CC:DD:EE:FF\n" = 24 chars)
    constant BUF_SIZE : integer := 32;
    type char_array_t is array (0 to BUF_SIZE-1) of std_logic_vector(7 downto 0);
    signal cmd_buffer : char_array_t := (others => (others => '0'));
    signal buf_index : integer range 0 to BUF_SIZE-1 := 0;

    -- Configuration registers
    signal dst_ip_reg   : std_logic_vector(31 downto 0) := DEFAULT_IP;
    signal dst_mac_reg  : std_logic_vector(47 downto 0) := DEFAULT_MAC;
    signal dst_port_reg : std_logic_vector(15 downto 0) := DEFAULT_PORT;
    
    -- NEW: Order book configuration registers
    signal threshold_reg     : std_logic_vector(31 downto 0) := x"000003E8";  -- Default: 1000
    signal symbol_enable_reg : std_logic_vector(7 downto 0) := x"FF";         -- All enabled

    -- State machine
    type state_type is (IDLE, RECEIVE_CMD, PARSE_CMD, SEND_STATUS);
    signal state : state_type := IDLE;
    
    -- STATUS response state machine
    type status_state_t is (IDLE, SEND_HEADER, SEND_ORDERS, SEND_BBO, SEND_LATENCY, SEND_CRLF, DONE);
    signal status_state : status_state_t := IDLE;
    signal status_char_index : integer range 0 to 63 := 0;
    signal uart_tx_start_int : std_logic := '0';
    signal uart_tx_busy_prev : std_logic := '0';
    
    -- Helper function: Convert 4-bit nibble to ASCII hex
    function nibble_to_hex(nibble : unsigned(3 downto 0)) return std_logic_vector is
    begin
        case nibble is
            when x"0" => return x"30";  -- '0'
            when x"1" => return x"31";  -- '1'
            when x"2" => return x"32";  -- '2'
            when x"3" => return x"33";  -- '3'
            when x"4" => return x"34";  -- '4'
            when x"5" => return x"35";  -- '5'
            when x"6" => return x"36";  -- '6'
            when x"7" => return x"37";  -- '7'
            when x"8" => return x"38";  -- '8'
            when x"9" => return x"39";  -- '9'
            when x"A" => return x"41";  -- 'A'
            when x"B" => return x"42";  -- 'B'
            when x"C" => return x"43";  -- 'C'
            when x"D" => return x"44";  -- 'D'
            when x"E" => return x"45";  -- 'E'
            when x"F" => return x"46";  -- 'F'
            when others => return x"30";
        end case;
    end function;

    -- ASCII constants
    constant CHAR_LF      : std_logic_vector(7 downto 0) := x"0A";  -- '\n' Line Feed
    constant CHAR_CR      : std_logic_vector(7 downto 0) := x"0D";  -- '\r' Carriage Return
    constant CHAR_COLON   : std_logic_vector(7 downto 0) := x"3A";  -- ':'
    constant CHAR_DOT     : std_logic_vector(7 downto 0) := x"2E";  -- '.'
    constant CHAR_QUESTION: std_logic_vector(7 downto 0) := x"3F";  -- '?'

    -- Helper function: ASCII hex digit to 4-bit value
    function hex_char_to_nibble(c : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case c is
            when x"30" => return x"0";  -- '0'
            when x"31" => return x"1";  -- '1'
            when x"32" => return x"2";  -- '2'
            when x"33" => return x"3";  -- '3'
            when x"34" => return x"4";  -- '4'
            when x"35" => return x"5";  -- '5'
            when x"36" => return x"6";  -- '6'
            when x"37" => return x"7";  -- '7'
            when x"38" => return x"8";  -- '8'
            when x"39" => return x"9";  -- '9'
            when x"41" | x"61" => return x"A";  -- 'A' or 'a'
            when x"42" | x"62" => return x"B";  -- 'B' or 'b'
            when x"43" | x"63" => return x"C";  -- 'C' or 'c'
            when x"44" | x"64" => return x"D";  -- 'D' or 'd'
            when x"45" | x"65" => return x"E";  -- 'E' or 'e'
            when x"46" | x"66" => return x"F";  -- 'F' or 'f'
            when others => return x"0";
        end case;
    end function;

    -- Helper function: ASCII decimal digit to 4-bit value
    function dec_char_to_nibble(c : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable temp : unsigned(7 downto 0);
    begin
        if c >= x"30" and c <= x"39" then  -- '0' to '9'
            temp := unsigned(c) - 48;  -- c - '0'
            return std_logic_vector(temp(3 downto 0));  -- Return only lower 4 bits
        else
            return x"0";
        end if;
    end function;

begin

    -- Output current configuration
    dst_ip <= dst_ip_reg;
    dst_mac <= dst_mac_reg;
    dst_port <= dst_port_reg;
    threshold_out <= threshold_reg;
    symbol_enable_out <= symbol_enable_reg;
    
    -- Default UART TX outputs
    uart_tx_data <= (others => '0');
    uart_tx_start <= uart_tx_start_int;

    -- Main process
    process(clk)
        variable cmd_type : std_logic_vector(7 downto 0);
        variable temp_ip : std_logic_vector(31 downto 0);
        variable temp_mac : std_logic_vector(47 downto 0);
        variable temp_port : std_logic_vector(15 downto 0);
        variable octet_val : unsigned(7 downto 0);
        variable port_val : unsigned(15 downto 0);
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                buf_index <= 0;
                cmd_buffer <= (others => (others => '0'));
                dst_ip_reg <= DEFAULT_IP;
                dst_mac_reg <= DEFAULT_MAC;
                dst_port_reg <= DEFAULT_PORT;
                threshold_reg <= x"000003E8";  -- Default: 1000
                symbol_enable_reg <= x"FF";    -- All enabled
                config_updated <= '0';
                status_state <= IDLE;
                status_char_index <= 0;
                uart_tx_start_int <= '0';
                uart_tx_busy_prev <= '0';

            else
                config_updated <= '0';  -- Default

                case state is

                    when IDLE =>
                        buf_index <= 0;
                        if rx_valid = '1' then
                            -- Ignore stray CR/LF characters (e.g., if terminal sends CRLF)
                            if rx_data /= CHAR_CR and rx_data /= CHAR_LF then
                                cmd_buffer(0) <= rx_data;
                                buf_index <= 1;
                                state <= RECEIVE_CMD;
                            end if;
                        end if;

                    when RECEIVE_CMD =>
                        if rx_valid = '1' then
                            -- Accept both CR ('\r') and LF ('\n') as command terminators
                            if rx_data = CHAR_LF or rx_data = CHAR_CR then
                                -- Command complete, parse it
                                state <= PARSE_CMD;
                            elsif buf_index < BUF_SIZE-1 then
                                cmd_buffer(buf_index) <= rx_data;
                                buf_index <= buf_index + 1;
                            else
                                -- Buffer overflow, reset
                                state <= IDLE;
                            end if;
                        end if;

                    when PARSE_CMD =>
                        -- Parse command based on first 3 characters
                        -- Check for "IP:", "MAC:", "PORT:", or "?"
                        -- Check for "STATUS" command
                        if buf_index = 6 and  -- 6 characters in buffer no need to check order of commands
                              cmd_buffer(0) = x"53" and  -- 'S'
                              cmd_buffer(1) = x"54" and  -- 'T'
                              cmd_buffer(2) = x"41" and  -- 'A'
                              cmd_buffer(3) = x"54" and  -- 'T'
                              cmd_buffer(4) = x"55" and  -- 'U'
                              cmd_buffer(5) = x"53" then -- 'S'

                            -- STATUS query command - send response via UART TX
                            config_updated <= '1';
                            state <= SEND_STATUS;
                            status_state <= SEND_HEADER;
                            status_char_index <= 0;

                        elsif buf_index >= 3 and
                           cmd_buffer(0) = x"49" and  -- 'I'
                           cmd_buffer(1) = x"50" and  -- 'P'
                           cmd_buffer(2) = CHAR_COLON then

                            -- Parse IP address: "IP:192.168.0.93"
                            -- Format: AAA.BBB.CCC.DDD (max 3 digits per octet)
                            idx := 3;  -- Start after "IP:"
                            temp_ip := (others => '0');

                            -- Parse first octet (max 3 digits)
                            octet_val := (others => '0');
                            for i in 0 to 2 loop
                                exit when idx >= buf_index or cmd_buffer(idx) = CHAR_DOT;
                                -- x*10 = x*8 + x*2 (shift-and-add is faster than multiply)
                                octet_val := resize(shift_left(octet_val, 3) + shift_left(octet_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 8), 8);
                                idx := idx + 1;
                            end loop;
                            temp_ip(31 downto 24) := std_logic_vector(octet_val);
                            idx := idx + 1;  -- Skip dot

                            -- Parse second octet (max 3 digits)
                            octet_val := (others => '0');
                            for i in 0 to 2 loop
                                exit when idx >= buf_index or cmd_buffer(idx) = CHAR_DOT;
                                octet_val := resize(shift_left(octet_val, 3) + shift_left(octet_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 8), 8);
                                idx := idx + 1;
                            end loop;
                            temp_ip(23 downto 16) := std_logic_vector(octet_val);
                            idx := idx + 1;  -- Skip dot

                            -- Parse third octet (max 3 digits)
                            octet_val := (others => '0');
                            for i in 0 to 2 loop
                                exit when idx >= buf_index or cmd_buffer(idx) = CHAR_DOT;
                                octet_val := resize(shift_left(octet_val, 3) + shift_left(octet_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 8), 8);
                                idx := idx + 1;
                            end loop;
                            temp_ip(15 downto 8) := std_logic_vector(octet_val);
                            idx := idx + 1;  -- Skip dot

                            -- Parse fourth octet (max 3 digits)
                            octet_val := (others => '0');
                            for i in 0 to 2 loop
                                exit when idx >= buf_index;
                                octet_val := resize(shift_left(octet_val, 3) + shift_left(octet_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 8), 8);
                                idx := idx + 1;
                            end loop;
                            temp_ip(7 downto 0) := std_logic_vector(octet_val);

                            -- Update register
                            dst_ip_reg <= temp_ip;
                            config_updated <= '1';

                        elsif buf_index >= 4 and
                              cmd_buffer(0) = x"4D" and  -- 'M'
                              cmd_buffer(1) = x"41" and  -- 'A'
                              cmd_buffer(2) = x"43" and  -- 'C'
                              cmd_buffer(3) = CHAR_COLON then

                            -- Parse MAC address: "MAC:AA:BB:CC:DD:EE:FF"
                            -- Format: HH:HH:HH:HH:HH:HH (17 chars after colon)
                            temp_mac := (others => '0');
                            idx := 4;  -- Start after "MAC:"

                            -- Parse 6 octets (AA, BB, CC, DD, EE, FF)
                            for i in 0 to 5 loop
                                if idx < buf_index-1 then
                                    temp_mac(47 - i*8 downto 47 - i*8 - 3) := hex_char_to_nibble(cmd_buffer(idx));
                                    temp_mac(47 - i*8 - 4 downto 47 - i*8 - 7) := hex_char_to_nibble(cmd_buffer(idx+1));
                                    idx := idx + 3;  -- Skip 2 hex chars + colon (or end)
                                end if;
                            end loop;

                            dst_mac_reg <= temp_mac;
                            config_updated <= '1';

                        elsif buf_index >= 5 and
                              cmd_buffer(0) = x"50" and  -- 'P'
                              cmd_buffer(1) = x"4F" and  -- 'O'
                              cmd_buffer(2) = x"52" and  -- 'R'
                              cmd_buffer(3) = x"54" and  -- 'T'
                              cmd_buffer(4) = CHAR_COLON then

                            -- Parse port: "PORT:5000"
                            idx := 5;  -- Start after "PORT:"
                            port_val := (others => '0');

                            -- Parse port number (max 5 digits for 0-65535)
                            for i in 0 to 4 loop
                                exit when idx >= buf_index;
                                -- x*10 = x*8 + x*2 (shift-and-add is faster than multiply)
                                port_val := resize(shift_left(port_val, 3) + shift_left(port_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 16), 16);
                                idx := idx + 1;
                            end loop;

                            dst_port_reg <= std_logic_vector(port_val);
                            config_updated <= '1';

                        elsif buf_index >= 10 and
                              cmd_buffer(0) = x"54" and  -- 'T'
                              cmd_buffer(1) = x"48" and  -- 'H'
                              cmd_buffer(2) = x"52" and  -- 'R'
                              cmd_buffer(3) = x"45" and  -- 'E'
                              cmd_buffer(4) = x"53" and  -- 'S'
                              cmd_buffer(5) = x"48" and  -- 'H'
                              cmd_buffer(6) = x"4F" and  -- 'O'
                              cmd_buffer(7) = x"4C" and  -- 'L'
                              cmd_buffer(8) = x"44" and  -- 'D'
                              cmd_buffer(9) = CHAR_COLON then

                            -- Parse THRESHOLD command: "THRESHOLD:1000"
                            idx := 10;  -- Start after "THRESHOLD:"
                            port_val := (others => '0');  -- Reuse port_val variable (16-bit)
                            
                            -- Parse threshold value (max 10 digits for 32-bit value)
                            for i in 0 to 9 loop
                                exit when idx >= buf_index;
                                -- x*10 = x*8 + x*2 (shift-and-add is faster than multiply)
                                port_val := resize(shift_left(port_val, 3) + shift_left(port_val, 1) + resize(unsigned(dec_char_to_nibble(cmd_buffer(idx))), 16), 16);
                                idx := idx + 1;
                            end loop;
                            
                            -- Extend to 32-bit and update register
                            threshold_reg <= x"0000" & std_logic_vector(port_val);
                            config_updated <= '1';

                        elsif buf_index >= 7 and
                              cmd_buffer(0) = x"53" and  -- 'S'
                              cmd_buffer(1) = x"59" and  -- 'Y'
                              cmd_buffer(2) = x"4D" and  -- 'M'
                              cmd_buffer(3) = x"42" and  -- 'B'
                              cmd_buffer(4) = x"4F" and  -- 'O'
                              cmd_buffer(5) = x"4C" and  -- 'L'
                              cmd_buffer(6) = CHAR_COLON then

                            -- Parse SYMBOL command: "SYMBOL:AAPL:1" or "SYMBOL:TSLA:0"
                            -- Symbol names: AAPL=0, TSLA=1, SPY=2, QQQ=3, GOOGL=4, MSFT=5, AMZN=6, NVDA=7
                            
                            -- Simple parsing: Check byte 7-10 for symbol name
                            if buf_index >= 12 then
                                -- Match symbol (case-insensitive)
                                if (cmd_buffer(7) = x"41" or cmd_buffer(7) = x"61") and  -- 'A' or 'a'
                                   (cmd_buffer(8) = x"41" or cmd_buffer(8) = x"61") and  -- 'A'
                                   (cmd_buffer(9) = x"50" or cmd_buffer(9) = x"70") and  -- 'P'
                                   (cmd_buffer(10) = x"4C" or cmd_buffer(10) = x"6C") then -- 'L'
                                    idx := 0;  -- AAPL = bit 0
                                    
                                elsif (cmd_buffer(7) = x"54" or cmd_buffer(7) = x"74") and  -- 'T'
                                      (cmd_buffer(8) = x"53" or cmd_buffer(8) = x"73") and  -- 'S'
                                      (cmd_buffer(9) = x"4C" or cmd_buffer(9) = x"6C") and  -- 'L'
                                      (cmd_buffer(10) = x"41" or cmd_buffer(10) = x"61") then -- 'A'
                                    idx := 1;  -- TSLA = bit 1
                                    
                                elsif (cmd_buffer(7) = x"53" or cmd_buffer(7) = x"73") and  -- 'S'
                                      (cmd_buffer(8) = x"50" or cmd_buffer(8) = x"70") and  -- 'P'
                                      (cmd_buffer(9) = x"59" or cmd_buffer(9) = x"79") then  -- 'Y'
                                    idx := 2;  -- SPY = bit 2
                                    
                                elsif (cmd_buffer(7) = x"51" or cmd_buffer(7) = x"71") and  -- 'Q'
                                      (cmd_buffer(8) = x"51" or cmd_buffer(8) = x"71") and  -- 'Q'
                                      (cmd_buffer(9) = x"51" or cmd_buffer(9) = x"71") then  -- 'Q'
                                    idx := 3;  -- QQQ = bit 3
                                    
                                elsif (cmd_buffer(7) = x"47" or cmd_buffer(7) = x"67") and  -- 'G'
                                      (cmd_buffer(8) = x"4F" or cmd_buffer(8) = x"6F") and  -- 'O'
                                      (cmd_buffer(9) = x"4F" or cmd_buffer(9) = x"6F") and  -- 'O'
                                      (cmd_buffer(10) = x"47" or cmd_buffer(10) = x"67") and  -- 'G'
                                      (cmd_buffer(11) = x"4C" or cmd_buffer(11) = x"6C") then -- 'L'
                                    idx := 4;  -- GOOGL = bit 4
                                    
                                elsif (cmd_buffer(7) = x"4D" or cmd_buffer(7) = x"6D") and  -- 'M'
                                      (cmd_buffer(8) = x"53" or cmd_buffer(8) = x"73") and  -- 'S'
                                      (cmd_buffer(9) = x"46" or cmd_buffer(9) = x"66") and  -- 'F'
                                      (cmd_buffer(10) = x"54" or cmd_buffer(10) = x"74") then -- 'T'
                                    idx := 5;  -- MSFT = bit 5
                                    
                                elsif (cmd_buffer(7) = x"41" or cmd_buffer(7) = x"61") and  -- 'A'
                                      (cmd_buffer(8) = x"4D" or cmd_buffer(8) = x"6D") and  -- 'M'
                                      (cmd_buffer(9) = x"5A" or cmd_buffer(9) = x"7A") and  -- 'Z'
                                      (cmd_buffer(10) = x"4E" or cmd_buffer(10) = x"6E") then -- 'N'
                                    idx := 6;  -- AMZN = bit 6
                                    
                                elsif (cmd_buffer(7) = x"4E" or cmd_buffer(7) = x"6E") and  -- 'N'
                                      (cmd_buffer(8) = x"56" or cmd_buffer(8) = x"76") and  -- 'V'
                                      (cmd_buffer(9) = x"44" or cmd_buffer(9) = x"64") and  -- 'D'
                                      (cmd_buffer(10) = x"41" or cmd_buffer(10) = x"61") then -- 'A'
                                    idx := 7;  -- NVDA = bit 7
                                    
                                else
                                    idx := 0;  -- Default to AAPL if unknown
                                end if;
                                
                                -- Get enable/disable value (byte after colon after symbol)
                                -- Format: "SYMBOL:AAPL:1" -> byte 12 = '1' or '0'
                                if buf_index > 12 and cmd_buffer(12) = x"31" then  -- '1' = enable
                                    symbol_enable_reg(idx) <= '1';
                                else
                                    symbol_enable_reg(idx) <= '0';
                                end if;
                                
                                config_updated <= '1';
                            end if;


                        end if;
                        
                        if state /= SEND_STATUS then
                            state <= IDLE;
                        end if;

                    when SEND_STATUS =>
                        -- STATUS response state machine
                        -- Format: "STATUS: Orders=XXXXXXXX, BBO=XXXXXXXX, Lat=XXXXXXXXns\r\n"
                        uart_tx_busy_prev <= uart_tx_busy;
                        
                        case status_state is
                            when IDLE =>
                                status_state <= SEND_HEADER;
                                status_char_index <= 0;
                                
                            when SEND_HEADER =>
                                -- Send "STATUS: " (8 characters)
                                if uart_tx_busy = '0' and uart_tx_start_int = '0' then
                                    case status_char_index is
                                        when 0 => uart_tx_data <= x"53"; uart_tx_start_int <= '1'; -- 'S'
                                        when 1 => uart_tx_data <= x"54"; uart_tx_start_int <= '1'; -- 'T'
                                        when 2 => uart_tx_data <= x"41"; uart_tx_start_int <= '1'; -- 'A'
                                        when 3 => uart_tx_data <= x"54"; uart_tx_start_int <= '1'; -- 'T'
                                        when 4 => uart_tx_data <= x"55"; uart_tx_start_int <= '1'; -- 'U'
                                        when 5 => uart_tx_data <= x"53"; uart_tx_start_int <= '1'; -- 'S'
                                        when 6 => uart_tx_data <= x"3A"; uart_tx_start_int <= '1'; -- ':'
                                        when 7 => uart_tx_data <= x"20"; uart_tx_start_int <= '1'; -- ' '
                                        when others => null;
                                    end case;
                                end if;
                                
                                -- Clear start pulse after one cycle
                                if uart_tx_busy = '1' then
                                    uart_tx_start_int <= '0';
                                end if;
                                
                                -- Advance to next character when transmission completes
                                if uart_tx_busy_prev = '1' and uart_tx_busy = '0' then
                                    if status_char_index < 7 then
                                        status_char_index <= status_char_index + 1;
                                    else
                                        status_state <= SEND_ORDERS;
                                        status_char_index <= 0;
                                    end if;
                                end if;
                                
                            when SEND_ORDERS =>
                                -- Send "Orders=" followed by 8 hex digits, then ", "
                                if uart_tx_busy = '0' and uart_tx_start_int = '0' then
                                    case status_char_index is
                                        when 0 => uart_tx_data <= x"4F"; uart_tx_start_int <= '1'; -- 'O'
                                        when 1 => uart_tx_data <= x"72"; uart_tx_start_int <= '1'; -- 'r'
                                        when 2 => uart_tx_data <= x"64"; uart_tx_start_int <= '1'; -- 'd'
                                        when 3 => uart_tx_data <= x"65"; uart_tx_start_int <= '1'; -- 'e'
                                        when 4 => uart_tx_data <= x"72"; uart_tx_start_int <= '1'; -- 'r'
                                        when 5 => uart_tx_data <= x"73"; uart_tx_start_int <= '1'; -- 's'
                                        when 6 => uart_tx_data <= x"3D"; uart_tx_start_int <= '1'; -- '='
                                        when 7 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(31 downto 28))); uart_tx_start_int <= '1';
                                        when 8 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(27 downto 24))); uart_tx_start_int <= '1';
                                        when 9 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(23 downto 20))); uart_tx_start_int <= '1';
                                        when 10 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(19 downto 16))); uart_tx_start_int <= '1';
                                        when 11 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(15 downto 12))); uart_tx_start_int <= '1';
                                        when 12 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(11 downto 8))); uart_tx_start_int <= '1';
                                        when 13 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(7 downto 4))); uart_tx_start_int <= '1';
                                        when 14 => uart_tx_data <= nibble_to_hex(unsigned(order_count_in(3 downto 0))); uart_tx_start_int <= '1';
                                        when 15 => uart_tx_data <= x"2C"; uart_tx_start_int <= '1'; -- ','
                                        when 16 => uart_tx_data <= x"20"; uart_tx_start_int <= '1'; -- ' '
                                        when others => null;
                                    end case;
                                end if;
                                
                                -- Clear start pulse after one cycle
                                if uart_tx_busy = '1' then
                                    uart_tx_start_int <= '0';
                                end if;
                                
                                -- Advance to next character when transmission completes
                                if uart_tx_busy_prev = '1' and uart_tx_busy = '0' then
                                    if status_char_index < 16 then
                                        status_char_index <= status_char_index + 1;
                                    else
                                        status_state <= SEND_BBO;
                                        status_char_index <= 0;
                                    end if;
                                end if;
                                
                            when SEND_BBO =>
                                -- Send "BBO=" followed by 8 hex digits, then ", "
                                if uart_tx_busy = '0' and uart_tx_start_int = '0' then
                                    case status_char_index is
                                        when 0 => uart_tx_data <= x"42"; uart_tx_start_int <= '1'; -- 'B'
                                        when 1 => uart_tx_data <= x"42"; uart_tx_start_int <= '1'; -- 'B'
                                        when 2 => uart_tx_data <= x"4F"; uart_tx_start_int <= '1'; -- 'O'
                                        when 3 => uart_tx_data <= x"3D"; uart_tx_start_int <= '1'; -- '='
                                        when 4 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(31 downto 28))); uart_tx_start_int <= '1';
                                        when 5 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(27 downto 24))); uart_tx_start_int <= '1';
                                        when 6 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(23 downto 20))); uart_tx_start_int <= '1';
                                        when 7 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(19 downto 16))); uart_tx_start_int <= '1';
                                        when 8 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(15 downto 12))); uart_tx_start_int <= '1';
                                        when 9 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(11 downto 8))); uart_tx_start_int <= '1';
                                        when 10 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(7 downto 4))); uart_tx_start_int <= '1';
                                        when 11 => uart_tx_data <= nibble_to_hex(unsigned(bbo_count_in(3 downto 0))); uart_tx_start_int <= '1';
                                        when 12 => uart_tx_data <= x"2C"; uart_tx_start_int <= '1'; -- ','
                                        when 13 => uart_tx_data <= x"20"; uart_tx_start_int <= '1'; -- ' '
                                        when others => null;
                                    end case;
                                end if;
                                
                                -- Clear start pulse after one cycle
                                if uart_tx_busy = '1' then
                                    uart_tx_start_int <= '0';
                                end if;
                                
                                -- Advance to next character when transmission completes
                                if uart_tx_busy_prev = '1' and uart_tx_busy = '0' then
                                    if status_char_index < 13 then
                                        status_char_index <= status_char_index + 1;
                                    else
                                        status_state <= SEND_LATENCY;
                                        status_char_index <= 0;
                                    end if;
                                end if;
                                
                            when SEND_LATENCY =>
                                -- Send "Lat=" followed by 8 hex digits, then "ns"
                                if uart_tx_busy = '0' and uart_tx_start_int = '0' then
                                    case status_char_index is
                                        when 0 => uart_tx_data <= x"4C"; uart_tx_start_int <= '1'; -- 'L'
                                        when 1 => uart_tx_data <= x"61"; uart_tx_start_int <= '1'; -- 'a'
                                        when 2 => uart_tx_data <= x"74"; uart_tx_start_int <= '1'; -- 't'
                                        when 3 => uart_tx_data <= x"3D"; uart_tx_start_int <= '1'; -- '='
                                        when 4 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(31 downto 28))); uart_tx_start_int <= '1';
                                        when 5 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(27 downto 24))); uart_tx_start_int <= '1';
                                        when 6 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(23 downto 20))); uart_tx_start_int <= '1';
                                        when 7 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(19 downto 16))); uart_tx_start_int <= '1';
                                        when 8 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(15 downto 12))); uart_tx_start_int <= '1';
                                        when 9 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(11 downto 8))); uart_tx_start_int <= '1';
                                        when 10 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(7 downto 4))); uart_tx_start_int <= '1';
                                        when 11 => uart_tx_data <= nibble_to_hex(unsigned(latency_p50_in(3 downto 0))); uart_tx_start_int <= '1';
                                        when 12 => uart_tx_data <= x"6E"; uart_tx_start_int <= '1'; -- 'n'
                                        when 13 => uart_tx_data <= x"73"; uart_tx_start_int <= '1'; -- 's'
                                        when others => null;
                                    end case;
                                end if;
                                
                                -- Clear start pulse after one cycle
                                if uart_tx_busy = '1' then
                                    uart_tx_start_int <= '0';
                                end if;
                                
                                -- Advance to next character when transmission completes
                                if uart_tx_busy_prev = '1' and uart_tx_busy = '0' then
                                    if status_char_index < 13 then
                                        status_char_index <= status_char_index + 1;
                                    else
                                        status_state <= SEND_CRLF;
                                        status_char_index <= 0;
                                    end if;
                                end if;
                                
                            when SEND_CRLF =>
                                -- Send "\r\n"
                                if uart_tx_busy = '0' and uart_tx_start_int = '0' then
                                    case status_char_index is
                                        when 0 => uart_tx_data <= CHAR_CR; uart_tx_start_int <= '1'; -- '\r'
                                        when 1 => uart_tx_data <= CHAR_LF; uart_tx_start_int <= '1'; -- '\n'
                                        when others => null;
                                    end case;
                                end if;
                                
                                -- Clear start pulse after one cycle
                                if uart_tx_busy = '1' then
                                    uart_tx_start_int <= '0';
                                end if;
                                
                                -- Advance to next character when transmission completes
                                if uart_tx_busy_prev = '1' and uart_tx_busy = '0' then
                                    if status_char_index < 1 then
                                        status_char_index <= status_char_index + 1;
                                    else
                                        status_state <= DONE;
                                    end if;
                                end if;
                                
                            when DONE =>
                                status_state <= IDLE;
                                state <= IDLE;
                                status_char_index <= 0;
                                
                        end case;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
