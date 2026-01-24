# 40GBASE-R4 Architecture Design

**Status:** Design Complete | Implementation Pending | Hardware Validation Required  
**Author:** Adilson Dias  
**Date:** January 2026  
**License:** Apache 2.0

---

## Overview

Extension of the custom 10GBASE-R Physical Coding Sublayer implementation (Projects 33-34) to 40 Gigabit Ethernet using IEEE 802.3ba 40GBASE-R4 specification. This design leverages four parallel 10.3125 Gbps lanes with multi-lane distribution (MLD) for lane bonding and alignment.

**Key Principle:** Reuse validated 10GBASE-R building blocks (64B/66B encoding, scrambling, block sync) across four parallel lanes, adding only the multi-lane distribution layer required for 40G operation.

---

## Architecture

### System Block Diagram

```
                    40GBASE-R4 PHY Architecture
┌──────────────────────────────────────────────────────────────┐
│                      TX PATH                                 │
│                                                              │
│  XGMII TX     ┌─────────────┐                               │
│  (256-bit) ──►│ Lane Striping│                               │
│  156.25 MHz   │ (Round-robin)│                               │
│               └──────┬───────┘                               │
│                      │                                       │
│         ┌────────────┼────────────┬────────────┐            │
│         │            │            │            │            │
│         ▼            ▼            ▼            ▼            │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │ 64B/66B│  │ 64B/66B│  │ 64B/66B│  │ 64B/66B│         │
│    │Encoder │  │Encoder │  │Encoder │  │Encoder │         │
│    │ Lane 0 │  │ Lane 1 │  │ Lane 2 │  │ Lane 3 │         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │Scrambler│ │Scrambler│ │Scrambler│ │Scrambler│        │
│    │X^58+   │  │X^58+   │  │X^58+   │  │X^58+   │         │
│    │X^39+1  │  │X^39+1  │  │X^39+1  │  │X^39+1  │         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │  GTX   │  │  GTX   │  │  GTX   │  │  GTX   │         │
│    │ Lane 0 │  │ Lane 1 │  │ Lane 2 │  │ Lane 3 │         │
│    │10.3125G│  │10.3125G│  │10.3125G│  │10.3125G│         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        └───────────┴───────────┴───────────┘               │
│                        │                                    │
│                        ▼                                    │
│                   QSFP+ Cage                                │
│                 (4× 10G lanes)                              │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                      RX PATH                                 │
│                                                              │
│                   QSFP+ Cage                                │
│                 (4× 10G lanes)                              │
│                        │                                    │
│        ┌───────────────┴───────────────┬────────────┐       │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │  GTX   │  │  GTX   │  │  GTX   │  │  GTX   │         │
│    │ Lane 0 │  │ Lane 1 │  │ Lane 2 │  │ Lane 3 │         │
│    │10.3125G│  │10.3125G│  │10.3125G│  │10.3125G│         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │Descram │  │Descram │  │Descram │  │Descram │         │
│    │bler    │  │bler    │  │bler    │  │bler    │         │
│    │X^58+   │  │X^58+   │  │X^58+   │  │X^58+   │         │
│    │X^39+1  │  │X^39+1  │  │X^39+1  │  │X^39+1  │         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │ Block  │  │ Block  │  │ Block  │  │ Block  │         │
│    │ Sync   │  │ Sync   │  │ Sync   │  │ Sync   │         │
│    │ FSM    │  │ FSM    │  │ FSM    │  │ FSM    │         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        ▼           ▼           ▼           ▼               │
│    ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐         │
│    │ 64B/66B│  │ 64B/66B│  │ 64B/66B│  │ 64B/66B│         │
│    │Decoder │  │Decoder │  │Decoder │  │Decoder │         │
│    │ Lane 0 │  │ Lane 1 │  │ Lane 2 │  │ Lane 3 │         │
│    └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘         │
│        │           │           │           │               │
│        └────────────┼────────────┼────────────┘            │
│                     │            │                         │
│                     ▼            ▼                         │
│              ┌──────────────────────────┐                  │
│              │  Multi-Lane Distribution │                  │
│              │  (MLD) Layer             │                  │
│              │  • Lane Deskew           │                  │
│              │  • Alignment Markers     │                  │
│              │  • Virtual Lane Mapping  │                  │
│              └──────────┬───────────────┘                  │
│                         │                                  │
│                         ▼                                  │
│                    XGMII RX                                │
│                    (256-bit)                               │
│                    156.25 MHz                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Reusable Components from 10GBASE-R

The following components from Projects 33-34 are directly reusable with minimal modification:

### 1. 64B/66B Encoder (× 4 instances)

**Source:** `phy_64b66b_encoder.vhd` from Project 33

**Modifications Required:**
- None - component is lane-independent
- Instantiate four times, one per physical lane

**Interface:**
```vhdl
entity phy_64b66b_encoder is
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- XGMII input (per lane)
        xgmii_txd       : in  std_logic_vector(63 downto 0);
        xgmii_txc       : in  std_logic_vector(7 downto 0);
        -- 66-bit encoded output
        tx_header       : out std_logic_vector(1 downto 0);  -- 0x1 or 0x2
        tx_data         : out std_logic_vector(63 downto 0)
    );
