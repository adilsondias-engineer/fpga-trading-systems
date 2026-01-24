# FPGA Learning Resources

Comprehensive list of documentation, datasheets, specifications, and tools used throughout this learning journey.

---

## Hardware Documentation

### Digilent Arty A7-100T (Projects 1-19)

**Official Documentation:**

- [Arty A7 Reference Manual](https://digilent.com/reference/programmable-logic/arty-a7/reference-manual)

  - Pin assignments for all peripherals
  - Schematic diagrams
  - Memory layout
  - Power specifications

- [Arty A7 Master XDC File](https://github.com/Digilent/digilent-xdc)
  - Complete pin constraints
  - All peripheral mappings
  - PMOD connector pinouts

**Board Features:**

- FPGA: Xilinx Artix-7 XC7A100T-1CSG324C
- Clock: 100 MHz oscillator
- Memory: 256 MB DDR3, 16 MB Quad-SPI Flash
- USB: UART bridge (FTDI FT2232HQ)
- Ethernet: 10/100 PHY (TI DP83848J)
- Peripherals: 4 buttons, 4 switches, 4 LEDs, 2 RGB LEDs

### ALINX AX7203 (Project 20+)

**Official Documentation:**

- [AX7203 Product Page](https://www.en.alinx.com/Product/FPGA-Development-Boards/Artix-7/AX7203.html)
  - Board overview and features
  - Technical specifications
  - Ordering information

- [AX7203 User Manual (PDF)](https://www.alinx.com/public/upload/file/AX7203_User_Manual.pdf)
  - Pin assignments and schematic
  - Peripheral interfaces
  - Example designs

- [AMD Partner Page](https://www.xilinx.com/products/boards-and-kits/1-1s6r42o.html)
  - Xilinx certification
  - Technical overview

**Board Features:**

- FPGA: Xilinx Artix-7 XC7A200T-2FBG484I
- Clock: 200 MHz LVDS differential, 125 MHz GTP reference
- Memory: 1 GB DDR3 (32-bit, 800 MT/s), 16 MB QSPI Flash
- USB: UART bridge (CP2102GM)
- Ethernet: **2× Gigabit Ethernet** (Realtek RTL8211E, RGMII)
- GTP: 4× transceivers (up to 6.6 Gb/s per channel)
- PCIe: Gen2 ×4 interface
- HDMI: 1× input, 1× output
- Expansion: 2× 40-pin headers (68 I/O)
- Form Factor: Core board (AC7200) + Carrier board

**Comparison with Arty A7-100T:**

| Feature | Arty A7-100T | AX7203 |
|---------|--------------|--------|
| FPGA | XC7A100T | XC7A200T |
| Logic Cells | 101,440 | 215,360 (**2.1×**) |
| Block RAM | 135 | 365 (**2.7×**) |
| DSP Slices | 240 | 740 (**3.1×**) |
| GTP Transceivers | 0 | 4 |
| Ethernet | MII 100M | RGMII Gigabit |
| DDR3 | 256 MB | 1 GB |
| System Clock | 100 MHz | 200 MHz |

**See Also:** [AX7203 Full Specifications](AX7203_SPECS.md)

### ALINX AX7325B (Projects 31-35)

**Official Documentation:**

- [AX7325B Product Page](https://www.en.alinx.com/) - Board overview and features

**Board Features:**

- FPGA: Xilinx Kintex-7 XC7K325T-2FFG900I
- Clock: 200 MHz LVDS system, 156.25 MHz GTX reference (on-board oscillator)
- Memory: 1 GB DDR3 (64-bit), 16 MB QSPI Flash
- USB: UART bridge (CP2102)
- Ethernet: **2× 10GbE SFP+** (via GTX transceivers)
- GTX: 16× transceivers (up to 12.5 Gb/s per channel), 4 quads
- PCIe: Gen2 ×8 interface
- Expansion: FMC-HPC connector
- Form Factor: Standalone board

**Comparison with AX7203:**

| Feature | AX7203 (Artix-7) | AX7325B (Kintex-7) |
|---------|-------------------|---------------------|
| FPGA | XC7A200T | XC7K325T |
| Logic Cells | 215,360 | **326,080 (1.5×)** |
| Block RAM | 365 (13.14 Mb) | **445 (16.02 Mb)** |
| DSP Slices | 740 | **840** |
| Transceivers | 4 GTP (6.6 Gb/s) | **16 GTX (12.5 Gb/s)** |
| Ethernet | RGMII Gigabit | **10GbE SFP+** |
| DDR3 | 1 GB (32-bit) | **1 GB (64-bit)** |

**See Also:** [AX7325B Full Specifications](AX7325B_SPECS.md)

### 10GbE Test Hardware (Projects 33-34)

Most developers will not have 10GbE networking at home. This project was verified using a dedicated fiber-optic test setup. **DAC cables did not work** with the AX7325B SFP+ cage.

| Component | Product | Specs |
|-----------|---------|-------|
| SFP+ Modules | 10G SFP+ Fiber Transceiver | SR MM850nm, 300m range, Duplex LC |
| Fiber Cable | Tunghey OM3 LC to LC Patch Cable | Multimode Duplex 50/125um, 15M, LS-ZH |
| 10GbE Switch | Binardat 8-Port 10G Managed Switch | 4x10G RJ45 + 4x10G SFP+, 160Gbps, L3 |
| PC NIC | Binardat 10G PCIe Network Adapter | Aquantia AQC107 chip, RJ45, PXE support |

**Test Topology:**
```
PC (AQC107 10G NIC, RJ45) <--Cat6a--> Binardat Switch <--OM3 Fiber + SFP+--> AX7325B FPGA
```

### Xilinx FPGA

**User Guides:**

- [UG470: 7 Series FPGAs Configuration User Guide](https://docs.xilinx.com/v/u/en-US/ug470_7Series_Config)

  - Configuration modes
  - Bitstream generation
  - Flash programming

- [UG471: 7 Series FPGAs SelectIO Resources User Guide](https://docs.xilinx.com/v/u/en-US/ug471_7Series_SelectIO)

  - I/O standards (LVCMOS33, LVDS, etc.)
  - Termination requirements
  - Timing parameters

- [UG472: 7 Series FPGAs Clocking Resources User Guide](https://docs.xilinx.com/v/u/en-US/ug472_7Series_Clocking)

  - PLL configuration (PLLE2_BASE)
  - MMCM configuration (MMCME2_BASE)
  - Clock distribution networks (BUFG, BUFR)
  - Jitter specifications

- [UG473: 7 Series FPGAs Memory Resources User Guide](https://docs.xilinx.com/v/u/en-US/ug473_7Series_Memory_Resources)

  - Block RAM architecture
  - FIFO implementation
  - Distributed RAM

- [UG953: Vivado Design Suite 7 Series FPGA and Zynq Libraries Guide](https://docs.xilinx.com/v/u/en-US/ug953-vivado-7series-libraries)
  - Primitive component specifications
  - Generic parameter requirements (STRING vs boolean!)
  - Port descriptions

**Datasheets:**

- [DS181: Artix-7 FPGAs Data Sheet](https://docs.xilinx.com/v/u/en-US/ds181_Artix_7_Data_Sheet)
  - DC/AC characteristics
  - Maximum frequencies
  - Power consumption
  - Package pinouts

- [DS182: Kintex-7 FPGAs Data Sheet](https://docs.amd.com/v/u/en-US/ds182_Kintex_7_Data_Sheet)
  - GTX transceiver specifications (12.5 Gb/s)
  - DC/AC characteristics
  - Power consumption per rail (VCCINT, MGTAVCC, MGTAVTT)
  - FFG900 package pinout

---

## Ethernet PHY Documentation

### TI DP83848J (Arty A7 Ethernet PHY - MII)

**Datasheet:**

- [DP83848J 10/100 Ethernet Physical Layer Transceiver](https://www.ti.com/product/DP83848J)
  - MII interface specification
  - Reset timing requirements (10ms minimum)
  - Register map (MDIO)
  - LED configuration modes

**Key Specifications:**

- Interface: MII (Media Independent Interface)
- Speed: 10/100 Mbps (NOT Gigabit)
- Clock: Requires 25 MHz reference from FPGA
- Pins: 18 MII signals + PHY management
- Auto-negotiation: IEEE 802.3u compliant

**Critical Notes:**

- Does NOT support RGMII
- Requires external 25 MHz reference clock
- PHY provides eth_rx_clk and eth_tx_clk to FPGA
- Minimum 10ms reset pulse required

### Realtek RTL8211E (AX7203 Ethernet PHY - RGMII)

**Datasheet:**

- [RTL8211E Gigabit Ethernet PHY](https://www.realtek.com/en/products/communications-network-ics/item/rtl8211e-vb-vl-cg)
  - RGMII interface specification
  - Register map (MDIO)
  - LED configuration
  - Timing diagrams

**Key Specifications:**

- Interface: RGMII (Reduced Gigabit Media Independent Interface)
- Speed: 10/100/1000 Mbps (Gigabit capable)
- Clock: 125 MHz RX clock output, FPGA provides TX clock
- Data: 4-bit DDR (8 bits per clock @ 125 MHz = 1 Gbps)
- Auto-negotiation: IEEE 802.3ab compliant

**Critical Notes:**

- RGMII requires DDR I/O primitives (ODDR/IDDR in Xilinx)
- TX clock must be 90° phase-shifted from TX data (RGMII spec)
- FPGA must generate TX clock using MMCM/PLL
- RX clock comes from PHY (use as MMCM reference)
- Internal delay mode: Configure for 2ns internal delay or use FPGA IDELAY

### RGMII Interface Specification

**Official Specification:**

- [RGMII v2.0 Specification (HP/Intel)](https://web.archive.org/web/20160303212629/http://www.hp.com/rnd/pdfs/RGMIIv2_0_final_hp.pdf)
  - Complete timing requirements
  - Clock-data relationship
  - Internal delay options

**RGMII vs MII Comparison:**

| Feature | MII | RGMII |
|---------|-----|-------|
| Data Width | 4 bits (SDR) | 4 bits (DDR) |
| Clock Rate (1000M) | N/A | 125 MHz |
| Clock Rate (100M) | 25 MHz | 25 MHz |
| Clock Rate (10M) | 2.5 MHz | 2.5 MHz |
| TX Clock Source | PHY | FPGA (90° shifted) |
| Pin Count | 18 | 12 |
| Max Speed | 100 Mbps | 1000 Mbps |

**FPGA Implementation Requirements:**

- **ODDR primitives:** For DDR TX data output
- **IDDR primitives:** For DDR RX data input (if implementing RX)
- **MMCM/PLL:** Generate 125 MHz + 125 MHz @ 90° phase
- **BUFG/BUFIO:** Proper clock routing
- **ASYNC_REG:** For reset synchronization across clock domains

---

## Protocol Specifications

### IEEE 802.3 - Ethernet

**Official Specification:**

- [IEEE 802.3-2018: Ethernet Standard](https://standards.ieee.org/ieee/802.3/7071/)
  - MAC frame format
  - Preamble/SFD structure
  - MII interface timing
  - CSMA/CD operation

**Frame Structure:**

```
Preamble (7 bytes):  0x55 0x55 0x55 0x55 0x55 0x55 0x55
SFD (1 byte):        0xD5
Dest MAC (6 bytes):  Target address
Src MAC (6 bytes):   Source address
Type/Length (2):     EtherType or payload length
Payload (46-1500):   Data
FCS (4 bytes):       CRC32 checksum
```

**MII Interface:**

- Data width: 4 bits (nibbles)
- Clock: 25 MHz (100 Mbps) or 2.5 MHz (10 Mbps)
- Preamble: Passed to FPGA (must strip in logic)
- Control signals: RX_DV, RX_ER, TX_EN, TX_ER
- Byte timing: Each byte stable for 2 clock cycles (12.5 MHz byte rate)
- **Critical:** State transitions cause type byte to repeat - use odd byte_counter (1,3,5,7...)

### ITCH 5.0 - Nasdaq Market Data Protocol

**Official Specification:**

- [ITCH 5.0 Protocol Specification](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf)
  - Binary message format
  - Message types (Add Order, Order Executed, Order Cancel, etc.)
  - Field layouts and data types
  - Big-endian byte order

**Message Types Implemented:**

- Type 'A' (0x41): Add Order - 36 bytes
  - Order reference (8 bytes), Buy/Sell (1 byte), Shares (4 bytes), Symbol (8 bytes), Price (4 bytes)
- Type 'E' (0x45): Order Executed - 31 bytes
  - Order reference (8 bytes), Executed shares (4 bytes), Match number (8 bytes)
- Type 'X' (0x58): Order Cancel - 23 bytes
  - Order reference (8 bytes), Cancelled shares (4 bytes)

**Key Characteristics:**

- Binary protocol (not ASCII)
- Network byte order (big-endian)
- Fixed-length messages per type
- Type byte identifies message format
- UDP transport (port 12345 in test environment)
- Price representation: 4-byte integer in 1/10000 dollars

### UART Communication

**Standard:** RS-232 compatible (LVCMOS levels)

- Format: 8N1 (8 data bits, no parity, 1 stop bit)
- Baud rate: 115200 bps
- Voltage: 3.3V CMOS levels
- Mid-bit sampling for noise immunity

---

## Software Tools

### AMD Vivado Design Suite

**Version Used:** Vivado 2025.1

**Documentation:**

- [UG835: Vivado Design Suite Tcl Command Reference Guide](https://docs.xilinx.com/r/en-US/ug835-vivado-tcl-commands)
- [UG888: Vivado Design Suite Tutorial](https://docs.xilinx.com/v/u/en-US/ug888-vivado-design-tutorials-getting-started)
- [UG893: Using the Vivado Logic Analyzer](https://docs.xilinx.com/v/u/en-US/ug893-vivado-logic-analyzer)
- [UG904: Vivado Implementation](https://docs.xilinx.com/v/u/en-US/ug904-vivado-implementation)
- [UG906: Vivado Design Analysis and Closure](https://docs.xilinx.com/v/u/en-US/ug906-vivado-design-analysis)

**Key Features Used:**

- Behavioral simulation
- Synthesis (out-of-context and project modes)
- Implementation (place & route)
- Timing analysis
- Bitstream generation
- Hardware manager (programming)

### Python Testing Tools

**PySerial (UART Testing):**

```bash
pip install pyserial
```

- Serial port communication
- Binary protocol testing
- Automated test scripts

**Scapy (Ethernet Testing):**

```bash
pip install scapy
```

- Raw Ethernet frame construction
- Layer 2 packet injection
- MAC address manipulation
- Wireshark-compatible captures

**Wireshark:**

- Packet capture and analysis
- Protocol dissection
- Timing measurements
- Filter expressions for debugging

---

## Learning Resources

### VHDL Language

**Books:**

- "VHDL for Engineers" by Kenneth Short
- "RTL Hardware Design Using VHDL" by Pong P. Chu

**Online References:**

- [VHDL Language Reference (IEEE Std 1076-2019)](https://standards.ieee.org/ieee/1076/10299/)
- [Free Range VHDL - Online Book](https://github.com/fabriziotappero/Free-Range-VHDL-book)
- [VHDL Tutorial - NANDLAND](https://nandland.com/introduction-to-vhdl/)
- [VHDL Tutorial - ElectronicsTutorials](https://www.electronics-tutorials.ws/combination/vhdl.html)

**Key Concepts Learned:**

- Signal vs variable timing
- Process evaluation order
- Sequential vs concurrent statements
- Clock domain crossing
- Synchronizer patterns
- State machine design

### Digital Design Fundamentals

**Metastability:**

- [Metastability in FPGA Design (Altera/Intel)](https://www.intel.com/content/www/us/en/docs/programmable/683082/current/metastability.html)
- 2FF synchronizers for CDC
- 3FF synchronizers for asynchronous inputs
- MTBF calculations

**Clock Domain Crossing:**

- Gray code counters
- Handshake protocols
- FIFO-based crossing
- Timing constraints (set_max_delay, set_false_path)

**Protocol Design:**

- Binary vs ASCII protocols
- Framing strategies (START_BYTE, length-prefixed)
- Error detection (checksums, CRC)
- State machine parsers

---

## Development Tools Configuration

### Git Repository Structure

```
fpga-trading-systems/
├── .gitignore           # Vivado files, temp files
├── README.md            # Portfolio overview
├── context.txt          # Context restoration (git ignored)
├── resources.md         # This file
├── docs/
│   └── lessons-learned.md
├── 01-project/
│   ├── src/
│   ├── test/
│   ├── constraints/
│   └── README.md
└── ...
```

**.gitignore Patterns:**

```
*.jou
*.log
*.str
*.xpr
*.cache/
*.hw/
*.runs/
*.sim/
*.tmp/
*.dcp
.Xil/
*.wdb
*.vcd
```

### Vivado Project Management

**TCL Scripts:**

- `build.tcl` - Batch synthesis/implementation
- `program.tcl` - FPGA programming
- Automated workflow for consistent builds

**Constraints Best Practices:**

- Separate timing from physical constraints
- Use variables for reusable values
- Comment all non-obvious constraints
- Include clock domain crossing constraints

---

## Community & Forums

**Xilinx Forums:**

- [AMD Support Community](https://support.xilinx.com/s/)
- Active community for tool issues
- Hardware-specific questions

**Stack Overflow:**

- Tag: [fpga], [vhdl], [xilinx]
- Good for language questions

**Reddit:**

- r/FPGA - Community discussions
- r/ECE - Electronics engineering

**GitHub:**

- Digilent reference designs
- Open-source IP cores
- Example projects

---

## Hardware Debugging Tools

**Integrated Logic Analyzer (ILA):**

- Xilinx IP core for on-chip debugging
- Real-time signal capture
- Trigger conditions
- Waveform export to Vivado

**Virtual I/O (VIO):**

- Runtime signal manipulation
- Interactive debugging
- Register inspection

**JTAG:**

- Programming interface
- Boundary scan
- ChipScope debugging

---

## Reference Designs

**Digilent GitHub:**

- [Arty A7 Reference Designs](https://github.com/Digilent/Arty-A7-100-Master-XDC)
- Example constraints
- Peripheral interfaces
- Complete working projects

**Xilinx Example Designs:**

- AXI interface examples
- Clock management examples
- High-speed serial transceivers
- Memory controller examples

---

## Advanced Software Technologies (Projects 9-15)

### C++ High-Performance Computing

**Boost Libraries:**
- [Boost.Asio](https://www.boost.org/doc/libs/1_82_0/doc/html/boost_asio.html) - Async I/O, TCP/UDP networking
- Multi-threaded programming
- Event-driven architecture

**Lock-Free Data Structures:**
- [LMAX Disruptor Pattern](https://lmax-exchange.github.io/disruptor/) - Ultra-low-latency IPC
- Lock-free ring buffers
- Memory ordering (std::memory_order_acquire/release)
- Cache-line alignment for false-sharing prevention

**Kernel Bypass Technologies:**
- [AF_XDP (Linux)](https://www.kernel.org/doc/html/latest/networking/af_xdp.html) - Zero-copy packet reception
- [eBPF](https://ebpf.io/) - Programmable packet filtering
- [libxdp](https://github.com/xdp-project/xdp-tools) - XDP library
- [libbpf](https://github.com/libbpf/libbpf) - BPF program loading
- POSIX shared memory (/dev/shm)

**Real-Time Optimization:**
- SCHED_FIFO scheduling policy
- CPU isolation (isolcpus kernel parameter)
- CPU pinning (pthread_setaffinity_np)
- NOHZ_FULL (tickless kernel)

**Protocol Libraries:**
- [libmosquitto](https://mosquitto.org/) - MQTT client library
- [librdkafka](https://github.com/confluentinc/librdkafka) - Apache Kafka client
- [nlohmann/json](https://github.com/nlohmann/json) - Modern C++ JSON library
- [spdlog](https://github.com/gabime/spdlog) - Fast C++ logging library

### Multi-Platform Development

**.NET MAUI (Project 11):**
- Cross-platform mobile development (Android, iOS, Windows)
- MVVM pattern with CommunityToolkit.Mvvm
- MQTTnet 5.x for MQTT connectivity
- System.Text.Json for parsing

**Java Desktop (Project 12):**
- JavaFX for GUI applications
- Gson for JSON parsing
- Maven build system
- Real-time charting libraries

**IoT/Embedded (Project 10):**
- ESP32-WROOM microcontroller
- Arduino IDE framework
- TFT_eSPI library for ST7735 displays
- PubSubClient for MQTT

### Trading System Architecture

**Market Data Protocols:**
- NASDAQ ITCH 5.0 (binary)
- FIX Protocol 4.2 (order execution)
- UDP multicast distribution

**Market Microstructure:**
- Order book mechanics (bid/ask levels)
- Price-time priority matching
- Market making strategies
- Position and risk management
- Best Bid/Offer (BBO) calculation

**Performance Measurement:**
- Latency percentiles (P50, P99, P99.9)
- Hardware timestamping
- End-to-end latency chains
- Performance baselines and optimization

---

## Lessons on Tool Usage

**Vivado Best Practices:**

- Always check critical warnings
- Timing must close (WNS > 0)
- Use IP Integrator for complex systems
- Out-of-context synthesis for IP
- Incremental compilation for faster iterations

**Simulation Best Practices:**

- Use reduced timing for fast simulation
- Self-checking testbenches save time
- Procedures for reusable test patterns
- Assert statements catch bugs early
- Simulate edge cases, not just happy path

**Hardware Verification:**

- LED debugging is surprisingly effective
- Wireshark for network protocol validation
- Scapy for controllable test traffic
- Oscilloscope for timing verification
- Always test on real hardware

---

## Key References Added (Projects 14-15)

### Kernel Bypass and High-Performance Networking
- [AF_XDP - Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [XDP Tutorial - xdp-project](https://github.com/xdp-project/xdp-tutorial)
- [Kernel Bypass Techniques in Linux for HFT](https://lambdafunc.medium.com/kernel-bypass-techniques-in-linux-for-high-frequency-trading-a-deep-dive-de347ccd5407)
- [DPDK AF_XDP PMD](https://doc.dpdk.org/guides/nics/af_xdp.html)
- [P51: High Performance Networking - Cambridge](https://www.cl.cam.ac.uk/teaching/1920/P51/Lecture6.pdf)
- [Linux Kernel vs DPDK Performance](https://talawah.io/blog/linux-kernel-vs-dpdk-http-performance-showdown/)

### LMAX Disruptor Pattern
- [Disruptor GitHub](https://github.com/LMAX-Exchange/disruptor) - Original Java implementation
- [Disruptor Technical Paper](https://lmax-exchange.github.io/disruptor/disruptor.html) - Architecture and design
- [Mechanical Sympathy Blog](https://mechanical-sympathy.blogspot.com/) - Martin Thompson's blog on performance
- [Ring Buffers - Design and Implementation](https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/)

### Performance Analysis
- [Brendan Gregg - Performance Methodology](https://www.brendangregg.com/methodology.html)
- [Brendan Gregg - perf Examples](https://www.brendangregg.com/perf.html)
- [Brendan Gregg - CPU Flame Graphs](https://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html)

### FIX Protocol (Project 16)
- [FIX Protocol Official Site](https://www.fixtrading.org/)
- [FIX 4.2 Specification](https://www.fixtrading.org/standards/fix-4-2/)
- [QuickFIX - Open-source FIX Engine](https://www.quickfixengine.org/)

### Market Making and Trading
- [Market Making Strategies](https://quant.stackexchange.com/questions/tagged/market-making)
- [Algorithmic Trading Basics](https://www.quantstart.com/articles/algorithmic-trading-beginners-guide/)
- [Order Book Dynamics](https://arxiv.org/abs/1301.3841)

### HFT Architecture and FPGA Technology (ByteMonk Videos)

**Inside a Real High-Frequency Trading System | HFT Architecture**
- [YouTube: HFT Architecture Deep Dive](https://www.youtube.com/watch?v=iwRaNYa8yTw)
- Comprehensive walkthrough of production HFT system architecture
- Key Topics Covered:
  - Market data ingestion (multicast, ultra-low-latency NICs, kernel bypass)
  - In-memory order book and active-passive replication
  - Event-driven pipeline with lock-free queues
  - Nanosecond timestamping and hardware clocks
  - FPGA acceleration for tick-to-trade execution
  - Market-making strategy engines
  - Smart order routing and pre-trade risk checks
  - Order Management System (OMS) and monitoring
  - Latency dashboards and metrics collection
- Architecture Components Detailed:
  - Network infrastructure (DPDK, Solarflare Onload)
  - Feed handlers and protocol parsers
  - Event stream processing
  - FPGA decision engines (arbitrage, market-making, quote stuffing)
  - Post-trade analysis and compliance
- Performance Targets: Sub-microsecond latency (300ns strategy latency achievable)

**FPGA in HFT Systems Explained | Why Reconfigurable Hardware Beats CPUs**
- [YouTube: FPGA Technology Deep Dive](https://www.youtube.com/watch?v=JmVOEkskft4)
- Technical explanation of FPGA architecture and programming
- Key Topics Covered:
  - FPGA fundamentals vs CPU/GPU/ASIC
  - Configurable Logic Blocks (CLBs) and Lookup Tables (LUTs)
  - Programmable interconnects and I/O blocks
  - Hardware Description Languages (Verilog/VHDL)
  - Synthesis tools and bitstream compilation
  - Real-world use cases: HFT, AI inference, telecom
- Why FPGAs for HFT:
  - Hardware-level processing (no OS/driver overhead)
  - Deterministic latency (no context switching)
  - Direct data path from network to logic
  - Reconfigurable post-deployment
  - Orders of magnitude faster than software for pipelined operations
- Trade-offs: Harder to program, best for predictable workloads

**Value for This Project:**
These videos validate the architectural decisions made in Projects 6-16:
- Event-driven architecture (Disruptor pattern in Projects 14-15)
- Hardware acceleration (FPGA feed parsing in Projects 6-8)
- Kernel bypass (AF_XDP in Project 14)
- Lock-free IPC (Disruptor in Projects 14-15)
- Market-making logic (Project 15 FSM)
- Order execution pipeline (Project 16)

Key insights: Production HFT systems use software feed handlers + FPGA acceleration (flexible), while this project uses FPGA feed handler (faster but less flexible). This project achieves **312 ns** latency (4-point hardware-measured), competitive for most trading strategies.

---

## ARM Cortex-M0 & PY32F030 (Project 19)

### PY32F030 Microcontroller

**Official Documentation:**
- [Puya PY32F030 Series](https://www.puyasemi.com/cpzx3/info_271_itemid_87.html) - Official product page
- [PY32F030 Datasheet](https://www.puyasemi.com/uploadfiles/2022/02/PY32F030x4x6x7x8.pdf) - Electrical characteristics, pinout, memory map

**Key Features:**
- **Core:** ARM Cortex-M0 @ 24 MHz (configurable up to 48 MHz)
- **Memory:** 64 KB Flash, 8 KB SRAM
- **Peripherals:** 2× SPI (up to 24 MHz master), 2× UART, 2× I2C, Timers, ADC, GPIO
- **Package:** TSSOP-20, QFN-32
- **Voltage:** 1.7V - 5.5V operating range
- **Cost:** < $0.50 USD (extremely cost-effective for monitoring/UI tasks)

### ARM Cortex-M0 Architecture

**ARM Documentation:**
- [Cortex-M0 Technical Reference Manual](https://developer.arm.com/documentation/ddi0432/c/) - ARM official TRM
- [Cortex-M0 Devices Generic User Guide](https://developer.arm.com/documentation/dui0497/a/) - Programming model, instruction set

**Architecture Highlights:**
- **32-bit RISC:** ARMv6-M instruction set (Thumb subset only)
- **Pipeline:** 3-stage pipeline (Fetch, Decode, Execute)
- **Performance:** ~0.95 DMIPS/MHz
- **Code Density:** Excellent (16-bit Thumb instructions)
- **Power:** Ultra-low power consumption (< 10 μA/MHz active)

### SPI Protocol (Mode 0: CPOL=0, CPHA=0)

**SPI Mode 0 Characteristics:**
- **CPOL=0:** Clock idles low
- **CPHA=0:** Data sampled on rising edge, shifted on falling edge
- **Timing:** MSB-first or LSB-first (configured in SPI control register)
- **CS# (Chip Select):** Active low, asserted before transaction, deasserted after
- **Full-Duplex:** Simultaneous MOSI (Master Out) and MISO (Slave In) transmission

**Key Timing Parameters:**
- **Setup Time (tSU):** Data valid before clock edge (typically 5-10 ns)
- **Hold Time (tH):** Data stable after clock edge (typically 5-10 ns)
- **Clock Frequency:** Up to 25 MHz for simple FPGA protocols
- **Inter-Byte Gap:** Optional delay between bytes (PY32 SPI master configurable)

### Development Tools

**PY32 Toolchain:**
- [GNU ARM Embedded Toolchain](https://developer.arm.com/tools-and-software/open-source-software/developer-tools/gnu-toolchain) - GCC for ARM Cortex-M
- [pyOCD](https://pyocd.io/) - Python-based debugger for ARM Cortex-M (used in Project 19)
  - `pip install pyocd` - Simple installation via pip
  - Supports ST-Link V2, CMSIS-DAP, and other debug probes
  - Excellent PY32F030 support with GDB server capability
- [OpenOCD](https://openocd.org/) - Alternative open-source debugger for ARM
- [ST-Link V2 Utility](https://www.st.com/en/development-tools/st-link-v2.html) - Programming and debugging (compatible with PY32)

**Programming Interface:**
- **ST-Link V2:** Low-cost USB programmer/debugger (SWD interface) - used with pyOCD in Project 19
- **UART Bootloader:** PY32F030 has built-in UART bootloader for firmware updates
- **SWD (Serial Wire Debug):** 2-wire debug interface (SWDIO, SWCLK)

**Project 19 Development Stack:**
- **Debugger:** pyOCD (Python-based, excellent ST-Link V2 support)
- **GDB:** ARM GDB from GNU ARM Embedded Toolchain
- **Build System:** Makefile with arm-none-eabi-gcc
- **Flash Tool:** pyOCD flash command or ST-Link Utility

### SPI Protocol Best Practices (Project 19 Lessons)

**Clock Domain Crossing:**
- Always use 2-FF synchronizer for asynchronous SPI signals (SCK, MOSI, CS#) crossing into FPGA clock domain
- Edge detection on synchronized signals, not raw SPI clock

**Pipeline Timing:**
- Account for sequential register reads (BRAM-style access creates 1-2 cycle delay)
- State machine must wait for pipeline to complete before shifting data
- Example: bit_count 0→1→2 setup phase before data shift phase

**Protocol Edge Cases:**
- **Address Byte Trailing Edge:** Skip first falling edge after address byte to prevent premature shift
- **CS# Glitches:** Add debouncing or minimum CS# low time requirement (typically 2× SPI clock period)
- **Back-to-Back Transactions:** Ensure minimum CS# high time between transactions (1 SPI clock period minimum)

**Testing Methodology:**
- **Testbench Validation:** Self-checking VHDL testbench with SPI transaction simulation
- **Hardware Stress Test:** 10,000+ transactions with error counting (detect timing violations)
- **Edge Case Testing:** Test CS# glitches, clock frequency limits, temperature variation

### Reference Designs

**FPGA-Microcontroller Integration:**
- Project 19 demonstrates production-grade heterogeneous system integration
- Modular SPI architecture (spi_slave_core → spi_register_if → application) enables reusability
- Pattern: FPGA handles time-critical paths (312 ns ITCH-to-BBO, hardware-measured), microcontroller handles UI/monitoring/configuration

**Key Architectural Lessons:**
- **Separation of Concerns:** FPGA → low-latency processing, MCU → slow UI/display tasks
- **Dynamic Configuration:** SPI write registers enable runtime parameter updates (no FPGA reprogramming)
- **Independent Monitoring:** External watchdog can detect and recover from FPGA hangs
- **Scalability:** Register bank architecture scales from 6 registers (demo) to 256 registers (production)

---

## 10GbE and Multi-FPGA Resources (Projects 31-35)

### 10GBASE-R PHY Implementation

**Key References:**
- [UG476: 7 Series GTX/GTH Transceivers](https://docs.amd.com/r/en-US/ug476_7Series_Transceivers) - GTX configuration, gearbox, QPLL
- [IEEE 802.3-2018 Clause 49](https://standards.ieee.org/ieee/802.3/7071/) - 10GBASE-R PCS specification
- [verilog-ethernet Library](https://github.com/alexforencich/verilog-ethernet) - Reference implementation (Forencich)
- [PG157: 10G/25G Ethernet Subsystem](https://docs.xilinx.com/r/en-US/pg157-axi-10g-eth-subsystem) - Xilinx vendor IP reference

**10GBASE-R Implementation Lessons:**
- GTX serializes TXDATA[0] first (LSB-first); IEEE 802.3 scrambler also operates LSB-first
- TXSEQUENCE counter must cycle 0 -> 32 -> 0 (33 values for 64B/66B gearbox)
- TXGEARBOXREADY indicates when GTX actually latches data (not every cycle)
- Block lock FSM requires edge detection on rx_datavalid for 64-bit gearbox mode
- Self-synchronizing descrambler polynomial: G(X) = 1 + X^39 + X^58

### Multi-FPGA Inter-Connect

**Aurora Protocol:**
- GTX-based point-to-point links (10.3125 Gbps per lane)
- 64B/66B encoding for clock recovery
- Low-latency alternative to Ethernet for inter-FPGA communication

### Market Data Session Layers

**MoldUDP64 (NASDAQ):**
- Session ID (10B) + Sequence Number (8B) + Message Count (2B) + Messages
- Each message: Length (2B) + ITCH payload
- Gap detection via sequence number tracking

**SoupBinTCP (ASX):**
- TCP-based session layer with heartbeat management
- Packet Length (2B) + Packet Type (1B) + Payload
- Types: Login Accepted (A), Heartbeat (H), Sequenced Data (S), End of Session (Z)

### PCB Design Resources

**Design Tools:**
- [KiCad 9](https://www.kicad.org/) - Open-source PCB design suite (also using EasyEDA for component library access via LCSC)
- [Saturn PCB Toolkit](http://www.saturnpcb.com/) - Impedance and stackup calculator

**High-Speed Design:**
- [SFF-8431: SFP+ Specification](https://www.snia.org/technology-focus/networking) - SFP+ cage pinout and electrical requirements
- JEDEC DDR3 SDRAM Standard - DDR3 SODIMM interface timing
- 100 ohm differential impedance for GTX pairs
- Length matching: +/- 5 mils within differential pair

---

_This resource list grows with each project. Last updated: Project 35 (3-FPGA Trading Appliance PCB)_
