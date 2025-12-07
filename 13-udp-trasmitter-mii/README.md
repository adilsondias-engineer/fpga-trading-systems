# Project 13: UDP Transmitter (MII TX)

## Overview

Hardware-accelerated order book implementation for high-frequency trading systems with **UDP BBO transmission**. Processes ITCH 5.0 market data messages in real-time, maintains order storage and price level aggregation, and tracks Best Bid/Offer (BBO) with sub-microsecond latency. **BBO updates are transmitted via UDP to 192.168.0.93:5000 for low-latency market data distribution, while UART is reserved for debug messages only.**

**Trading Context:** Order books are the fundamental data structure in electronic trading systems. Hardware implementation delivers deterministic latency and eliminates software stack overhead—critical advantages where microseconds directly impact profitability. UDP transmission enables real-time BBO distribution to trading algorithms with minimal overhead.

## Status

**Project Status:** 🔧 Functional - Multi-symbol order book with 8 parallel order books and spread calculation

**Hardware Status:** Synthesized, Programmed, and Verified on Arty A7-100T

**Development Status:** Integration and performance testing ongoing

**Key Achievements:**
- ✅ **Multi-symbol support:** 8 parallel order books (AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA)
- ✅ **Round-robin BBO arbiter:** Cycles through symbols with change detection
- ✅ **Spread calculation:** Correctly calculates ask - bid for risk management
- ✅ **BRAM-based order storage:** 1024 orders × 130 bits per symbol (32 RAMB36 tiles total)
- ✅ **BRAM-based price level table:** 256 levels × 82 bits per symbol
- ✅ **Real-time BBO tracking** with FSM scanner per symbol
- ✅ **ITCH message integration** (A, E, X, D, U message types)
- ✅ **Production-grade BRAM inference** (not LUTRAM)
- ✅ **Comprehensive debug infrastructure**

## Hardware Requirements

- **Board:** Digilent Arty A7-100T Development Board
- **FPGA:** Xilinx Artix-7 XC7A100T-1CSG324C
- **PHY:** TI DP83848J 10/100 Ethernet (MII interface)
- **Tools:** AMD Vivado Design Suite 2025.1

## Features Implemented

### UDP BBO Transmission

**Real-time BBO Distribution** (`bbo_udp_formatter.vhd` + `eth_udp_send_wrapper.sv`):
- Transmits BBO updates via UDP when order book changes
- **Dynamic Configuration:** Destination IP, MAC, and port configurable via UART commands (see [UART_CONFIG_GUIDE.md](UART_CONFIG_GUIDE.md))
- Default Destination: 192.168.0.93:5000 (broadcast MAC: FF:FF:FF:FF:FF:FF)
- Source: 192.168.0.212:5000 (FPGA MAC: 00:18:3E:04:5D:E7)
- Payload: 256 bytes (28 bytes BBO data + 228 bytes padding)
- UART used for dynamic configuration and debug messages

### UART Configuration Commands

**Dynamic Destination Setup** (`uart_config.vhd` + `uart_rx.vhd`):
- Configure UDP destination without reprogramming FPGA
- ASCII command protocol via UART (115200 baud, 8N1)
- Commands take effect immediately

**Supported Commands:**
```
IP:192.168.0.93\n       - Set destination IP address
MAC:FF:FF:FF:FF:FF:FF\n - Set destination MAC address
PORT:5000\n             - Set destination UDP port
```

**Example Usage:**
```bash
# Configure for C++ gateway on 192.168.0.100
IP:192.168.0.100
MAC:FF:FF:FF:FF:FF:FF
PORT:5000
```

**Complete Documentation:** See [UART_CONFIG_GUIDE.md](UART_CONFIG_GUIDE.md) for detailed usage, testing procedures, and troubleshooting.

**UDP Packet Format:**

| Offset | Size | Field | Description | Example Value |
|--------|------|-------|-------------|---------------|
| **Ethernet Header (14 bytes)** |
| 0x00 | 6 | Destination MAC | Broadcast address | `FF:FF:FF:FF:FF:FF` |
| 0x06 | 6 | Source MAC | FPGA MAC address | `00:18:3E:04:5D:E7` |
| 0x0C | 2 | EtherType | IPv4 | `0x0800` |
| **IP Header (20 bytes)** |
| 0x0E | 1 | Version/IHL | IPv4, 20-byte header | `0x45` |
| 0x10 | 2 | Total Length | IP + UDP + Payload | `0x011C` (284 bytes) |
| 0x17 | 1 | Protocol | UDP | `0x11` (17) |
| 0x1A | 4 | Source IP | FPGA IP address | `192.168.0.212` |
| 0x1E | 4 | Destination IP | Target IP | `192.168.0.93` |
| **UDP Header (8 bytes)** |
| 0x22 | 2 | Source Port | FPGA UDP port | `0x1388` (5000) |
| 0x24 | 2 | Destination Port | Target UDP port | `0x1388` (5000) |
| 0x26 | 2 | Length | UDP header + payload | `0x0108` (264 bytes) |
| 0x28 | 2 | Checksum | Not computed | `0x0000` |
| **UDP Payload (256 bytes)** |
| 0x2A - 0xFD | 228 | Padding | Zero padding | `0x00...` |
| **BBO Data (28 bytes, at end of payload due to nibble reversal)** |
| 0xFE - 0x101 | 4 | Spread | Ask - Bid (big-endian) | `0x000061A8` = 25,000 |
| 0x102 - 0x105 | 4 | ASK Shares | Total ask shares (big-endian) | `0x0000012C` = 300 |
| 0x106 - 0x109 | 4 | ASK Price | Best ask price (big-endian) | `0x00173180` = 1,520,000 |
| 0x10A - 0x10D | 4 | BID Shares | Total bid shares (big-endian) | `0x0000012C` = 300 |
| 0x10E - 0x111 | 4 | BID Price | Best bid price (big-endian) | `0x0016CFD8` = 1,495,000 |
| 0x112 - 0x119 | 8 | Symbol | Stock ticker (ASCII) | `"AAPL    "` |