end entity;
```

### 2. 64B/66B Decoder (× 4 instances)

**Source:** `phy_64b66b_decoder.vhd` from Project 33

**Modifications Required:**
- None - component is lane-independent
- Instantiate four times, one per physical lane

**Interface:**
```vhdl
entity phy_64b66b_decoder is
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- 66-bit encoded input
        rx_header       : in  std_logic_vector(1 downto 0);
        rx_data         : in  std_logic_vector(63 downto 0);
        -- XGMII output
        xgmii_rxd       : out std_logic_vector(63 downto 0);
        xgmii_rxc       : out std_logic_vector(7 downto 0);
        -- Error reporting
        decode_error    : out std_logic
    );
end entity;
```

### 3. Scrambler (× 4 instances)

**Source:** `phy_scrambler.vhd` from Project 33

**Polynomial:** X^58 + X^39 + 1 (per IEEE 802.3 Clause 49.2.6)

**Modifications Required:**
- None - scrambler is self-synchronizing and lane-independent
- Instantiate four times, one per physical lane

**Interface:**
```vhdl
entity phy_scrambler is
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- Input (after 64B/66B encoding)
        data_in         : in  std_logic_vector(63 downto 0);
        -- Scrambled output
        data_out        : out std_logic_vector(63 downto 0)
    );
end entity;
```

### 4. Descrambler (× 4 instances)

**Source:** `phy_descrambler.vhd` from Project 33

**Modifications Required:**
- None - uses same polynomial, self-synchronizing
- Instantiate four times, one per physical lane

### 5. Block Synchronization FSM (× 4 instances)

**Source:** `phy_block_sync.vhd` from Project 33

**Modifications Required:**
- Minor: Add per-lane status outputs for MLD layer monitoring
- Instantiate four times, one per physical lane

**Modified Interface:**
```vhdl
entity phy_block_sync is
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;
        rx_header       : in  std_logic_vector(1 downto 0);
        rx_data         : in  std_logic_vector(63 downto 0);
        block_lock      : out std_logic;  -- Used by MLD for lane status
        sync_data       : out std_logic_vector(63 downto 0);
        sync_header     : out std_logic_vector(1 downto 0)
    );
end entity;
```

### 6. GTX Transceiver Configuration (4× GTX channels)

**Source:** `phy_gtx_wrapper.vhd` from Project 33

**Modifications Required:**
- Change from single GTX channel to quad GTX tile
- Use GTXE2_COMMON for shared QPLL across 4 lanes
- Instantiate 4× GTXE2_CHANNEL primitives

**Clocking:**
- QPLL: 10.3125 GHz (same as 10G)
- TX/RX User Clocks: 156.25 MHz × 4 lanes
- Reference Clock: 156.25 MHz (shared across quad)

---

## New Components Required

### 1. Multi-Lane Distribution (MLD) Layer

Per IEEE 802.3ba Clause 82, the MLD layer provides:

#### A. Lane Alignment

**Purpose:** Detect and compensate for inter-lane skew

**Alignment Markers:**
- Inserted every 16,383 blocks on each lane
- 4-block sequence: Marker, M0, M1, M2
- Unique per lane for identification

**Marker Format (per IEEE 802.3ba Table 82-4):**
```
Lane 0: 0x90_76_47_D2_50_89_B8_2D
Lane 1: 0xF0_C4_E6_96_0F_3B_19_69
Lane 2: 0xC5_65_9B_32_3A_9A_64_CD
Lane 3: 0xA7_79_E3_1D_58_86_1C_E2
```

**VHDL Entity:**
```vhdl
entity lane_alignment is
    generic (
        LANE_ID : integer range 0 to 3
    );
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- Input from 64B/66B encoder
        tx_data_in      : in  std_logic_vector(63 downto 0);
        tx_header_in    : in  std_logic_vector(1 downto 0);
        -- Output with markers inserted
        tx_data_out     : out std_logic_vector(63 downto 0);
        tx_header_out   : out std_logic_vector(1 downto 0);
        -- Marker insertion flag
        marker_inserted : out std_logic
    );
