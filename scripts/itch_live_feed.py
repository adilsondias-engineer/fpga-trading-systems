#!/usr/bin/env python3
"""
itch_live_feed.py - Automated multi-symbol live feed simulator from MySQL

Reads from MySQL database and sends ITCH messages to FPGA in real-time,
simulating live market data across all 8 symbols simultaneously.

Features:
- Multi-symbol interleaving (all 8 symbols active)
- Configurable replay speed (1x = real-time, 10x = fast-forward)
- Smart message scheduling based on timestamps
- Auto-reconnect on network errors
- Progress monitoring and statistics

Requirements:
    pip install pymysql scapy

Usage:
    # Real-time replay (1x speed)
    python itch_live_feed.py --fpga-ip 192.168.0.212 --symbols AAPL,TSLA,SPY,QQQ,GOOGL,MSFT,AMZN,NVDA

    # Fast replay (10x speed, 5000 messages per symbol)
    python itch_live_feed.py --fpga-ip 192.168.0.212 --speed 10 --max-per-symbol 5000

    # Maximum speed with delay between symbols
    python itch_live_feed.py --fpga-ip 192.168.0.212 --speed 0 --inter-symbol-delay 0.1
"""

import sys
import argparse
import time
import signal
from datetime import datetime
from collections import deque
import heapq

try:
    from scapy.all import Ether, IP, UDP, Raw, sendp, get_if_hwaddr, get_if_list
except ImportError:
    print("\n ERROR: Scapy not installed")
    print("Install with: pip install scapy")
    sys.exit(1)

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("\n ERROR: PyMySQL not installed")
    print("Install with: pip install pymysql")
    sys.exit(1)


