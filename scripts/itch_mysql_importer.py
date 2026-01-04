#!/usr/bin/env python3
"""
itch_mysql_importer_fixed.py - Import ITCH binary files to MySQL/MariaDB

FIXED: Uses streaming/generator pattern to avoid memory explosion on Linux.
The original loaded entire file into a list causing segfaults with large files.

Requirements:
    pip install pymysql

Usage:
    python itch_mysql_importer_fixed.py 12302019.NASDAQ_ITCH50 \
        --host localhost --user root --password xxx --database nasdaq_itch
"""

import sys
import argparse
import struct
from collections import defaultdict
import time

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("\nERROR: PyMySQL not installed")
    print("Install with: pip install pymysql")
    sys.exit(1)


# ITCH 5.0 message lengths (bytes, excluding 2-byte length prefix)
ITCH_MESSAGE_LENGTHS = {
    b'S': 12,   # System Event
    b'R': 39,   # Stock Directory
    b'H': 25,   # Stock Trading Action
    b'Y': 20,   # Reg SHO Restriction
    b'L': 26,   # Market Participant Position
    b'V': 35,   # MWCB Decline Level
    b'W': 12,   # MWCB Status
    b'K': 28,   # IPO Quoting Period Update
    b'J': 35,   # LULD Auction Collar
    b'h': 21,   # Operational Halt
    b'A': 36,   # Add Order (no MPID)
    b'F': 40,   # Add Order (with MPID)
    b'E': 31,   # Order Executed
    b'C': 36,   # Order Executed with Price
    b'X': 23,   # Order Cancel
    b'D': 19,   # Order Delete
    b'U': 35,   # Order Replace
    b'P': 44,   # Trade (non-cross)
    b'Q': 40,   # Cross Trade
    b'B': 19,   # Broken Trade
    b'I': 50,   # NOII
}

# Message types we care about (FPGA supported + order lifecycle)
SUPPORTED_TYPES = {
    'S': 'System Event',
    'R': 'Stock Directory', 
    'A': 'Add Order',
    'F': 'Add Order (MPID)',
    'E': 'Order Executed',
    'C': 'Order Executed Price',
    'X': 'Order Cancel',
    'D': 'Order Delete',
    'U': 'Order Replace',
    'P': 'Trade',
    'Q': 'Cross Trade'
}


def parse_itch_message(msg_type_byte: bytes, payload: bytes):
    """
    Parse ITCH message to extract symbol and timestamp.
    
    Returns dict with type, symbol, timestamp_ns, raw bytes.
    Symbol extraction varies by message type per ITCH 5.0 spec.
    """
    msg_type = msg_type_byte.decode('ascii')
    
    if msg_type not in SUPPORTED_TYPES:
        return None
    
    result = {
        'type': msg_type,
        'symbol': None,
        'timestamp_ns': None,
        'order_ref': None,
        'raw': payload
    }
    
    # Extract timestamp (bytes 5-10, 6 bytes, nanoseconds since midnight)
    # All messages have timestamp at same offset
    if len(payload) >= 11:
        # 6-byte big-endian timestamp
        ts_bytes = payload[5:11]
        result['timestamp_ns'] = int.from_bytes(ts_bytes, 'big')
    
    # Extract symbol based on message type
    # ITCH 5.0 spec defines different offsets per message type
    
    if msg_type == 'S':
        # System Event: No symbol (12 bytes total)
        pass
        
    elif msg_type == 'R':
        # Stock Directory: symbol at offset 11, 8 bytes
        if len(payload) >= 19:
            result['symbol'] = payload[11:19].decode('ascii', errors='ignore').strip()
            
    elif msg_type == 'A':
        # Add Order (no MPID): 36 bytes
        # order_ref at 11-18 (8 bytes), buy_sell at 19, shares at 20-23
        # symbol at 24-31 (8 bytes), price at 32-35
        if len(payload) >= 32:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            result['symbol'] = payload[24:32].decode('ascii', errors='ignore').strip()
            
    elif msg_type == 'F':
        # Add Order (with MPID): 40 bytes
        # Same as A but with 4-byte MPID at end
        if len(payload) >= 32:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            result['symbol'] = payload[24:32].decode('ascii', errors='ignore').strip()
            
    elif msg_type == 'E':
        # Order Executed: 31 bytes
        # order_ref at 11-18, NO SYMBOL (must lookup from Add order)
        if len(payload) >= 19:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
        # symbol = None (intentional - ITCH spec doesn't include it)
        
    elif msg_type == 'C':
        # Order Executed with Price: 36 bytes
        # order_ref at 11-18, NO SYMBOL
        if len(payload) >= 19:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            
    elif msg_type == 'X':
        # Order Cancel: 23 bytes
        # order_ref at 11-18, NO SYMBOL
        if len(payload) >= 19:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            
    elif msg_type == 'D':
        # Order Delete: 19 bytes
        # order_ref at 11-18, NO SYMBOL
        if len(payload) >= 19:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            
    elif msg_type == 'U':
        # Order Replace: 35 bytes
        # orig_order_ref at 11-18, new_order_ref at 19-26
        # shares at 27-30, price at 31-34
        # NO SYMBOL (must lookup from original Add order)
        if len(payload) >= 27:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')  # Original ref
            
    elif msg_type == 'P':
        # Trade (non-cross): 44 bytes
        # order_ref at 11-18, buy_sell at 19, shares at 20-23
        # symbol at 24-31 (8 bytes), price at 32-35, match at 36-43
        if len(payload) >= 32:
            result['order_ref'] = int.from_bytes(payload[11:19], 'big')
            result['symbol'] = payload[24:32].decode('ascii', errors='ignore').strip()
            
    elif msg_type == 'Q':
        # Cross Trade: 40 bytes
        # shares at 11-18 (8 bytes!), symbol at 19-26, price at 27-30
        if len(payload) >= 27:
            result['symbol'] = payload[19:27].decode('ascii', errors='ignore').strip()
    
    return result