**Important Notes:**
1. **Byte Order:** Multi-byte integers are in **big-endian** format (network byte order)
2. **Price Format:** Prices are in fixed-point format (4 decimal places): `1,495,000 = $149.50`
3. **BBO Location:** Due to nibble-write order reversal, BBO data appears at **bytes 228-255** instead of bytes 0-27
4. **Symbol Padding:** Symbol names are 8 bytes, space-padded (e.g., `"AAPL    "`)

**Example Packet (AAPL):**
```
Hex dump (offsets 0x110-0x119, bytes 228-255 of payload):
0110: 00 00 61 a8 00 00 01 2c 00 17 31 80 00 00 01 2c
0120: 00 16 cf d8 41 41 50 4c 20 20 20 20

Decoded:
- Symbol: "AAPL    "
- BID: $149.50 (1,495,000), 300 shares
- ASK: $152.00 (1,520,000), 300 shares
- Spread: $2.50 (25,000)
```

**Python Parsing Example:**
```python
import socket
import struct

def parse_bbo_packet(data):
    # Skip Ethernet (14) + IP (20) + UDP (8) = 42 bytes
    payload = data[42:]

    # BBO data is at bytes 228-255 (last 28 bytes)
    bbo_data = payload[228:256]

    # Unpack as big-endian (network byte order)
    spread, ask_shares, ask_price, bid_shares, bid_price = struct.unpack(
        '>IIIII', bbo_data[0:20]
    )
    symbol = bbo_data[20:28].decode('ascii').rstrip()

    # Convert to decimal (4 decimal places)
    return {
        'symbol': symbol,
        'bid_price': bid_price / 10000.0,
        'bid_shares': bid_shares,
        'ask_price': ask_price / 10000.0,
        'ask_shares': ask_shares,
        'spread': spread / 10000.0
    }

# Receive UDP packets
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('192.168.0.93', 5000))

while True:
    data, addr = sock.recvfrom(1024)
    bbo = parse_bbo_packet(data)
    print(f"[{bbo['symbol']}] Bid: ${bbo['bid_price']:.2f} ({bbo['bid_shares']}) | "
          f"Ask: ${bbo['ask_price']:.2f} ({bbo['ask_shares']}) | "
          f"Spread: ${bbo['spread']:.2f}")
```

**C++ Parsing Example:**
```cpp
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <cstring>

struct BBO {
    char symbol[9];     // 8 chars + null terminator
    uint32_t bid_price;
    uint32_t bid_shares;
    uint32_t ask_price;
    uint32_t ask_shares;
    uint32_t spread;
};

BBO parse_bbo_packet(const uint8_t* data, size_t len) {
    BBO bbo = {};

    // Skip to UDP payload (42 bytes header)
    const uint8_t* payload = data + 42;

    // BBO data at bytes 228-255
    const uint8_t* bbo_data = payload + 228;

    // Parse big-endian integers
    bbo.spread = ntohl(*(uint32_t*)(bbo_data + 0));
    bbo.ask_shares = ntohl(*(uint32_t*)(bbo_data + 4));
    bbo.ask_price = ntohl(*(uint32_t*)(bbo_data + 8));
    bbo.bid_shares = ntohl(*(uint32_t*)(bbo_data + 12));
    bbo.bid_price = ntohl(*(uint32_t*)(bbo_data + 16));

    // Copy symbol (8 bytes)
    memcpy(bbo.symbol, bbo_data + 20, 8);
    bbo.symbol[8] = '\0';

    // Trim trailing spaces
    for (int i = 7; i >= 0; i--) {
        if (bbo.symbol[i] == ' ') bbo.symbol[i] = '\0';
        else break;
    }

    return bbo;
}
```

### SPI Slave Interface (Project 19 Integration)

**PY32F030 Status Display** (`spi_slave_core.vhd` + `spi_register_if.vhd` + `spi_slave.vhd`):
- External ARM Cortex-M0 microcontroller (PY32F030) reads FPGA status via SPI
- **6-register bank:** 4 read-only status inputs + 2 read-write configuration outputs
- **SPI Mode 0** (CPOL=0, CPHA=0), up to 10 MHz tested
- **Modular architecture:** Generic SPI core + application-specific register mapping
- **Production-grade timing:** 2-cycle pipeline for register reads, proper CDC handling

**Register Map:**

| Address | Name | Type | Description | FPGA Source | PY32 Use |
|---------|------|------|-------------|-------------|----------|
| 0x00 | ORDER_COUNT | R | Total orders processed | Order book | Activity indicator |
| 0x01 | BBO_COUNT | R | BBO updates generated | BBO tracker | Update frequency |
| 0x02 | LATENCY_P50 | R | P50 latency (ns) | Latency monitor | Performance metric |
| 0x03 | STATUS | R | System status flags | System monitor | Health check |
| 0x04 | SYMBOL_EN | RW | Symbol enable mask (8 bits) | PY32 config | Symbol filtering |
| 0x05 | THRESHOLD | RW | BBO spread threshold | PY32 config | Risk parameter |

