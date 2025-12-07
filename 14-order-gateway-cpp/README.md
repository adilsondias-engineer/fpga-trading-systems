# Project 14: C++ Order Gateway - DPDK/XDP Kernel Bypass + Disruptor IPC

**Platform:** Linux (Windows for legacy UDP mode)
**Technology:** C++20, DPDK 23.11, AF_XDP, LMAX Disruptor, Boost.Asio, MQTT (libmosquitto), Kafka (librdkafka)
**Status:** Completed and tested on hardware

---

## Overview

The C++ Order Gateway is the **middleware layer** of the FPGA trading system, acting as a bridge between multiple data sources and application clients. It reads BBO (Best Bid/Offer) data from **FPGA hardware via DPDK/XDP kernel bypass** and **Binance WebSocket streams**, then distributes it using **LMAX Disruptor lock-free IPC** for ultra-low-latency communication or multi-protocol distribution for client applications.

**Primary Data Flow (Ultra-Low-Latency):**
```
FPGA Order Book (UDP) → DPDK Kernel Bypass (0.04 μs, 40ns avg) → Disruptor Shared Memory → Market Maker FSM
```

**Multi-Protocol Distribution:**
```
FPGA Order Book (UDP) → C++ Gateway → TCP/MQTT/Kafka → Applications
Binance WebSocket (wss://) → C++ Gateway → TCP/MQTT/Kafka → Applications
```

**Data Sources:**
- **FPGA Feed:** Binary BBO packets via UDP/XDP/DPDK (ultra-low latency, sub-50ns parsing with DPDK)
- **Binance Feed:** JSON WebSocket streams (real-time cryptocurrency market data, ~5 μs parsing)

---

## Architecture

### Core Components

**Primary Architecture (Ultra-Low-Latency Mode - DPDK):**
```
┌─────────────────────────────────────────────────────────────┐
│                   C++ Order Gateway (Project 14)             │
│                                                              │
│  ┌─────────────────┐     ┌──────────────────────────┐       │
│  │  DPDK Listener  │────→│     BBO Parser           │       │
│  │  (Poll Mode     │     │  (Binary Protocol)       │       │
│  │   Driver)       │     │  40ns avg, 50ns P99      │       │
│  │  Port 5000      │     │                          │       │
│  └─────────────────┘     └──────────┬───────────────┘       │
│   Zero-copy RX                      │                        │
│   Huge pages                        ↓                        │
│   Busy polling               ┌──────────────────────┐        │
│                              │  Disruptor Producer  │        │
│                              │  (Lock-Free Publish) │        │
│                              └──────────┬───────────┘        │
│                                         │                    │
└─────────────────────────────────────────┼────────────────────┘
                                          │
                    POSIX Shared Memory (/dev/shm/bbo_ring_gateway)
                    Ring Buffer: 1024 entries × 128 bytes = 131 KB
                    Lock-Free IPC: Atomic sequence numbers
                                          │
┌─────────────────────────────────────────┼────────────────────┐
│                                         ↓                    │
│                              ┌──────────────────────┐        │
│                              │  Disruptor Consumer  │        │
│                              │  (Lock-Free Poll)    │        │
│                              └──────────┬───────────┘        │
│                                         │                    │
│                   Market Maker FSM (Project 15)              │
└──────────────────────────────────────────────────────────────┘
```

**Alternative Mode (XDP Kernel Bypass):**
```
┌─────────────────────────────────────────────────────────────┐
│                   C++ Order Gateway (Project 14)             │
│                                                              │
│  ┌────────────────┐     ┌──────────────────────────┐        │
│  │  XDP Listener  │────→│     BBO Parser          │        │
│  │  (AF_XDP)      │     │  (Binary Protocol)       │        │
│  │  Port 5000     │     │  50ns avg, 130-150ns P99 │        │
│  └────────────────┘     └──────────┬───────────────┘        │
│                                    │                         │
│                                    ↓                         │
│                         ┌──────────────────────┐             │
│                         │  Disruptor Producer  │             │
│                         │  (Lock-Free Publish) │             │
│                         └──────────┬───────────┘             │
│                                    │                         │
└────────────────────────────────────┼─────────────────────────┘
                                     │
                    POSIX Shared Memory (/dev/shm/bbo_ring_gateway)
                                     │
┌────────────────────────────────────┼─────────────────────────┐
│                                    ↓                         │
│                   Market Maker FSM (Project 15)              │
└─────────────────────────────────────────────────────────────┘
```

**Multi-Protocol Distribution Architecture:**
```
┌──────────────────────────────────────────────────────────┐
│                   C++ Order Gateway                      │
│                                                          │
│  ┌────────────────┐     ┌──────────────────────────┐     │
│  │  UDP Listener  │────→│     BBO Parser           │     │
│  │  (Async I/O)   │     │  (Binary Protocol)       │     │
│  │  Port 5000     │     │                          │     │
│  └────────────────┘     └──────────┬───────────────┘     │
│                                    │                     │
│  ┌────────────────┐     ┌──────────┴───────────────┐     │
│  │ Binance WS     │────→│   Binance Parser         │     │
│  │ Client         │     │  (JSON Protocol)         │     │
│  │ (Boost.Beast)  │     │                          │     │
│  │ wss://stream   │     └──────────┬───────────────┘     │
│  │ .binance.com   │                │                     │
│  └────────────────┘                │                     │
│                                    ↓                     │
│                         ┌──────────────────┐             │
│                         │  Thread-Safe     │             │
│                         │  BBO Queue       │             │
│                         │  (Unified)       │             │
│                         └─────────┬────────┘             │
│                                   │                      │
│          ┌────────────────────────┼────────────────┐     │
│          ↓                        ↓                ↓     │
│  ┌──────────────┐      ┌───────────────┐ ┌──────────────┐│
│  │ TCP Server   │      │ MQTT Publisher│ │Kafka Producer││
│  │ localhost    │      │ Mosquitto     │ │              ││
│  │ port 9999    │      │ 192.168.0.2   │ │ 192.168.0.203││
│  │              │      │ :1883         │ │ :9092        ││
│  │ JSON output  │      │ v3.1.1        │ │ For future   ││
│  └──────────────┘      └───────────────┘ └──────────────┘│
└──────────────────────────────────────────────────────────┘
```

### Multi-Protocol Distribution

| Protocol | Use Case | Clients | Status |
|----------|----------|---------|--------|
| **TCP** | Java Desktop (low-latency trading terminal) | JavaFX app | ✅ Active |
| **MQTT** | ESP32 IoT + Mobile App (lightweight, mobile-friendly) | ESP32 TFT + .NET MAUI | ✅ Active |
| **Kafka** | Future analytics, data persistence, replay | None yet | Reserved |

---

## Features

### 1. Data Sources

#### FPGA Feed (UDP/XDP/DPDK)
- **Multiple kernel bypass modes** for different performance requirements:
  - **DPDK Mode:** Poll Mode Driver with zero-copy, huge pages, busy polling (FASTEST - 40ns avg)
  - **XDP Mode:** AF_XDP kernel bypass with eBPF (50ns avg)
  - **Standard UDP:** Boost.Asio async socket listening (200ns avg)
- **Port:** 5000 (configurable)
- **Format:** Binary BBO data packets from FPGA (256-byte packets)
- **Enable/Disable:** `--disable-fpga` flag to disable FPGA feed for testing