class LiveFeedSimulator:
    """Multi-symbol ITCH live feed simulator with smart message scheduling"""

    # Default FPGA symbols (matching symbol_filter_pkg.vhd)
    DEFAULT_SYMBOLS = ['AAPL', 'TSLA', 'SPY', 'QQQ', 'GOOGL', 'MSFT', 'AMZN', 'NVDA']

    # FPGA-supported message types
    FPGA_MESSAGE_TYPES = ['A', 'E', 'X', 'S', 'R', 'D', 'U', 'P', 'Q']

    # Network configuration (matching send_itch_packets.py)
    PC_INTERFACE_MAC = "80-3F-5D-FB-17-63" #"60-FF-9E-D1-70-EC"
    FPGA_MAC = "ff:ff:ff:ff:ff:ff"  # Broadcast


    def __init__(self, db_host, db_user, db_password, db_name, fpga_ip, fpga_port=1234):
        """Initialize database connection and network interface"""

        # Database connection
        print(f"Connecting to MySQL: {db_user}@{db_host}/{db_name}")
        self.conn = pymysql.connect(
            host=db_host,
            user=db_user,
            password=db_password,
            database=db_name,
            charset='utf8mb4',
            cursorclass=pymysql.cursors.SSCursor  # Server-side cursor for large result sets
        )
        self.cursor = self.conn.cursor()
        print(" Connected to MySQL")

        # Network setup
        self.fpga_ip = fpga_ip
        self.fpga_port = fpga_port
        self.iface = self._find_interface()

        # Statistics
        self.stats = {
            'total_sent': 0,
            'per_symbol': {},
            'per_type': {},
            'start_time': None,
            'errors': 0
        }

        # Graceful shutdown
        self.running = True
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _find_interface(self):
        """Find network interface by MAC address"""
        target_mac = self.PC_INTERFACE_MAC.lower().replace('-', ':')

        for iface in get_if_list():
            try:
                mac = get_if_hwaddr(iface)
                if mac and mac.lower() == target_mac:
                    print(f"Using interface: {iface} ({mac})")
                    return iface
            except:
                continue

        print(f"\n ERROR: Could not find interface with MAC {self.PC_INTERFACE_MAC}")
        print("\nAvailable interfaces:")
        for iface in get_if_list():
            try:
                mac = get_if_hwaddr(iface)
                print(f"  {iface}: {mac}")
            except:
                pass
        sys.exit(1)

    def _signal_handler(self, sig, frame):
        """Handle Ctrl+C gracefully"""
        print("\n\nShutdown signal received, stopping...")
        self.running = False

    def replay_multi_symbol(self, symbols=None, speed_multiplier=1.0,
                           max_per_symbol=None, inter_symbol_delay=0.0):
        """
        Replay messages for multiple symbols with time-based interleaving

        Args:
            symbols: List of symbols (default: FPGA 8 symbols)
            speed_multiplier: Replay speed (0=max, 1=real-time, 10=10x)
            max_per_symbol: Max messages per symbol (None=unlimited)
            inter_symbol_delay: Delay between symbols in round-robin (seconds)
        """

        if symbols is None:
            symbols = self.DEFAULT_SYMBOLS

        print(f"\n{'='*70}")
        print(f"Multi-Symbol Live Feed Simulator")
        print(f"{'='*70}")
        print(f"FPGA: {self.fpga_ip}:{self.fpga_port}")
        print(f"Symbols: {', '.join(symbols)}")
        print(f"Speed: {speed_multiplier}x" if speed_multiplier > 0 else "Speed: MAXIMUM")
        print(f"Max per symbol: {max_per_symbol if max_per_symbol else 'Unlimited'}")
        print(f"Inter-symbol delay: {inter_symbol_delay}s")
        print(f"{'='*70}\n")

        # Initialize statistics
        self.stats['start_time'] = time.time()
        for symbol in symbols:
            self.stats['per_symbol'][symbol] = 0

        # Fetch messages from all symbols and merge by timestamp
        print("Loading messages from database...")
        message_heap = self._load_messages_heap(symbols, max_per_symbol)

        if not message_heap:
            print(" No messages found for specified symbols")
            return

        print(f" Loaded {len(message_heap):,} messages\n")
        print("Starting replay...\n")

        # Replay with time-based scheduling
        last_timestamp = None
        last_display = time.time()
        display_interval = 1.0  # Update display every second

        while message_heap and self.running:
            # Get next message (earliest timestamp)
            timestamp_ns, symbol, msg_type, raw_message = heapq.heappop(message_heap)

            # Rate limiting based on timestamps
            if speed_multiplier > 0 and last_timestamp is not None:
                time_delta_ns = timestamp_ns - last_timestamp
                sleep_sec = (time_delta_ns / 1e9) / speed_multiplier

                # Cap sleep to handle large gaps
                sleep_sec = min(sleep_sec, 0.5)

                if sleep_sec > 0:
                    time.sleep(sleep_sec)

            # Send message to FPGA (pass msg_type for validation)
            self._send_message(raw_message, symbol, msg_type)

            # Update statistics
            self.stats['total_sent'] += 1
            self.stats['per_symbol'][symbol] += 1
            self.stats['per_type'][msg_type] = self.stats['per_type'].get(msg_type, 0) + 1
            last_timestamp = timestamp_ns

            # Inter-symbol delay (optional, for pacing)
            if inter_symbol_delay > 0:
                time.sleep(inter_symbol_delay)

            # Progress display
            now = time.time()
            if now - last_display >= display_interval:
                self._display_progress()
                last_display = now

        # Final report
        self._display_final_report()

    def _load_messages_heap(self, symbols, max_per_symbol):
        """
        Load messages from database into min-heap sorted by timestamp

        Returns:
            List of tuples: (timestamp_ns, symbol, msg_type, raw_message)
        """

        placeholders_symbols = ','.join(['%s'] * len(symbols))
        placeholders_types = ','.join(['%s'] * len(self.FPGA_MESSAGE_TYPES))

        query = f"""
            SELECT timestamp_ns, stock_symbol, message_type, raw_message
            FROM itch_messages
            WHERE stock_symbol IN ({placeholders_symbols})
            AND message_type IN ({placeholders_types})
            ORDER BY stock_symbol, timestamp_ns
        """

        if max_per_symbol:
            # Limit per symbol using UNION ALL (MySQL doesn't support LIMIT in WHERE)
            # This query gets max_per_symbol messages per symbol
            queries = []
            for symbol in symbols:
                q = f"""
                    (SELECT timestamp_ns, stock_symbol, message_type, raw_message
                     FROM itch_messages
                     WHERE stock_symbol = %s
                     AND message_type IN ({placeholders_types})
                     ORDER BY timestamp_ns
                     LIMIT {max_per_symbol})
                """
                queries.append(q)

            query = " UNION ALL ".join(queries) + " ORDER BY timestamp_ns"

            # Flatten parameters
            params = []
            for symbol in symbols:
                params.append(symbol)
                params.extend(self.FPGA_MESSAGE_TYPES)
        else:
            params = symbols + self.FPGA_MESSAGE_TYPES

        self.cursor.execute(query, params)

        # Load into heap
        heap = []
        for row in self.cursor:
            timestamp_ns, symbol, msg_type, raw_message = row
            
            # Ensure raw_message is bytes (PyMySQL BLOB should return bytes)
            if isinstance(raw_message, str):
                # If it's a string, encode as latin-1 (preserves byte values)
                raw_message = raw_message.encode('latin-1')
            elif not isinstance(raw_message, (bytes, bytearray)):
                print(f"WARNING: Unexpected raw_message type {type(raw_message)} for message type {msg_type}")
                continue
            
            # Validate message type matches first byte
            if len(raw_message) > 0 and chr(raw_message[0]) != msg_type:
                print(f"WARNING: Message type mismatch: DB says '{msg_type}' but first byte is '{chr(raw_message[0])}'")
            
            heapq.heappush(heap, (timestamp_ns, symbol, msg_type, raw_message))

        return heap

    def _send_message(self, raw_message, symbol, expected_msg_type=None):
        """Send ITCH message to FPGA via UDP
        
        Args:
            raw_message: Raw message bytes from database
            symbol: Stock symbol (for reference)
            expected_msg_type: Expected message type from database (for validation)
        """
        try:
            # raw_message should already be bytes from database (validated in _load_messages_heap)
            # But handle edge cases for safety
            if isinstance(raw_message, str):
                # If it's a string, encode as latin-1 (preserves byte values 0-255)
                payload = raw_message.encode('latin-1')
            elif isinstance(raw_message, (bytes, bytearray)):
                payload = bytes(raw_message)
            else:
                raise ValueError(f"Unexpected raw_message type: {type(raw_message)}")

            # Validate payload
            if len(payload) == 0:
                raise ValueError("Empty payload")
            
            # Check if payload might have 2-byte length prefix
            # Valid ITCH message types are ASCII characters
            first_byte = payload[0]
            actual_msg_type = chr(first_byte) if 32 <= first_byte <= 126 else None
            
            # If first byte is not a valid message type, check if it might be length prefix
            valid_msg_types = ['S', 'R', 'H', 'Y', 'L', 'V', 'W', 'K', 'J', 'h',
                             'A', 'F', 'E', 'C', 'X', 'D', 'U', 'P', 'Q', 'B', 'I']
            
            if actual_msg_type not in valid_msg_types and len(payload) >= 2:
                # First byte is not a valid message type - might be length prefix
                possible_length = (payload[0] << 8) | payload[1]
                # Check if it looks like a length prefix (reasonable ITCH message length: 12-50 bytes)
                if 12 <= possible_length <= 50 and len(payload) == possible_length + 2:
                    # Likely has length prefix, strip it
                    payload = payload[2:]
                    if len(payload) == 0:
                        raise ValueError("Payload became empty after stripping length prefix")
                    # Re-check message type after stripping
                    first_byte = payload[0]
                    actual_msg_type = chr(first_byte) if 32 <= first_byte <= 126 else None
            
            # Validate message type
            if actual_msg_type not in valid_msg_types:
                raise ValueError(f"Invalid message type: first byte 0x{first_byte:02x} ('{actual_msg_type}')")
            
            # Validate message type matches database record (if provided)
            if expected_msg_type and actual_msg_type != expected_msg_type:
                # This is a data integrity issue - log but continue
                if self.stats['errors'] < 5:  # Only log first few
                    print(f"\nWARNING: Message type mismatch - DB says '{expected_msg_type}' but payload is '{actual_msg_type}'")
                self.stats['errors'] += 1
            
            # Remove trailing null bytes (safety measure - should not be needed if importer fixed)
            # ITCH messages have fixed formats and should never have trailing zeros
            original_len = len(payload)
            payload = payload.rstrip(b'\x00')
            stripped_bytes = original_len - len(payload)
            
            if stripped_bytes > 0:
                # Log if we stripped trailing zeros (indicates database has padding - should be fixed in importer)
                # Only log occasionally to avoid spam (every 1000th occurrence)
                if self.stats['total_sent'] % 1000 == 0:
                    print(f"\nNOTE: Stripped {stripped_bytes} trailing zero(s) from message "
                          f"(DB may have padding - consider re-importing with fixed importer)")
            
            # Re-validate length after stripping (should still be valid)
            if len(payload) == 0:
                raise ValueError("Payload became empty after stripping trailing zeros")
            
            # Re-check message type after stripping (first byte should still be valid)
            if payload[0] < 32 or payload[0] > 126:
                raise ValueError(f"Invalid message type after stripping: 0x{payload[0]:02x}")
            
            # Validate message length matches expected ITCH message type length
            # This helps catch corrupted messages
            msg_type_byte = payload[0]
            expected_lengths = {
                ord('S'): 12,   # System Event
                ord('R'): 39,   # Stock Directory
                ord('A'): 36,   # Add Order (no MPID)
                ord('F'): 40,   # Add Order (with MPID)
                ord('E'): 31,   # Order Executed
                ord('C'): 36,   # Order Executed with Price
                ord('X'): 23,   # Order Cancel
                ord('D'): 19,   # Order Delete
                ord('U'): 35,   # Order Replace
                ord('P'): 44,   # Trade (non-cross)
                ord('Q'): 40,   # Cross Trade
            }
            
            if msg_type_byte in expected_lengths:
                expected_len = expected_lengths[msg_type_byte]
                if len(payload) != expected_len:
                    # Log length mismatch (might indicate database corruption)
                    if self.stats['errors'] < 10:
                        print(f"\nWARNING: Message type '{chr(msg_type_byte)}' has length {len(payload)}, expected {expected_len}")
                    self.stats['errors'] += 1
            
            # Symbol uppercasing is disabled (data already uppercase in database)
            # Uncomment below if needed:
            # msg_type = payload[0]
            # if msg_type in [ord('A'), ord('U'), ord('P'), ord('Q')]:
            #     if len(payload) >= 32:
            #         payload = bytearray(payload)
            #         for i in range(24, 32):
            #             if ord('a') <= payload[i] <= ord('z'):
            #                 payload[i] = payload[i] - 32
            #         payload = bytes(payload)
            
            # Build Ethernet/IP/UDP packet
            # Explicitly set UDP length to match actual payload size (after stripping zeros)
            # UDP length = UDP header (8 bytes) + payload length
            udp_length = 8 + len(payload)
            
            packet = (
                Ether(dst=self.FPGA_MAC) /
                IP(dst=self.fpga_ip) /
                UDP(sport=54321, dport=self.fpga_port, len=udp_length) /
                Raw(load=payload)
            )
            
            # Scapy will automatically calculate IP and UDP checksums
            # Note: Ethernet frame padding (to reach 64-byte minimum) is added automatically by the network driver
            # This padding is NOT part of the UDP payload and is normal behavior
            sendp(packet, iface=self.iface, verbose=False)
            print(f"Payload: {payload.hex()}")
        except Exception as e:
            self.stats['errors'] += 1
            if self.stats['errors'] < 10:  # Only print first 10 errors
                print(f"\n Error sending message: {e}")

    def _display_progress(self):
        """Display live progress statistics"""
        elapsed = time.time() - self.stats['start_time']
        rate = self.stats['total_sent'] / elapsed if elapsed > 0 else 0

        # Build progress line
        symbol_counts = ' | '.join([
            f"{sym}:{cnt}" for sym, cnt in sorted(self.stats['per_symbol'].items())
        ])

        print(f"\r  Sent: {self.stats['total_sent']:,} msgs @ {rate:.0f} msg/sec | "
              f"{symbol_counts}        ", end='', flush=True)

    def _display_final_report(self):
        """Display final statistics"""
        elapsed = time.time() - self.stats['start_time']
        avg_rate = self.stats['total_sent'] / elapsed if elapsed > 0 else 0

        print(f"\n\n{'='*70}")
        print(f"Replay Complete")
        print(f"{'='*70}")
        print(f"Total messages: {self.stats['total_sent']:,}")
        print(f"Duration: {elapsed:.1f} seconds")
        print(f"Average rate: {avg_rate:.0f} messages/second")
        print(f"Errors: {self.stats['errors']}")

        print(f"\nPer-symbol breakdown:")
        for symbol, count in sorted(self.stats['per_symbol'].items()):
            pct = (count / self.stats['total_sent']) * 100 if self.stats['total_sent'] > 0 else 0
            print(f"  {symbol:8s}: {count:8,} ({pct:5.1f}%)")

        if self.stats['per_type']:
            print(f"\nPer-type breakdown:")
            for msg_type, count in sorted(self.stats['per_type'].items()):
                pct = (count / self.stats['total_sent']) * 100 if self.stats['total_sent'] > 0 else 0
                print(f"  {msg_type}: {count:8,} ({pct:5.1f}%)")

    def list_available_symbols(self, min_messages=1000):
        """List symbols in database with message counts"""
        query = """
            SELECT symbol, message_count, first_seen, last_seen
            FROM symbols
            WHERE message_count >= %s
            ORDER BY message_count DESC
            LIMIT 50
        """

        cursor = self.conn.cursor(pymysql.cursors.DictCursor)
        cursor.execute(query, (min_messages,))

        print(f"\nAvailable Symbols (>= {min_messages:,} messages):")
        print(f"{'='*70}")
        print(f"{'Symbol':<10} {'Messages':>12} {'First Seen':>20} {'Last Seen':>20}")
        print(f"{'-'*70}")

        for row in cursor:
            symbol = row['symbol']
            count = row['message_count']
            first = datetime.fromtimestamp(row['first_seen'] / 1e9).strftime('%Y-%m-%d %H:%M:%S')
            last = datetime.fromtimestamp(row['last_seen'] / 1e9).strftime('%Y-%m-%d %H:%M:%S')

            print(f"{symbol:<10} {count:>12,} {first:>20} {last:>20}")

        cursor.close()

    def close(self):
        """Close database connection"""
        self.cursor.close()
        self.conn.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Automated multi-symbol ITCH live feed simulator',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Real-time replay of 8 FPGA symbols
  python itch_live_feed.py --fpga-ip 192.168.0.212 --db-user itch_user --db-password mypass

  # Fast replay (10x speed) with 5000 messages per symbol
  python itch_live_feed.py --fpga-ip 192.168.0.212 --speed 10 --max-per-symbol 5000 \\
      --db-user root --db-password root

  # Maximum speed replay for testing
  python itch_live_feed.py --fpga-ip 192.168.0.212 --speed 0 --max-per-symbol 1000 \\
      --db-user root --db-password root

  # List available symbols in database
  python itch_live_feed.py --list-symbols --db-user root --db-password root
        """
    )

    # Database arguments
    parser.add_argument('--db-host', default='localhost', help='MySQL host')
    parser.add_argument('--db-port', type=int, default=3306, help='MySQL port')
    parser.add_argument('--db-user', required=True, help='MySQL username')
    parser.add_argument('--db-password', required=True, help='MySQL password')
    parser.add_argument('--db-name', default='itch_data', help='Database name')

    # FPGA arguments
    parser.add_argument('--fpga-ip', help='FPGA IP address (required for replay)')
    parser.add_argument('--fpga-port', type=int, default=1234, help='FPGA UDP port')

    # Replay arguments
    parser.add_argument('--symbols',
                       help='Comma-separated symbols (default: AAPL,TSLA,SPY,QQQ,GOOGL,MSFT,AMZN,NVDA)')
    parser.add_argument('--speed', type=float, default=1.0,
                       help='Replay speed multiplier (0=max, 1=real-time, 10=10x)')
    parser.add_argument('--max-per-symbol', type=int,
                       help='Maximum messages per symbol (default: unlimited)')
    parser.add_argument('--inter-symbol-delay', type=float, default=0.0,
                       help='Delay between symbols in seconds (default: 0)')

    # Info arguments
    parser.add_argument('--list-symbols', action='store_true',
                       help='List available symbols and exit')

    args = parser.parse_args()

    # Create simulator
    simulator = LiveFeedSimulator(
        db_host=args.db_host,
        db_user=args.db_user,
        db_password=args.db_password,
        db_name=args.db_name,
        fpga_ip=args.fpga_ip if args.fpga_ip else '192.168.0.212',
        fpga_port=args.fpga_port
    )

    try:
        if args.list_symbols:
            # List symbols and exit
            simulator.list_available_symbols()
        else:
            if not args.fpga_ip:
                print(" ERROR: --fpga-ip required for replay")
                sys.exit(1)

            # Parse symbols
            symbols = None
            if args.symbols:
                symbols = [s.strip().upper() for s in args.symbols.split(',')]

            # Start replay
            simulator.replay_multi_symbol(
                symbols=symbols,
                speed_multiplier=args.speed,
                max_per_symbol=args.max_per_symbol,
                inter_symbol_delay=args.inter_symbol_delay
            )

    finally:
        simulator.close()