**SPI Protocol:**
- **Transaction Format:** [CMD_BYTE][ADDR_BYTE][DATA_32BIT]
- **Command Bytes:** 0x01=READ, 0x02=WRITE
- **Data Format:** 32-bit big-endian (MSB first)
- **Clock Domain Crossing:** SPI_SCK → 100 MHz via 2-FF synchronizer
- **Validation:** 10,000+ SPI transactions tested, zero errors

**Example PY32 Display Output:**
```
Orders: 1 | BBO: 2 | Lat: 3 ns | Status: 0x00000004 | Symbol: 0xFF | Threshold: 1000
```

**Architecture Benefits:**
1. **Resource Optimization:** FPGA focuses on time-critical paths (< 5 μs wire-to-BBO), not slow UI tasks
2. **Dynamic Configuration:** PY32 can update symbol filtering and risk thresholds via SPI writes
3. **Independent Monitoring:** External watchdog can reset FPGA if status registers freeze
4. **Scalability:** Register bank expandable to 256 registers (8-bit address space) for comprehensive monitoring

**See Also:** [../19-py32-fpga-status/README.md](../19-py32-fpga-status/README.md) for complete SPI implementation details

### Multi-Symbol Order Book Architecture

**Multi-Symbol Wrapper** (`multi_symbol_order_book.vhd`):
- 8 parallel order book instances (one per symbol)
- Symbol demultiplexer routes ITCH messages to correct book
- Round-robin BBO arbiter (40 µs per symbol @ 25 MHz)
- Change detection: only outputs BBO when it changes
- Supports: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA

**Order Storage** (`order_storage.vhd`) - Per Symbol:
- 1024 concurrent orders per symbol
- 130-bit order entries (order_ref, price, shares, side, valid)
- Simple Dual-Port BRAM (write port + read port, same clock)
- 2-cycle read latency pipeline
- Order count tracking

**Price Level Table** (`price_level_table.vhd`) - Per Symbol:
- 256 price levels (128 bids + 128 asks)
- 82-bit level entries (price, total_shares, order_count, side, valid)
- Read-First BRAM with 2-cycle read-modify-write pipeline
- Address mapping: `[0-127] = Bids (descending), [128-255] = Asks (ascending)`
- Level count tracking (active bid/ask levels)

**BBO Tracker** (`bbo_tracker.vhd`) - Per Symbol:
- Finite state machine scans price level table
- Finds highest bid (best bid) and lowest ask (best offer)
- Calculates spread (ask - bid) in clocked FSM
- Updates BBO on price level changes
- 2-cycle read latency handling

**Order Book Manager** (`order_book_manager.vhd`) - Per Symbol:
- Top-level FSM coordinates all components
- Handles ITCH message types: A (Add), E (Execute), X (Cancel), D (Delete), U (Replace)
- Latency: ~12-17 clock cycles per message
- Statistics tracking (order counts, level counts, lifetime operations)

### ITCH Message Processing

| Message Type | Action | Order Storage | Price Level | BBO Update |
|--------------|--------|---------------|-------------|------------|
| **A** (Add Order) | Add new order | Write order entry | Add shares to level | Trigger scan |
| **E** (Execute) | Reduce shares | Update shares | Remove shares from level | Trigger scan |
| **X** (Cancel) | Reduce shares | Update shares | Remove shares from level | Trigger scan |
| **D** (Delete) | Remove order | Mark invalid | Remove shares from level | Trigger scan |
| **U** (Replace) | Modify order | Update price/shares | Update both levels | Trigger scan |

### BRAM Inference Architecture

**Critical Achievement:** Both `order_storage` and `price_level_table` correctly infer Block RAM instead of Distributed RAM (LUTRAM).

**Order Storage BRAM:**
- Simple Dual-Port pattern (write-only port A, read-only port B)
- Separate `valid_bits` array for order counting (prevents read-modify-write on main BRAM)
- `ram_style` attribute: `"block"` to force BRAM inference
- Size: 1024 × 130 bits ≈ 16 KB (4 BRAM36 blocks)

**Price Level Table BRAM:**
- Read-First Single-Port pattern (2-cycle read-modify-write pipeline)
- Stage 1: Capture command, read old level from BRAM
- Stage 2: Modify level, write back to BRAM
- Explicit BRAM control signals (`bram_do`, `bram_we`, `bram_addr`, `bram_di`)
- Size: 256 × 82 bits ≈ 2.5 KB (1 BRAM36 block)

**Key Lesson:** Read-modify-write patterns prevent BRAM inference. Separate read and write operations, or use separate storage for tracking data.

### Debug Infrastructure

**UART BBO Formatter** (`uart_bbo_formatter.vhd`):
- Real-time BBO output: `Bid:0xXXXXXXXX | Ask:0xXXXXXXXX | Spr:0xXXXXXXXX`
- Debug fields: `Tr=0x` (trigger), `Rd=0x` (ready), `Lv=0x` (level valid), `LdP=0xXXXXXXXX` (level data price), `LdA=0xXX` (level address)
- Write tracking: `WrA=0xXX` (write address), `WrP=0xXXXXXXXX` (write price), `WrS=0xX` (write side)
- Statistics: Order counts, level counts, update counts