end entity;
```

**Implementation:**
- Block counter: 0 to 16,382 (wraps at 16,383)
- When counter = 16,383, insert 4-block marker sequence
- Replace normal data blocks with marker pattern

#### B. Lane Deskew

**Purpose:** Compensate for differential delay between lanes (up to 32 blocks)

**Architecture:**
```
Lane 0 Data ──► Marker Detect ──► Deskew FIFO (32 deep) ──┐
Lane 1 Data ──► Marker Detect ──► Deskew FIFO (32 deep) ──┤
Lane 2 Data ──► Marker Detect ──► Deskew FIFO (32 deep) ──┼──► Aligned Data
Lane 3 Data ──► Marker Detect ──► Deskew FIFO (32 deep) ──┘
                                        │
                                   Alignment
                                   Controller
```

**VHDL Entity:**
```vhdl
entity lane_deskew is
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- Inputs from 4 lanes (after descrambling + block sync)
        lane0_data      : in  std_logic_vector(63 downto 0);
        lane0_header    : in  std_logic_vector(1 downto 0);
        lane0_valid     : in  std_logic;
        lane1_data      : in  std_logic_vector(63 downto 0);
        lane1_header    : in  std_logic_vector(1 downto 0);
        lane1_valid     : in  std_logic;
        lane2_data      : in  std_logic_vector(63 downto 0);
        lane2_header    : in  std_logic_vector(1 downto 0);
        lane2_valid     : in  std_logic;
        lane3_data      : in  std_logic_vector(63 downto 0);
        lane3_header    : in  std_logic_vector(1 downto 0);
        lane3_valid     : in  std_logic;
        -- Deskewed outputs (all aligned)
        deskewed_lane0  : out std_logic_vector(63 downto 0);
        deskewed_lane1  : out std_logic_vector(63 downto 0);
        deskewed_lane2  : out std_logic_vector(63 downto 0);
        deskewed_lane3  : out std_logic_vector(63 downto 0);
        deskew_valid    : out std_logic;
        -- Status
        lanes_aligned   : out std_logic
    );
end entity;
```

**Algorithm:**
1. Detect alignment markers on each lane independently
2. Calculate inter-lane skew (marker arrival time delta)
3. Buffer faster lanes in FIFO until all markers aligned
4. Once aligned, continuously compensate for skew

**Latency:**
- Minimum: 0 blocks (all lanes perfectly aligned)
- Maximum: 32 blocks × 66 bits / (10.3125 Gbps) = ~0.21 μs
- Typical: ~0.1 μs (average skew scenario)

#### C. Virtual Lane Mapping

**Purpose:** Distribute 256-bit XGMII across four 64-bit physical lanes

**TX Path (Striping):**
```
XGMII TX (256-bit @ 156.25 MHz)
    ↓