#### Binance WebSocket Feed
- **WebSocket client** connecting to Binance Spot API streams
- **Endpoint:** `wss://stream.binance.com:9443/stream`
- **Stream Type:** `bookTicker` (best bid/ask updates in real-time)
- **Format:** JSON messages converted to BBOData structure
- **Features:**
  - Automatic reconnection with exponential backoff
  - Ping/pong keepalive (every 20 seconds)
  - Combined stream support (multiple symbols in single connection)
  - Thread-safe integration with existing BBO queue
  - Asynchronous I/O using Boost.Beast for non-blocking operations
  - SSL/TLS encrypted connection
  - Latency measurement using PerfMonitor (same as FPGA feed)
- **Enable:** Configure in `config.json`:
  ```json
  {
    "fpga": { "enable": false },
    "binance": {
      "enable": true,
      "symbols": ["BTCUSDT", "ETHUSDT", "SOLUSDT"],
      "stream_type": "bookTicker"
    }
  }
  ```
- **Use Cases:**
  - Testing Binance feed in isolation: Set `fpga.enable: false` and `binance.enable: true`
  - Running both feeds in parallel: Enable both FPGA and Binance feeds
  - Multi-exchange market data aggregation
  - Real-time cryptocurrency market data for trading systems
- **Performance:** See Binance WebSocket Performance section below

**DPDK Performance (Validated - FASTEST MODE):**
- **Average:** 0.04 μs, **P50:** 0.04 μs, **P95:** 0.05 μs, **P99:** 0.05 μs
- **Test Load:** 78,296 samples @ 400 Hz
- **Consistency:** 0.01 μs standard deviation (2× better than XDP!)
- **Improvement over XDP:** 62-67% faster P99, 2× more consistent
- **No CPU isolation required:** DPDK built-in thread affinity achieves HFT performance
- **See:** Performance Characteristics section below for detailed benchmarks

**XDP Kernel Bypass Performance (Validated):**
- **Average:** 0.05 μs, **P50:** 0.05 μs, **P99:** 0.13-0.15 μs
- **Test Load:** 78,616 samples @ 400 Hz
- **Consistency:** 0.02-0.03 μs standard deviation
- **P95:** 0.09 μs
- **Improvement over standard UDP:** 4× faster average
- **See:** [README_XDP.md](README_XDP.md) for XDP setup and implementation details

**Standard UDP Performance (Validated):**
- **Average:** 0.20 μs, **P50:** 0.19 μs, **P99:** 0.38 μs
- **Test Load:** 10,000 samples @ 400 Hz (25 seconds sustained)
- **Consistency:** 0.06 μs standard deviation
- **P95:** 0.32 μs (95% of messages under 0.32 μs)

**Kernel Bypass Comparison:**
- **DPDK:** 40ns avg, 50ns P99 - Best for HFT, requires DPDK setup, higher CPU (busy polling)
- **XDP:** 50ns avg, 130-150ns P99 - Good balance, requires XDP setup + CPU isolation
- **Standard UDP:** 200ns avg, 380ns P99 - Simplest setup, kernel overhead

### 2. BBO Parser
- Parses binary BBO data packets
- Extracts symbol, bid/ask prices, shares, spread
- Direct binary-to-decimal conversion for high performance

### 3. TCP Server
- **Port:** 9999 (configurable)
- **Protocol:** JSON over TCP
- **Clients:** Java desktop trading terminal
- **Format:** Same JSON format as Project 9 (maintains client compatibility)
  ```json
  {
    "type": "bbo",
    "symbol": "AAPL",
    "timestamp": 1699824000123456789,
    "bid": {
      "price": 290.1708,
      "shares": 30
    },
    "ask": {
      "price": 290.2208,
      "shares": 30
    },
    "spread": {
      "price": 0.05,
      "percent": 0.017
    }
  }
  ```

### 4. MQTT Publisher
- **Broker:** Mosquitto @ 192.168.0.2:1883
- **Protocol:** MQTT v3.1.1 (for ESP32/mobile compatibility)
- **Authentication:** trading / trading123
- **Topic:** `bbo_messages`
- **QoS:** 0 (fire-and-forget for low latency)
- **Clients:** ESP32 IoT display, .NET MAUI mobile app

**Why MQTT for IoT/Mobile?**
- ✅ Lightweight protocol (low power consumption)
- ✅ Handles unreliable networks (WiFi/cellular)
- ✅ Low latency (< 100ms)
- ✅ Native support on ESP32 and mobile platforms
- ✅ No dependency issues on Android/iOS

### 5. Kafka Producer
- **Broker:** 192.168.0.203:9092
- **Topic:** `bbo_messages`
- **Key:** Symbol name (for partitioning)
- **Status:** Gateway publishes to Kafka, but **no consumers implemented yet**

**Kafka Reserved for Future Use:**
- Time-series database integration
- Historical replay for backtesting
- Analytics pipelines (Spark, Flink)
- Machine learning feature generation
- Microservices integration

**Why NOT Kafka for mobile/IoT?**
- ❌ Heavy protocol overhead (battery drain)
- ❌ Persistent TCP connections required
- ❌ Native library dependencies (Android issues)
- ❌ Designed for backend services, not edge devices

### 6. Disruptor IPC (Ultra-Low-Latency Mode)
- **Architecture:** LMAX Disruptor lock-free ring buffer
- **Shared Memory:** `/dev/shm/bbo_ring_gateway` (POSIX shm)
- **Ring Buffer Size:** 1024 entries × 128 bytes = 131,328 bytes
- **IPC Method:** Lock-free atomic operations (memory_order_acquire/release)
- **Consumer:** Project 15 (Market Maker FSM)
- **Performance:** 0.10 μs publish latency, 4.13 μs end-to-end

**Disruptor Pattern Benefits:**
- ✅ Zero-copy shared memory (no TCP/socket overhead)
- ✅ Lock-free synchronization (atomic sequence numbers)
- ✅ Cache-line aligned structures (prevents false sharing)
- ✅ Power-of-2 ring buffer (fast modulo using bitwise AND)
- ✅ 3× faster than TCP IPC (12.73 μs → 4.13 μs)

**Critical Implementation Details:**
- Fixed-size data structures (char arrays, not std::string/vector)
- Template parameter `RingBuffer<T, size_t N>` for fixed array
- Signal handlers must be minimal (only set flag, no cleanup)
- Latency measurement at BBO creation, not at read time

**Enable Disruptor Mode:**
```bash
# Run gateway with Disruptor IPC enabled
./order_gateway 0.0.0.0 5000 --use-xdp --enable-disruptor
```

### 7. CSV Logging (Optional)
- Logs all BBO updates to CSV file
- Format: `timestamp,symbol,bid_price,bid_shares,ask_price,ask_shares,spread`
- Useful for debugging and offline analysis

---

## Build Instructions

### Prerequisites

**Windows:**
- Visual Studio 2019+ with C++17 support
- vcpkg package manager

**Linux:**
- GCC 7+ or Clang 5+
- CMake 3.15+

### Dependencies (via vcpkg)

```bash
# Install vcpkg (if not already installed)
git clone https://github.com/Microsoft/vcpkg.git
cd vcpkg
./bootstrap-vcpkg.sh  # or bootstrap-vcpkg.bat on Windows
./vcpkg integrate install

# Install dependencies
./vcpkg install boost-asio boost-system boost-thread
./vcpkg install nlohmann-json
./vcpkg install librdkafka
./vcpkg install mosquitto
```

### Build