**Example Output (Multi-Symbol):**
```
[BBO:NODATA  ]
[BBO:AAPL    ]Bid:0x0016E360 (0x00000064) | Ask:0x0016D99C (0x000000C8) | Spr:0x00001388
[BBO:TSLA    ]Bid:0x003EC7E0 (0x00000014) | Ask:0x00432380 (0x0000000A) | Spr:0x00045BA0
[BBO:SPY     ]Bid:0x0031522C (0x000001F4) | Ask:0x003148CC (0x000001F4) | Spr:0x00000960
[BBO:QQQ     ]Bid:0x0020A440 (0x00000320) | Ask:0x0020A184 (0x00000384) | Spr:0x00000258
[BBO:GOOGL   ]Bid:0x00BEBCE8 (0x00000001) | Ask:0x00CEC408 (0x0000000B) | Spr:0x00100720
[BBO:MSFT    ]Bid:0x001ADB00 (0x00000001) | Ask:0x001ADB00 (0x00000001) | Spr:0x00000000
[BBO:AMZN    ]Bid:0x011E7EF8 (0x00000014) | Ask:0x011E5854 (0x00000014) | Spr:0x00000000
[BBO:NVDA    ]Bid:0x00232BE8 (0x00000044) | Ask:0x00241948 (0x00000080) | Spr:0x0000ED60
```

**Format:** `[BBO:SYMBOL]Bid:0xPRICE (0xSHARES) | Ask:0xPRICE (0xSHARES) | Spr:0xSPREAD`

## Architecture

### Module Hierarchy

```
mii_eth_top (top-level)
├── ITCH Parser Pipeline (from Project 7) - 25 MHz domain
│   ├── mii_rx
│   ├── mac_parser
│   ├── ip_parser
│   ├── udp_parser
│   ├── itch_parser
│   └── symbol_filter (filters to 8 tracked symbols)
├── Multi-Symbol Order Book System - 25 MHz domain
│   ├── multi_symbol_order_book
│   │   ├── Symbol Demultiplexer (routes messages to correct book)
│   │   ├── order_book_manager[0] - AAPL
│   │   │   ├── order_storage (4 RAMB36)
│   │   │   ├── price_level_table (1 RAMB36)
│   │   │   └── bbo_tracker
│   │   ├── order_book_manager[1] - TSLA
│   │   ├── order_book_manager[2] - SPY
│   │   ├── order_book_manager[3] - QQQ
│   │   ├── order_book_manager[4] - GOOGL
│   │   ├── order_book_manager[5] - MSFT
│   │   ├── order_book_manager[6] - AMZN
│   │   ├── order_book_manager[7] - NVDA
│   │   └── BBO Arbiter (round-robin with change detection)
│   └── CDC Synchronizer (25 MHz → 100 MHz)
├── UDP TX System - 100 MHz domain (NEW)
│   ├── bbo_udp_formatter (formats BBO as 256-byte UDP payload)
│   └── eth_udp_send_wrapper (SystemVerilog wrapper)
│       └── eth_udp_send (from fpga-ethernet-udp project)
│           └── MII TX (25 MHz domain)
├── UART Formatter - 100 MHz domain (DEBUG ONLY)
│   └── uart_bbo_formatter (includes symbol name)
└── UART TX
```

### Data Flow

```
═══════════════════════════════════════════════════════════
ITCH Message Arrival (from Project 7)
═══════════════════════════════════════════════════════════
ITCH Parser (25 MHz)
    ↓ (parsed fields)
ITCH Message Encoder
    ↓ (324-bit serialized)
Async FIFO (Gray Code CDC)
    ↓
═══════════════════════════════════════════════════════════
Order Book Processing (100 MHz)
═══════════════════════════════════════════════════════════
ITCH Message Decoder
    ↓ (decoded fields: type, order_ref, price, shares, etc.)
Order Book Manager FSM
    ├─→ Order Storage (BRAM write/read)
    ├─→ Price Level Table (BRAM read-modify-write)
    └─→ BBO Tracker (scan price levels)
        ↓
BBO Output (bid_price, ask_price, spread, symbol, valid)
    ├───────────────────┬─────────────────────┐
    ↓                   ↓                     ↓
═══════════════════ ═══════════════════ ═══════════════════
UDP TX PATH (NEW)   UART DEBUG PATH     CDC to 100 MHz
═══════════════════ ═══════════════════ ═══════════════════
BBO UDP Formatter   UART BBO Formatter
    ↓                   ↓
256-byte Payload    ASCII output
    ↓                   ↓
eth_udp_send        UART TX
    ↓               (115200 baud)
MII TX (25 MHz)     (DEBUG ONLY)
    ↓
Ethernet PHY
    ↓
UDP Packet
192.168.0.212:5000
→ 192.168.0.93:5000
═══════════════════════════════════════════════════════════
```

### Order Book Manager FSM

```
IDLE
  ↓ (itch_valid = '1')
LOOKUP_ORDER (for E/X/D/U - read existing order)
  ↓
ADD_ORDER / UPDATE_ORDER / DELETE_ORDER
  ↓ (write to order_storage)
WAIT_PRICE_CMD (2-cycle latency)
  ↓
UPDATE_PRICE_ADD / UPDATE_PRICE_REMOVE
  ↓ (read-modify-write price_level_table)
WAIT_PRICE_CMD (2-cycle latency)
  ↓
UPDATE_BBO (trigger bbo_tracker scan)
  ↓
WAIT_BBO (wait for scan complete)
  ↓
DONE → IDLE
```

