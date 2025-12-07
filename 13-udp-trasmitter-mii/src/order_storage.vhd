--------------------------------------------------------------------------------
-- Module: order_storage
-- Description: BRAM-based storage for active orders
--
-- Storage: 1024 entries × 130 bits = ~16 KB (4 BRAM36 blocks)
-- Access: Simple Dual-Port (one write port, one read port, same clock)
-- Addressing: Hash of order_ref (lower 10 bits)
--
-- Operations:
--   ADD     : Write new order to BRAM
--   LOOKUP  : Read order by order_ref
--   UPDATE  : Modify existing order (shares, price)
--   DELETE  : Mark order as invalid
--
-- BRAM Template: Simple Dual-Port with One Clock (Xilinx template)
--   Following simple_dual_one_clock.vhd pattern
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.order_book_pkg.all;

entity order_storage is
    Port (
        clk     : in  std_logic;
        rst     : in  std_logic;

        -- Write interface (Add/Update/Delete orders)
        wr_en       : in  std_logic;
        wr_addr     : in  std_logic_vector(ORDER_ADDR_WIDTH-1 downto 0);
        wr_order    : in  order_entry_t;

        -- Read interface (Lookup orders)
        rd_en       : in  std_logic;
        rd_addr     : in  std_logic_vector(ORDER_ADDR_WIDTH-1 downto 0);
        rd_order    : out order_entry_t;
        rd_valid    : out std_logic;  -- Read data valid (after 2-cycle latency)

        -- Statistics
        order_count : out unsigned(15 downto 0)  -- Total valid orders
    );
end order_storage;

architecture Behavioral of order_storage is

    -- BRAM storage array (using signal for Simple Dual-Port inference)
    -- Following rams_sdp_record.vhd pattern
    type bram_t is array (0 to MAX_ORDERS-1) of std_logic_vector(129 downto 0);
    signal bram : bram_t := (others => (others => '0'));
    
    -- Force BRAM inference (not LUTRAM)
    attribute ram_style : string;
    attribute ram_style of bram : signal is "block";

    -- Read pipeline registers (2-cycle latency)
    signal rd_data_stage1 : std_logic_vector(129 downto 0) := (others => '0');
    signal rd_data_stage2 : std_logic_vector(129 downto 0) := (others => '0');
    signal rd_valid_stage1 : std_logic := '0';
    signal rd_valid_stage2 : std_logic := '0';

    -- Order count tracking
    signal order_count_reg : unsigned(15 downto 0) := (others => '0');

    -- Separate storage for valid bits (to avoid read-modify-write on main BRAM)
    -- Small array (1024 bits) can be LUTRAM without issue
    type valid_bits_t is array (0 to MAX_ORDERS-1) of std_logic;
    signal valid_bits : valid_bits_t := (others => '0');

begin

    -- Output assignments
    rd_order <= slv_to_order(rd_data_stage2);
    rd_valid <= rd_valid_stage2;
    order_count <= order_count_reg;

    ------------------------------------------------------------------------
    -- BRAM Write Process (Port A)
    -- Following Xilinx rams_sdp_record.vhd template
    -- IMPORTANT: Write-only process - no reads to allow BRAM inference
    ------------------------------------------------------------------------
    process(clk)
        variable wr_data : std_logic_vector(129 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- Reset handled in order count process
            else
                if wr_en = '1' then
                    -- Convert order record to std_logic_vector
                    wr_data := order_to_slv(wr_order);
                    
                    -- Write to BRAM (signal-based, following rams_sdp_record.vhd pattern)
                    -- Pure write operation - no read-modify-write pattern
                    bram(to_integer(unsigned(wr_addr))) <= wr_data;
                    
                    -- Update separate valid bits storage (read from this, not BRAM)
                    valid_bits(to_integer(unsigned(wr_addr))) <= wr_order.valid;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- BRAM Read Process (Port B)
    -- Following Xilinx rams_sdp_record.vhd template exactly
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rd_data_stage1 <= (others => '0');
                rd_valid_stage1 <= '0';
            else
                if rd_en = '1' then
                    -- Direct read from BRAM signal (registered output)
                    rd_data_stage1 <= bram(to_integer(unsigned(rd_addr)));
                    rd_valid_stage1 <= '1';
                else
                    rd_valid_stage1 <= '0';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Read Output Pipeline (2-cycle latency)
    -- Stage 1: Already done in BRAM Read Process
    -- Stage 2: Register stage1 data
    ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rd_data_stage2 <= (others => '0');
                rd_valid_stage2 <= '0';
            else
                -- Pipeline stage 2: Register stage1 data
                rd_data_stage2 <= rd_data_stage1;
                rd_valid_stage2 <= rd_valid_stage1;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Order Count Tracking
    -- Count valid orders by monitoring writes
    -- Uses separate valid_bits array to avoid read-modify-write on main BRAM
    ------------------------------------------------------------------------
    process(clk)
        variable prev_valid : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                order_count_reg <= (others => '0');
            elsif wr_en = '1' then
                -- Read previous valid bit from separate storage (not BRAM)
                prev_valid := valid_bits(to_integer(unsigned(wr_addr)));
                
                -- Check if adding or removing an order
                if wr_order.valid = '1' and prev_valid = '0' then
                    -- Adding new order
                    order_count_reg <= order_count_reg + 1;
                elsif wr_order.valid = '0' and prev_valid = '1' then
                    -- Deleting order
                    if order_count_reg > 0 then
                        order_count_reg <= order_count_reg - 1;
                    end if;
                end if;
                -- If both valid or both invalid, count stays the same (update case)
            end if;
        end if;
    end process;

end Behavioral;