**Windows (Visual Studio):**
```bash
# Open solution in Visual Studio
# Build → Build Solution (Ctrl+Shift+B)
# Or use command line:
msbuild 09-order-gateway-cpp.sln /p:Configuration=Release
```

**Linux (CMake):**
```bash
mkdir build
cd build
cmake ..
make -j$(nproc)
```

### Building with XDP Support (Linux Only)

**Additional Prerequisites:**
- Linux kernel 5.4+ with XDP support
- libbpf-dev (BPF library)
- libxdp-dev (XDP library)
- clang/llvm (for compiling BPF programs)
- xdp-tools (for loading XDP programs)

**Install Dependencies:**
```bash
# Ubuntu/Debian
sudo apt-get install -y libbpf-dev libxdp-dev clang llvm xdp-tools

# Or build from source
git clone https://github.com/libbpf/libbpf
cd libbpf/src
make
sudo make install
```

**Build with XDP:**
```bash
mkdir build
cd build
cmake -DUSE_XDP=ON ..
make -j$(nproc)
```

**XDP Program Setup:**

1. **Load XDP program** (redirects UDP packets to AF_XDP socket):
```bash
# Reload XDP program (safe, can run multiple times)
./reload_xdp.sh

# Or manually:
sudo xdp-loader load -m native -s xdp eno2 build/xdp_prog.o
```

2. **Verify XDP program loaded:**
```bash
sudo xdp-loader status eno2
# Should show: xdp_prog.o loaded in native mode
```

3. **Configure network queues** (critical for stability):
```bash
# Check current queue configuration
ethtool -l eno2

# Set combined channels to 4 (required for queue_id 3)
sudo ethtool -L eno2 combined 4

# Verify RSS (Receive Side Scaling) distributes to queue 3
# Monitor which queue receives packets:
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep xdp
```

4. **Run gateway with XDP:**
```bash
# Grant network capabilities
sudo setcap cap_net_raw,cap_net_admin,cap_sys_nice=eip ./build/order_gateway

# Run with XDP (use queue_id 3, the only stable configuration)
sudo ./build/order_gateway 0.0.0.0 5000 --use-xdp --xdp-interface eno2 --xdp-queue-id 3

# With debug logging to troubleshoot
sudo ./build/order_gateway 0.0.0.0 5000 --use-xdp --xdp-interface eno2 --xdp-queue-id 3 --enable-xdp-debug
```

**Important Notes:**
- **Queue Configuration:** Only `combined 4` with `queue_id 3` is stable. Other combinations may kill network connectivity.
- **Unload Before Network Changes:** Run `sudo xdp-loader unload eno2 --all` before changing network settings.
- **Root Required:** XDP requires root privileges or CAP_NET_RAW + CAP_NET_ADMIN capabilities.
- **See Also:** [README_XDP.md](README_XDP.md) for detailed XDP architecture and troubleshooting.

### Building with DPDK Support (Linux Only)

**Additional Prerequisites:**
- DPDK 23.11 or later
- Huge pages support (1GB or 2MB pages)
- IOMMU/VFIO support for userspace drivers
- Compatible NIC (Intel I219-LM, most Intel/Mellanox NICs supported)

**Install DPDK:**
```bash
# Option 1: Install from package manager (Ubuntu 22.04+)
sudo apt-get install -y dpdk dpdk-dev

# Option 2: Build from source (recommended for latest features)
wget https://fast.dpdk.org/rel/dpdk-23.11.tar.xz
tar xf dpdk-23.11.tar.xz
cd dpdk-23.11
meson build
cd build
ninja
sudo ninja install
sudo ldconfig
```

**Configure Huge Pages:**
```bash
# Allocate 1GB huge pages (requires reboot)
echo 'vm.nr_hugepages=4' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Or allocate temporarily
echo 4 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

# Verify huge pages
grep Huge /proc/meminfo
```

**Build with DPDK:**
```bash
mkdir build
cd build
cmake -DUSE_DPDK=ON ..
make -j$(nproc)
```

**Run gateway with DPDK:**
```bash
# Grant capabilities
sudo setcap cap_net_raw,cap_net_admin,cap_sys_nice,cap_ipc_lock=eip ./build/order_gateway

# Run with DPDK (polls NIC directly, zero-copy)
sudo ./build/order_gateway

# DPDK will initialize EAL (Environment Abstraction Layer) automatically
# Huge pages will be mapped and PMD (Poll Mode Driver) will start
```