### BBO Tracker FSM

```
IDLE
  ↓ (update_trigger = '1')
SCAN_BIDS
  ├─→ SCAN_BIDS_WAIT1 (read latency cycle 1)
  ├─→ SCAN_BIDS_WAIT2 (read latency cycle 2)
  └─→ Check level_valid, level_data.valid, level_data.side
      ↓ (if valid bid found)
      Update best_bid_price_reg
  ↓ (scan_addr > 1)
  Continue scanning (decrement scan_addr)
  ↓ (scan_addr = 1, all bids scanned)
SCAN_ASKS
  ├─→ SCAN_ASKS_WAIT1 (read latency cycle 1)
  ├─→ SCAN_ASKS_WAIT2 (read latency cycle 2)
  └─→ Check level_valid, level_data.valid, level_data.side
      ↓ (if valid ask found)
      Update best_ask_price_reg
  ↓ (scan_addr = MAX_BID_LEVELS + MAX_ASK_LEVELS, all asks scanned)
COMPLETE
  ↓ (output BBO, assert bbo_update)
IDLE
```

## Implementation Details

### BRAM Inference Fixes

**Problem:** Initial implementation inferred LUTRAM (Distributed RAM) instead of Block RAM, causing:
- Resource waste (LUTRAM uses logic resources)
- Potential timing issues
- Incorrect bid price values (read pipeline timing)

**Root Causes Identified:**

1. **Read-Modify-Write Pattern** (`price_level_table.vhd`):
   - Reading from BRAM signal in write process prevented BRAM inference
   - Solution: 2-stage pipeline (Stage 1: read, Stage 2: modify+write)
   - Explicit BRAM control signals following Xilinx Read-First template

2. **Read in Write Process** (`order_storage.vhd`):
   - Reading `prev_valid` from BRAM in write process created read-modify-write
   - Solution: Separate `valid_bits` array for order counting
   - Write process is now write-only (matches Simple Dual-Port template)

3. **Missing `ram_style` Attribute**:
   - Added `attribute ram_style : string; attribute ram_style of bram : signal is "block";`
   - Forces BRAM inference when code pattern matches template

**Xilinx Templates Used:**
- `simple_dual_one_clock.vhd` - For `order_storage` (Simple Dual-Port)
- `rams_sp_rf.vhd` - For `price_level_table` (Read-First Single-Port)

### Address Mapping

**Price to Address Conversion** (`price_to_addr` function):
```vhdl
-- Bids: [0-127] (descending price order)
-- Asks: [128-255] (ascending price order)
-- Address offset: +1 to avoid address 0 (historical debugging)

if side = '0' then  -- Buy
    addr := resize(price_bits + 1, PRICE_ADDR_WIDTH);  -- [1-128]
else  -- Sell
    addr := resize(price_bits + 128 + 1, PRICE_ADDR_WIDTH);  -- [129-255]
end if;
```

**BBO Scan Addresses:**
- Bids: Start at `MAX_BID_LEVELS` (128), scan down to 1
- Asks: Start at `MAX_BID_LEVELS + 1` (129), scan up to 255

### Read Pipeline Latency

**2-Cycle Latency Pattern:**
1. **Cycle 0:** Assert `rd_en` / `level_req`, set address
2. **Cycle 1:** BRAM outputs data (registered)
3. **Cycle 2:** Data available on `rd_data` / `level_data`

**Handling in FSM:**
- `WAIT_PRICE_CMD` state: `wait_counter <= 2` (accounts for 2-cycle latency)
- `SCAN_BIDS_WAIT1` / `SCAN_BIDS_WAIT2`: Two wait states for read latency
- `SCAN_ASKS_WAIT1` / `SCAN_ASKS_WAIT2`: Two wait states for read latency

### Debug Journey: Bid Price Issue

**Symptom:** Bid prices consistently `0x00000000` while ask prices worked correctly.

**Debug Process:**
1. Added debug outputs: `SA` (scan address), `BdP` (bid price), `BdV` (bid valid), `St` (state)
2. Discovered: BBO tracker stuck in IDLE, `scan_addr` not initialized
3. Fixed: `scan_addr` reset initialization
4. Discovered: `bbo_trigger` never set, `bbo_ready` always high
5. Fixed: `bbo_trigger` timing in `UPDATE_BBO` / `WAIT_BBO` states
6. Discovered: `LdP=0x00000000` even when `Lv=1` (level valid but price zero)
7. Fixed: Read pipeline timing in `price_level_table` (`rd_valid_pending` signal)
8. Discovered: BRAM inferring LUTRAM instead of BRAM
9. Fixed: Refactored to Xilinx BRAM templates, added `ram_style` attribute
10. **Result:** Bid prices now show correct values

**Key Debug Signals Added:**
- `debug_level_valid` - Level valid signal from price level table
- `debug_level_data_price` - Raw price read from level_data
- `debug_level_addr` - Address being read (captured when level_req asserted)
- `debug_wr_addr`, `debug_wr_price`, `debug_wr_side`, `debug_wr_valid` - Write operation tracking

## Building the Design

### Prerequisites
- Vivado 2025.1 (or compatible version)
- Windows PC (universal build.tcl works on Windows)
- Git for version control
- Project 7 (ITCH parser) as dependency

### Build Commands

Use the universal build script from repository root:

```batch
REM Full build (synthesis + implementation + bitstream)
REM Auto-increments build version
build 08-order-book

REM Program FPGA
prog 08-order-book
```