[Bytes 0-7]   → Lane 0 (64-bit)
[Bytes 8-15]  → Lane 1 (64-bit)
[Bytes 16-23] → Lane 2 (64-bit)
[Bytes 24-31] → Lane 3 (64-bit)
```

**RX Path (Bonding):**
```
Lane 0 (64-bit) → [Bytes 0-7]   ┐
Lane 1 (64-bit) → [Bytes 8-15]  ├─► XGMII RX (256-bit @ 156.25 MHz)
Lane 2 (64-bit) → [Bytes 16-23] │
Lane 3 (64-bit) → [Bytes 24-31] ┘
```

**VHDL Entity:**
```vhdl
entity virtual_lane_mapper is
    port (
        clk             : in  std_logic;  -- 156.25 MHz
        reset           : in  std_logic;
        -- XGMII interface (256-bit)
        xgmii_txd       : in  std_logic_vector(255 downto 0);
        xgmii_txc       : in  std_logic_vector(31 downto 0);
        -- Per-lane outputs (64-bit each)
        lane0_txd       : out std_logic_vector(63 downto 0);
        lane0_txc       : out std_logic_vector(7 downto 0);
        lane1_txd       : out std_logic_vector(63 downto 0);
        lane1_txc       : out std_logic_vector(7 downto 0);
        lane2_txd       : out std_logic_vector(63 downto 0);
        lane2_txc       : out std_logic_vector(7 downto 0);
        lane3_txd       : out std_logic_vector(63 downto 0);
        lane3_txc       : out std_logic_vector(7 downto 0)
    );