**Important Notes:**
- **Higher CPU usage:** DPDK busy-polls the NIC (100% CPU core utilization)
- **Best performance:** 40ns average, 50ns P99 - production HFT-grade
- **No CPU isolation required:** DPDK built-in thread affinity is sufficient
- **Tradeoff:** Higher power consumption vs lowest latency and jitter
- **When to use:** Ultimate performance for HFT/market making applications
- **See Also:** [DPDK Documentation References](#dpdk-data-plane-development-kit) for detailed setup guides and architecture information

---

## Usage

### Configuration File

Project 14 uses a JSON configuration file (similar to Project 15) instead of command-line arguments. The default configuration file is `config.json` in the same directory as the executable.

**Basic Usage:**
```bash
# Use default config.json
./order_gateway

# Use custom config file
./order_gateway /path/to/config.json
```

### Configuration File Format

Example `config.json`:

```json
{
  "log_level": "info",
  
  "fpga": {
    "enable": true,
    "udp_ip": "0.0.0.0",
    "udp_port": 5000,
    "use_xdp": false,
    "xdp_interface": "eno2",
    "xdp_queue_id": 0,
    "enable_xdp_debug": false
  },
  
  "binance": {
    "enable": false,
    "symbols": ["BTCUSDT", "ETHUSDT"],
    "stream_type": "bookTicker"
  },
  
  "tcp": {
    "enable": true,
    "port": 9999
  },
  
  "mqtt": {
    "enable": true,
    "broker_url": "mqtt://192.168.0.2:1883",
    "client_id": "order_gateway",
    "username": "trading",
    "password": "trading123",
    "topic": "bbo_messages"
  },
  
  "kafka": {
    "enable": true,
    "broker_url": "192.168.0.203:9092",
    "client_id": "order_gateway",
    "topic": "bbo_messages"
  },
  
  "csv_logger": {
    "enable": false,
    "file": ""
  },
  
  "disruptor": {
    "enable": false,
    "shm_name": "gateway"
  },
  
  "performance": {
    "enable_rt": false,
    "quiet_mode": false,
    "benchmark_mode": false
  }
}
```

### Configuration Options

| Section | Option | Description | Default |
|---------|--------|-------------|---------|
| `log_level` | - | Log level: trace, debug, info, warn, error, critical | info |
| `fpga.enable` | - | Enable FPGA feed (UDP/XDP) | true |
| `fpga.udp_ip` | - | UDP IP address to bind | 0.0.0.0 |
| `fpga.udp_port` | - | UDP port to listen on | 5000 |
| `fpga.use_xdp` | - | Use AF_XDP for kernel bypass | false |
| `fpga.xdp_interface` | - | Network interface for XDP | eno2 |
| `fpga.xdp_queue_id` | - | XDP queue ID | 0 |
| `fpga.enable_xdp_debug` | - | Enable XDP debug logging | false |
| `binance.enable` | - | Enable Binance WebSocket feed | false |
| `binance.symbols` | - | Array of Binance symbols | [] |
| `binance.stream_type` | - | Stream type: bookTicker or depth@100ms | bookTicker |
| `tcp.enable` | - | Enable TCP server | true |
| `tcp.port` | - | TCP server port | 9999 |
| `mqtt.enable` | - | Enable MQTT publisher | true |
| `mqtt.broker_url` | - | MQTT broker URL | mqtt://192.168.0.2:1883 |
| `mqtt.client_id` | - | MQTT client ID | order_gateway |
| `mqtt.username` | - | MQTT username | trading |
| `mqtt.password` | - | MQTT password | trading123 |
| `mqtt.topic` | - | MQTT topic | bbo_messages |
| `kafka.enable` | - | Enable Kafka producer | true |
| `kafka.broker_url` | - | Kafka broker URL | 192.168.0.203:9092 |
| `kafka.client_id` | - | Kafka client ID | order_gateway |
| `kafka.topic` | - | Kafka topic | bbo_messages |
| `csv_logger.enable` | - | Enable CSV logging | false |
| `csv_logger.file` | - | CSV log file path | "" |
| `disruptor.enable` | - | Enable Disruptor IPC | false |
| `disruptor.shm_name` | - | Shared memory name | gateway |
| `performance.enable_rt` | - | Enable RT scheduling + CPU pinning | false |
| `performance.quiet_mode` | - | Suppress console BBO output | false |
| `performance.benchmark_mode` | - | Benchmark mode (single-threaded) | false |

### Example Configurations

**XDP Mode (Kernel Bypass):**
```json
{
  "log_level": "warn",
  "fpga": {
    "enable": true,
    "udp_ip": "0.0.0.0",
    "udp_port": 5000,
    "use_xdp": true,
    "xdp_interface": "eno2",
    "xdp_queue_id": 3,
    "enable_xdp_debug": false
  },
  "tcp": { "enable": true, "port": 9999 },
  "mqtt": { "enable": false },
  "kafka": { "enable": false },
  "performance": { "enable_rt": true, "quiet_mode": true }
}
```

**Binance WebSocket Only:**
```json
{
  "log_level": "info",
  "fpga": { "enable": false },
  "binance": {
    "enable": true,
    "symbols": ["BTCUSDT", "ETHUSDT"],
    "stream_type": "bookTicker"
  },
  "tcp": { "enable": true, "port": 9999 },
  "mqtt": { "enable": true },
  "kafka": { "enable": false }
}
```

**Disruptor IPC Mode:**
```json
{
  "log_level": "warn",
  "fpga": {
    "enable": true,
    "use_xdp": true,
    "xdp_interface": "eno2",
    "xdp_queue_id": 3
  },
  "disruptor": { "enable": true },
  "tcp": { "enable": false },
  "mqtt": { "enable": false },
  "kafka": { "enable": false },
  "performance": { "enable_rt": true, "quiet_mode": true }
}
```

**Note:** XDP options require `USE_XDP` build flag and libxdp library. See [README_XDP.md](README_XDP.md) for XDP setup instructions. Disruptor mode creates shared memory at `/dev/shm/bbo_ring_gateway` for ultra-low-latency IPC with Project 15. Binance WebSocket requires internet connectivity to `wss://stream.binance.com:9443`.

---

## System Integration

### Full Data Flow

```
┌──────────────┐                    ┌──────────────────────┐
│ FPGA         │ UDP                │ Binance WebSocket    │
│ Order Book   │ @ Port 5000        │ wss://stream         │
│ (8 symbols)  │                    │ .binance.com:9443    │
└──────┬───────┘                    │ (Multiple symbols)   │
       │                            └──────┬───────────────┘
       │                                   │
       ↓  Binary BBO packets               ↓  JSON WebSocket messages
┌──────────────────────────────────────────────────────────────┐
│ C++ Order Gateway                                            │
│ - Parse binary → decimal (FPGA)                              │
│ - Parse JSON → BBOData (Binance)                             │
│ - Unified BBO queue (both sources)                           │
│ - Multi-protocol fanout                                      │
└──┬────────┬────────┬─────────────────────────────────────────┘
   │        │        │
   │        │        └──→ [Kafka: Future Analytics]
   │        │
   │        └──→ [MQTT Broker: 192.168.0.2:1883]
   │                 ↓
   │            ┌─────────┬──────────────┐
   │            ↓         ↓              ↓
   │         ESP32    Mobile App    (Future IoT)
   │         TFT      .NET MAUI
   │
   └──→ [TCP: localhost:9999]
            ↓
      Java Desktop
      Trading Terminal
```

**Data Source Characteristics:**

| Source | Protocol | Format | Latency (Best Performance) | Use Case |
|--------|----------|--------|----------------------------|----------|
| **FPGA** | UDP/XDP/DPDK | Binary | **0.04 μs P50, 0.05 μs P99 (DPDK)** | Ultra-low latency HFT, market making |
| **Binance** | WebSocket (wss://) | JSON | 4.15 μs P50 (11.40 μs P99) | Real-time cryptocurrency market data |

### Currently Active Clients

1. **Java Desktop (TCP)** - [12-java-desktop-trading-terminal/](../12-java-desktop-trading-terminal/)
   - Live BBO table with charts
   - Order entry with risk checks
   - Real-time updates via TCP JSON stream

2. **ESP32 IoT Display (MQTT)** - [10-esp32-ticker/](../10-esp32-ticker/)
   - 1.8" TFT LCD color display
   - Real-time ticker for trading floor
   - Low power consumption

3. **Mobile App (MQTT)** - [11-mobile-app/](../11-mobile-app/)
   - .NET MAUI (Android/iOS/Windows)
   - Real-time BBO monitoring
   - Cross-platform support

### Future Kafka Consumers (Not Yet Implemented)

- Analytics dashboard (time-series charts)
- Data archival service (InfluxDB, TimescaleDB)
- Backtesting engine (historical replay)
- ML feature pipeline (real-time + historical)

---

## Performance Characteristics

### Latency Measurements (Validated with RT Optimizations)

#### Standard UDP Mode

| Stage | Latency | Notes |
|-------|---------|-------|
| UDP Receive | < 0.1 µs | Network I/O (included in parse) |
| BBO Parse | **0.20 µs avg** | Binary parse (validated) |
| TCP Publish | ~10-50 µs | localhost |
| MQTT Publish | ~50-100 µs | LAN |
| Kafka Publish | ~100-200 µs | LAN |
| **Total: FPGA → TCP** | **~15-100 µs** | End-to-end |

**Validated Performance (Standard UDP):**
```
=== Project 14 (UDP) Performance Metrics ===
Samples:  10,000
Avg:      0.20 μs
Min:      0.10 μs
Max:      2.12 μs
P50:      0.19 μs
P95:      0.32 μs
P99:      0.38 μs
StdDev:   0.06 μs
```

**Test Conditions:**
- Duration: 25 seconds
- Total messages: 10,000 (8 symbols)
- Average rate: 400 messages/second (realistic FPGA BBO rate)
- Hardware: AMD Ryzen AI 9 365 w/ Radeon 880M
- Configuration: taskset -c 2-5 (CPU isolation) + SCHED_FIFO RT scheduling
- Errors: 0

**Key Characteristics:**
- **Highly consistent:** Standard deviation only 0.06 μs (30% of average)
- **Predictable tail latency:** P99 at 0.38 μs (2× median)
- **Minimal outliers:** Max 2.12 μs (likely single OS scheduling event)

#### XDP Kernel Bypass Mode

**Validated Performance (AF_XDP):**
```
=== Project 14 (XDP) Performance Metrics ===
Samples:  78,585
Avg:      0.04 μs
Min:      0.03 μs
Max:      0.49 μs
P50:      0.04 μs
P95:      0.08 μs
P99:      0.12 μs
StdDev:   0.02 μs
```

**Test Conditions:**
- Total messages: 78,585 (8 symbols × multiple runs)
- Average rate: 400 messages/second (realistic FPGA BBO rate)
- Hardware: AMD Ryzen AI 9 365 w/ Radeon 880M
- Network: Intel I219-LM (eno2)
- Queue: Combined channel 4, queue_id 3 (only stable configuration)
- XDP Mode: Native (driver-level redirect)
- Errors: 0

**Key Characteristics:**
- **Ultra-low latency:** Average 0.04 μs (40 nanoseconds!)
- **Excellent consistency:** Standard deviation only 0.02 μs (50% of average)
- **Tight tail latency:** P99 at 0.12 μs (3× median)
- **Minimal outliers:** Max 0.49 μs (4× lower than standard UDP)
- **5× faster average** than standard UDP (0.04 μs vs 0.20 μs)
- **7× faster P95** than standard UDP (0.08 μs vs 0.32 μs)

#### UDP vs XDP vs XDP+Disruptor Comparison

| Metric | Standard UDP | XDP Kernel Bypass | XDP + Disruptor | Best Improvement |
|--------|--------------|-------------------|-----------------|------------------|
| **Avg Latency** | 0.20 µs | **0.04 µs** | **0.10 µs** | **5× faster (UDP→XDP)** |
| **P50 Latency** | 0.19 µs | **0.04 µs** | **0.09 µs** | **4.8× faster (UDP→XDP)** |
| **P95 Latency** | 0.32 µs | **0.08 µs** | Not measured | **4× faster (UDP→XDP)** |
| **P99 Latency** | 0.38 µs | **0.12 µs** | **0.29 µs** | **3.2× faster (UDP→XDP)** |
| **Std Dev** | 0.06 µs | **0.02 µs** | Not measured | **3× more consistent** |
| **Max Latency** | 2.12 µs | **0.49 µs** | Not measured | **4.3× faster** |
| **Samples** | 10,000 | **78,585** | **78,514** | Large validation datasets |
| **Transport** | Kernel UDP stack | AF_XDP (kernel bypass) | AF_XDP + Disruptor IPC | Zero-copy shared memory |
| **IPC Method** | N/A (parsing only) | N/A (parsing only) | POSIX shm (131 KB) | Lock-free ring buffer |
| **End-to-End** | N/A | N/A | **4.13 µs to Project 15** | 3× faster than TCP mode |

**Key Insights:**
- **XDP eliminates kernel overhead:** 5× average latency improvement by bypassing network stack
- **Tighter tail latencies:** P95 improvement (4×) and much lower max latency (4.3×) shows consistent performance
- **Sub-100ns parsing:** 40 ns average puts parsing well below network jitter
- **Disruptor adds minimal overhead:** 0.06 µs (60 ns) to publish to shared memory ring buffer
- **Disruptor vs TCP IPC:** 3× faster end-to-end (12.73 µs → 4.13 µs) by eliminating socket overhead
- **Validated with large dataset:** 78,514+ samples demonstrate stability and reliability
- **When to use XDP:** For ultra-low latency trading (HFT), market making, or high-frequency analytics
- **When to use Disruptor:** For ultra-low-latency IPC between processes (Project 14 → Project 15)
- **Setup complexity:** XDP requires kernel bypass setup, XDP program loading, and specific queue configuration

#### DPDK Kernel Bypass Mode

**Validated Performance (DPDK - RT Optimized):**
```
=== Project 14 (DPDK) Performance Metrics ===
Samples:  78,296
Avg:      0.04 μs
Min:      0.04 μs
Max:      0.95 μs
P50:      0.04 μs
P95:      0.05 μs
P99:      0.05 μs
StdDev:   0.01 μs
```

**Test Conditions:**
- Total messages: 78,296 (8 symbols)
- Average rate: 400 messages/second (realistic FPGA BBO rate)
- Hardware: AMD Ryzen AI 9 365 w/ Radeon 880M
- Network: Intel I219-LM (eno2)
- DPDK Version: 23.11
- PMD: Poll Mode Driver (busy polling, zero-copy)
- Memory: Huge pages (1GB pages)
- RT Optimization: SCHED_FIFO priority 80, CPU core 2 pinning
- CPU Optimizations: RT enabled (no GRUB isolation required!)
- Errors: 0

**Key Characteristics:**
- **Ultra-low latency:** Average 0.04 μs (40 nanoseconds) matches XDP
- **Outstanding consistency:** Standard deviation only 0.01 μs (2× better than XDP!)
- **Extremely tight tail latency:** P99 at 0.05 μs (62-67% faster than XDP P99)
- **Low jitter:** StdDev 0.01 μs vs XDP 0.02 μs shows superior consistency
- **Production-grade:** Poll Mode Driver with zero-copy, kernel bypass
- **No CPU isolation needed:** DPDK's built-in affinity achieves HFT performance without GRUB changes
- **Cache-optimized:** DPDK packet processing designed for L1/L2 cache efficiency

**DPDK vs XDP Comparison:**

| Metric | XDP (CPU Optimized) | DPDK (RT Optimized) | Improvement |
|--------|---------------------|---------------------|-------------|
| **Avg Latency** | 0.04-0.05 μs | **0.04 μs** | Same or better |
| **P50 Latency** | 0.05 μs | **0.04 μs** | **20% faster** |
| **P95 Latency** | 0.09 μs | **0.05 μs** | **44% faster** |
| **P99 Latency** | 0.13-0.15 μs | **0.05 μs** | **62-67% faster** |
| **Std Dev** | 0.02-0.03 μs | **0.01 μs** | **2-3× more consistent** |
| **Max Latency** | 0.91-0.96 μs | **0.95 μs** | Comparable |
| **CPU Isolation** | Required (GRUB) | **Not required** | Simpler deployment |
| **Setup Complexity** | eBPF program + XDP load | DPDK init + PMD config | Similar complexity |

**Key Insights:**
- **DPDK achieves better performance than XDP WITHOUT CPU isolation:** Built-in thread affinity sufficient
- **Superior tail latency:** P99 is 0.05 μs (same as P95) - incredibly tight distribution
- **Lower jitter:** Half the standard deviation of XDP (0.01 μs vs 0.02 μs)
- **Production HFT-grade:** 40 ns average parsing means network jitter dominates
- **Poll Mode Driver advantage:** Busy polling + zero-copy + huge pages = consistent sub-50ns performance
- **When to use DPDK:** Ultimate performance for HFT, market data feeds, or low-latency applications
- **Tradeoff:** Higher CPU usage (busy polling) vs lower latency and jitter

#### Binance WebSocket Feed Performance

**Validated Performance (Binance WebSocket - CPU Optimized):**
```
=== Project 14 Binance (WebSocket) Performance Metrics ===
Samples:  563,037
Avg:      4.77 μs
Min:      3.16 μs
Max:      4.44 μs
P50:      4.15 μs
P95:      8.23 μs
P99:      11.40 μs
StdDev:   5.44 μs
```

**Test Conditions:**
- Total messages: 563,037 (multiple symbols: BTCUSDT, ETHUSDT, SOLUSDT, etc.)
- Stream type: `bookTicker` (best bid/ask updates)
- Hardware: AMD Ryzen AI 9 365 w/ Radeon 880M
- Network: Internet connection to Binance WebSocket API
- Protocol: WebSocket over SSL/TLS (wss://)
- CPU Optimizations: C-state disabled, hyperthreading disabled, virtualization off, quiet mode enabled
- Errors: 0 (automatic reconnection handled disconnects)

**Key Characteristics:**
- **Sub-5μs parsing:** Average 4.77 μs for JSON parsing and BBO conversion
- **Consistent performance:** P50 at 4.15 μs shows most messages processed quickly
- **Production-realistic tail latency:** P99 at 11.40 μs reflects long-running system performance
- **JSON overhead:** Higher than binary FPGA protocol (4.77 μs vs 0.05 μs) due to JSON parsing
- **Production-scale validation:** 563,037 samples (6× larger than typical benchmarks) from live Binance market data
- **Stability proven:** Large sample size demonstrates system reliability over extended duration
- **Multi-symbol support:** Handles multiple symbols simultaneously via combined streams
- **CPU optimizations:** Quiet mode + system tuning reduced P99 from 22.56 μs → 11.40 μs (2× improvement)

**Binance vs FPGA Performance Comparison:**

| Metric | FPGA (UDP) | FPGA (XDP - CPU Optimized) | Binance (WebSocket - CPU Optimized) | Notes |
|--------|------------|----------------------------|-------------------------------------|-------|
| **Avg Latency** | 0.20 μs | **0.05 μs** | 4.77 μs | JSON parsing overhead |
| **P50 Latency** | 0.19 μs | **0.05 μs** | 4.15 μs | Binary vs JSON format |
| **P95 Latency** | 0.32 μs | **0.09 μs** | 8.23 μs | Network variability |
| **P99 Latency** | 0.38 μs | **0.13-0.15 μs** | 11.40 μs | Internet latency (2× improvement) |
| **StdDev** | 0.06 μs | **0.02-0.03 μs** | 5.44 μs | Production-realistic jitter |
| **Samples** | 10,000 | **78,616** | **563,037** | Production-scale validation |
| **Format** | Binary | Binary | JSON | Protocol difference |
| **Transport** | UDP (LAN) | AF_XDP (kernel bypass) | WebSocket (Internet) | Network stack overhead |
| **CPU Optimizations** | None | **C-state/HT/Virt OFF** | **C-state/HT/Virt OFF + Quiet Mode** | Deterministic latency |
| **Use Case** | Ultra-low latency HFT | Ultra-low latency HFT | Real-time cryptocurrency market data | Different requirements |

**Key Insights:**
- **Binary protocol advantage:** FPGA binary format is 95× faster than JSON (0.05 μs vs 4.77 μs)
- **Network stack impact:** Internet WebSocket adds latency compared to local UDP
- **JSON parsing cost:** Text parsing and conversion adds ~4.7 μs overhead
- **CPU optimizations impact:** Binance P99 improved 2× (22.56 μs → 11.40 μs) with quiet mode + system tuning
- **Real-world performance:** 4.77 μs average is excellent for real-time market data applications
- **Production-scale validation:** 563,037 samples (largest Binance benchmark) demonstrate long-running stability
- **Multi-exchange support:** Binance feed enables cryptocurrency market data alongside FPGA equity data
- **Sample size matters:** 563K samples provide production-realistic tail latencies vs short-duration tests

### Throughput

- **Max BBO rate:** > 10,000 updates/sec (validated)
- **Realistic load:** 400 messages/sec (matches FPGA BBO output rate)
- **CPU usage:** 2-5% per core (4 isolated cores, taskset -c 2-5)

### Performance vs Project 9 (UART)

| Metric | Project 9 (UART) | Project 14 (UDP) | Improvement |
|--------|------------------|------------------|-------------|
| **Avg Latency** | 10.67 µs | **0.20 µs** | **53× faster** |
| **P50 Latency** | 6.32 µs | **0.19 µs** | **33× faster** |
| **P95 Latency** | 26.33 µs | **0.32 µs** | **82× faster** |
| **P99 Latency** | 50.92 µs | **0.38 µs** | **134× faster** |
| **Std Dev** | 8.04 µs | **0.06 µs** | **134× more consistent** |
| **Max Latency** | 86.14 µs | 2.12 µs | **41× faster** |
| **Samples** | 1,292 | **10,000** | 7.7× more validation data |
| **Transport** | Serial @ 115200 baud | UDP network | Network eliminates bottleneck |

**Key Insights:**
- **53× average latency improvement:** UDP + binary protocol + RT optimization eliminates serial bottleneck
- **Tail latency advantage:** P99 shows 134× improvement, demonstrating consistent low-latency performance
- **Sub-microsecond parsing:** 0.20 μs average puts parsing well below network jitter
- **Validated with realistic load:** 10,000 samples at 400 Hz sustained for 25 seconds

### Real-Time Optimizations

The gateway supports optional real-time optimizations for ultra-low latency applications:

#### CPU Isolation (System-Level)

Isolated CPU cores prevent OS scheduling interference:

```bash
# Add to /etc/default/grub
GRUB_CMDLINE_LINUX="isolcpus=2,3,4,5 nohz_full=2,3,4,5,6 rcu_nocbs=2,3,4,5,6"

# Update GRUB and reboot
sudo update-grub
sudo reboot

# Verify isolation
cat /proc/cmdline | grep isolcpus
```

**Impact:** Running on isolated core 2 via `taskset -c 2` achieved **26% latency reduction** (2.09 μs → 1.54 μs avg).

#### RT Scheduling and CPU Pinning (Code-Level)

Enable real-time scheduling with the `--enable-rt` flag:

```bash
# Grant CAP_SYS_NICE capability (required for SCHED_FIFO)
sudo setcap cap_sys_nice=eip ./order_gateway

# Run with RT optimizations
./order_gateway 192.168.0.99 5000 --enable-rt
```

**What `--enable-rt` does:**
- Applies `SCHED_FIFO` real-time scheduling to critical threads
- Pins FPGA thread (UDP/XDP) to isolated core 2 (priority 80)
- Pins Binance thread to isolated core 6 (priority 80)
- Pins publish thread to isolated core 3 (priority 70)
- Reduces context switches and scheduler jitter

**Thread Configuration:**

| Thread | Priority (1-99) | CPU Core | Purpose |
|--------|-----------------|----------|---------|
| FPGA Listener (UDP/XDP) | 80 (highest) | Core 2 | Critical path: UDP/XDP receive + parse |
| Binance WebSocket | 80 (highest) | Core 6 | Binance WebSocket receive + JSON parse |
| Publish Thread | 70 (high) | Core 3 | TCP/MQTT/Kafka distribution |

**Implementation:** See [include/common/rt_config.h](include/common/rt_config.h) for `RTConfig` utilities.

**Expected Impact:**
- Further reduction in average latency (target: < 1.5 μs)
- Lower tail latencies (P95, P99)
- Reduced jitter (standard deviation)
- More deterministic performance

**Performance Results:** See [docs/performance_benchmark.md](../docs/performance_benchmark.md) for detailed RT optimization results.

---

## Code Structure

```
14-order-gateway-cpp/
├── config.json               # Configuration file (JSON format)
├── src/
│   ├── main.cpp              # Entry point, config file loading
│   ├── order_gateway.cpp     # Main gateway orchestration
│   ├── udp_listener.cpp      # Async UDP listening (Boost.Asio)
│   ├── xdp_listener.cpp      # AF_XDP kernel bypass listener
│   ├── bbo_parser.cpp        # Binary → decimal parser
│   ├── binance_ws_client.cpp # Binance WebSocket client
│   ├── binance_parser.cpp    # Binance JSON message parser
│   ├── tcp_server.cpp        # JSON TCP server
│   ├── mqtt.cpp              # MQTT publisher (libmosquitto)
│   ├── kafka_producer.cpp    # Kafka producer (librdkafka)
│   └── csv_logger.cpp        # CSV file logging
├── include/
│   ├── order_gateway.h
│   ├── udp_listener.h
│   ├── xdp_listener.h
│   ├── bbo_parser.h
│   ├── binance_ws_client.h   # Binance WebSocket client interface
│   ├── binance_parser.h       # Binance JSON parser interface
│   ├── bbo_data.h             # Common BBO data structure
│   ├── tcp_server.h
│   ├── mqtt.h
│   ├── kafka_producer.h
│   ├── csv_logger.h
│   └── common/
│       ├── perf_monitor.h    # Performance monitoring
│       └── rt_config.h        # RT scheduling utilities
├── vcpkg.json                # Dependency manifest
└── CMakeLists.txt            # Build configuration
```

---

## Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Language** | C++20 | Modern C++ with STL |
| **Async I/O** | Boost.Asio 1.89+ | UDP, TCP sockets |
| **WebSocket** | Boost.Beast 1.89+ | Binance WebSocket client (SSL/TLS) |
| **Threading** | Boost.Thread | Multi-threaded architecture |
| **JSON** | nlohmann/json 3.11+ | TCP output serialization, config file parsing, Binance message parsing |
| **MQTT** | libmosquitto 2.0+ | IoT/mobile publish |
| **Kafka** | librdkafka 2.6+ | Future analytics |
| **Performance** | High-res clock | Latency measurement |
| **Logging** | spdlog | Structured logging with levels |

---

## Logging

Project 14 uses **spdlog** for structured logging instead of `std::cout`/`std::cerr`. The log level can be configured in `config.json`:

- **trace**: Very detailed debugging information
- **debug**: Debug information (useful for troubleshooting)
- **info**: Informational messages (default)
- **warn**: Warning messages
- **error**: Error messages
- **critical**: Critical errors only

Example output:
```
[2025-01-15 10:23:45.123] [order_gateway] [info] Order Gateway started
[2025-01-15 10:23:45.124] [order_gateway] [info]   FPGA Feed: 0.0.0.0 @ 5000 port (UDP mode)
[2025-01-15 10:23:45.125] [order_gateway] [info]   TCP Port: 9999
[2025-01-15 10:23:45.126] [order_gateway] [info] Gateway running. Press Ctrl+C to stop.
```

For production deployments, set `log_level` to `"warn"` or `"error"` to reduce log volume and improve performance.

---

## Troubleshooting

### "UDP bind failed"

**Cause:** Port already in use or permissions issue

**Solution:**
```bash
# Check if port 5000 is already in use
# Linux:
sudo netstat -tulpn | grep 5000
# Or
sudo lsof -i :5000

# Windows:
netstat -ano | findstr :5000

# Kill process using the port or choose different port
```

### "MQTT connection failed"

**Cause:** Mosquitto broker not running or wrong credentials

**Solution:**
```bash
# Test MQTT broker connectivity
mosquitto_sub -h 192.168.0.2 -p 1883 -t bbo_messages -u trading -P trading123 -v

# Check Mosquitto logs
sudo tail -f /var/log/mosquitto/mosquitto.log
```

### "Kafka connection failed"

**Cause:** Kafka broker not running or network issue

**Solution:**
```bash
# Test Kafka connectivity
kafka-console-consumer --bootstrap-server 192.168.0.203:9092 --topic bbo_messages

# Check Kafka status
systemctl status kafka
```

### "No data from FPGA"

**Cause:** FPGA not sending UDP packets or network issue

**Solution:**
1. Check FPGA is receiving ITCH packets
2. Verify network connectivity between FPGA and gateway
3. Use Wireshark to capture UDP packets on port 5000
4. Check firewall rules aren't blocking UDP traffic
5. Verify FPGA is sending to correct IP:port

---

## Example Output

### FPGA Feed (UDP/XDP) Example

```
Order Gateway started
  FPGA Feed: 0.0.0.0 @ 5000 port (UDP mode)
  TCP Port: 9999
  MQTT Broker: mqtt://192.168.0.2:1883
  MQTT Topic: bbo_messages
  Kafka Broker: 192.168.0.203:9092
  Kafka Topic: bbo_messages

FPGA UDP/XDP thread started
Publish thread started

[BBO] AAPL    Bid: $290.17 (30) | Ask: $290.22 (30) | Spread: $0.05 (0.02%)
[BBO] TSLA    Bid: $431.34 (20) | Ask: $432.18 (25) | Spread: $0.84 (0.19%)
[BBO] SPY     Bid: $322.96 (50) | Ask: $322.99 (50) | Spread: $0.03 (0.01%)
...

^C
Stopping Order Gateway...

=== Project 14 FPGA (UDP) Performance Metrics ===
Samples:  3789
Avg:      2.09 μs
Min:      0.42 μs
Max:      45.84 μs
P50:      1.04 μs
P95:      7.01 μs
P99:      11.91 μs
StdDev:   2.51 μs
[PERF] Saved 3789 samples to project14_fpga_latency.csv

FPGA UDP thread stopped
Publish thread stopped
Order Gateway stopped
```

### Binance WebSocket Feed Example

```
[2025-12-01 13:30:27.574] [order_gateway] [info] [BTCUSDT] Bid: 87089.9900 (5) | Ask: 87090.0000 (2) | Spread: 0.0100
[2025-12-01 13:30:27.674] [order_gateway] [info] [BTCUSDT] Bid: 87089.9900 (8) | Ask: 87090.0000 (2) | Spread: 0.0100
[2025-12-01 13:30:27.774] [order_gateway] [info] [SOLUSDT] Bid: 127.9600 (502) | Ask: 127.9700 (448) | Spread: 0.0100
[2025-12-01 13:30:27.875] [order_gateway] [info] [ZECUSDT] Bid: 388.9800 (2) | Ask: 389.0800 (1) | Spread: 0.1000
[2025-12-01 13:30:27.975] [order_gateway] [info] [BTCUSDT] Bid: 87091.5400 (3) | Ask: - (-) | Spread: 0.0100
[2025-12-01 13:30:28.076] [order_gateway] [info] [BTCUSDT] Bid: 87094.1000 (1) | Ask: - (-) | Spread: 0.0100
[2025-12-01 13:30:28.176] [order_gateway] [info] [DOGEUSDT] Bid: 0.1389 (147183) | Ask: 0.1389 (10253) | Spread: 0.0000
[2025-12-01 13:30:28.277] [order_gateway] [info] [BTCUSDT] Bid: 87095.8000 (2) | Ask: - (-) | Spread: 0.0100

^C
[2025-12-01 13:30:28.370] [order_gateway] [info] Shutdown signal received (2)

=== Project 14 Binance (WebSocket) Performance Metrics ===
Samples:  32696
Avg:      4.96 μs
Min:      1.79 μs
Max:      126.40 μs
P50:      3.12 μs
P95:      11.94 μs
P99:      22.56 μs
StdDev:   4.39 μs
[PERF] Saved 32696 samples to project14_binance_latency.csv

[2025-12-01 13:30:28.373] [order_gateway] [info] Stopping Order Gateway...
[2025-12-01 13:30:28.373] [order_gateway] [info] [Binance] Stopping WebSocket client...
[2025-12-01 13:30:28.377] [order_gateway] [info] Publish thread stopped
[2025-12-01 13:30:28.396] [order_gateway] [info] Binance WebSocket thread stopped
[2025-12-01 13:30:28.735] [order_gateway] [info] [Binance] WebSocket client stopped
[2025-12-01 13:30:28.735] [order_gateway] [info] Binance client stopped
[2025-12-01 13:30:28.836] [order_gateway] [info] MQTT disconnected
[2025-12-01 13:30:28.836] [order_gateway] [info] Order Gateway stopped
```

---

## Next Steps

### Current Status
✅ Gateway complete and operational
✅ TCP client (Java Desktop) working
✅ MQTT clients (ESP32 + Mobile) working
   Kafka consumers not yet implemented

### Future Enhancements (Optional)

1. **Kafka Consumer Services:**
   - Time-series database writer (InfluxDB, TimescaleDB)
   - Analytics dashboard (Grafana, custom web UI)
   - Historical data archival

2. **Performance Optimizations:**
   - Zero-copy buffers for high-frequency data
   - Lock-free queues for thread communication
   - DPDK for kernel bypass (if needed)

3. **Monitoring:**
   - Prometheus metrics export
   - Health check endpoint
   - Performance statistics logging

4. **Reliability:**
   - Automatic reconnection for MQTT/Kafka
   - Circuit breaker pattern
   - Graceful degradation (continue if one protocol fails)

---

## Related Projects

- **[08-order-book/](../08-order-book/)** - FPGA order book (data source)
- **[10-esp32-ticker/](../10-esp32-ticker/)** - ESP32 IoT display (MQTT client)
- **[11-mobile-app/](../11-mobile-app/)** - Mobile app (MQTT client)
- **[12-java-desktop-trading-terminal/](../12-java-desktop-trading-terminal/)** - Java desktop (TCP client)
- **[15-market-maker/](../15-market-maker/)** - Market maker FSM (TCP client for automated trading)

---

## References

### DPDK (Data Plane Development Kit)
- [DPDK Official Documentation](https://doc.dpdk.org/) - Complete DPDK documentation portal
- [DPDK Getting Started Guide](https://doc.dpdk.org/guides/linux_gsg/index.html) - Linux installation and setup
- [DPDK Programmer's Guide](https://doc.dpdk.org/guides/prog_guide/index.html) - Core DPDK concepts and APIs
- [DPDK Poll Mode Drivers](https://doc.dpdk.org/guides/nics/index.html) - NIC-specific PMD documentation
- [DPDK Sample Applications](https://doc.dpdk.org/guides/sample_app_ug/index.html) - Example DPDK applications
- [DPDK Performance Reports](https://core.dpdk.org/perf-reports/) - Official DPDK performance benchmarks
- [Intel DPDK White Paper](https://www.intel.com/content/www/us/en/developer/articles/technical/dpdk-performance-report.html) - DPDK architecture and performance analysis
- [DPDK for High-Frequency Trading](https://www.net.in.tum.de/fileadmin/bibtex/publications/papers/DPDK-HFT.pdf) - Academic paper on DPDK for trading systems
- [DPDK vs Kernel Networking](https://blog.selectel.com/introduction-dpdk-architecture-principles/) - Architecture comparison and principles

### AF_XDP and Kernel Bypass
- [AF_XDP - Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html) - Official AF_XDP documentation
- [AF_XDP - DRM/Networking Documentation](https://dri.freedesktop.org/docs/drm/networking/af_xdp.html) - Detailed AF_XDP architecture
- [XDP Tutorial - xdp-project](https://github.com/xdp-project/xdp-tutorial) - Comprehensive XDP tutorial with examples
- [AF_XDP Examples - xdp-project](https://github.com/xdp-project/bpf-examples/blob/main/AF_XDP-example/README.org) - Practical AF_XDP implementation examples
- [DPDK AF_XDP PMD](https://doc.dpdk.org/guides/nics/af_xdp.html) - DPDK's AF_XDP poll mode driver documentation
- [Kernel Bypass Techniques in Linux for HFT](https://lambdafunc.medium.com/kernel-bypass-techniques-in-linux-for-high-frequency-trading-a-deep-dive-de347ccd5407) - Deep dive into kernel bypass for trading systems
- [Kernel Bypass Networking: DPDK, SPDK, io_uring](https://anshadameenza.com/blog/technology/2025-01-15-kernel-bypass-networking-dpdk-spdk-io_uring/) - Comparison of kernel bypass approaches
- [Linux Kernel vs DPDK HTTP Performance](https://talawah.io/blog/linux-kernel-vs-dpdk-http-performance-showdown/) - Performance comparison study

### Ring Buffers and Lock-Free Data Structures
- [LMAX Disruptor - Technical Paper](https://lmax-exchange.github.io/disruptor/disruptor.html) - Official Disruptor pattern documentation
- [Mechanical Sympathy - Martin Thompson](https://mechanical-sympathy.blogspot.com/) - Blog covering Disruptor and performance engineering
- [Imperial HFT - GitHub Repository](https://github.com/0burak/imperial_hft) - Source of Disruptor implementation classes used in Project 14-15
- [Low-Latency Trading Systems - Thesis](https://arxiv.org/abs/2309.04259) - Burak Gunduz thesis on HFT systems with Disruptor pattern
- [Imperial HFT Explanation Video](https://www.youtube.com/watch?v=65XoXkh6VcY) - Video explanation of Disruptor implementation for trading systems
- [Ring Buffers](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) - Ring buffer design and implementation
- [eBPF Ring Buffer Optimization](https://ebpfchirp.substack.com/p/challenge-3-ebpf-ring-buffer-optimization) - eBPF ring buffer optimization techniques
- [Lock-Free Programming](https://preshing.com/20120612/an-introduction-to-lock-free-programming/) - Introduction to lock-free programming concepts

### Performance Analysis
- [Brendan Gregg - CPU Flame Graphs](https://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html) - CPU profiling visualization
- [Brendan Gregg - perf Examples](https://www.brendangregg.com/perf.html) - Linux perf tool usage guide
- [Brendan Gregg - Performance Methodology](https://www.brendangregg.com/methodology.html) - Performance analysis methodology

### High-Performance Networking
- [P51: High Performance Networking - University of Cambridge](https://www.cl.cam.ac.uk/teaching/1920/P51/Lecture6.pdf) - Academic perspective on high-performance networking

### Trading Systems Architecture
- [NASDAQ ITCH 5.0 Specification](../docs/NQTVITCHspecification.pdf) - Market data protocol specification (referenced in Project 7)
- [Xilinx Arty A7 Reference Manual](../docs/ARTY_A7_COMPLETE_REFERENCE.md) - FPGA hardware specifications

### Binance API and WebSocket
- [Binance WebSocket Streams Documentation](https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams) - Official Binance WebSocket API documentation
- [Binance API Documentation](https://developers.binance.com/docs) - Complete Binance API reference
- [Binance Combined Streams](https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams#general-wss-information) - Combined stream format for multiple symbols
- [Boost.Beast Documentation](https://www.boost.org/doc/libs/1_89_0/libs/beast/doc/html/index.html) - Boost.Beast WebSocket library used for Binance client

---

**Build Time:** ~30 seconds
**Hardware Status:** Tested with FPGA UDP transmitter at 5000 port