Build time: ~15-20 minutes on typical desktop

**Build Version:** Displayed in build log:
```
==========================================
BUILD VERSION: X
==========================================
```

## Testing

### Hardware Setup

1. Connect Arty A7 to PC via USB (JTAG + UART)
2. Connect Ethernet cable from PC/Network switch to Arty A7
3. Configure Ethernet adapter:
   - IP: 192.168.1.10
   - Subnet: 255.255.255.0
   - No gateway needed
4. Open serial terminal (115200 baud, 8N1):
   ```batch
   python -m serial.tools.miniterm COM3 115200
   ```

### Test Procedure

#### 1. Add Order Test

```batch
cd 07-itch-parser-v4\test
python send_itch_packets.py --target 192.168.1.10 --port 12345 --test add_order
```

**Expected UART output:**
```
[BBO] Bid:0x0016E360 | Ask:0xFFFFFFFF | Spr:0xFFFFFFFF (BW=00 AW=00) A0W=00 P=00000000 S=00000000
```

Shows: Bid price $150.00 (0x0016E360), no ask yet (0xFFFFFFFF = invalid)

#### 2. Complete Order Lifecycle

```batch
python send_itch_packets.py --target 192.168.1.10 --port 12345 --test lifecycle
```

Sends sequence:
1. Add Order (Buy) → Bid price appears
2. Add Order (Sell) → Ask price appears, spread calculated
3. Execute → Shares reduced, BBO updated
4. Cancel → Shares reduced, BBO updated
5. Delete → Order removed, BBO updated

**Verification:**
- BBO prices update correctly
- Spread calculated: `Spr = Ask - Bid`
- Order counts increment/decrement
- Level counts track active price levels

#### 3. Multiple Price Levels

```batch
python send_itch_packets.py --target 192.168.1.10 --port 12345 --test multi_level
```

**Expected:** BBO shows best bid (highest) and best ask (lowest), even with multiple orders at different prices

### Debug Output Interpretation

**BBO Format:**
```
[BBO] Bid:0x0016E360 | Ask:0x0016D99C | Spr:0x00001388
      ^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^
      Best bid price   Best ask price   Spread (ask - bid)
```

**Debug Fields:**
- `Tr=0x` - BBO trigger (1 = scan triggered)
- `Rd=0x` - BBO ready (1 = scan complete, 0 = scanning)
- `Lv=0x` - Level valid (1 = level data available)
- `LdP=0xXXXXXXXX` - Level data price (price read from level)
- `LdA=0xXX` - Level data address (address being scanned)
- `WrA=0xXX` - Write address (when write occurs)
- `WrP=0xXXXXXXXX` - Write price (price being written)
- `WrS=0xX` - Write side (0=bid, 1=ask)

**Statistics Fields:**
- `BLv=XX` - Bid level count (active bid price levels)
- `ALv=XX` - Ask level count (active ask price levels)
- `BOrd=XXXX` - Bid order count (active buy orders)
- `AOrd=XXXX` - Ask order count (active sell orders)
- `Upd=XXXX` - Update count (total BBO updates)

### Troubleshooting

| Symptom | Possible Cause | Solution |
|---------|---------------|----------|
| Bid prices always 0x00000000 | BRAM inferring LUTRAM | Check synthesis report, verify BRAM templates |
| BBO not updating | `bbo_trigger` not set | Check `UPDATE_BBO` / `WAIT_BBO` states |
| Level data always zero | Read pipeline timing | Verify 2-cycle latency handling |
| Multiple driver errors | Signal driven from multiple processes | Consolidate signal assignments |
| Buffer overflow in UART | Debug fields exceed buffer size | Increase `byte_array` size in formatter |

## Performance Metrics

### Test Data

The order book has been validated using real-world NASDAQ market data:

**Source:** `12302019.NASDAQ_ITCH50` (December 30, 2019 trading day)
- **Total Dataset:** ~250 million ITCH 5.0 messages (8 GB binary file)
- **MySQL Database:** 50 million records imported (first 3 hours of trading)
- **Test Dataset:** 80,000 messages (10,000 per symbol)
- **Symbols:** AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA
- **Message Mix:** 98.2% Add Orders (A), 1.8% Trades (P)
- **Test Rate:** 600+ messages/second sustained

All performance metrics below are based on processing this real-world trading day data.

**Detailed Information:** See [../docs/database.md](../docs/database.md) for complete extraction process, message distribution, and data quality validation.

### Latency

- **Order processing:** ~12-17 clock cycles per message (@ 100 MHz = 120-170 ns)
- **BBO update:** ~260 clock cycles (128 bids + 128 asks × 2 cycles/level) = 2.6 μs
- **Total wire-to-BBO:** < 5 μs (including ITCH parsing)

### Resource Utilization

Actual for Artix-7 XC7A100T (Multi-Symbol Implementation):

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | ~30,000 | 63,400 | ~47% |
| Slice Registers | ~16,000 | 126,800 | ~13% |
| RAMB36 Tiles | 32 | 135 | 23.7% |
| RAMB18 Tiles | 2 | 270 | 0.74% |
| DSP Slices | 0 | 240 | 0% |

**BRAM Breakdown (Multi-Symbol):**
- `order_storage` × 8 symbols: 32 RAMB36 blocks (1024 × 130 bits each)
- `price_level_table` × 8 symbols: Included in above (256 × 82 bits each)
- `async_fifo`: 2 RAMB18 blocks (512 × 324 bits)