def stream_itch_file(filename: str, max_messages: int = None):
    """
    Generator that streams ITCH messages from binary file.
    
    ITCH 5.0 binary format:
    - Each message prefixed with 2-byte big-endian length
    - Message data follows immediately
    
    Yields:
        Parsed message dicts
    """
    message_count = 0
    
    with open(filename, 'rb') as f:
        while True:
            # Read 2-byte length prefix
            length_bytes = f.read(2)
            if not length_bytes or len(length_bytes) < 2:
                break
            
            msg_length = struct.unpack('>H', length_bytes)[0]
            
            if msg_length == 0:
                continue
            
            # Read message payload
            payload = f.read(msg_length)
            if len(payload) < msg_length:
                print(f"Warning: Truncated message at offset {f.tell()}, expected {msg_length}, got {len(payload)}")
                break
            
            # Remove trailing null bytes (ITCH messages should never have trailing zeros)
            # This prevents database padding issues and ensures clean message storage
            payload = payload.rstrip(b'\x00')
            
            # Validate payload is not empty after stripping
            if len(payload) == 0:
                continue  # Skip empty messages
            
            # Get message type (first byte)
            msg_type_byte = payload[0:1]
            
            # Parse message
            msg = parse_itch_message(msg_type_byte, payload)
            if msg:
                yield msg
                message_count += 1
                
                if message_count % 1_000_000 == 0:
                    print(f"  Streamed {message_count:,} messages...")
                
                if max_messages and message_count >= max_messages:
                    print(f"Reached limit of {max_messages:,} messages")
                    break