end entity;
```

---

## Resource Estimates

### FPGA: Kintex-7 XC7K325T-2FFG900I

**Available Resources:**
- Logic Cells: 326,080
- LUTs: 203,800
- Flip-Flops: 407,600
- BRAM (36 Kb): 445 tiles
- DSP Slices: 840
- GTX Transceivers: 8 (using 4 for 40G)

**Estimated Utilization:**

| Resource | Per 10G Lane | × 4 Lanes | MLD Layer | Total | % Utilization |
|----------|--------------|-----------|-----------|-------|---------------|
| LUTs | ~3,500 | 14,000 | ~6,000 | **20,000** | 10% |
| FFs | ~2,000 | 8,000 | ~4,000 | **12,000** | 3% |
| BRAM Tiles | ~2 | 8 | ~18 | **26** | 6% |
| GTX | 1 | 4 | - | **4** | 50% |

**BRAM Breakdown:**
- Deskew FIFOs: 4 lanes × 32 blocks × 66 bits = ~4 BRAM36 tiles
- Alignment marker buffers: ~2 BRAM36 tiles
- Control state storage: ~1 BRAM36 tile
- Total MLD BRAM: ~7 BRAM36 tiles (conservative: ~18 with headroom)

**Clocking Resources:**
- QPLL: 1 (shared across 4 GTX in quad)
- MMCM: 1 (generate 156.25 MHz from reference)
- BUFG: ~6 (clock distribution)

**Margin:** Excellent headroom for additional logic (order books, parsers, etc.)

---

## Timing Analysis

### Critical Paths

**1. XGMII Lane Striping (TX Path):**
- Clock: 156.25 MHz (6.4 ns period)
- Path: 256-bit demux → 4× 64-bit lanes
- Estimated: ~3.5 ns (combinatorial)
- **Slack:** +2.9 ns

**2. Lane Deskew FIFO Read/Write (RX Path):**
- Clock: 156.25 MHz
- Path: Marker detect → FIFO write enable → Data storage
- Estimated: ~4.2 ns
- **Slack:** +2.2 ns

**3. 64B/66B Encoding (per lane):**
- Clock: 156.25 MHz
- Path: Reused from 10G (already met timing with +2.2 ns slack)
- **Slack:** +2.2 ns

**4. Scrambler Feedback (per lane):**
- Clock: 156.25 MHz
- Path: Reused from 10G (met timing with +1.8 ns slack)
- **Slack:** +1.8 ns

**GTX Timing:**
- Internal GTX timing handled by primitives (auto-generated constraints)
- TX/RX recovered clocks: 156.25 MHz per lane
- QPLL lock time: <100 μs (startup only)

**Overall:** All paths expected to meet timing with margin. MLD layer logic is relatively simple (FIFOs + muxes), not timing-critical.

---

## Implementation Phases

### Phase 1: Replicate 10GBASE-R Components (1-2 weeks)

**Tasks:**
1. Create 40GBASE-R4 top-level hierarchy
2. Instantiate 4× encoders (copy from Project 33)
3. Instantiate 4× decoders (copy from Project 33)
4. Instantiate 4× scramblers (copy from Project 33)
5. Instantiate 4× descramblers (copy from Project 33)
6. Instantiate 4× block sync FSMs (copy from Project 33)
7. Configure GTX quad (4× GTXE2_CHANNEL + 1× GTXE2_COMMON)

**Verification:**
- Simulate each lane independently
- Verify 10G loopback per lane (4 separate tests)
- Confirm QPLL lock and TX/RX clocks

### Phase 2: Multi-Lane Distribution Layer (2-3 weeks)

**Tasks:**
1. **Lane Alignment (TX):**
   - Implement block counter (0-16,382)
   - Implement marker insertion logic
   - Create marker ROM (4 lane-specific patterns)
   
2. **Lane Deskew (RX):**
   - Implement marker detection FSM (per lane)
   - Create 32-deep FIFO per lane (BRAM-based)
   - Implement alignment controller
   - Calculate inter-lane skew compensation
   
3. **Virtual Lane Mapping:**
   - TX: 256-bit XGMII → 4× 64-bit lanes (simple demux)
   - RX: 4× 64-bit lanes → 256-bit XGMII (simple mux)

**Verification:**
- Simulate marker insertion/detection
- Test deskew with artificial skew injection
- Verify 256-bit XGMII reconstruction

### Phase 3: Integration & Timing Closure (1-2 weeks)

**Tasks:**
1. Integrate all components (TX path: XGMII → Lanes; RX path: Lanes → XGMII)
2. Add top-level constraints (XDC)
3. Synthesis and timing analysis
4. Fix any timing violations (pipeline if needed)
5. Generate bitstream

**Verification:**
- Internal loopback test (FPGA TX → FPGA RX without QSFP+)
- ILA probes on critical signals
- Verify 40G aggregate throughput

### Phase 4: Hardware Validation (1 week - requires 40G equipment)

**Prerequisites:**
- 40GbE switch with QSFP+ ports
- QSFP+ loopback module
- Kintex-7 board with QSFP+ cage (AX7325B)

**Test Procedure:**
1. **Link Bring-Up:**
   - Program bitstream
   - Verify QPLL lock
   - Verify all 4 GTX lanes TXRESETDONE/RXRESETDONE
   - Verify block lock on all 4 lanes
   
2. **Alignment Validation:**
   - Monitor lanes_aligned signal (should go high within 100 μs)
   - ILA capture of alignment markers on all lanes
   - Verify deskew FIFO depths stabilize
   
3. **Traffic Testing:**
   - Send test patterns at 40 Gbps aggregate
   - Verify data integrity (loopback or switch reflection)
   - Measure BER (target: <10^-12)
   
4. **Performance Measurement:**
   - Latency: TX XGMII → RX XGMII (expected: ~0.3-0.5 μs including deskew)
   - Throughput: Verify 40 Gbps sustained (39.81 Gbps line rate)

---

## Testing Requirements

### Hardware

**Minimum Configuration:**
- ALINX AX7325B board (Kintex-7 XC7K325T with QSFP+ cage)
- 40GBASE-SR4 QSFP+ transceiver
- 40G switch with QSFP+ port
- MPO/MTP fiber cable

**Alternative (Lower Cost):**
- QSFP+ loopback module
- Internal loopback without external equipment (validation limited)

### Simulation

**Testbenches Required:**
1. Per-lane 10G test (reuse from Project 33)
2. Marker insertion/detection test
3. Lane deskew with artificial skew test (0-32 block delta)
4. Virtual lane mapping test (256-bit → 4× 64-bit → 256-bit)
5. Full 40G loopback test

**Test Vectors:**
- Random data patterns
- Alignment marker sequences
- Worst-case skew scenarios (32-block differential)

---

## Expected Performance

### Latency

**TX Path:**
- XGMII input → Lane striping: ~6 ns (1 clock)
- 64B/66B encoding: ~13 ns (2 clocks)
- Scrambling: ~6 ns (1 clock)
- Marker insertion: ~6 ns (1 clock, only at marker boundary)
- GTX serialization: ~50 ns (internal)
- **Total TX:** ~80-100 ns

**RX Path:**
- GTX deserialization: ~50 ns (internal)
- Descrambling: ~6 ns (1 clock)
- Block sync: ~13 ns (2 clocks)
- 64B/66B decoding: ~13 ns (2 clocks)
- Lane deskew: ~100-200 ns (depends on skew, typically ~150 ns)
- Lane bonding: ~6 ns (1 clock)
- **Total RX:** ~200-300 ns

**Round-Trip (TX → RX):** ~300-400 ns (excluding cable/switch propagation)

**Comparison to 10GBASE-R (Project 33):**
- 10G: ~80 ns TX + ~120 ns RX = ~200 ns
- 40G: ~100 ns TX + ~250 ns RX = ~350 ns
- **Overhead:** ~150 ns due to lane deskew (expected for multi-lane)

### Throughput

**Maximum Line Rate:**
- 4 lanes × 10.3125 Gbps = 41.25 Gbps raw
- After 64B/66B overhead: 41.25 × (64/66) = **40 Gbps** effective
- Ethernet frame rate: ~59.52 Mpps (64-byte frames)

**Resource Efficiency:**
- 20K LUTs for 40 Gbps = **2 Mbps per LUT**
- Compare to vendor IP: Unknown (proprietary), likely similar

---

## Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Architecture Design** |  Complete | This document |
| **10G Building Blocks** |  Validated | Projects 33-34 hardware-verified |
| **MLD Layer Design** |  Complete | Documented above |
| **VHDL Implementation** |  Not Started | Awaiting test equipment |
| **Simulation** | Not Started | Awaiting implementation |
| **Hardware Validation** |  Blocked | Requires $600+ in 40G test equipment |

**Blocker:** 40GBASE-R4 validation requires a 40 Gigabit Ethernet switch with QSFP+ ports. Current cost for used equipment: ~$500-600 (switch) + ~$100 (transceiver/cable).

**Decision:** Design is completed and documented. Implementation deferred until test equipment is available or a specific use case justifies the investment.

---

## References

### IEEE Standards

- **IEEE 802.3ba-2010:** 40 Gb/s and 100 Gb/s Ethernet (Clause 82: Multi-Lane Distribution)
- **IEEE 802.3-2018:** Ethernet Standard (Clause 49: 64B/66B Physical Coding Sublayer)

### Related Projects

- **Project 33:** Custom 10GBASE-R PHY (validated with 30K+ frames)
- **Project 34:** Multi-protocol ITCH parser (NASDAQ + ASX over 10GbE)

### External Resources

- Xilinx UG476: 7 Series FPGAs GTX/GTH Transceivers User Guide
- Xilinx PG047: 10G/25G Ethernet Subsystem (vendor IP reference for comparison)

---

## Future Work

### Potential Extensions

**1. 100GBASE-R4 (100 Gigabit Ethernet):**
- Uses same architecture as 40GBASE-R4
- 4 lanes @ 25.78125 Gbps each (requires GTH transceivers, not GTX)
- Kintex-7 does not support 25G; would need UltraScale+ FPGA

**2. Forward Error Correction (FEC):**
- IEEE 802.3 Clause 74 (Reed-Solomon FEC)
- Improves BER in noisy environments
- Adds ~100-200 ns latency

**3. Energy Efficient Ethernet (EEE):**
- IEEE 802.3az Low Power Idle (LPI) support
- Reduces power during idle periods
- Not critical for trading systems (always active)

**4. Jumbo Frames:**
- Support for >1500 byte MTU
- Requires XGMII layer modifications
- Useful for bulk data transfer scenarios

---

## Conclusion

The 40GBASE-R4 design leverages the validated 10GBASE-R implementation from Projects 33-34, replicating core components across four parallel lanes and adding a Multi-Lane Distribution (MLD) layer for alignment and bonding.

**Key Advantages:**
- Reuses proven 10G building blocks (64B/66B, scrambler, block sync)
- Minimal new logic (MLD layer only)
- Excellent resource efficiency (~10% LUT utilization on Kintex-7)
- Clean architecture suitable for further scaling (100G, 400G)

**Implementation Effort:** Estimated 4-6 weeks for a single engineer with FPGA experience, I may get it done in 16 weeks as I'm learning. :-) 

**Validation Requirement:** 40G switch and QSFP+ test equipment (~$600 investment).

This design is ready for implementation when test equipment becomes available or a specific application demands 40 Gigabit Ethernet capability.

---

**End of Document**

For questions or implementation assistance, contact: github.com/adilsondias-engineer