**Resource Scalability:**
- Single symbol: 4 RAMB36 per order book
- 8 symbols: 32 RAMB36 (24% utilization)
- **Headroom:** 76% BRAM capacity remaining for additional features

### Timing

- **System clock:** 100 MHz (10 ns period)
- **Worst Negative Slack (WNS):** > 0 ns (timing met)
- **Critical path:** BRAM read paths, BBO scanner FSM

## Key Design Decisions

### BRAM Inference Strategy

**Requirement:** Efficient on-chip memory for 1024 orders and 256 price levels.

**Implementation:** Xilinx BRAM templates for guaranteed Block RAM inference:
- **Simple Dual-Port** (order_storage): Separate write and read processes eliminates read-modify-write conflicts
- **Read-First Single-Port** (price_level_table): 2-stage pipeline (read → modify → write)
- **ram_style attribute:** Explicit directive forces BRAM when code matches template

**Rationale:** Synthesis tools use pattern-matching for memory inference. Template compliance guarantees Block RAM instead of distributed LUT RAM, saving logic resources and improving timing.

### Architectural Separation for Complex Operations

**Challenge:** Order counting requires reading valid status during write operations—creates read-modify-write pattern preventing BRAM inference.

**Solution:** Separate `valid_bits` array tracks order validity independently from main BRAM storage.

**Trade-off:** Additional logic resources for tracking array, but enables proper BRAM inference for primary storage. Net resource savings and better timing closure.

### Debug Instrumentation Philosophy

**Approach:** Comprehensive UART output of internal state:
- Scan addresses, read data, write operations
- FSM states, trigger signals, ready flags
- Performance counters (order counts, level counts, update counts)

**Rationale:** Hardware debugging without visibility is speculation. Strategic instrumentation enabled:
- Systematic root cause diagnosis (BRAM inference issue identified in 2 build cycles)
- Performance characterization (actual vs expected latency)
- Production validation (BBO correctness verification)

**Cost:** ~500 LUTs for debug formatter. Benefit: 10x faster debug cycles.

### Pipeline Latency Handling

**BRAM Characteristic:** 1-2 cycle read latency (registered output).

**FSM Design:** Explicit wait states in all read paths:
- `wait_counter` tracks pipeline stages
- Separate WAIT states for each read operation
- BBO scanner includes WAIT1/WAIT2 states for 2-cycle latency

**Validation:** Simulation waveforms verify data availability timing before hardware deployment.

## Production Trading System Applicability

**Architecture Patterns:**

1. **BRAM-Based Storage:** On-chip memory architecture scales to multi-symbol order books
2. **Multi-Stage FSMs:** Deterministic latency pipelines essential for HFT systems
3. **Memory Inference Control:** Template-based design guarantees resource utilization
4. **Systematic Debug:** Instrumentation enables rapid production issue diagnosis
5. **Latency Budgeting:** Sub-microsecond processing meets HFT requirements

**Real-World Relevance:**

- **Core Infrastructure:** Order books are fundamental to exchange matching engines, market makers, HFT systems
- **Deterministic Performance:** Fixed-cycle FSMs eliminate software non-determinism (no GC pauses, cache misses, context switches)
- **Scalability Path:** BRAM architecture extends to multiple symbols, deeper books, additional order types
- **Production Debugging:** Instrumentation techniques apply directly to production FPGA trading systems where observability is limited

## Files Structure

### Core Modules

- `order_book_manager.vhd` - Top-level FSM coordinating all components
- `order_storage.vhd` - BRAM-based order storage (1024 orders)
- `price_level_table.vhd` - BRAM-based price level aggregation (256 levels)
- `bbo_tracker.vhd` - FSM scanner for Best Bid/Offer tracking
- `order_book_pkg.vhd` - Constants, types, helper functions

### Integration

- `mii_eth_top.vhd` - Top-level integration with ITCH parser (from Project 7)
- `uart_bbo_formatter.vhd` - UART output formatter for BBO and debug data
- `itch_msg_decoder.vhd` - ITCH message decoder (from Project 7)

### Supporting Files

- `async_fifo.vhd` - Clock domain crossing FIFO (from Project 7)
- `itch_msg_pkg.vhd` - ITCH message encoding/decoding (from Project 7)
- All ITCH parser modules (from Project 7)

## Future Enhancements

**✅ Phase 2: Multi-Symbol Support** - COMPLETE
- ✅ Symbol filtering integration (8 symbols: AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA)
- ✅ Per-symbol order books (8 parallel instances)
- ✅ Symbol-based BBO tracking with round-robin arbiter
- ✅ Spread calculation for risk management

**Phase 3: Order Matching** - Next Steps
- Price-time priority matching
- Trade execution logic
- Fill reporting

**Phase 4: Market Data Output**
- Level 2 market data (full depth)
- Order book snapshots
- Real-time updates via Ethernet

**✅ Phase 5: C++ Order Gateway (Project 9)** - COMPLETE (See `09-order-gateway-cpp/`)
- ✅ UART BBO parser (C++)
- ✅ Multi-protocol output: TCP JSON, MQTT, Kafka
- ✅ Real-time market data distribution
- ✅ Integration with FPGA order book
- ✅ Live chart display in Java desktop application

---

## Project Status

**Status:** Functional - Integration Testing in Progress

**Created:** November 2025

**Last Updated:** November 2025 - Multi-Symbol Order Book with Spread Calculation Complete

