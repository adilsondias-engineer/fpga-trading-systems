# FPGA Trading System - Complete Architecture & Design

**Date:** January 2026
**Status:** FUNCTIONAL - PCIe Pipeline Architecture + XGBoost GPU Inference + SDL2 Control Panel
**Projects:** 6-29 (Network Stack → Order Book → PCIe Bridge → Pipeline Processing → SDL2 UI)
**Development Time:** 560+ hours

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Architecture Layers](#architecture-layers)
3. [Data Flow](#data-flow)
4. [Technology Stack](#technology-stack)
5. [Protocol Specifications](#protocol-specifications)
6. [Application Ecosystem](#application-ecosystem)
7. [Performance Characteristics](#performance-characteristics)
8. [Deployment Architecture](#deployment-architecture)
9. [Future Enhancements](#future-enhancements)

---

## System Overview

A complete **low-latency market data processing and distribution system** combining FPGA hardware acceleration with multi-protocol software gateway for real-time financial data delivery.

### Key Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                    HARDWARE LAYER (FPGA)                            │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────────────────┐    │
│  │ Ethernet   │→ │ ITCH 5.0     │→ │ Multi-Symbol Order Book   │    │
│  │ MII PHY    │  │ Parser       │  │ (8 symbols, BRAM-based)   │    │
│  │ 10/100 Mb  │  │ (9 msg types)│  │ • BBO tracking            │    │
│  └────────────┘  └──────────────┘  │ • Spread calculation      │    │
│                                    │ • Round-robin arbiter     │    │
│                                    └───────────┬───────────────┘    │
│                                                │ UART 115200        │
└────────────────────────────────────────────────┼────────────────────┘
                                                 │
                                                 ↓
┌───────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                  SOFTWARE LAYER (C++ Gateway)                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   ┌──────────────┐  ┌───────────────┐   │
│  │ UART Parser  │→ │ BBO Decoder  │→ │ Multi-Protocol Publisher │   │   Binance    │  │ Binance WS    │   │
│  │ (Raw ASCII)  │  │ (Hex→Decimal)│  │ • TCP Server             │ ← │   Parser     │← │   Client      │   │
│  │              │  │              │  │ • MQTT Publisher         │   │ JSON Protocol│  │ (Boost.Beast) │   │                                      
│  │              │  │              │  │ • Kafka Producer         │   │              │  │               │   │
│  └──────────────┘  └──────────────┘  └───────────┬──────────────┘   └──────────────┘  └───────────────┘   │
└──────────────────────────────────────────────────┼────────────────────────────────────────────────────────┘
                                                   │
                ┌──────────────────────────────────┼────────────────┐
                │                                  │                │
                ↓                                  ↓                ↓
        ┌───────────────┐                   ┌───────────────┐  ┌─────────────┐
        │ TCP Endpoint  │                   │ MQTT Broker   │  │Kafka Cluster│
        │ localhost:9999│                   │ (Mosquitto)   │  │             │
        └───────┬───────┘                   └───────┬───────┘  └──────┬──────┘
                │                                   │                 │
                ↓                                   ↓                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│                   APPLICATION LAYER                                 │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────────┐   │
│  │ Java Desktop │      │  ESP32 IoT   │      │   Mobile App     │   │
│  │  (JavaFX)    │      │  TFT/OLED    │      │ (.NET MAUI)      │   │
│  │              │      │              │      │                  │   │
│  │ • Live BBO   │      │ • MQTT Client│      │ • MQTT Client    │   │
│  │ • Charts     │      │ • Live Ticker│      │ • Android/iOS    │   │
│  │ • TCP Client │      │ • BBO Display│      │ • Real-time BBO  │   │
│  └──────────────┘      └──────────────┘      └──────────────────┘   │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Kafka → Future Analytics (Data Persistence, Replay, ML)       │ │
│  │    Reserved for backend services, time-series DB, pipelines    │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Architecture Layers

### Layer 1: Hardware (FPGA - Artix-7)

**Development Boards:**
- **Arty A7-100T** (XC7A100T) - Projects 6-8, 13, 19 - MII 100 Mbps Ethernet
- **ALINX AX7203** (XC7A200T) - Project 20+ - RGMII Gigabit Ethernet

**Purpose:** Ultra-low-latency market data processing in hardware

#### Project 6: UDP/IP Network Stack
- **Components:** MII PHY, MAC Parser, IP Parser, UDP Parser
- **Latency:** < 2 µs wire-to-parsed
- **Features:**
  - Real-time byte-by-byte parsing
  - Production CDC (Clock Domain Crossing)
  - 100% reliability under stress testing
  - XDC timing constraints verified

#### Project 7: NASDAQ ITCH 5.0 Parser
- **Components:** ITCH Parser, Symbol Filter, Async FIFO
- **Message Types:** S, R, A, E, X, D, U, P, Q (9 types)
- **Features:**
  - Configurable symbol filtering (8 symbols)
  - Gray code CDC (25 MHz → 100 MHz)
  - Message encoding/decoding pipeline
  - Deterministic parsing latency

#### Project 8: Multi-Symbol Order Book
- **Components:**
  - 8 parallel order book managers
  - Symbol demultiplexer
  - BBO tracker with spread calculation
  - Round-robin BBO arbiter
- **Capacity per Symbol:**
  - 1,024 concurrent orders
  - 256 price levels (128 bid + 128 ask)
- **Symbols Tracked:** AAPL, TSLA, SPY, QQQ, GOOGL, MSFT, AMZN, NVDA
- **Latency:**
  - Order processing: 120-170 ns
  - BBO update: ~2.6 µs per symbol
  - Full scan: ~30 µs for all 256 levels
- **Resources:** 32 RAMB36 tiles (24% utilization)
- **Output:** UART @ 115200 baud (debug only)
  ```
  [BBO:AAPL    ]Bid:0x002C46CC (0x0000001E) | Ask:0x002CE55C (0x0000001E) | Spr:0x00001F90
  ```

#### Project 13: UDP BBO Transmitter (MII TX)
- **Purpose:** Real-time BBO distribution via UDP (frees UART for debug)
- **Architecture:**
  - BBO UDP formatter (VHDL)
  - eth_udp_send_wrapper.sv (SystemVerilog/VHDL bridge)
  - MII TX interface (25 MHz, 4-bit nibbles)
- **Protocol:** UDP/IP broadcast to 192.168.0.93:5000
- **Packet Format:**
  - 256-byte payload (28 bytes BBO data + 228 bytes padding)
  - Big-endian fixed-point (4 decimal places: 1,495,000 = $149.50)
  - Symbol (8B) + Bid Price/Shares (8B) + Ask Price/Shares (8B) + Spread (4B)
- **Key Innovation:**
  - SystemVerilog wrapper flattens interfaces for VHDL instantiation
  - Pipelined nibble formatter (CALC_NIBBLE → WRITE_NIBBLE) for timing closure
  - XDC constraints for generated clk_25mhz (not eth_tx_clk)
- **Latency:** 312 ns ITCH parse → UDP TX (4-point hardware-measured)
- **Output:** UDP packets
  ```
  Destination: 192.168.0.93:5000
  Source: 192.168.0.212:5000 (FPGA MAC: 00:18:3E:04:5D:E7)
  Payload: 256 bytes binary (BBO data at bytes 228-255)
  ```

#### Project 19: PY32F030 FPGA Status Display (SPI Monitoring)
- **Purpose:** External ARM Cortex-M0 microcontroller for FPGA monitoring and configuration via SPI
- **Architecture:**
  - **spi_slave_core.vhd:** Generic SPI Mode 0 protocol handler (reusable across projects)
  - **spi_register_if.vhd:** Application-specific 6-register bank (4 read-only status + 2 read-write config)
  - **spi_slave.vhd:** Backward compatibility wrapper for integration
  - **PY32F030 Firmware:** SPI master, register read/write, UART display formatting
- **Register Bank:**
  - **Status Inputs (Read-Only):** ORDER_COUNT, BBO_COUNT, LATENCY_P50, STATUS
  - **Configuration Outputs (Read-Write):** SYMBOL_EN (8-bit symbol filter), THRESHOLD (BBO spread threshold)
- **SPI Protocol:**
  ```
  Transaction Format: [CMD_BYTE][ADDR_BYTE][DATA_32BIT]
  Commands: 0x01=READ, 0x02=WRITE
  Data Format: 32-bit big-endian (MSB first), matches UDP/IP network byte order
  SPI Mode 0: CPOL=0, CPHA=0, up to 10 MHz tested
  ```
- **Clock Domain Crossing:**
  - Variable SPI clock (up to 10 MHz) → 100 MHz FPGA via 2-FF synchronizer
  - Edge detection on synchronized signals (rising/falling for SEND_DATA/RECEIVE_DATA states)
  - 10,000+ SPI transactions tested, zero errors, no metastability issues
- **Critical Bug Fixes:**
  - **Pipeline Timing:** 2-cycle register fetch delay handled via setup phase (bit_count 0→1→2)
  - **Address Byte Trailing Edge:** Explicit bit_count=2 check skips premature shift on falling edge
- **PY32F030 Hardware:** ARM Cortex-M0 @ 24 MHz, 64 KB Flash, 8 KB SRAM, SPI master (up to 12 MHz)
- **Architecture Benefits:**
  - **Resource Optimization:** FPGA LUTs/BRAM dedicated to time-critical paths only (312 ns ITCH-to-BBO, hardware-measured)
  - **Dynamic Configuration:** PY32 writes SYMBOL_EN, THRESHOLD via SPI (no FPGA reprogramming)
  - **Independent Monitoring:** External watchdog can reset FPGA if status registers freeze
  - **Scalability:** Register bank expandable to 256 registers (8-bit address space)
- **Example Output:** `Orders: 1 | BBO: 2 | Lat: 3 ns | Status: 0x00000004 | Symbol: 0xFF | Threshold: 1000`

#### Project 20: Gigabit Ethernet Order Book (RGMII TX) - AX7203 Migration
- **Purpose:** Full trading system migration from Arty A7-100T to ALINX AX7203 with Gigabit Ethernet
- **Hardware Upgrade:**
  - **Board:** Arty A7-100T → ALINX AX7203
  - **FPGA:** XC7A100T → XC7A200T (2.1× logic, 2.7× BRAM, 3.1× DSP)
  - **System Clock:** 100 MHz → 200 MHz
  - **Ethernet:** MII 100 Mbps → RGMII 1000 Mbps (10× bandwidth)
- **Architecture:**
  - RGMII TX with DDR ODDR primitives for 4-bit data at 125 MHz (1 Gbps)
  - MMCM clock generation: 125 MHz @ 0° (TXD) + 125 MHz @ 90° (TXC)
  - Hardware CRC32 calculation for Ethernet FCS (validated with Wireshark)
  - Async FIFO CDC from 200 MHz order book to 125 MHz RGMII TX
- **Key Innovation:** Proper reset synchronization with 2-stage CDC and ASYNC_REG attributes
- **Clock Domains:**
  - 200 MHz system clock (order book, ITCH parser)
  - 125 MHz RGMII RX (from PHY)
  - 125 MHz RGMII TX (from MMCM, 0° and 90° phases)
- **BBO Payload Format (28 bytes):**
  ```
  Symbol (8B) + Bid Price (4B) + Bid Size (4B) + Ask Price (4B) + Ask Size (4B) + Spread (4B)
  ```
- **Resources:** ~33% LUT, ~11% BRAM utilization (significant headroom for expansion)
- **Latency:** Sub-microsecond BBO processing, ITCH parse → UDP TX = **312 ns** (4-point hardware-measured)
- **Status:** FUNCTIONAL - validated with real BBO packets on hardware

---

### Layer 2: Middleware (C++ Order Gateway)

**Purpose:** Parse FPGA output (UART or UDP) and distribute to multiple protocols

#### Project 9: C++ Order Gateway (UART-based)

**Core Functions:**
1. **UART Reader:** Read raw ASCII from FPGA UART port (/dev/ttyUSB0)
2. **BBO Parser:** Parse hex format to decimal prices/shares
3. **Multi-Protocol Publisher:** Fan-out to 3 protocols simultaneously

**Performance:** 10.67 μs avg parse latency, 6.32 μs P50
**Status:** Functional, performance testing in progress

#### Project 14: C++ Order Gateway (UDP/XDP + Disruptor IPC)

**Core Functions:**
1. **XDP Listener:** AF_XDP kernel bypass with eBPF program redirecting UDP packets to userspace
2. **Binary BBO Parser:** Parse big-endian fixed-point format directly (no hex conversion)
3. **Disruptor Producer:** LMAX Disruptor lock-free ring buffer for ultra-low-latency IPC
4. **Multi-Protocol Publisher:** Fan-out to 3 protocols simultaneously (TCP/MQTT/Kafka - legacy mode)

**Performance (XDP + Disruptor Mode - Validated with 78,514 samples):**
- **Average:** 0.10 μs (100 nanoseconds)
- **P50:** 0.09 μs
- **P99:** 0.29 μs
- **Std Dev:** 0.10 μs
- **End-to-End Latency:** 4.13 μs (FPGA → Market Maker FSM in Project 15)
- **Improvement over TCP Mode:** 3× faster (12.73 μs → 4.13 μs)
- **IPC Method:** LMAX Disruptor lock-free ring buffer (131 KB shared memory)

**Performance (Raw XDP Mode - Without Disruptor):**
- **Average:** 0.04 μs (40 nanoseconds)
- **P50:** 0.03 μs
- **P99:** 0.14 μs
- **267× faster than UART Project 9** (10.67 μs → 0.04 μs)

**Performance (Standard UDP Mode):**
- **Average:** 0.20 μs
- **P50:** 0.19 μs
- **P99:** 0.38 μs

**XDP Kernel Bypass Architecture:**
- **eBPF Program:** Loaded on network interface, redirects UDP port 5000 to XSK map
- **AF_XDP Socket:** Zero-copy packet reception via UMEM shared memory
- **Queue Configuration:** Combined channel 4, queue_id 3 (hardware-specific)
- **Ring Buffers:** RX ring, Fill ring, Completion ring (zero-copy operation)

**RT Optimization:**
- **RT Scheduling:** SCHED_FIFO priority 99
- **CPU Pinning:** Core 5 (isolated)
- **CPU Isolation:** GRUB parameters (isolcpus=2-5, nohz_full=2-5, rcu_nocbs=2-5)

**Status:** Complete, XDP mode validated with large dataset

**Architecture:**
```cpp
class OrderGateway {
    // UART Interface
    SerialPort uart;              // /dev/ttyUSB0 or COM3

    // Parsers
    BboParser parser;             // Hex → Decimal conversion

    // Publishers
    TcpServer tcpServer;          // localhost:9999
    MqttPublisher mqttPub;        // broker:1883
    KafkaProducer kafkaProd;      // broker:9092

    // Threading
    std::thread uartThread;       // Read UART continuously
    std::thread publishThread;    // Fan-out to protocols

    // Data pipeline
    Queue<BboUpdate> queue;       // Thread-safe queue
};
```

**Data Structures:**
```cpp
struct BboUpdate {
    std::string symbol;           // "AAPL", "TSLA", etc.
    double bid_price;             // Decimal: 150.75
    uint32_t bid_shares;          // 100
    double ask_price;             // Decimal: 151.50
    uint32_t ask_shares;          // 150
    double spread;                // Decimal: 0.75
    uint64_t timestamp_ns;        // Nanosecond timestamp
};
```

**Output Formats:**

**TCP (JSON):**
```json
{
  "symbol": "AAPL",
  "bid": {
    "price": 150.75,
    "shares": 100
  },
  "ask": {
    "price": 151.50,
    "shares": 150
  },
  "spread": 0.75,
  "timestamp": 1699824000123456789
}
```

**MQTT (Lightweight Protocol for Mobile/IoT):**
```
Topic: bbo_messages
Broker: Mosquitto (192.168.0.2:1883)
Auth: trading / trading123
Protocol: MQTT v3.1.1

Payload (JSON):
{
  "type": "bbo",
  "symbol": "AAPL",
  "timestamp": 1699824000123456789,
  "bid": {"price": 150.75, "shares": 100},
  "ask": {"price": 151.50, "shares": 150},
  "spread": {"price": 0.75, "percent": 0.497}
}

[COMPLETE] Used by: ESP32 IoT Display, Mobile App (.NET MAUI)
[COMPLETE] Benefits: Low power, unreliable network support, mobile-friendly
```

**Kafka (Reserved for Future Analytics):**
```
Topic: fpga-bbo-updates
Key: AAPL
Value: {"bid": 150.75, "ask": 151.50, "spread": 0.75, "ts": 1699824000123456789}
Partition: hash(symbol) % num_partitions

 Future Use Cases:
   - Data persistence (time-series database)
   - Historical replay for backtesting
   - Analytics pipelines (Spark, Flink)
   - Machine learning feature generation
   - Microservices integration

 Note: Gateway publishes to Kafka, but no consumers yet implemented
```

**Technologies:**
- **C++17:** Modern C++ with threading (Project 9 legacy)
- **Boost.Asio:** Async I/O for TCP/UART
- **libmosquitto:** MQTT client library
- **librdkafka:** High-performance Kafka client
- **nlohmann/json:** JSON serialization
- **spdlog:** Structured logging

**Performance:**
- **UART Read:** Non-blocking, event-driven
- **Parsing:** ~1-5 µs per BBO update
- **Publishing:** Async (non-blocking)
- **Throughput:** > 10,000 BBO updates/sec
- **Latency:** < 100 µs UART → TCP/MQTT/Kafka

---

### Layer 3: Applications

#### Project 10: Java Desktop Trading Terminal (JavaFX)

**Purpose:** Real-time BBO visualization and order management

**Architecture:**
```java
// TCP Client → JavaFX GUI
public class TradingTerminal extends Application {
    // UI Components
    @FXML private TableView<BboUpdate> bboTable;
    @FXML private LineChart<Number, Number> spreadChart;
    @FXML private TextField orderSymbol;
    @FXML private TextField orderPrice;
    @FXML private TextField orderShares;

    // Backend
    private TcpClient gateway;
    private ObservableList<BboUpdate> bboData;
    private OrderManager orderMgr;

    // Features
    - Real-time BBO table (8 symbols)
    - Spread chart (time series)
    - Order entry form
    - Risk checks (fat finger prevention)
    - Chronicle Queue persistence
    - Position tracking
}
```

**Features:**
- **Real-time BBO Display:** TableView with auto-refresh
- **Charting:** LineChart for spread over time
- **Order Entry:** GUI form with validation
- **Risk Management:**
  - Fat finger check (price > ask + 10×spread)
  - Position limits
  - Spread % warnings
- **Persistence:** Chronicle Queue for replay
- **Testing:** JUnit 5 with ITCH packet generator

**Technologies:**
- **Java 17+:** Modern Java with records
- **JavaFX:** Rich desktop UI
- **Chronicle Queue:** Low-latency persistence
- **JUnit 5:** Testing framework
- **Maven/Gradle:** Build system

---

#### Project 10: ESP32 IoT Live Ticker Display - **IMPLEMENTED**

**Purpose:** Physical trading floor display with MQTT feed

**Status:** [COMPLETE] Complete - See `10-esp32-ticker/`

**Hardware:**
- **ESP32-WROOM/Wrover:** WiFi-enabled MCU @ 240MHz dual-core
- **TFT Display (ST7735):** 128×160 color LCD, 16-bit color, SPI interface
- **Alternative:** ILI9341 (240×320) or OLED SSD1306 (128×64)

**Architecture:**
```cpp
// ESP32 + MQTT Client + TFT Display
#include <WiFi.h>
#include <PubSubClient.h>
#include <TFT_eSPI.h>

class LiveTicker {
    WiFiClient wifiClient;
    PubSubClient mqtt;
    TFT_eSPI tft;

    void mqttCallback(char* topic, byte* payload, unsigned int length) {
        // Parse JSON from MQTT
        JsonDocument doc;
        deserializeJson(doc, payload, length);

        // Extract BBO
        String symbol = doc["symbol"];
        double bid = doc["bid"]["price"];
        double ask = doc["ask"]["price"];
        double spread = doc["spread"];

        // Update display
        displayBbo(symbol, bid, ask, spread);
    }

    void displayBbo(String symbol, double bid, double ask, double spread) {
        tft.fillScreen(TFT_BLACK);
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
        tft.setTextSize(2);

        tft.setCursor(0, 0);
        tft.print("Symbol: "); tft.println(symbol);

        tft.setTextColor(TFT_GREEN, TFT_BLACK);
        tft.print("Bid:    "); tft.println(bid, 2);

        tft.setTextColor(TFT_RED, TFT_BLACK);
        tft.print("Ask:    "); tft.println(ask, 2);

        tft.setTextColor(TFT_YELLOW, TFT_BLACK);
        tft.print("Spread: "); tft.println(spread, 2);
    }
};
```

**Features:**
- **Live BBO Updates:** Subscribe to specific symbols
- **Color-Coded Display:**
  - Green: Bid prices
  - Red: Ask prices
  - Yellow: Spread
  - White: Alerts
- **Multi-Symbol Rotation:** Cycle through symbols
- **Spread Alerts:** Visual/audio alerts on wide spreads
- **WiFi OTA Updates:** Remote firmware updates

**Technologies:**
- **ESP32 Arduino Core:** Platform
- **TFT_eSPI:** Display driver library
- **PubSubClient:** MQTT client
- **ArduinoJson:** JSON parsing
- **WiFiManager:** WiFi configuration

**Display Modes:**

**Mode 1: Single Symbol**
```
┌────────────────────┐
│ AAPL               │
│                    │
│ Bid:    150.75     │
│ Ask:    151.50     │
│ Spread:   0.75     │
│                    │
│ Updated: 12:34:56  │
└────────────────────┘
```

**Mode 2: Multi-Symbol Scroll**
```
┌────────────────────┐
│ AAPL   150.75/151.5│
│ TSLA   225.30/226.1│
│ SPY    445.20/445.3│
│ QQQ    380.10/380.2│
│ ↓ Updating...      │
└────────────────────┘
```

**Mode 3: Spread Alert**
```
┌────────────────────┐
│   WIDE SPREAD      │
│                    │
│ GOOGL              │
│ Spread: $104.50    │
│ (Illiquid!)        │
└────────────────────┘
```

---

#### Project 11: Mobile App (Android/iOS) - **IMPLEMENTED**

**Purpose:** Cross-platform mobile BBO terminal for real-time market data

**Status:** [COMPLETE] Complete - See `11-maui-mobile-app/`

**Architecture (.NET MAUI with MQTT):**
```csharp
// MVVM Pattern with CommunityToolkit.Mvvm
public partial class BboViewModel : ObservableObject
{
    private MqttConsumerService _mqttService;

    [ObservableProperty]
    private string _brokerUrl = "192.168.0.2";

    [ObservableProperty]
    private int _port = 1883;

    [ObservableProperty]
    private string _topic = "bbo_messages";

    public ObservableCollection<BboUpdate> BboUpdates { get; } = new();

    [RelayCommand]
    private void Connect()
    {
        _mqttService = new MqttConsumerService(BrokerUrl, Port, Topic, Username, Password);
        _mqttService.BboReceived += OnBboReceived;
        _mqttService.ConnectionStateChanged += OnConnectionStateChanged;
        _mqttService.Start();
    }

    private void OnBboReceived(object? sender, BboUpdate bbo)
    {
        var existing = BboUpdates.FirstOrDefault(b => b.Symbol == bbo.Symbol);
        if (existing != null)
            BboUpdates[BboUpdates.IndexOf(existing)] = bbo;
        else
            BboUpdates.Add(bbo);
    }
}
```

**MQTT Consumer Service:**
```csharp
public class MqttConsumerService : IDisposable
{
    private IMqttClient _mqttClient;

    public event EventHandler<BboUpdate> BboReceived;
    public event EventHandler<string> ErrorOccurred;
    public event EventHandler<bool> ConnectionStateChanged;

    public async void Start()
    {
        var factory = new MqttClientFactory();
        _mqttClient = factory.CreateMqttClient();

        var options = new MqttClientOptionsBuilder()
            .WithProtocolVersion(MqttProtocolVersion.V311)  // v3.1.1 for compatibility
            .WithTcpServer(_brokerUrl, _port)
            .WithClientId($"maui-mobile-app-{Guid.NewGuid()}")
            .WithCredentials(_username, _password)
            .WithCleanSession()
            .Build();

        await _mqttClient.ConnectAsync(options);
        await _mqttClient.SubscribeAsync(_topic);
    }
}
```

**Features:**
- **Real-time BBO Display:** Live updates for all 8 symbols via MQTT
- **Symbol Selector:** Tap any symbol to see detailed view
- **Color-coded UI:**
  - Bid prices (green)
  - Ask prices (red)
  - Spread (orange)
- **Connection Management:** Connect/Disconnect with status indicator
- **Cross-Platform:** Android, iOS, Windows support
- **MVVM Architecture:** Clean separation with data binding
- **ESP32-inspired Design:** Simple, clean UI matching IoT display

**Technologies:**
- **.NET 10 / .NET MAUI:** Cross-platform mobile framework
- **MQTTnet 5.x:** Pure .NET MQTT client (Android-compatible!)
- **CommunityToolkit.Mvvm 8.4:** MVVM source generators
- **System.Text.Json 10.0:** JSON deserialization
- **MQTT v3.1.1:** Protocol version for compatibility

**Why MQTT (not Kafka)?**
[COMPLETE] **Perfect for Mobile:**
- Lightweight protocol (low battery usage)
- Handles unreliable networks (WiFi/cellular switching)
- Low latency (< 100ms)
- Mobile-optimized QoS levels
- No native library dependencies

[MISSING] **Kafka Not Ideal for Mobile:**
- Heavy protocol overhead
- Requires persistent TCP connections
- Native library dependencies (Android compatibility issues)
- Designed for backend services, not mobile clients

---

#### Project 15: Market Maker FSM - Disruptor Consumer + Automated Trading - **IMPLEMENTED**

**Purpose:** Automated market making strategy with ultra-low-latency Disruptor IPC and position management

**Status:** [COMPLETE] Complete - See `15-cpp-market-maker/`

**Architecture:**
```cpp
// Disruptor Consumer → Market Maker FSM → Quote Generation
class MarketMakerFSM {
    // Disruptor Connection to Project 14
    DisruptorClient disruptor;      // POSIX shared memory /dev/shm/bbo_ring_gateway

    // Core Components
    MarketMakerFSM fsm;             // State machine
    PositionTracker positions;      // Position & PnL tracking

    // FSM States
    enum State {
        IDLE,           // Waiting for BBO
        CALCULATE,      // Computing fair value
        QUOTE,          // Generating quotes with skew
        RISK_CHECK,     // Position/notional limits
        ORDER_GEN,      // Sending orders
        WAIT_FILL       // Waiting for fills
    };

    // Configuration
    double min_spread_bps;          // Minimum spread (5 bps)
    double edge_bps;                // Edge from fair value (2 bps)
    int max_position;               // Max shares per symbol (500)
    double position_skew_bps;       // Inventory adjustment (1 bps)
    int quote_size;                 // Shares per side (100)
    double max_notional;            // Max dollar exposure ($100k)
};
```

**Features:**
- **Fair Value Calculation:** Weighted mid-price using bid/ask sizes
- **Quote Generation:** Two-sided markets with position-based inventory skew
- **Position Management:** Real-time PnL tracking (realized + unrealized)
- **Risk Controls:** Pre-trade position and notional limit checks
- **FSM-based Logic:** Deterministic state transitions for quote generation

**Performance (Disruptor Mode - Validated with 78,514 samples):**
- **Average:** 4.13 μs (end-to-end: UDP packet arrival → Market maker processing complete)
- **P50:** 4.37 μs
- **P99:** 5.82 μs
- **Std Dev:** 1.39 μs
- **Improvement over TCP Mode:** 3× faster (12.73 μs → 4.13 μs)

**Performance (Legacy TCP Mode - 78,606 samples):**
- **Average:** 12.73 μs (TCP read + JSON parse + FSM processing)
- **P50:** 11.76 μs
- **P99:** 21.53 μs

**End-to-End Latency Chain (Disruptor Mode):**
```
FPGA Order Book (Project 13)
    ↓ UDP (binary BBO)
Project 14 XDP + Disruptor: 0.10 μs
    ↓ POSIX Shared Memory (131 KB ring buffer, lock-free IPC ~0.50 μs)
Project 15 Market Maker FSM: ~3.23 μs business logic
    ↓
Total: 4.13 μs (FPGA → Trading Decision)

Latency Breakdown:
├─ XDP packet processing: 0.10 μs
├─ Disruptor IPC: ~0.50 μs
└─ Market maker FSM: ~3.23 μs
```

**Trading Algorithm:**
```
Fair Value = (bid_price + ask_price) / 2 + size-weighted adjustment
Skew = (position / max_position) × position_skew_bps × fair_value
Bid = fair_value - edge + skew
Ask = fair_value + edge + skew
```

**Risk Management:**
- Position limits enforced per symbol
- Notional exposure limits (max dollar risk)
- Position skew discourages inventory buildup (long → skew DOWN to sell, short → skew UP to buy)
- Pre-trade risk checks before quote generation

**Technologies:**
- **C++20:** Modern C++ with concepts
- **Boost.Asio:** TCP client for Project 14 connection
- **nlohmann/json:** JSON BBO parsing
- **spdlog:** High-performance logging
- **RT Scheduling:** SCHED_FIFO priority 50, CPU cores 2-3

**Dependencies:**
- Requires Project 14 running (TCP server on localhost:9999)
- Project 14 requires Project 13 (FPGA UDP transmitter)
- Optionally integrates with Project 16 (Order Execution Engine via Disruptor)

**Project 16 Integration:**
When `enable_order_execution=true` in config.json:
- **OrderProducer class:** Manages bidirectional Disruptor communication
- **Order Ring Buffer:** `/dev/shm/order_ring_mm` (sends orders to Project 16)
- **Fill Ring Buffer:** `/dev/shm/fill_ring_oe` (receives fills from Project 16)
- **processFills() method:** Updates PositionTracker with executed trades

---

#### Project 16: Order Execution Engine - Simulated Exchange - **IMPLEMENTED**

**Purpose:** Complete order execution loop with FIX 4.2 protocol and price-time priority matching

**Status:** [COMPLETE] Complete - See `16-cpp-order-execution/`

**Architecture:**
```cpp
// Disruptor-based Order Execution Engine
class OrderExecutionEngine {
    // Input: Order Ring Buffer Consumer
    OrderRingBuffer order_consumer;        // From Project 15

    // Core Components
    MatchingEngine matcher;                // Price-time priority
    FIXEncoder fix_encoder;                // FIX 4.2 messages
    FIXDecoder fix_decoder;                // Parse FIX orders

    // Output: Fill Ring Buffer Producer
    FillRingBuffer fill_producer;          // To Project 15

    // Ring Buffer Paths
    const char* order_ring_path = "/dev/shm/order_ring_mm";
    const char* fill_ring_path = "/dev/shm/fill_ring_oe";

    // Configuration
    int64_t ring_size = 1024;              // Lock-free ring buffer size
    bool immediate_fill = true;            // Simulated exchange mode
};
```

**Data Flow:**
```
Project 15 Market Maker
    ↓ OrderProducer writes to order_ring_mm
Order Ring Buffer (shared memory, lock-free)
    ↓ OrderExecutionEngine reads
Matching Engine
    ├─ Order validation
    ├─ Price-time priority matching
    └─ Simulated exchange (immediate fills)
    ↓ FIX 4.2 ExecutionReport
Fill Ring Buffer (shared memory, lock-free)
    ↓ Market Maker processFills() reads
Project 15 PositionTracker
```

**FIX 4.2 Protocol Implementation:**

**NewOrderSingle (MsgType=D):**
```
8=FIX.4.2|9=XXX|35=D|49=MM|56=OE|34=1|52=YYYYMMDD-HH:MM:SS|
11=OrderID|21=1|55=AAPL|54=1|60=YYYYMMDD-HH:MM:SS|38=100|40=2|44=150.00|10=XXX|
```

**ExecutionReport (MsgType=8):**
```
8=FIX.4.2|9=XXX|35=8|49=OE|56=MM|34=1|52=YYYYMMDD-HH:MM:SS|
11=OrderID|17=ExecID|20=0|150=2|39=2|55=AAPL|54=1|38=100|44=150.00|
32=100|31=150.00|151=0|14=100|6=150.00|10=XXX|
```

**Fields:**
- **11:** ClOrdID (Order ID from Market Maker)
- **17:** ExecID (Execution ID generated by matching engine)
- **150:** ExecType (2 = Trade/Fill)
- **39:** OrdStatus (2 = Filled)
- **32:** LastQty (Fill quantity)
- **31:** LastPx (Fill price)
- **14:** CumQty (Cumulative quantity filled)
- **6:** AvgPx (Average fill price)

**Performance:**
- **Order Processing:** ~1 μs (Disruptor read → match → FIX encode)
- **Fill Notification:** <1 μs (FIX encode → Disruptor write)
- **Round-Trip Latency:** ~2 μs (Project 15 → Project 16 → Project 15)

**Ring Buffer Configuration:**
- **Order Ring:** Single writer (Project 15), single reader (Project 16)
- **Fill Ring:** Single writer (Project 16), single reader (Project 15)
- **Slots:** 1024 per ring (configurable)
- **Memory:** Shared memory (`/dev/shm`) for zero-copy IPC
- **Synchronization:** Lock-free with atomic sequence cursors

**Matching Engine:**
```cpp
// Simulated Exchange - Immediate Fills
class MatchingEngine {
    bool match_order(const OrderRequest& order, FillNotification& fill) {
        // Simple immediate fill logic (for testing)
        fill.order_id = order.order_id;
        fill.symbol = order.symbol;
        fill.side = order.side;
        fill.fill_qty = order.quantity;        // 100% fill
        fill.avg_price = order.price;          // Fill at order price
        fill.exec_type = '2';                  // Trade (filled)
        fill.ord_status = '2';                 // Filled
        return true;
    }
};
```

**Technologies:**
- **C++20:** Modern C++ with concepts
- **LMAX Disruptor:** Lock-free ring buffers (order + fill)
- **FIX 4.2 Protocol:** Industry-standard order execution protocol
- **Shared Memory IPC:** Zero-copy communication via `/dev/shm`
- **spdlog:** Structured logging for order/fill events

**Dependencies:**
- Works with Project 15 when `enable_order_execution=true`
- Requires common headers: `order_data.h`, `OrderRingBuffer.h`, `FillRingBuffer.h`

**Testing:**
- Full order execution loop validated
- Position tracking verified with fill processing
- FIX message encoding/decoding tested
- Disruptor latency benchmarked at ~1-2 μs round-trip

---

## Data Flow

### End-to-End Message Flow

```
1. Market Data Packet (UDP/IP)
   ↓
2. FPGA MII Interface (10 ns)
   ↓ 25 MHz clock domain
3. FPGA MAC/IP/UDP Parser (< 2 µs)
   ↓
4. FPGA ITCH Parser (deterministic)
   ↓ Symbol filter (8 symbols)
5. Multi-Symbol Order Book
   ├─ Symbol Demux (route to correct book)
   ├─ Order Storage (BRAM - 1024 orders)
   ├─ Price Level Table (BRAM - 256 levels)
   └─ BBO Tracker (scan all levels)
   ↓ Round-robin arbiter (40 µs/symbol)
6. UART Output @ 115200 baud
   [BBO:AAPL]Bid:0x... | Ask:0x... | Spr:0x...
   ↓
7. C++ Gateway UART Reader
   ↓ Parse hex → decimal
8. C++ Multi-Protocol Publisher
   ├─ TCP: JSON to localhost:9999
   ├─ MQTT: Publish to broker
   └─ Kafka: Produce to topic
   ↓ ↓ ↓
9. Applications
   ├─ Java Desktop: Real-time GUI
   ├─ ESP32: Physical display
   └─ Mobile: Push alerts
```

### Latency Budget

| Stage | Latency | Cumulative |
|-------|---------|-----------|
| Ethernet packet arrival | 0 | 0 |
| MII → UDP parsed | 2 µs | 2 µs |
| ITCH parsing | 1 µs | 3 µs |
| Order book update | 0.17 µs | 3.17 µs |
| BBO scan (256 levels) | 30 µs | 33.17 µs |
| UART transmission (ASCII) | 3 ms | 3.033 ms |
| C++ Gateway parsing | 5 µs | 3.038 ms |
| TCP/MQTT/Kafka publish | 50 µs | 3.088 ms |
| **Total: Wire → App** | | **~3.1 ms** |

**Breakdown:**
- **FPGA (hardware):** 33 µs (1%)
- **UART (serial):** 3 ms (97%)
- **Software (C++):** 55 µs (2%)

**UART is the bottleneck!** Future enhancement: Use Ethernet output instead of UART.

---

## Technology Stack

### Hardware
- **FPGA:** Xilinx Artix-7 XC7A100T-1CSG324C
- **Board:** Digilent Arty A7-100T
- **PHY:** TI DP83848J 10/100 Ethernet (MII)
- **Tools:** AMD Vivado Design Suite 2025.1
- **Language:** VHDL

### Middleware
- **Language:** C++17/20
- **Build:** CMake 3.20+
- **Libraries:**
  - Boost.Asio (async I/O)
  - libmosquitto (MQTT)
  - librdkafka (Kafka)
  - nlohmann/json (JSON)
  - spdlog (logging)

### Applications

**Java Desktop:**
- Java 17+
- JavaFX 17+
- Chronicle Queue
- JUnit 5

**ESP32 IoT:**
- ESP32 Arduino Core
- TFT_eSPI
- PubSubClient (MQTT)
- ArduinoJson

**Mobile:**
- Kotlin
- Jetpack Compose
- Kafka Android Client
- Room Database

### Infrastructure
- **MQTT Broker:** Eclipse Mosquitto
- **Kafka:** Apache Kafka 3.x
- **Container:** Docker/Docker Compose
- **Monitoring:** Grafana + Prometheus

---

## Protocol Specifications

### FPGA UART Output Format

**Format:** ASCII text, newline-terminated
**Baud Rate:** 115200
**Example:**
```
[BBO:AAPL    ]Bid:0x002C46CC (0x0000001E) | Ask:0x002CE55C (0x0000001E) | Spr:0x00001F90\n
```

**Fields:**
- `Symbol`: 8 characters, space-padded (e.g., "AAPL    ")
- `Bid Price`: 32-bit hex (e.g., 0x002C46CC = 2,901,708 = $290.1708)
- `Bid Shares`: 32-bit hex (e.g., 0x0000001E = 30 shares)
- `Ask Price`: 32-bit hex
- `Ask Shares`: 32-bit hex
- `Spread`: 32-bit hex (ask - bid)

**Price Encoding:** Fixed-point with 4 decimal places
**Example:** 0x002C46CC = 2,901,708 → $290.1708

---

### TCP Protocol (JSON)

**Endpoint:** `tcp://localhost:9999`
**Protocol:** Line-delimited JSON
**Encoding:** UTF-8

**Message Format:**
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

**Client Example (Java):**
```java
Socket socket = new Socket("localhost", 9999);
BufferedReader in = new BufferedReader(
    new InputStreamReader(socket.getInputStream())
);

String line;
while ((line = in.readLine()) != null) {
    JsonObject json = JsonParser.parseString(line).getAsJsonObject();
    String symbol = json.get("symbol").getAsString();
    double bidPrice = json.getAsJsonObject("bid").get("price").getAsDouble();
    // ...
}
```

---

### MQTT Protocol

**Broker:** `mqtt://broker:1883`
**QoS:** 1 (at least once)
**Retain:** true (last value retained)

**Topic Structure:**
```
fpga/
├── bbo/
│   ├── AAPL          (individual symbol updates)
│   ├── TSLA
│   ├── SPY
│   ├── QQQ
│   ├── GOOGL
│   ├── MSFT
│   ├── AMZN
│   ├── NVDA
│   └── all           (array of all symbols)
├── spread/
│   ├── high          (symbols with spread > 5%)
│   └── alert         (threshold alerts)
└── stats/
    ├── update_rate   (BBO updates/sec)
    └── latency       (avg latency)
```

**Payload Format (JSON):**
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

**Subscribe Example (ESP32):**
```cpp
mqtt.subscribe("bbo_messages");
```

---

### Kafka Protocol

**Topic:** `bbo_messages`
**Partitions:** 8 (one per symbol, keyed by symbol)
**Replication:** 3 (for production)
**Retention:** 7 days

**Message Format:**
- **Key:** Symbol (String) - used for partitioning
- **Value:** JSON (String)
- **Timestamp:** Event time (from BBO)

**Value Schema:**
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

**Partitioning Strategy:**
```
partition = hash(symbol) % num_partitions
```
This ensures all updates for a symbol go to the same partition (ordering guaranteed).

**Consumer Group:** `mobile-app`, `analytics`, `archive`

---

## Application Ecosystem

### Use Cases by Application

| Application | Use Case | Protocol | Latency Req |
|-------------|----------|----------|-------------|
| Java Desktop | Live trading terminal | TCP | < 10 ms |
| ESP32 Display | Trading floor ticker | MQTT | < 100 ms |
| Mobile App (.NET MAUI) | Real-time BBO monitoring | MQTT | < 100 ms |
| Analytics (Future) | Historical analysis | Kafka | N/A (batch) |
| Archive (Future) | Compliance/audit | Kafka | N/A (persist) |

### Deployment Scenarios

#### Scenario 1: Development (Single Machine)
```
┌─────────────────────────────────┐
│  Developer Laptop               │
│  ┌───────────┐  ┌─────────────┐ │
│  │ FPGA      │  │ C++ Gateway │ │
│  │ (USB)     │→ │ (localhost) │ │
│  └───────────┘  └──────┬──────┘ │
│                        │         │
│  ┌─────────────────────┼───────┐ │
│  │ Mosquitto   Kafka   │  Java │ │
│  │ (Docker)    (Docker)│  IDE  │ │
│  └─────────────────────┴───────┘ │
└─────────────────────────────────┘
```

#### Scenario 2: Lab/Testing (Distributed) - **CURRENTLY DEPLOYED**
```
┌──────────────┐      ┌──────────────┐      ┌──────────────────────┐
│  FPGA Box    │      │  Gateway     │      │   Infrastructure     │
│  (Arty A7)   │ UART │  (Windows)   │ LAN  │                      │
│              │─────→│  C++ App     │─────→│  Raspberry Pi:       │
│  Ethernet    │      │  localhost   │      │  - MQTT Broker       │
│  UDP ITCH    │      │              │      │    (Mosquitto)       │
└──────────────┘      └──────────────┘      │                      │
                                            │  Kubernetes Node:    │
                                            │  - Kafka Cluster     │
                                            └──────────┬───────────┘
                                                       │
                                               ┌───────┴───────┐
                                               │               │
                                         ┌─────┴─────┐   ┌─────┴─────┐
                                         │Java Desktop│   │   ESP32   │
                                         │ (JavaFX)  │   │  Display  │
                                         │Live Charts│   │  (MQTT)   │
                                         │  (TCP)    │   │           │
                                         └───────────┘   └───────────┘
```

**Actual Deployment:**
- **FPGA:** Arty A7-100T running order book @ 100 MHz
- **Gateway:** C++ application on Windows PC, multi-protocol publisher
- **MQTT Broker:** Mosquitto on Raspberry Pi server (IoT tier)
- **Kafka:** Running on Kubernetes node (enterprise tier)
- **Java App:** JavaFX desktop application with live BBO charts (TCP JSON)

#### Scenario 3: Production (High Availability)
```
┌────────────────────────────────────────────────────────────┐
│                      Cloud/Colo                             │
│  ┌─────────────┐      ┌─────────────┐                      │
│  │  Gateway 1  │      │  Gateway 2  │  (Active-Active)     │
│  │  (Primary)  │      │  (Backup)   │                      │
│  └──────┬──────┘      └──────┬──────┘                      │
│         │                    │                              │
│         └────────┬───────────┘                              │
│                  ↓                                          │
│  ┌───────────────────────────────────────────────────────┐ │
│  │         Kafka Cluster (3 brokers, RF=3)               │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐               │ │
│  │  │Broker 1 │  │Broker 2 │  │Broker 3 │               │ │
│  │  └─────────┘  └─────────┘  └─────────┘               │ │
│  └───────────────────┬───────────────────────────────────┘ │
│                      │                                      │
│  ┌───────────────────┼───────────────────────────────────┐ │
│  │        Consumer Groups (Auto-scaling)                 │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐      │ │
│  │  │ Analytics  │  │  Archive   │  │   Mobile   │      │ │
│  │  │ (Flink)    │  │ (S3/HDFS)  │  │  Notifier  │      │ │
│  │  └────────────┘  └────────────┘  └────────────┘      │ │
│  └────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

---

## Performance Characteristics

### Throughput

| Component | Throughput | Bottleneck |
|-----------|----------|------------|
| FPGA Order Book | 8.3M orders/sec | 120 ns/order × 100 MHz |
| FPGA BBO Updates | 33k BBO/sec | 30 µs/BBO |
| UDP Output (Project 13) | ~400k pkts/sec | 256-byte packets @ 100 Mbps |
| UART Output (Project 09) | 11.5k chars/sec | 115200 baud |
| C++ Gateway (UDP, Project 14) | 400k BBO/sec | Parsing CPU (optimized) |
| C++ Gateway (UART, Project 09) | 100 BBO/sec | UART @ 115200 baud |
| TCP Clients | 50k msg/sec | Network I/O |
| MQTT Broker | 100k msg/sec | Mosquitto |
| Kafka Cluster | 1M msg/sec | Broker cluster |

**Project 09 (UART) Bottleneck:** UART @ 115200 baud limits BBO output rate

**UART Calculation:**
```
Average BBO message: ~120 characters
115200 baud = 11,520 bytes/sec
11,520 / 120 = 96 BBO messages/sec

With 8 symbols: 96 / 8 = 12 BBO/sec per symbol
```

**Project 14 (UDP) Improvement:** UDP eliminates UART bottleneck, gateway handles ~400 msg/sec sustained

### Latency

**Project 09 (UART-based Gateway):**
| Path | P50 | P99 | P99.9 |
|------|-----|-----|-------|
| FPGA: Packet → BBO | 33 µs | 35 µs | 40 µs |
| UART: FPGA → Gateway | 3 ms | 3.1 ms | 3.2 ms |
| Gateway: Parse → Publish | 6.32 µs | ~20 µs | ~50 µs |
| TCP: Gateway → Client | 100 µs | 500 µs | 1 ms |
| MQTT: Publish → Deliver | 5 ms | 20 ms | 50 ms |
| Kafka: Produce → Consume | 10 ms | 50 ms | 100 ms |
| **E2E: Wire → Desktop** | **3.2 ms** | **3.7 ms** | **4.5 ms** |

**Project 14 (UDP-based Gateway - High-Performance, Validated):**
| Path | P50 | P95 | P99 |
|------|-----|-----|-----|
| FPGA: Packet → BBO | 33 µs | 35 µs | 40 µs |
| UDP: FPGA → Gateway | 0.19 µs | 0.32 µs | 0.38 µs |
| Gateway: Parse → Publish | 0.19 µs | 0.32 µs | 0.38 µs |
| TCP: Gateway → Client | 100 µs | 500 µs | 1 ms |
| MQTT: Publish → Deliver | 5 ms | 20 ms | 50 ms |
| Kafka: Produce → Consume | 10 ms | 50 ms | 100 ms |
| **E2E: Wire → Desktop** | **~150 µs** | **~550 µs** | **~1.1 ms** |

**Validated Performance (10,000 samples @ 400 Hz):**
- **Average:** 0.20 µs, **Std Dev:** 0.06 µs (highly consistent)
- **Test conditions:** 25-second sustained load, AMD Ryzen AI 9 365
- **Configuration:** taskset -c 2-5 + SCHED_FIFO RT scheduling

**Performance Improvement (Project 14 vs Project 09):**
- Gateway parsing: **53× faster** (10.67 µs → 0.20 µs avg)
- P99 latency: **134× faster** (50.92 µs → 0.38 µs)
- E2E latency: ~21× faster (3.2 ms → ~150 µs)
- Binary protocol + RT optimization: Eliminates conversion overhead and scheduling jitter

### Resource Utilization

**FPGA (Artix-7 100T):**
| Resource | Used | Available | % |
|----------|------|-----------|---|
| Slice LUTs | 30,000 | 63,400 | 47% |
| Slice Registers | 16,000 | 126,800 | 13% |
| RAMB36 | 32 | 135 | 24% |
| DSP48E | 0 | 240 | 0% |

**BRAM Breakdown (FPGA Projects 6-8):**
- Order storage (1024 orders): 4 BRAM36 blocks (130 bits × 1024 entries)
- Price level table (256 levels): 1 BRAM36 block (82 bits × 256 entries)
- Async FIFO (CDC - ITCH parser): 1-2 BRAM36 blocks (gray code synchronizer)
- UDP transmitter buffers: 1-2 BRAM36 blocks (packet assembly)

**Note:** Projects 14-15 use software-based Disruptor pattern (POSIX shared memory), not FPGA BRAM

**C++ Gateway (Project 09 - UART):**
| Resource | Usage |
|----------|-------|
| CPU | 5-10% (single core) |
| Memory | 50 MB |
| Threads | 4 (UART, Publish, TCP Server, Logger) |
| Network | < 1 Mbps |

**C++ Gateway (Project 14 - UDP with RT optimization):**
| Resource | Usage |
|----------|-------|
| CPU | 2-5% per core (4 isolated cores, CFS) |
| Memory | 50 MB |
| Threads | 4 (UDP, Publish, TCP Server, Logger) |
| Network | ~10 Mbps (256-byte packets @ 400 msg/sec) |
| RT Priority | SCHED_FIFO (99) when --enable-rt flag used |
| CPU Affinity | Cores 2-5 (isolated via GRUB: isolcpus, nohz_full, rcu_nocbs) |

---

## Completed Performance Enhancements

### [COMPLETE] Phase 1: UDP Output (COMPLETED - Projects 13 & 14)

**Replace UART with Ethernet Output:**
- **Previous bottleneck:** 115200 baud UART (Project 09)
- **Solution:** Added UDP output module to FPGA (Project 13) + UDP gateway (Project 14)
- **Achieved improvement:** 3 ms → ~150 µs (21× faster E2E)
- **Architecture:**
  ```
  FPGA BBO Arbiter → UDP Packet Builder → MAC TX (Project 13)
                      ↓ 192.168.0.93:5000 (256-byte binary packets)
  C++ Gateway UDP Receiver @ 100 Mbps (Project 14)
  ```

**Achieved Benefits:**
- [COMPLETE] 21× E2E latency reduction (3.2 ms → 150 µs)
- [COMPLETE] 400× throughput increase (~96 msg/sec → ~400 msg/sec sustained)
- [COMPLETE] Simpler deployment (no USB cables)
- [COMPLETE] Binary protocol (no hex conversion overhead)

**RT Optimization Learnings:**
- CFS scheduler with multi-core isolation outperforms SCHED_FIFO for ~400 msg/sec workload
- CPU isolation (GRUB parameters) critical for consistent sub-microsecond performance
- Optimal: taskset -c 2-5 (0.51 µs avg, 0.16 µs P50)

---

### Phase 2: Scalability

**Increase Symbol Count:**
- Current: 8 symbols
- Target: 64 symbols
- BRAM usage: 24% → 76% (within capacity)

**Add More Order Book Depth:**
- Current: 256 price levels
- Target: 1024 price levels (full L2 depth)

**Kafka Stream Processing:**
- Apache Flink for real-time analytics
- Windowed aggregations (VWAP, TWAP)
- Pattern detection (order flow imbalance)

---

### Phase 3: Advanced Features

**Order Matching Engine:**
- Price-time priority matching
- Trade execution in FPGA
- Fill reporting

**Market Making Logic:**
- Automated quote generation
- Spread-based pricing
- Inventory management

**Risk Management:**
- Pre-trade risk checks in FPGA
- Position limits
- Credit checks
- Fat finger prevention

---

### Phase 4: Cloud Integration

**AWS/GCP Deployment:**
- FPGA on AWS F1 instances
- Kafka on AWS MSK / GCP Pub/Sub
- Auto-scaling consumers
- Global distribution

**Machine Learning:**
- Price prediction models
- Anomaly detection (flash crashes)
- Sentiment analysis (news feeds)

**Blockchain Integration:**
- Crypto exchange order books
- DeFi liquidity tracking
- On-chain settlement

---

---

## PCIe Pipeline Architecture (Projects 21-29)

**Architecture Overview:** Production trading system with FPGA PCIe bridge, pipeline-parallel GPU inference, and dedicated control panel.

### Pipeline Parallelism Design

The PCIe architecture implements pipeline parallelism to maximize throughput:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                    FPGA Layer (Project 23 - AX7203 Artix-7)                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Ethernet RX → UDP/IP → ITCH 5.0 → Order Book → BBO Tracker → PCIe C2H DMA          │
│   (RGMII)      200 MHz   200 MHz     200 MHz       200 MHz      250 MHz              │
│                                                                                      │
│  Output: 56-byte BBO packets (Magic Header + Symbol + Bid/Ask/Spread + Timestamps)  │
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ PCIe Gen2 x4 (/dev/xdma0_c2h_0)
                                          │ ~1-2 μs DMA latency
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│           Project 24: Order Gateway (Low-Latency PCIe Passthrough)                   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  PCIeListener → BBO Validation → Disruptor Producer                                 │
│     1-2 μs          ~1 μs              ~0.5 μs                                       │
│                                                                                      │
│  Design: XGBoost inference moved to P25 for pipeline parallelism                    │
│  Benefit: Sub-5 μs passthrough allows P24 to process next BBO while P25 infers      │
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Disruptor Shared Memory
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│           Project 25: Market Maker (XGBoost GPU + Strategy)                          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Disruptor Consumer → XGBoostPredictor (GPU) → MarketMakerFSM → Order Producer      │
│       ~0.5 μs            10-100 μs               ~5 μs             ~0.5 μs           │
│                                                                                      │
│  XGBoost Model: itch_predictor.ubj (36MB, 84% accuracy)                             │
│  GPU: RTX 5090 CUDA backend (~10-100 μs inference)                                  │
│  ML-enhanced fair value: base_fair_value + prediction * spread * weight             │
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Order Ring
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│           Project 26: Order Execution (Simulated Fills)                              │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Order Consumer → Simulated Matching → Fill Producer                                │
│       ~0.5 μs         50 μs (config)        ~0.5 μs                                 │
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Fill Ring → P25
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│           Project 28: System Orchestrator                                            │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  Manages lifecycle: P24 → P25 → P26 (startup order, health checks, metrics)         │
│  Prometheus metrics on port 9094                                                    │
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Status/Control
                                          ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│           Project 29: TradingOS Control Panel (SDL2 DRM/KMS)                         │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  SDL2 DRM/KMS → UIManager → ProcessManager → MetricsReader                          │
│  5120x1440 ultrawide fullscreen on dedicated display (no X11/Wayland)               │
│                                                                                      │
│  Features: Process start/stop, real-time CPU/GPU/Memory metrics, log viewer         │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Project 24: Order Gateway (Low-Latency PCIe Passthrough)

**Purpose:** Ultra-low-latency PCIe passthrough from FPGA to downstream processing

**Architecture:**
- PCIeListenerV2 reads 56-byte BBO packets from /dev/xdma0_c2h_0
- Magic header synchronization (0xBB0BB048) for reliable packet boundaries
- BBO validation filters corrupted data
- Disruptor Producer publishes to shared memory

**January 2026 Update:**
- Updated to 56-byte packet format with magic header
- Host reads magic header as 0x48B00BBB (little-endian)
- Packet sync via magic header scanning for reliable DMA streaming

**Design Decision:** XGBoost inference relocated to P25 for pipeline parallelism
- P24 latency reduced from ~300μs to sub-5μs
- P24 processes next BBO while P25 runs inference on previous BBO

### Project 25: Market Maker (XGBoost GPU + Strategy)

**Purpose:** Consumes BBO from P24, runs XGBoost GPU inference, generates orders

**XGBoost Integration:**
```cpp
// ML-enhanced fair value calculation
double MarketMakerFSM::applyMLPrediction(double base_fair_value, const BBO& bbo) {
    std::vector<float> features = {
        static_cast<float>(bbo.bid_price),
        static_cast<float>(bbo.ask_price),
        static_cast<float>(bbo.bid_shares),
        static_cast<float>(bbo.ask_shares),
        static_cast<float>(bbo.spread),
        static_cast<float>((bbo.bid_price + bbo.ask_price) / 2.0)
    };

    float prediction = predictor_->predict(features);
    double spread = bbo.ask_price - bbo.bid_price;
    double adjustment = prediction * spread * config_.xgboost.prediction_weight;

    return base_fair_value + adjustment;
}
```

**Configuration:**
```json
{
    "xgboost": {
        "enabled": true,
        "model_path": "/opt/trading/model/itch_predictor.ubj",
        "use_gpu": true,
        "gpu_device_id": 0,
        "prediction_weight": 0.5
    }
}
```

### Project 29: TradingOS Control Panel

**Purpose:** Graphical control panel for TradingOS running directly on framebuffer

**Architecture:**
- SDL2 with DRM/KMS backend (no X11/Wayland required)
- UIManager handles window, rendering, events
- ProcessManager controls P24/P25/P26 lifecycle
- MetricsReader gathers CPU/GPU/Memory utilization

**Features:**
- Process control (start/stop/restart) for each trading process
- Real-time metrics display (CPU, GPU, Memory progress bars)
- Per-process status with BBO/s, latency, running state
- System log viewer with color-coded log levels
- Dedicated display for trading system monitoring

**Display Configuration:**
- Resolution: 5120x1440 ultrawide fullscreen
- DRM/KMS for minimal latency
- No desktop environment required

**Startup Script:**
```bash
#!/bin/bash
export SDL_VIDEODRIVER=kmsdrm
export SDL_RENDER_DRIVER=software
exec /opt/trading/bin/trading_ui "$@"
```

### End-to-End Latency (Pipeline Parallelism)

| Stage | Latency |
|-------|---------|
| PCIe read | ~1-2 μs |
| P24 passthrough | ~3 μs |
| Disruptor transfer | ~0.5 μs |
| XGBoost GPU inference (P25) | ~10-100 μs |
| Market maker FSM | ~5 μs |
| Order execution | ~50 μs (simulated) |
| **Total** | **~70-160 μs** |

**Pipeline Benefit:** P24 processes next BBO while P25 runs inference on current BBO.
Effective throughput improved by decoupling PCIe read from GPU inference.

---

## Conclusion

This system demonstrates a **complete end-to-end low-latency trading infrastructure** combining:

1. **Hardware acceleration** (FPGA) for deterministic microsecond latency
2. **Modern middleware** (C++) for multi-protocol distribution
3. **Diverse applications** (Desktop, IoT, Mobile) for real-world use cases

**Key Innovations:**
- Multi-symbol hardware order book (8 parallel books)
- Multi-protocol gateway (TCP + MQTT + Kafka)
- Physical IoT display (ESP32 + TFT)
- Mobile real-time alerts (Kafka stream)

**Real-World Applicability:**
- **Trading Firms:** Market data distribution
- **Exchanges:** Order book engines
- **Fintech:** Real-time pricing
- **IoT:** Edge computing + cloud

**Portfolio Value:**
- Demonstrates hardware/software co-design
- Shows understanding of financial protocols
- Proves ability to build production systems
- Covers full stack (FPGA → Cloud → Mobile)

---

**Status:** XDP kernel bypass gateway + market maker operational with 15 complete projects

**Next Steps:**
1. Project 16: Order execution engine integration
2. Multi-symbol support for market maker
3. Advanced trading strategies (adverse selection detection, spread widening)
4. Kafka infrastructure deployment for analytics

---

## References

### Kernel Bypass and High-Performance Networking
- [AF_XDP - Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html) - Official AF_XDP documentation
- [AF_XDP - DRM/Networking Documentation](https://dri.freedesktop.org/docs/drm/networking/af_xdp.html) - Detailed AF_XDP architecture
- [XDP Tutorial - xdp-project](https://github.com/xdp-project/xdp-tutorial) - Comprehensive XDP tutorial with examples
- [AF_XDP Examples - xdp-project](https://github.com/xdp-project/bpf-examples/blob/main/AF_XDP-example/README.org) - Practical AF_XDP implementation
- [DPDK AF_XDP PMD](https://doc.dpdk.org/guides/nics/af_xdp.html) - DPDK's AF_XDP poll mode driver
- [Kernel Bypass Techniques for HFT](https://lambdafunc.medium.com/kernel-bypass-techniques-in-linux-for-high-frequency-trading-a-deep-dive-de347ccd5407) - Deep dive into kernel bypass
- [Kernel Bypass: DPDK, SPDK, io_uring](https://anshadameenza.com/blog/technology/2025-01-15-kernel-bypass-networking-dpdk-spdk-io_uring/) - Comparison of approaches
- [Linux Kernel vs DPDK Performance](https://talawah.io/blog/linux-kernel-vs-dpdk-http-performance-showdown/) - Performance study
- [P51: High Performance Networking - Cambridge](https://www.cl.cam.ac.uk/teaching/1920/P51/Lecture6.pdf) - Academic perspective

### Performance Analysis and Optimization
- [Brendan Gregg - Performance Methodology](https://www.brendangregg.com/methodology.html) - Performance analysis methodology
- [Brendan Gregg - perf Examples](https://www.brendangregg.com/perf.html) - Linux perf tool usage
- [Brendan Gregg - CPU Flame Graphs](https://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html) - CPU profiling visualization
- [Ring Buffers - Design and Implementation](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/) - Ring buffer design
- [eBPF Ring Buffer Optimization](https://ebpfchirp.substack.com/p/challenge-3-ebpf-ring-buffer-optimization) - eBPF ring buffer techniques
- [Imperial HFT - GitHub Repository](https://github.com/0burak/imperial_hft) - Source of Disruptor implementation classes
- [Low-Latency Trading Systems - Thesis](https://arxiv.org/abs/2309.04259) - Burak Gunduz thesis on HFT with Disruptor
- [Imperial HFT Explanation Video](https://www.youtube.com/watch?v=65XoXkh6VcY) - Video explanation of Disruptor for trading

### FPGA and Hardware Design
- [Xilinx 7 Series FPGAs Overview](https://www.xilinx.com/support/documentation/data_sheets/ds180_7Series_Overview.pdf)
- [Xilinx UG473 - 7 Series Memory Resources](https://www.xilinx.com/support/documentation/user_guides/ug473_7Series_Memory_Resources.pdf)
- [Xilinx UG901 - Vivado Synthesis](https://www.xilinx.com/support/documentation/sw_manuals/xilinx2020_1/ug901-vivado-synthesis.pdf)

### Market Data Protocols and Trading
- [NASDAQ ITCH 5.0 Specification](NQTVITCHspecification.pdf) - Market data protocol
- [Market Making Strategies](https://quant.stackexchange.com/questions/tagged/market-making) - Trading strategy discussion

### Messaging and Communication Protocols
- [MQTT v3.1.1 Specification](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html)
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Boost.Asio Documentation](https://www.boost.org/doc/libs/1_84_0/doc/html/boost_asio.html)

---

*This architecture demonstrates complete end-to-end trading infrastructure from FPGA hardware acceleration to automated market making strategies.*
