-- Query Optimization for itch_messages with order_symbol_map lookup
-- Original slow query uses COALESCE in WHERE which prevents index usage

-- ============================================================================
-- OPTION 1: Use UNION to split the query (RECOMMENDED - Fastest)
-- ============================================================================
-- This allows MySQL to use indexes on both branches
SELECT m.message_type, m.timestamp_ns, 
       m.stock_symbol as stock_symbol, 
       m.raw_message
FROM itch_messages m
WHERE m.stock_symbol = 'AAPL'  -- Note: removed leading space
  AND m.message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P')
  
UNION ALL

SELECT m.message_type, m.timestamp_ns, 
       o.stock_symbol as stock_symbol, 
       m.raw_message
FROM itch_messages m
INNER JOIN order_symbol_map o ON m.order_ref = o.order_ref
WHERE m.stock_symbol IS NULL
  AND o.stock_symbol = 'AAPL'
  AND m.message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P')

ORDER BY timestamp_ns;

-- ============================================================================
-- OPTION 2: Use OR conditions (Alternative - may be slower than UNION)
-- ============================================================================
SELECT m.message_type, m.timestamp_ns, 
       COALESCE(m.stock_symbol, o.stock_symbol) as stock_symbol, 
       m.raw_message
FROM itch_messages m
LEFT JOIN order_symbol_map o ON m.order_ref = o.order_ref
WHERE (m.stock_symbol = 'AAPL' OR (m.stock_symbol IS NULL AND o.stock_symbol = 'AAPL'))
  AND m.message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P')
ORDER BY m.timestamp_ns;

-- ============================================================================
-- INDEX RECOMMENDATIONS
-- ============================================================================

-- 1. Composite covering index for messages with stock_symbol (most common case)
-- This index covers the entire query for the first UNION branch
ALTER TABLE itch_messages 
ADD INDEX idx_symbol_type_time (stock_symbol, message_type, timestamp_ns);

-- 2. Composite index for messages without stock_symbol (needs join)
-- This helps the second UNION branch
ALTER TABLE itch_messages 
ADD INDEX idx_null_symbol_type_orderref (stock_symbol, message_type, order_ref, timestamp_ns)
WHERE stock_symbol IS NULL;  -- Note: MySQL 8.0+ functional index, or use regular index

-- For MySQL < 8.0, use regular index (less selective but still helps):
ALTER TABLE itch_messages 
ADD INDEX idx_type_orderref_time (message_type, order_ref, timestamp_ns);

-- 3. Ensure order_symbol_map has proper index (already has PRIMARY KEY on order_ref)
-- Add index on stock_symbol if doing lookups by symbol
ALTER TABLE order_symbol_map 
ADD INDEX idx_symbol (stock_symbol);

-- 4. If you frequently query by message_type + timestamp, add this:
ALTER TABLE itch_messages 
ADD INDEX idx_type_time (message_type, timestamp_ns);

-- ============================================================================
-- OPTION 3: Denormalization (Best for read-heavy workloads)
-- ============================================================================
-- If this query pattern is common, consider denormalizing:
-- Add a computed/resolved_symbol column that's always populated
-- This eliminates the need for JOINs and COALESCE

-- Add column:
ALTER TABLE itch_messages 
ADD COLUMN resolved_symbol VARCHAR(8) AS (
    COALESCE(stock_symbol, 
        (SELECT stock_symbol FROM order_symbol_map WHERE order_ref = itch_messages.order_ref LIMIT 1)
    )
) STORED;  -- STORED = materialized, VIRTUAL = computed on-the-fly

-- Add index on resolved_symbol:
ALTER TABLE itch_messages 
ADD INDEX idx_resolved_symbol_type_time (resolved_symbol, message_type, timestamp_ns);

-- Then query becomes simple and fast:
SELECT message_type, timestamp_ns, resolved_symbol as stock_symbol, raw_message
FROM itch_messages
WHERE resolved_symbol = 'AAPL'
  AND message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P')
ORDER BY timestamp_ns;

-- ============================================================================
-- PERFORMANCE ANALYSIS QUERIES
-- ============================================================================

-- Check current index usage:
EXPLAIN SELECT m.message_type, m.timestamp_ns, 
       COALESCE(m.stock_symbol, o.stock_symbol) as stock_symbol, 
       m.raw_message
FROM itch_messages m
LEFT JOIN order_symbol_map o ON m.order_ref = o.order_ref
WHERE COALESCE(m.stock_symbol, o.stock_symbol) = 'AAPL' 
  AND m.message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P')
ORDER BY m.timestamp_ns;

-- Check table statistics:
SELECT 
    table_name,
    table_rows,
    data_length / 1024 / 1024 as data_mb,
    index_length / 1024 / 1024 as index_mb
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN ('itch_messages', 'order_symbol_map');

-- Check cardinality of stock_symbol (how many NULLs vs populated):
SELECT 
    COUNT(*) as total,
    COUNT(stock_symbol) as with_symbol,
    COUNT(*) - COUNT(stock_symbol) as null_symbol,
    ROUND(100.0 * COUNT(stock_symbol) / COUNT(*), 2) as pct_with_symbol
FROM itch_messages
WHERE message_type IN ('A', 'F', 'E', 'C', 'X', 'D', 'U', 'P');