## Recent Fixes

**Multi-Symbol Support (November 2025):**
- ✅ Implemented `multi_symbol_order_book.vhd` wrapper with 8 parallel order books
- ✅ Symbol demultiplexer routes ITCH messages to correct book based on symbol match
- ✅ Round-robin BBO arbiter cycles through 8 symbols with change detection
- ✅ Per-symbol BBO tracking maintains independent state for each symbol
- ✅ Resource usage: 32 RAMB36 tiles (23.7% utilization) - well within capacity

**Spread Calculation & BBO Persistence Fix (November 2025):**
- ✅ Fixed `bbo_tracker.vhd` spread calculation by moving to clocked FSM (was combinational process)
- ✅ Added `best_spread_reg` register and calculate in COMPUTE_SPREAD state
- ✅ Fixed `multi_symbol_order_book.vhd` missing spread output port
- ✅ Connected spread through complete data path: bbo_tracker → order_book_manager → multi_symbol_order_book → mii_eth_top → UART
- ✅ **CRITICAL FIX**: Removed data-clearing logic in `bbo_tracker.vhd` that was wiping BBO registers when one side was empty
  - **Root Cause**: COMPUTE_SPREAD state cleared all price registers when `best_bid_found='0' OR best_ask_found='0'`
  - **Impact**: Orders were being added correctly but BBO scan would clear bid data when no asks existed (and vice versa)
  - **Solution**: Removed clearing logic from SCAN_BIDS/SCAN_ASKS completion (lines 139-143, 187-191)
  - **Result**: Price registers now persist between scans, only updated when valid data is found
- ✅ **CRITICAL FIX**: Changed COMPUTE_SPREAD validation from scan flags to register contents
  - **Root Cause**: `best_bid_found` and `best_ask_found` flags only tracked current scan, not accumulated data
  - **Impact**: Spread was always 0 because flags were cleared at start of each scan, even if registers had valid data
  - **Solution**: Check actual register values (`best_bid_price_reg /= 0x00000000` and `best_ask_price_reg /= 0xFFFFFFFF`) instead of scan flags
  - **Result**: Spread now correctly calculates `ask_price - bid_price` when both sides exist in register
- ✅ Spread now correctly calculates ask_price - bid_price for all symbols
- ✅ BBO maintains both bid and ask sides simultaneously (no longer clears one when updating the other)

**BRAM Inference Fixes (November 2025):**
- Fixed `order_storage.vhd` LUTRAM inference by separating read and write processes (Simple Dual-Port pattern)
- Fixed `price_level_table.vhd` LUTRAM inference by implementing 2-stage read-modify-write pipeline (Read-First Single-Port pattern)
- Added `ram_style` attribute to force BRAM inference after template refactoring
- Resolved bid price issue (consistently `0x00000000`) through BRAM template compliance

**Debug Infrastructure (November 2025):**
- Added comprehensive UART debug outputs: scan addresses, read data, write operations, state machine status
- Fixed BBO tracker initialization and trigger timing
- Fixed read pipeline latency handling (2-cycle BRAM latency)

**Architecture Improvements (November 2025):**
- Refactored `order_storage` to use separate `valid_bits` array for order counting (prevents read-modify-write on main BRAM)
- Refactored `price_level_table` to explicit BRAM control signals following Xilinx template
- Updated `order_book_manager` to account for 2-cycle price level table latency

**BBO UART Format Enhancements (November 2025):**
- Added symbol name to BBO output: `[BBO:AAPL    ]` instead of generic `[BBO]`
- Added bid_shares and ask_shares to output format: `Bid:0xPRICE (0xSHARES)`
- Added spread to output: `Spr:0xSPREAD`
- Added `[BBO:NODATA  ]` status message when order book is empty (vs repeating stale prices)
- Fixed symbol byte order (MSB-first extraction from FILTER_SYMBOL_LIST constant)
- Disabled heartbeat trigger to prevent false activity in C++ gateway (Project 9 integration)
- BBO now only sent when prices, shares, or valid status actually change

---

## Credits and Acknowledgments

### Third-Party Components

**eth_udp_send SystemVerilog Module:**
- **Source:** [fpga-ethernet-udp](https://github.com/adamchristiansen/fpga-ethernet-udp) by Adam Christiansen
- **License:** MIT License
- **Usage:** Core UDP transmission module providing UDP/IP packet construction and MII TX interface
- **Integration:** Custom VHDL wrapper (eth_udp_send_wrapper.sv) created to flatten SystemVerilog interfaces for VHDL compatibility

**Project 13 Original Work:**
- `bbo_udp_formatter.vhd` - BBO to UDP payload formatter with pipelined state machine
- `eth_udp_send_wrapper.sv` - SystemVerilog/VHDL language interoperability bridge
- XDC timing constraints for generated clock domains (clk_25mhz)
- Integration into mii_eth_top.vhd
- UDP packet format specification and parsing examples (Python/C++)
- Complete documentation and architecture updates

**Attribution:**
The fpga-ethernet-udp project by Adam Christiansen provides the excellent eth_udp_send SystemVerilog implementation that handles low-level UDP/IP packet construction and MII TX interface timing. Project 13 integrates this module through a custom wrapper pattern and implements the application-specific BBO formatting and clock domain management.

---

This project demonstrates production-grade FPGA design for trading systems, including BRAM architecture, FSM design, mixed-language integration, and comprehensive debugging techniques.