class MySQLITCHImporter:
    """Import ITCH messages to MySQL with streaming and order_ref tracking"""

    def __init__(self, host, user, password, database='itch_data', port=3306):
        print(f"Connecting to MySQL: {user}@{host}:{port}/{database}")

        self.conn = pymysql.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            database=database,
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=False
        )
        self.cursor = self.conn.cursor()

        # Performance settings
        self.cursor.execute("SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO'")
        self.cursor.execute("SET SESSION autocommit = 0")
        self.cursor.execute("SET SESSION unique_checks = 0")
        self.cursor.execute("SET SESSION foreign_key_checks = 0")
        
        # Order reference to symbol mapping (for E/X/D/C messages)
        # This is the KEY fix - track order_ref -> symbol from A/F messages
        self.order_ref_to_symbol = {}
        
        print("Connected to MySQL successfully")

    def create_tables(self, drop_existing=False):
        """Create tables with order_ref column for joins"""

        if drop_existing:
            print("Dropping existing tables...")
            self.cursor.execute("DROP TABLE IF EXISTS itch_messages")
            self.cursor.execute("DROP TABLE IF EXISTS symbols")
            self.cursor.execute("DROP TABLE IF EXISTS import_stats")

        print("Creating tables...")

        # Main messages table with order_ref for E/X/D/C lookups
        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS itch_messages (
                id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                timestamp_ns BIGINT UNSIGNED NOT NULL,
                message_type CHAR(1) NOT NULL,
                stock_symbol VARCHAR(8),
                order_ref BIGINT UNSIGNED,
                raw_message BLOB NOT NULL,

                INDEX idx_timestamp (timestamp_ns),
                INDEX idx_symbol_time (stock_symbol, timestamp_ns),
                INDEX idx_type (message_type),
                INDEX idx_order_ref (order_ref),
                INDEX idx_symbol_type (stock_symbol, message_type)
            ) ENGINE=InnoDB
            ROW_FORMAT=COMPRESSED
            KEY_BLOCK_SIZE=8
        """)

        # Symbols catalog
        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS symbols (
                symbol VARCHAR(8) PRIMARY KEY,
                message_count INT UNSIGNED DEFAULT 0,
                first_seen BIGINT UNSIGNED,
                last_seen BIGINT UNSIGNED,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            ) ENGINE=InnoDB
        """)

        # Import tracking
        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS import_stats (
                id INT AUTO_INCREMENT PRIMARY KEY,
                filename VARCHAR(255),
                imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                total_messages BIGINT UNSIGNED,
                duration_seconds FLOAT,
                messages_per_second INT UNSIGNED
            ) ENGINE=InnoDB
        """)

        self.conn.commit()
        print("Tables created successfully")

    def import_file(self, input_file, batch_size=10000, max_messages=None, 
                    track_order_refs=True, progress_interval=100000):
        """
        Import ITCH file using streaming (no memory explosion).
        
        Args:
            input_file: Path to binary ITCH file
            batch_size: Records per batch insert
            max_messages: Limit total messages (None = all)
            track_order_refs: Build order_ref->symbol map for E/X/D/C
            progress_interval: Print progress every N messages
        """
        print(f"\nImporting: {input_file}")
        print(f"Batch size: {batch_size:,}")
        print(f"Track order_refs: {track_order_refs}")
        if max_messages:
            print(f"Max messages: {max_messages:,}")

        start_time = time.time()
        
        batch = []
        total_count = 0
        type_counts = defaultdict(int)
        symbol_stats = defaultdict(lambda: {'count': 0, 'first': None, 'last': None})
        
        # Track order_ref -> symbol from A/F messages
        order_ref_map = {} if track_order_refs else None
        refs_resolved = 0
        refs_unresolved = 0

        for msg in stream_itch_file(input_file, max_messages):
            msg_type = msg['type']
            symbol = msg['symbol']
            order_ref = msg.get('order_ref')
            timestamp_ns = msg['timestamp_ns']
            
            # Build order_ref -> symbol mapping from Add orders
            if track_order_refs and order_ref:
                if msg_type in ('A', 'F') and symbol:
                    order_ref_map[order_ref] = symbol
                elif msg_type in ('E', 'C', 'X', 'D', 'U') and not symbol:
                    # Lookup symbol from order_ref
                    symbol = order_ref_map.get(order_ref)
                    if symbol:
                        refs_resolved += 1
                    else:
                        refs_unresolved += 1
            
            # Add to batch
            batch.append((
                timestamp_ns,
                msg_type,
                symbol,
                order_ref,
                msg['raw']
            ))

            # Update statistics
            type_counts[msg_type] += 1
            if symbol:
                stats = symbol_stats[symbol]
                stats['count'] += 1
                if stats['first'] is None:
                    stats['first'] = timestamp_ns
                stats['last'] = timestamp_ns

            total_count += 1

            # Batch insert
            if len(batch) >= batch_size:
                self._insert_batch(batch)
                batch = []
                self.conn.commit()

            # Progress
            if total_count % progress_interval == 0:
                elapsed = time.time() - start_time
                rate = total_count / elapsed if elapsed > 0 else 0
                mem_mb = len(order_ref_map) * 50 / 1024 / 1024 if order_ref_map else 0
                print(f"  {total_count:,} messages ({rate:,.0f}/sec) "
                      f"| order_ref map: {len(order_ref_map) if order_ref_map else 0:,} entries (~{mem_mb:.1f}MB)")

        # Insert remaining
        if batch:
            self._insert_batch(batch)
            self.conn.commit()

        # Update symbol stats
        print("\nUpdating symbol statistics...")
        self._update_symbol_stats(symbol_stats)

        # Record import stats
        duration = time.time() - start_time
        rate = total_count / duration if duration > 0 else 0

        self.cursor.execute("""
            INSERT INTO import_stats (filename, total_messages, duration_seconds, messages_per_second)
            VALUES (%s, %s, %s, %s)
        """, (input_file, total_count, duration, int(rate)))
        self.conn.commit()

        # Report
        print(f"\n{'='*60}")
        print(f"Import Complete!")
        print(f"{'='*60}")
        print(f"Total messages: {total_count:,}")
        print(f"Duration: {duration:.1f} seconds")
        print(f"Rate: {rate:,.0f} messages/second")
        
        if track_order_refs:
            print(f"\nOrder reference tracking:")
            print(f"  Unique order_refs: {len(order_ref_map):,}")
            print(f"  E/X/D/C resolved: {refs_resolved:,}")
            print(f"  E/X/D/C unresolved: {refs_unresolved:,}")
        
        print(f"\nMessage type breakdown:")
        for msg_type in sorted(type_counts.keys()):
            count = type_counts[msg_type]
            pct = (count / total_count) * 100
            name = SUPPORTED_TYPES.get(msg_type, 'Other')
            print(f"  {msg_type} ({name}): {count:,} ({pct:.1f}%)")

        print(f"\nUnique symbols: {len(symbol_stats):,}")
        
        # Clear order_ref map to free memory
        if order_ref_map:
            order_ref_map.clear()

    def _insert_batch(self, batch):
        """Batch insert with order_ref column"""
        if not batch:
            return

        sql = """
            INSERT INTO itch_messages (timestamp_ns, message_type, stock_symbol, order_ref, raw_message)
            VALUES (%s, %s, %s, %s, %s)
        """
        self.cursor.executemany(sql, batch)

    def _update_symbol_stats(self, symbol_stats):
        """Update symbol statistics table"""
        if not symbol_stats:
            return

        sql = """
            INSERT INTO symbols (symbol, message_count, first_seen, last_seen)
            VALUES (%s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                message_count = message_count + VALUES(message_count),
                first_seen = LEAST(first_seen, VALUES(first_seen)),
                last_seen = GREATEST(last_seen, VALUES(last_seen))
        """

        batch = [
            (symbol, stats['count'], stats['first'], stats['last'])
            for symbol, stats in symbol_stats.items()
        ]
        self.cursor.executemany(sql, batch)
        self.conn.commit()

    def get_stats(self):
        """Get current table statistics"""
        self.cursor.execute("""
            SELECT
                COUNT(*) as total_messages,
                COUNT(DISTINCT stock_symbol) as unique_symbols,
                MIN(timestamp_ns) as first_timestamp,
                MAX(timestamp_ns) as last_timestamp
            FROM itch_messages
        """)
        return self.cursor.fetchone()

    def get_type_distribution(self):
        """Get message type distribution"""
        self.cursor.execute("""
            SELECT message_type, COUNT(*) as count
            FROM itch_messages
            GROUP BY message_type
            ORDER BY count DESC
        """)
        return self.cursor.fetchall()

    def close(self):
        self.cursor.close()
        self.conn.close()
        print("Database connection closed")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Import ITCH binary files to MySQL (streaming, memory-safe)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Full import with order_ref tracking (resolves E/X/D/C symbols)
  python itch_mysql_importer_fixed.py 12302019.NASDAQ_ITCH50 \\
      --host localhost --user root --password xxx --database nasdaq_itch

  # Import first 10M messages only
  python itch_mysql_importer_fixed.py 12302019.NASDAQ_ITCH50 \\
      --host localhost --user root --password xxx --max-messages 10000000

  # Larger batch size for faster import
  python itch_mysql_importer_fixed.py 12302019.NASDAQ_ITCH50 \\
      --host localhost --user root --password xxx --batch-size 50000
        """
    )

    parser.add_argument('itch_file', help='Binary ITCH 5.0 file')
    parser.add_argument('--host', default='venus', help='MySQL host')
    parser.add_argument('--port', type=int, default=3306, help='MySQL port')
    parser.add_argument('--user', default='fpga', help='MySQL username')
    parser.add_argument('--password', default='password', help='MySQL password')
    parser.add_argument('--database', default='itch_data', help='Database name')
    parser.add_argument('--batch-size', type=int, default=10000, help='Batch insert size')
    parser.add_argument('--max-messages', type=int, help='Limit total messages')
    parser.add_argument('--drop-tables', action='store_true', help='Drop existing tables')
    parser.add_argument('--no-track-refs', action='store_true', 
                        help='Disable order_ref->symbol tracking (uses less memory)')
    parser.add_argument('--stats-only', action='store_true', help='Show stats only')

    args = parser.parse_args()

    importer = MySQLITCHImporter(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        database=args.database
    )

    try:
        if args.stats_only:
            stats = importer.get_stats()
            print("\nDatabase Statistics:")
            print(f"  Total messages: {stats['total_messages']:,}")
            print(f"  Unique symbols: {stats['unique_symbols']:,}")
            
            print("\nMessage type distribution:")
            for row in importer.get_type_distribution():
                print(f"  {row['message_type']}: {row['count']:,}")
        else:
            importer.create_tables(drop_existing=args.drop_tables)
            importer.import_file(
                args.itch_file,
                batch_size=args.batch_size,
                max_messages=args.max_messages,
                track_order_refs=not args.no_track_refs
            )

    finally:
        importer.close()