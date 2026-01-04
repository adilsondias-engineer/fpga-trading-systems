# FPGA Development - Lessons Learned

Critical insights from FPGA development for trading systems. This document includes both a **Quick Reference** (organized by category) and **Detailed Project History** (chronological, in-depth).

---

## Quick Reference by Category

### VHDL Language Gotchas

**1. `with...select` - Single Signal Only**
```vhdl
-- WRONG: Cannot use 'and' in when clause
with mode select led <= nibble when MODE_UDP and counter = 0,

-- RIGHT: Use intermediate signal
with counter select temp <= nibble_data(15 downto 12) when 0,
with mode select led <= temp when MODE_UDP,
```
**Lesson:** VHDL `with...select` limited to one signal. Use intermediate signals for complex logic.

**2. Signal Assignment Timing**
- All assignments take effect on **next** clock edge
- Transitioning to IDLE with old state values can cause spurious errors
- **Lesson:** Explicitly clear ALL state variables when entering new states

**3. Xilinx Primitive Generic Types**
```vhdl
-- WRONG: STARTUP_WAIT => FALSE
-- RIGHT: STARTUP_WAIT => "FALSE"  -- String literal required
```
**Lesson:** Xilinx primitives require string literals for parameters (check UG953)

### Hardware & Timing

**4. Power-Up Initialization Glitches**
- Combinational error signals assert when registers initialize to '0'
- **Fix:** Gate error detection with `initialized` flag set after first reset
- **Lesson:** Always protect error latches from power-up glitches

**5. Human-Visible Timing**
- Hardware events: 10ns (1 clock @ 100MHz)
- Human eye persistence: 100ms
- **Ratio: 10,000,000× too fast!**
- **Fix:** Pulse stretcher with 100ms-1sec timer
- **Lesson:** Use pulse stretchers for visual indicators

**6. MII Preamble Stripping**
- MII PHY sends preamble (7×0x55) + SFD (0xD5) before frame
- MAC parser must detect SFD and skip preamble
- **Lesson:** PHY interface behavior varies (MII vs RGMII). Check IEEE 802.3 spec.

**7. MII Byte Timing (Off-by-One Errors)**
```vhdl
-- MII outputs bytes every 2 clock cycles (12.5 MHz byte rate)
-- Type byte remains visible for 1 extra cycle on state transition
-- WRONG: Process on even counters (0,2,4,6)
-- RIGHT: Process on ODD counters (1,3,5,7)
if byte_counter >= 1 and (byte_counter mod 2) = 1 then
    -- Process data bytes (skips repeated type byte)
end if
```
**Lesson:** State transitions don't align with byte boundaries. Formula: Physical byte N → byte_counter = 2*N - 1

### Debug Strategies

**8. Testbench Timing for Transient Signals**
```vhdl
-- WRONG: Check at fixed time (pulse might be gone)
wait for 390 ns;
assert udp_valid = '1';

-- RIGHT: Actively monitor and capture
for i in 0 to 20 loop
    wait for CLK_PERIOD;
    if udp_valid = '1' then
        valid_captured := '1';  -- Capture occurrence
        port_captured := udp_dst_port;  -- Sample data
    end if;
end loop;
assert valid_captured = '1';
```
**Lesson:** Actively monitor for transient pulses, don't just check at fixed time

**9. Waveform Analysis Essential**
- Transcript shows "what failed"
- Waveforms show "why it failed" and **when**
- **Lesson:** Always generate waveforms for failing tests

**10. Synthesis Warnings Judgment**
- "Unused register removed" → Check if intentional vs broken
- "Unconnected port" → Likely real issue if port should be used
- **Lesson:** Review all warnings, verify functionality, check timing

### Design Patterns

**11. State Machine for Protocols**
```vhdl
type state_type is (IDLE, PREAMBLE, HEADER, VALIDATE, PAYLOAD);
```
Benefits: Clear structure, easy to extend, self-documenting

**12. Clock Domain Crossing Checklist**
1. Identify all signals crossing boundary
2. Single-bit → 2FF synchronizer
3. Multi-bit → Sample on valid pulse
4. Add XDC timing constraints (ASYNC_REG, set_false_path)
**Lesson:** Systematically synchronize EVERY signal (don't forget status/error signals!)

**13. Error Detection with Pulse Stretcher**
1. Detect brief error pulse (1 cycle)
2. Set timer (e.g., 50M clocks = 0.5 sec)
3. Keep LED ON while timer > 0
4. New errors restart timer
**Lesson:** Makes transient hardware events visible to operators

**14. SPI Protocol Implementation - Pipeline Timing (Project 19)**
```vhdl
-- Problem: Sequential register access creates 2-cycle delay
-- addr_byte updated → reg_addr calculated → register read → data_rd valid

when SEND_DATA =>
    if bit_count = 0 then
        -- Cycle 0: Wait for addr_byte propagation
        bit_count <= 1;
    elsif bit_count = 1 then
        -- Cycle 1: data_rd now valid, load shift register
        data_shift <= data_rd;
        bit_count <= 2;
    elsif bit_count >= 2 then
        -- Shift phase begins
```
**Symptom:** Testbench reading 0x00000000 instead of 0x00000001 from register 0x00
**Root Cause:** `data_rd` not ready when `data_shift` loaded (2-cycle register fetch pipeline)
**Solution:** Restructure SEND_DATA state into setup phase (bit_count 0→1→2) before shift phase
**Lesson:** When crossing abstraction boundaries (protocol ↔ memory), account for pipeline delays explicitly in state machine

**15. SPI Address Byte Trailing Edge (Project 19)**
```vhdl
-- Problem: SPI Mode 0 falling edge immediately after address byte causes premature shift

elsif bit_count = 2 then
    if spi_sck_falling = '1' then
        -- Skip address byte's trailing falling edge
        bit_count <= 3;
    end if;
elsif bit_count >= 3 then
    if spi_sck_falling = '1' then
        -- Now shift data on falling edge (MSB first)
        data_shift <= data_shift(30 downto 0) & '0';
```
**Symptom:** PY32 reading doubled values (2,4,6,8) instead of correct sequence (1,2,3,4)
**Root Cause:** Responding to falling edge immediately after address byte shifts MSB prematurely
**Solution:** Add explicit bit_count=2 check to skip first falling edge after address byte
**Lesson:** SPI protocol timing is subtle—transitions between command/address/data phases need explicit edge skipping

**16. Modular SPI Architecture (Project 19)**
```
spi_slave_core.vhd       ← Generic SPI Mode 0 protocol (reusable)
    ↓
spi_register_if.vhd      ← Application-specific register mapping
    ↓
spi_slave.vhd            ← Backward compatibility wrapper
```
**Design Decision:** Three-layer architecture instead of monolithic SPI slave
**Benefits:**
- **Reusability:** spi_slave_core works with any register map (6 registers today, 256 registers tomorrow)
- **Testability:** Each layer tested independently (protocol, register mapping, integration)
- **Maintainability:** Register changes don't require touching low-level SPI protocol logic
**Trade-off:** Slightly more complex hierarchy, but 10× easier to debug and extend
**Lesson:** Layered architecture investment pays off immediately when debugging complex timing issues

**17. Big-Endian vs Little-Endian for SPI (Project 19)**
**Decision:** Transmit 32-bit data MSB first (big-endian) over SPI
**Rationale:**
- **Network standard:** Matches UDP/IP network byte order (Project 13)
- **Consistency:** Same byte order across UART debug (Project 8) and UDP BBO (Project 13)
- **Implementation:** FPGA shifts left (MSB out), PY32 receives MSB first and reconstructs
**Lesson:** Choose byte order based on system integration, not individual module convenience

**18. Reset Synchronization for CDC (Project 20)**
**Problem:** TX path not transmitting packets despite valid data
**Root Cause:** Combinatorial CDC violation
```vhdl
-- WRONG: Combinatorial logic crossing clock domains
reset_tx <= reset or (not tx_pll_locked);
```
**Solution:** 2-stage synchronizer with ASYNC_REG attributes
```vhdl
signal reset_tx_sync1 : STD_LOGIC := '1';
signal reset_tx_sync2 : STD_LOGIC := '1';
attribute ASYNC_REG : string;
attribute ASYNC_REG of reset_tx_sync1 : signal is "TRUE";
attribute ASYNC_REG of reset_tx_sync2 : signal is "TRUE";

process(clk_txd)
begin
    if rising_edge(clk_txd) then
        reset_tx_sync1 <= reset or (not tx_pll_locked);
        reset_tx_sync2 <= reset_tx_sync1;
        reset_tx <= reset_tx_sync2;
    end if;
end process;
```
**Lesson:** All signals crossing clock domains require synchronization. Combinatorial expressions cannot cross CDC boundaries safely.

**19. RGMII TX Clock Phase Shift (Project 20)**
**Requirement:** RGMII specification requires 90° phase shift on TX clock relative to TX data
**Implementation:**
- MMCM generates dual clocks: 125 MHz @ 0° (TXD) + 125 MHz @ 90° (TXC)
- 0° clock drives ODDR for TXD and TXCTL
- 90° clock drives ODDR for TXC output
**Why:** 2ns delay (90° of 8ns period) provides proper setup/hold time at PHY
**Lesson:** RGMII timing compliance requires careful clock phase management via MMCM

**20. DDR Output via ODDR Primitives (Project 20)**
**RGMII uses DDR signaling:** 4-bit data at 125 MHz = 8 bits per clock = 1 Gbps
**Implementation:**
```vhdl
ODDR_TXD: ODDR
    generic map (DDR_CLK_EDGE => "SAME_EDGE")
    port map (
        C => clk_125mhz,
        CE => '1',
        D1 => tx_data(3 downto 0),  -- Rising edge
        D2 => tx_data(7 downto 4),  -- Falling edge
        Q => rgmii_txd
    );
```
**Lesson:** Gigabit Ethernet RGMII requires DDR primitives. Cannot use simple signal assignments for 1 Gbps throughput.

**21. Hardware CRC32 for Ethernet FCS (Project 20)**
**Requirement:** Ethernet frames require 32-bit CRC (FCS) appended to payload
**Implementation:**
- Calculate CRC32 as each byte transmits (running calculation)
- Output inverted, bit-reversed CRC after payload completes
- Polynomial: 0x04C11DB7 (IEEE 802.3 standard)
**Validation:** Wireshark confirms "Frame check sequence: [correct]"
**Lesson:** Ethernet FCS is inverted and bit-reversed. Standard CRC32 algorithms need post-processing.

**22. Spread Data Path Through FIFO (Project 20)**
**Issue:** Spread value not appearing in UDP packets
**Root Cause:** Incomplete data path
- order_book calculated spread but trading_top didn't export it
- FIFO packing didn't include spread field
- ethernet_top spread input was unconnected
**Fix:** Trace complete data path from source to destination:
1. Add `bbo_spread` output port to trading_top
2. Update FIFO packing to include spread in bits [63:32]
3. Connect spread through all intermediate components
**Lesson:** When adding new fields, trace the complete data path through all FIFOs and hierarchies

### Development Workflow

**23. Documentation First**
- **Mistake:** Coded RGMII interface without reading docs (wasted 4 hours)
- **Correct:** 30 min reading Arty A7 manual → found MII interface
- **Savings:** 3.5 hours
- **Lesson:** Read hardware docs before coding

**24. Incremental Integration**
- Phase 1A: MII + MAC → Verify
- Phase 1D: + IP → Verify
- Phase 1F: + UDP → Verify
- **Anti-pattern:** Build entire stack, debug all layers at once
- **Lesson:** Verify each layer before adding next

**25. Component Interface Management**
- **Solutions:**
  - Direct entity instantiation (recommended - single source of truth)
  - Auto-generate component from entity
  - Avoid manual component declarations
- **Lesson:** Use direct `entity work.module` instantiation

### Software Performance Optimization

**26. Real-Time Scheduling vs Multi-Core Isolation (Project 14)**
- **Experiment:** Compared SCHED_FIFO RT scheduling vs CFS with CPU isolation
- **Hardware:** AMD Ryzen AI 9 365 (10 cores, 20 threads)
- **Workload:** ~400 UDP BBO messages/sec
- **Results:**
  - **CFS + taskset -c 2-5:** 0.51 µs avg, 0.16 µs P50 (OPTIMAL)
  - **SCHED_FIFO + CPU pinning:** 0.64-0.93 µs avg (variable performance)
- **Key Finding:** For moderate workload (~400 msg/sec), CFS scheduler with 4 isolated cores outperforms rigid RT pinning
- **CPU Isolation Setup (GRUB):**
  ```bash
  isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5
  ```
- **Lesson:** RT scheduling isn't always optimal. Multi-core isolation with CFS can provide better performance for workloads with moderate variability. Profile both approaches.

**27. Database Query Optimization - Cursor Selection**
- **Problem:** Python script processing MySQL data at 40 msg/sec (expected 400 msg/sec), using only 1% CPU
- **Root Cause:** Server-side cursor (SSCursor) fetching rows one-by-one → 8,000+ network round-trips
- **Solution:**
  - Remove SSCursor (use default client-side cursor)
  - Use `fetchall()` for bulk fetch
  - Optimize heap construction: `heapify()` O(n) vs `heappush()` loop O(n log n)
- **Expected Result:** 10× speedup (40 → 400 msg/sec)
- **Lesson:** Network-bound operations disguise as low CPU usage. Client-side cursors for bulk queries, server-side only for streaming large result sets.

**28. Binary Protocols vs ASCII/Hex (Projects 9 vs 14)**
- **ASCII/Hex (Project 9 UART):** 10.67 µs avg parse latency, hex-to-decimal conversion overhead
- **Binary (Project 14 UDP):** 2.09 µs avg parse latency (5.1× faster)
- **Additional Benefits:**
  - Smaller packet size (256 bytes fixed vs variable ASCII)
  - No string parsing, direct memory access
  - Deterministic parsing time
- **Lesson:** Binary protocols critical for low-latency systems. ASCII/hex suitable for debugging, not production.

**29. Interface Selection Impact (UART vs UDP)**
- **UART @ 115200 baud (Project 9):**
  - Throughput: ~96 BBO msg/sec
  - Latency: 10.67 µs avg (gateway parsing)
  - Bottleneck: Serial bandwidth
- **UDP @ 100 Mbps (Project 14):**
  - Throughput: ~400 BBO msg/sec sustained
  - Latency: 0.20 µs avg (gateway parsing) - **53× faster**
  - No bandwidth bottleneck for this workload
- **Improvement:** 53× parsing, 21× E2E latency reduction
- **Lesson:** Interface choice dominates system performance. UART acceptable for debugging, UDP/Ethernet essential for production trading systems.

**30. Scapy Performance on Linux (Testing Tools)**
- **Problem:** Scapy's `sendp()` for raw Ethernet frames extremely slow on Linux (~100-200 pkt/sec)
- **Root Cause:** Raw socket overhead, kernel path for Layer 2 sending
- **Solution:** Use native UDP sockets instead
  ```python
  # Slow (Scapy)
  sendp(Ether()/IP()/UDP()/Raw(payload), iface='eth0')  # ~100 pkt/sec

  # Fast (Native Socket)
  sock.sendto(payload, (ip, port))  # 10,000+ pkt/sec
  ```
- **Impact:** 100× throughput improvement for test scripts
- **Lesson:** Scapy excellent for packet inspection/analysis, but use native sockets for high-throughput testing.

**31. Mock Test Data Generators (Testing Without Hardware)**
- **Challenge:** Testing Project 14 (UDP gateway) requires FPGA sending BBO packets
- **Solution:** Created `mock_bbo_sender.py` to simulate FPGA UDP output
  - Sends 256-byte binary BBO packets matching Project 13 format
  - Configurable rate (100 Hz, 400 Hz, 1000 Hz, or max speed)
  - Enables software-only testing without FPGA hardware
- **Benefits:**
  - Rapid iteration during development
  - Consistent test load for benchmarking
  - No hardware dependency for CI/CD
- **Example:** 10,000 packets @ 400 Hz for Project 14 validation
- **Lesson:** Mock data generators critical for validating parsing/processing logic independently from hardware. Enables faster development cycles and reproducible testing.

---

## Detailed Project History

### What I Learned so far
#### FPGA Development Workflow

- Complete design -> simulation -> synthesis -> implementation -> hardware verification cycle
- Importance of setting correct top module for synthesis vs simulation (different "tops" for different purposes)
- Synthesis is for actual hardware designs only - testbenches cannot be synthesized
- Flash programming for autonomous boot on power-up
- Hardware verification is essential - testbenches complement but don't replace real testing

### Testbench Development

- Procedure placement: VHDL procedures must be declared in architecture declarative region (between architecture and begin), NOT inside processes
- Procedures declared in architecture can only be CALLED from processes, not DEFINED in them
- Self-checking testbenches with assert statements are more effective than manual waveform inspection
- Use shortened timing parameters (Generic mapping) for fast simulation vs hardware-accurate timing
- Reusable test procedures for common operations (encoder rotation, button presses)
- Test boundary conditions rather than exhaustive testing (test 0, 255, midpoint instead of all 256 values)

### Waveform Debugging Techniques

- Monitor multiple signals simultaneously to track data flow
- Use $monitor in testbenches for automatic change logging
- Identify metastability in waveforms (X or unknown states)
- Trace signal propagation through synchronizer chains
- Correlate simulation waveforms with hardware behavior

### Constraint Files (XDC)

- Single signal syntax: [get_ports signal_name]
- Vector syntax: [get_ports {vector_name[*]}] for all bits
- Individual vector bits: [get_ports {vector_name[0]}]
- Clock constraints with create_clock for timing analysis
- Pin mapping updates when changing physical connections (rotary encoder rewiring)

### Digital Design Fundamentals
#### Synchronous vs Asynchronous Reset

- Synchronous reset checked only on clock edge (safer for timing)
- Asynchronous reset responds immediately (better for emergency stops)
- Trade-off: timing closure vs responsiveness
- Most modern designs prefer synchronous reset

### Clock Domain Crossing (CDC)

- Critical: All asynchronous inputs MUST go through synchronizers
- Three-stage synchronizer is industry standard for metastability protection
- MTBF (Mean Time Between Failures) calculation depends on synchronizer stages
- CDC bugs can cause random, hard-to-reproduce failures in production

### Edge Detection

- Bug discovered: Order matters in sequential logic
- Must detect edge BEFORE updating previous state storage
- Ambiguous evaluation order can cause missed edges
- Correct pattern: read -> compare -> update

### Generic Parameters

- Design flexibility through configurable parameters
- DEBOUNCE_TIME for adjustable filtering periods
- FIFO_DEPTH for scalable buffer sizes
- Different values for simulation (fast) vs hardware (accurate)
- Enables IP reuse across different projects

### Component Design Patterns
#### Debouncing

- Mechanical switches bounce for 5-50ms typically
- 20ms debounce period filters all mechanical noise
- Counter-based implementation more reliable than sampling
- Must reset counter on any state change

### FIFO Buffers

- Circular buffer implementation with read/write pointers
- Full/empty flag generation from pointer comparison
- Careful handling of wrap-around conditions
- Synchronous read/write for predictable timing
- Critical for data flow control in streaming systems

### Rotary Encoder Decoding

- Quadrature encoding provides direction information
- Gray code sequence: only one bit changes at a time
- State machine decodes rotation direction
- Debouncing still required for mechanical encoders
- Edge detection on final stable state

### Bug Fixes During Development
#### Synthesis Attempting Testbench (Project 1)

- Error: [Synth 8-27] non-clocking wait statement not supported
- Cause: Testbench added to Design Sources instead of Simulation Sources
- Fix: Set design module as synthesis top, not testbench
- Lesson: Vivado's file organization matters - wrong placement causes cryptic errors

#### VHDL Procedure Syntax Errors (Project 4 Testbench)

- Error: syntax error near procedure and type error near ms
- Cause: Procedures defined inside process instead of architecture
- Fix: Move procedure declarations to architecture declarative region
- Lesson: VHDL has strict scoping rules for procedures

#### Edge Detection Timing (Project 2)

- Issue: LED toggle inconsistent, missed button presses
- Cause: Previous state updated before edge check
- Fix: Reorder to check edge first, then update state
- Lesson: Sequential statement order is critical in processes

#### Testbench Timing Failures (Project 2)

- Issue: Assertions failing despite correct logic
- Cause: Insufficient wait time after button release
- Fix: Increased wait times from 500ns to 5μs
- Lesson: Debouncer needs time to stabilize after input changes

### Hardware Integration Insights

- ChipKit headers provide flexible I/O expansion on Arty A7
- Pull-up resistors often needed for mechanical switches/encoders
- Breadboard connections can be unreliable - check continuity
- Color-coded wiring prevents confusion (red=power, black=ground, etc.)
- Current limiting resistors essential for LEDs (220Ω typical)

### Performance & Timing

- 100MHz system clock = 10ns period
- Timing closure becomes critical at high frequencies
- Setup/hold time violations cause intermittent failures
- Pipelining trades latency for throughput
- Register everything at module boundaries

### Vivado Tool Insights

- Behavioral simulation faster than post-implementation
- Synthesis optimizes away unused logic (can hide bugs)
- Implementation may fail even if synthesis succeeds (placement/routing)
- Critical warnings often indicate real problems
- ILA (Integrated Logic Analyzer) cores enable hardware debugging

### Documentation Best Practices

- Document bugs and fixes - shows learning mindset
- Include waveform screenshots with annotations
- Explain WHY not just WHAT in comments
- Create README with clear project structure
- Add interview talking points for portfolio projects

### Trading System Relevance

- FIFOs essential for packet buffering in network interfaces
- Metastability protection critical for asynchronous market data
- Low latency requires minimal logic levels
- Deterministic timing more important than average case
- Hardware timestamps need synchronized clocks
- Backpressure handling through full/empty flags

###  Key Conceptual Breakthroughs

- "You simulate signals, not physics" - Don't model LED photons or button mechanics
- "Synthesis is for hardware, simulation is for testing" - Testbenches are not synthesizable
- "Every async input is a potential failure point" - Never skip synchronizers
- "Edge detection is a pattern, not a primitive" - Must implement carefully
- "Timing is everything" - One clock cycle can make or break functionality
- "Signal assignments take effect NEXT clock cycle" - Reading immediately after assignment gives old value
- "Multiple processes see the same old values" - Cannot solve race conditions with flags between processes
- "One state machine is better than two" - Unified state machine eliminates inter-process race conditions

---

## Project 05: UART Transmitter with Binary Protocol

### VHDL Timing & Multi-Process Race Conditions

**Critical Discovery:** The most important lesson from this project - understanding VHDL signal timing and why multiple processes can't coordinate via flags.

#### Signal Assignment Timing
- Signal assignments in VHDL take effect at the **END** of the clock cycle
- Reading a signal immediately after assigning it returns the **old value**
- This is fundamental to how VHDL synchronous logic works
- Example:
  ```vhdl
  process(clk)
  begin
      if rising_edge(clk) then
          flag <= '1';           -- Assignment scheduled
          if flag = '1' then     -- Reads OLD value (still '0')!
              -- This won't execute until NEXT cycle
          end if;
      end if;
  end process;
  ```

#### Multi-Process Race Conditions
**Problem:** Two separate processes reading the same signals on the same clock edge will **always** see identical old values.

**Example of the Bug:**
```vhdl
-- Process 1: Protocol parser
process(clk)
begin
    if rising_edge(clk) then
        if rx_valid = '1' and rx_data = START_BYTE then
            protocol_active <= '1';  -- Set flag
            -- Parse protocol...
        end if;
    end if;
end process;

-- Process 2: ASCII echo handler
process(clk)
begin
    if rising_edge(clk) then
        if rx_valid = '1' and protocol_active = '0' then  -- Reads OLD value!
            -- Still sees '0' even though Process 1 set it to '1'
            -- RACE CONDITION: Both processes handle same byte!
        end if;
    end if;
end process;
```

**Why It Fails:**
- Both processes trigger on same rising_edge(clk)
- Both see `protocol_active = '0'` (the old value)
- Both processes execute their logic
- Flag update happens at END of cycle (too late)

**Failed Fix Attempts (4 total):**
1. **Added `protocol_active` flag** - Both processes saw old '0' value
2. **Removed redundant reset** - Same race condition persisted
3. **Checked `protocol_state` directly** - State transitions have 1-cycle delay
4. **Double-check (state AND flag)** - Same fundamental timing issue

**Successful Solution:** Unified State Machine
- Merged both processes into **single process**
- Single process reads `rx_data` and routes immediately
- No inter-process communication = no race condition

```vhdl
process(clk)
begin
    if rising_edge(clk) then
        case state is
            when WAIT_RX =>
                if rx_valid = '1' then
                    -- Check and route in SAME CYCLE
                    if rx_data = START_BYTE then
                        state <= PROTO_WAIT_CMD;  -- Binary protocol
                    else
                        -- Handle as ASCII command
                        case rx_data is
                            when X"52" => -- 'R' Reset
                            when X"49" => -- 'I' Increment
                            -- ... etc
                        end case;
                    end if;
                end if;
        end case;
    end if;
end process;
```

**Why This Works:**
- Single process makes routing decision immediately
- No waiting for signal updates from another process
- `rx_data` examined directly when `rx_valid` arrives
- Correct handling guaranteed in same cycle

**Key Insight:** Architectural problem requires architectural solution. Cannot fix multi-process race conditions with flags or checks - must eliminate the multiple processes.

### Binary Protocol Design (Trading-Style)

Implemented professional binary message protocol similar to exchange protocols (FIX, ITCH, OUCH):

**Message Format:**
```
[START_BYTE][CMD][LENGTH][DATA...][CHECKSUM]
   0xAA      u8    u8      N bytes    u8
```

**Checksum Calculation:**
```
CHECKSUM = CMD ⊕ LENGTH ⊕ DATA[0] ⊕ DATA[1] ⊕ ... ⊕ DATA[N-1]
```

**Protocol State Machine:**
- `WAIT_RX` - Waiting for START_BYTE (0xAA)
- `PROTO_WAIT_CMD` - Reading command byte
- `PROTO_WAIT_LEN` - Reading length byte
- `PROTO_WAIT_DATA` - Reading N data bytes
- `PROTO_WAIT_CSUM` - Validating checksum
- `PROTO_PROCESS` - Executing validated command

**Commands Implemented:**
- `0x01` - Set counter (LENGTH=1, DATA=value)
- `0x02` - Add to counter (LENGTH=1, DATA=value)
- `0x03` - Query counter (LENGTH=0, returns 2-byte hex ASCII)
- `0x04` - Write to FIFO (LENGTH=N, DATA=bytes)
- `0x05` - Read from FIFO (LENGTH=0, transmits all queued data)

**Trading Relevance:**
- **Framing:** START_BYTE enables resynchronization after errors
- **Length-prefixed:** Variable-length messages (like market data updates)
- **Checksums:** Data integrity critical in trading (detects transmission errors)
- **Binary format:** More efficient than ASCII (bandwidth matters)
- **State machine:** Professional approach to protocol parsing

### UART Communication Best Practices

**Baud Rate Generation:**
- 100MHz clock -> 115200 baud
- Clock division: 100,000,000 / 115,200 ≈ 868 cycles per bit
- Mid-bit sampling: Sample at cycle 434 for noise immunity

**Handshake Flags:**
- `tx_busy` flag indicates transmission in progress
- `tx_started` flag for proper wait-for-start-then-complete pattern

**Correct Handshake Pattern:**
```vhdl
when ECHO_TX =>
    if tx_busy = '1' then
        tx_started <= '1';  -- Mark transmission started
    elsif tx_started = '1' and tx_busy = '0' then
        -- Transmission completed
        tx_started <= '0';
        state <= WAIT_RX;
    end if;
```

**Wrong Pattern (Bug):**
```vhdl
when ECHO_TX =>
    if tx_busy = '0' then  -- WRONG! Might read '0' before '1'
        state <= WAIT_RX;  -- Transition too early!
    end if;
```

### RGB LED Pulse Stretching

**Problem:** Brief signals invisible to human eye
- Red LED (`rx_valid`): Only 10ns @ 100MHz - invisible
- Green LED (`tx_busy`): ~87μs per byte - barely visible flash
- Blue LED (idle): Constant - always on (no indication of activity)

**Solution:** 100ms pulse stretchers
```vhdl
-- 100ms @ 100MHz = 10,000,000 cycles
constant LED_STRETCH_TIME : integer := 10_000_000;
signal led_r_stretch : integer range 0 to LED_STRETCH_TIME := 0;

process(clk)
begin
    if rising_edge(clk) then
        -- Stretch rx_valid pulse
        if rx_valid = '1' then
            led_r_stretch <= LED_STRETCH_TIME;  -- Start 100ms timer
        elsif led_r_stretch > 0 then
            led_r_stretch <= led_r_stretch - 1;  -- Count down
        end if;
    end if;
end process;

-- LED assignment
led0_r <= '1' when led_r_stretch > 0 else '0';
```

**Result:**
- Red visible for 100ms when receiving
- Green visible for 100ms when transmitting
- Blue only when truly idle (not receiving/transmitting)
- Clear visual feedback for protocol activity

### Protocol State Management Bug

**Bug:** Query command (`0x03`) only returned 1 hex digit instead of 2.

**Root Cause:** Conditional state check at end of PROTO_PROCESS state:
```vhdl
when PROTO_PROCESS =>
    case protocol_cmd is
        when X"03" =>  -- Query
            tx_data <= nibble_to_hex(value_counter(7 downto 4));
            tx_start <= '1';
            state <= ECHO_TX;  -- Set state to send both digits
        -- ... other commands
    end case;

    -- WRONG: This always executes because state still = PROTO_PROCESS!
    if state = PROTO_PROCESS then
        state <= WAIT_RX;  -- Overwrites the ECHO_TX above!
    end if;
```

**Why It Failed:**
- `state` still holds old value `PROTO_PROCESS` during same cycle
- Condition `state = PROTO_PROCESS` always TRUE
- Overwrites the `state <= ECHO_TX` assignment
- Query command skips sending second hex digit

**Fix:** Explicit state transitions for each command branch
```vhdl
when PROTO_PROCESS =>
    protocol_data_buffer <= (others => '0');  -- Clear buffer

    case protocol_cmd is
        when X"01" =>  -- Set counter
            value_counter <= unsigned(protocol_data_buffer(7 downto 0));
            state <= WAIT_RX;  -- Explicit transition

        when X"03" =>  -- Query counter
            tx_data <= nibble_to_hex(value_counter(7 downto 4));
            tx_start <= '1';
            state <= ECHO_TX;  -- Explicit transition - not overwritten!

        when others =>
            state <= WAIT_RX;
    end case;
```

### Python Test Automation

**Created automated test script** for protocol validation:
```python
import serial

ser = serial.Serial('COM7', 115200)

# Set counter to 0x10
msg = bytes([0xAA, 0x01, 0x01, 0x10, 0x10])
ser.write(msg)

# Query counter (should return "10")
msg = bytes([0xAA, 0x03, 0x00, 0x03])
ser.write(msg)
response = ser.read(2)

if response == b'10':
    print("PASS")
else:
    print(f"FAIL - Got {response}")
```

**Benefits:**
- Faster than manual testing
- Repeatable test cases
- Clear pass/fail criteria
- Regression testing capability
- Validates checksum calculation
- Tests multiple commands in sequence

### Hex Output Conversion

**Implemented nibble-to-ASCII conversion function:**
```vhdl
function nibble_to_hex(nibble : std_logic_vector(3 downto 0))
    return std_logic_vector is
begin
    case nibble is
        when X"0" => return X"30";  -- '0'
        when X"1" => return X"31";  -- '1'
        when X"2" => return X"32";  -- '2'
        -- ... X"3" through X"9"
        when X"A" => return X"41";  -- 'A'
        when X"B" => return X"42";  -- 'B'
        -- ... through X"F" = X"46" ('F')
    end case;
end function;
```

**Usage:**
```vhdl
-- Send high nibble of value_counter as ASCII hex
tx_data <= nibble_to_hex(value_counter(7 downto 4));

-- Example: value_counter = 0x5A
-- High nibble (7 downto 4) = 0x5
-- nibble_to_hex(0x5) = 0x35 = ASCII '5'
-- Low nibble (3 downto 0) = 0xA
-- nibble_to_hex(0xA) = 0x41 = ASCII 'A'
-- Result: "5A" sent to terminal
```

### Multi-Protocol Support

**Designed system to handle two protocols simultaneously:**
1. **Binary Protocol** (efficient, production-style)
   - START_BYTE detection (0xAA)
   - Length-prefixed messages
   - Checksum validation
   - Commands: Set, Add, Query, FIFO operations

2. **ASCII Protocol** (human-readable, debugging)
   - Single-character commands
   - 'R' = Reset, 'I' = Increment, 'D' = Decrement
   - 'Q' = Query (returns hex), 'S' = Status, 'G' = Get FIFO

**Routing Logic:**
```vhdl
if rx_data = START_BYTE then
    state <= PROTO_WAIT_CMD;  -- Binary protocol path
else
    case rx_data is          -- ASCII command path
        when X"52" => -- 'R'
        when X"49" => -- 'I'
        -- ... etc
    end case;
end if;
```

**Benefits:**
- Production binary protocol for efficiency
- ASCII fallback for debugging
- Educational: shows both approaches
- Mirrors real systems (control plane ASCII, data plane binary)

---

## Project 06: UDP Packet Parser - MII Ethernet Receiver

### Critical Lesson: Documentation BEFORE Implementation

**Major Mistake:** Initially implemented RGMII interface when hardware requires MII.

**Time Wasted:** 4+ hours implementing wrong interface
- 2 hours RGMII implementation
- 1.5 hours debugging
- 15 minutes identifying root cause

**Root Cause:** Insufficient hardware verification before implementation

**What Should Have Been Done:**
1. Read Arty A7 Reference Manual (Section 6: Ethernet PHY)
2. Check PHY part number (DP83848J datasheet)
3. Verify interface type (MII, not RGMII)
4. Review master XDC for pin assignments
5. THEN begin implementation

**Lesson Learned:** **Documentation -> Planning -> Coding**
- 30 minutes of documentation review prevents hours of wasted implementation
- Hardware specifications are non-negotiable - software assumptions don't apply
- Always verify PHY capabilities before selecting interface protocol

### MII vs RGMII Comparison

**Key Differences:**

| Specification    | MII (Required)      | RGMII (Wrong)       |
| ---------------- | ------------------- | ------------------- |
| Speed            | 10/100 Mbps         | 1000 Mbps           |
| Data Width       | 4-bit               | 4-bit               |
| Data Rate        | SDR (rising edge)   | DDR (both edges)    |
| Clock Frequency  | 25 MHz / 2.5 MHz    | 125 MHz             |
| Clock Source     | PHY -> FPGA         | FPGA -> PHY         |
| Reference Clock  | FPGA -> PHY         | None                |
| Pin Count        | ~18 signals         | ~12 signals         |
| Compatible PHY   | DP83848J            | RTL8211E, etc.      |

**Arty A7 Hardware:**
- PHY: Texas Instruments DP83848J
- Interface: MII only (10/100 Mbps)
- No RGMII support

### MII Interface Implementation

**Clock Architecture (Critical Understanding):**

```
FPGA generates:  25 MHz -> eth_ref_clk -> PHY X1 pin (reference clock)

PHY generates:   25 MHz -> eth_rx_clk -> FPGA (RX data sampling clock)
                 25 MHz -> eth_tx_clk -> FPGA (TX data clocking)
```

**This is OPPOSITE of RGMII!**
- RGMII: FPGA drives TX_CLK and RX_CLK
- MII: PHY provides both data clocks, FPGA provides reference

### PLL/MMCM Clock Generation

**Challenge:** Generate 25 MHz reference clock from 100 MHz system clock

**Solution:** PLLE2_BASE primitive (Xilinx 7-Series)

```vhdl
PLLE2_BASE
    generic map (
        CLKFBOUT_MULT   => 8,        -- 100 MHz * 8 = 800 MHz (VCO)
        CLKOUT0_DIVIDE  => 32,       -- 800 MHz / 32 = 25 MHz
        CLKIN1_PERIOD   => 10.0,     -- 100 MHz input (10ns period)
        DIVCLK_DIVIDE   => 1,
        STARTUP_WAIT    => "FALSE"   -- STRING literal, not boolean!
    )
    port map (
        CLKIN1   => CLK,             -- 100 MHz system clock
        CLKFBOUT => clkfb,
        CLKFBIN  => clkfb,
        CLKOUT0  => eth_ref_clk_unbuf,
        LOCKED   => pll_locked,
        PWRDWN   => '0',
        RST      => '0'
    );
```

**Critical Bug - Xilinx Primitive Parameters:**
- **WRONG:** `STARTUP_WAIT => FALSE` (boolean)
- **CORRECT:** `STARTUP_WAIT => "FALSE"` (string literal)
- Error: "type error near false; current type boolean; expected type string"
- **Lesson:** Xilinx primitives require STRING LITERALS for generic parameters
- Always check UG953 (Vivado 7 Series Libraries Guide)

### PHY Reset Timing

**DP83848J Datasheet Requirement:** Minimum 10ms reset pulse

**Implementation:**
```vhdl
-- Counter for 20ms @ 100MHz = 2,000,000 cycles
signal reset_counter : unsigned(23 downto 0) := (others => '0');

process(clk_100mhz)
begin
    if rising_edge(clk_100mhz) then
        if btn_reset = '1' then
            reset_counter <= (others => '0');
            reset_sync <= '1';
        elsif reset_counter < 2_000_000 then
            reset_counter <= reset_counter + 1;
            reset_sync <= '1';
        else
            reset_sync <= '0';
        end if;
    end if;
end process;

eth_rst_n <= not reset_sync;  -- PHY reset is active LOW
```

**Lesson:**
- Add safety margin (20ms when 10ms required)
- Use counter at known frequency for accurate timing
- Improper reset prevents PHY link establishment
- PHY won't function without proper reset sequence

### Preamble/SFD Stripping (Critical for MII)

**Problem:** MII receiver passes preamble bytes to FPGA

**Ethernet Frame Structure:**
```
Preamble (7 bytes): 0x55 0x55 0x55 0x55 0x55 0x55 0x55
SFD (1 byte):       0xD5 (Start Frame Delimiter)
Dest MAC (6 bytes): 0x00 0x0A 0x35 0x02 0xAF 0x9A
Src MAC (6 bytes):  ...
Type (2 bytes):     0x08 0x00 (IPv4)
Payload:            ...
FCS (4 bytes):      Frame Check Sequence
```

**Bug:** MAC parser expected destination MAC as first byte, but received preamble

**Symptom:** LEDs stuck at 0000 despite link established and frames transmitted

**Root Cause Analysis:**
1. Wireshark confirmed frames sent correctly
2. Link LEDs showed PHY connection established
3. FPGA not incrementing frame counter
4. Traced data path: PHY -> mii_rx -> mac_parser
5. Realized: MII passes preamble, RMII/RGMII strip it

**Solution:** SFD Detection in mii_rx.vhd

```vhdl
signal sfd_detected : std_logic := '0';

process(eth_rx_clk)
begin
    if rising_edge(eth_rx_clk) then
        if rx_dv = '1' then
            -- Detect SFD (0xD5)
            if rx_data = X"D5" then
                sfd_detected <= '1';
            end if;

            -- Only output data AFTER SFD
            if sfd_detected = '1' and rx_data /= X"D5" then
                data_out <= rx_data;
                data_valid <= '1';
            end if;
        else
            sfd_detected <= '0';  -- Reset on frame end
        end if;
    end if;
end process;
```

**Lesson:**
- Different PHY interfaces handle framing differently
- MII: FPGA must strip preamble/SFD
- RMII/RGMII: PHY may strip automatically (check datasheet!)
- Always verify byte-level frame structure
- IEEE 802.3 specification is authoritative

### MAC Address Filtering

**Purpose:** Only process frames addressed to FPGA

**Target MAC:** `00:0a:35:02:af:9a` (Digilent OUI + board serial)

**Implementation:**
```vhdl
constant FPGA_MAC : std_logic_vector(47 downto 0) := X"000a3502af9a";
signal mac_match : std_logic;

-- Receive destination MAC (first 6 bytes)
case byte_count is
    when 0 => dest_mac(47 downto 40) <= rx_data;
    when 1 => dest_mac(39 downto 32) <= rx_data;
    when 2 => dest_mac(31 downto 24) <= rx_data;
    when 3 => dest_mac(23 downto 16) <= rx_data;
    when 4 => dest_mac(15 downto 8)  <= rx_data;
    when 5 => dest_mac(7 downto 0)   <= rx_data;
              -- Check match after last byte
              if dest_mac(47 downto 8) & rx_data = FPGA_MAC then
                  mac_match <= '1';
              else
                  mac_match <= '0';  -- Reject frame
              end if;
end case;

-- Also accept broadcast
if dest_mac = X"ffffffffffff" then
    mac_match <= '1';
end if;
```

**Testing:**
- Frames to FPGA_MAC: Accepted, LEDs increment
- Frames to wrong MAC: Rejected, no increment
- Broadcast frames: Accepted

### Clock Domain Crossing (25 MHz -> 100 MHz)

**Challenge:** `frame_valid` pulse generated in 25 MHz domain, stats counter in 100 MHz domain

**Solution:** 2-Flip-Flop Synchronizer

```vhdl
signal frame_valid_sync1 : std_logic := '0';
signal frame_valid_sync2 : std_logic := '0';

process(clk_100mhz)
begin
    if rising_edge(clk_100mhz) then
        frame_valid_sync1 <= frame_valid_cdc;  -- First FF
        frame_valid_sync2 <= frame_valid_sync1; -- Second FF (stable)
    end if;
end process;

-- Use sync2 for counter increment
```

**Timing Constraints (XDC):**
```tcl
set_max_delay -from [get_clocks eth_rx_clk] -to [get_clocks sys_clk] 40.0
set_max_delay -from [get_clocks sys_clk] -to [get_clocks eth_rx_clk] 10.0
```

**Lesson:**
- 2FF synchronizer is minimum for CDC
- First FF may go metastable
- Second FF guarantees stability
- Proper timing constraints essential
- Same pattern used in Project 2 (button debouncer)

### Python/Scapy Testing

**Test Script:** Send raw Ethernet frames directly to FPGA MAC

```python
from scapy.all import Ether, sendp

FPGA_MAC = "00:0a:35:02:af:9a"
frame = Ether(dst=FPGA_MAC, src=MY_MAC, type=0x0800) / b"Hello FPGA!"
sendp(frame, iface="Ethernet 17", count=10, verbose=False)
```

**Benefits:**
- Bypasses OS network stack
- Full control over frame contents
- Can test MAC filtering, broadcasts, malformed frames
- Real hardware validation

**Testing Scenarios:**
1. Correct MAC -> LEDs increment
2. Wrong MAC -> LEDs don't change
3. Broadcast -> LEDs increment
4. Various frame sizes (64 to 1518 bytes)
5. Burst testing (100 frames rapidly)

### Nibble-to-Byte Assembly

**MII Interface:** 4-bit nibbles @ 25 MHz

**Assembly Logic:**
```vhdl
signal nibble_count : std_logic := '0';
signal byte_lower   : std_logic_vector(3 downto 0);

process(eth_rx_clk)
begin
    if rising_edge(eth_rx_clk) then
        if rx_dv = '1' then
            if nibble_count = '0' then
                byte_lower <= rxd;     -- Store lower nibble
                nibble_count <= '1';
            else
                -- Upper nibble received, output complete byte
                data_out <= rxd & byte_lower;  -- Concatenate
                data_valid <= '1';
                nibble_count <= '0';
            end if;
        end if;
    end if;
end process;
```

**Bit Ordering:** Network byte order (big-endian)
- First nibble received = bits [3:0]
- Second nibble received = bits [7:4]

### Module Hierarchy

```
mii_eth_top
├── PLLE2_BASE (100 MHz -> 25 MHz reference clock)
├── mii_rx (MII receiver - nibble assembly, SFD detection)
├── mac_parser (MAC frame parser with filtering)
├── 2FF synchronizer (25 MHz -> 100 MHz CDC)
└── stats_counter (LED display + activity indicator)
```

**Clean separation of concerns:**
- mii_rx: Physical layer (nibble assembly, preamble stripping)
- mac_parser: Data link layer (MAC filtering, frame validation)
- stats_counter: Application layer (counting, display)

### Timing Analysis Results

**WNS (Worst Negative Slack):** +7.234 ns (PASSING)
**TNS (Total Negative Slack):** 0 ns
**Setup/Hold:** All constraints met

**Critical Path:** eth_rx_clk to sys_clk crossing
- Properly constrained with set_max_delay
- 2FF synchronizer adds latency but guarantees stability

### Hardware Verification

**Visual Confirmation:**
1. Blue LED ON after 5 seconds (PHY reset complete)
2. RJ45 link LEDs illuminate (PHY negotiated link)
3. LEDs count frames in binary (LD0-LD2)
4. Green LED pulses on frame reception

**Wireshark Validation:**
- Confirmed frames transmitted correctly
- Destination MAC matches FPGA
- Source MAC shows PC adapter
- Frame structure correct per IEEE 802.3

**LED Counter Test:**
- Send 1 frame: LEDs show 0001
- Send 10 frames: LEDs show 1010 (wraps to lower 3 bits)
- Send 100 frames: LEDs show 100 (mod 8 = 4)

### Process Improvements Implemented

**New Development Workflow:**
1. **Documentation Review** (30 min) - Read reference manuals, datasheets
2. **Planning** (15 min) - Module hierarchy, interfaces, constraints
3. **Coding** (2-3 hours) - Implementation with proper synchronizers
4. **Hardware Testing** (30 min) - Real board verification

**Old (Wrong) Workflow:**
1. Make assumptions about hardware
2. Start coding immediately
3. Debug for hours when it doesn't work
4. Finally read documentation and discover wrong interface

**Time Saved:** Hours of debugging prevented by upfront documentation review

### Trading System Relevance

**Market Data Reception:**
- Direct PHY interfacing = minimal latency
- Bypasses OS network stack completely
- MAC filtering reduces processing load
- Hardware timestamps possible (next phase)

**Packet Processing:**
- Preamble stripping at wire speed
- Immediate MAC filtering (not CPU-based)
- Dedicated state machines for protocol parsing
- Deterministic latency (no OS scheduling)

**Next Steps (Phase 1B):**
- IP header parsing
- UDP packet extraction
- Hardware timestamping (sub-microsecond precision)
- MDIO interface for PHY register access

---

## Project 06 Phase 1F: Bug #13 - Critical CDC Issues & Real-Time Architecture

###  The Most Important Lesson: Clock Domain Crossing Can Break Working Designs

**Context:** IP parser worked perfectly (ip=1, proto=11), but UDP parser consistently failed (udp=0). This was Bug #13 - a race condition caused by CDC violations that took significant debugging to identify and resolve.

### Bug #13: UDP Parser Race Condition (99% Failure Rate)

**Initial Symptoms:**
```
Terminal Output: MAC: frame fr=1 ip=1 udp=0 pend=-- ver=0 ihl=0 csum=0 b14=45 proto=11
                      ^^^^^^^^^^^^ IP parsing works   ^^^^ UDP parsing fails
```

**Root Cause Analysis Timeline:**

1. **First Discovery:** Event-driven UDP parser triggered on `ip_valid` pulse
2. **Debug Investigation:** Added debug outputs (proto=, upok=, ulok=, frm=)
3. **Race Condition Revealed:**
   - UDP parser triggered at byte 37 (when `ip_valid` pulsed)
   - UDP header bytes 34-41 already passed by that time
   - State machine entered PARSE_HEADER too late to capture data
   - Success rate: ~1% (only when timing accidentally aligned)

**Timing Diagram of the Failure:**
```
Byte Index:  23    24-33       34   35   36   37        38-41
             ↓     ↓           ↓    ↓    ↓    ↓         ↓
IP Parse:    proto VALIDATE    ─────────────> ip_valid (pulse)
UDP Parse:   idle  idle        idle idle idle START     Too late!
                                ^^^^^^^^^^^^^^^^^^^
                                UDP header bytes missed
```

**Failed Fix Attempts:**
1. Trigger window `byte_index >= 24 and < 34` → 100% failure (too early)
2. Trigger window `byte_index >= 23 and < 34` → Still mostly 0% (timing off)
3. Trigger window `byte_index >= 23` (no upper bound) → ~1% success (race persists)

**Successful Solution:** Complete architectural rewrite from event-driven to real-time.

### Real-Time vs Event-Driven Parser Architecture

**[FAIL] Event-Driven (v3b - FAILED):**
```vhdl
-- Wait for signal, then try to capture bytes
when IDLE =>
    if ip_valid = '1' then  -- Signal arrives too late!
        state <= PARSE_HEADER;
    end if;

when PARSE_HEADER =>
    -- By now, UDP header bytes already passed
    if byte_index = UDP_HEADER_START + header_byte_count then
        case header_byte_count is
            when 0 => src_port_reg(15 downto 8) <= data_in;  -- MISSED!
```

**[PASS] Real-Time (v5 - SUCCESS):**
```vhdl
-- Trigger at exact byte position
when IDLE =>
    if frame_valid = '1' and byte_index = UDP_HEADER_START then  -- Byte 34
        state <= PARSE_HEADER;
    end if;

when PARSE_HEADER =>
    -- Capture bytes in real-time as they arrive
    if byte_index = (UDP_HEADER_START + header_byte_count) then
        case header_byte_count is
            when 0 => src_port_reg(15 downto 8) <= data_in;  -- ✓ Captured!
            when 1 => src_port_reg(7 downto 0) <= data_in;
            when 2 => dst_port_reg(15 downto 8) <= data_in;
            when 3 => dst_port_reg(7 downto 0) <= data_in;
            when 4 => length_reg(15 downto 8) <= data_in;
            when 5 => length_reg(7 downto 0) <= data_in;
            when 6 => checksum_reg(15 downto 8) <= data_in;
            when 7 =>
                checksum_reg(7 downto 0) <= data_in;
                state <= VALIDATE;  -- All 8 bytes captured!
```

**Key Differences:**

| Aspect | Event-Driven (v3b) | Real-Time (v5) |
|--------|-------------------|----------------|
| **Trigger** | Waits for `ip_valid` signal | Triggers at `byte_index = 34` |
| **Timing** | Arrives too late (byte 37) | Exact position (byte 34) |
| **Success Rate** | ~1% (race condition) | 100% (deterministic) |
| **Code Size** | 280+ lines | 188 lines |
| **States** | 5 states | 4 states (simplified) |
| **Complexity** | Complex triggering logic | Simple byte-position logic |

**Results:**
- v3b: 1% success rate → v5: 100% success rate
- Reduced code size: 280+ lines → 188 lines
- Eliminated race condition entirely
- Production-ready reliability

### Clock Domain Crossing (CDC) - Production Patterns

**Challenge:** Signals crossing from 25 MHz (eth_rx_clk) to 100 MHz (clk) domain can cause metastability.

**Critical CDC Fixes Applied:**

#### 1. Reset Synchronization (NEW in v5)
```vhdl
-- Reset synchronizer for 25 MHz domain
signal mdio_rst_rxclk_sync1 : std_logic := '1';
signal mdio_rst_rxclk_sync2 : std_logic := '1';
signal mdio_rst_rxclk       : std_logic := '1';

process(eth_rx_clk)
begin
    if rising_edge(eth_rx_clk) then
        mdio_rst_rxclk_sync1 <= reset;
        mdio_rst_rxclk_sync2 <= mdio_rst_rxclk_sync1;
        mdio_rst_rxclk       <= mdio_rst_rxclk_sync2;
    end if;
end process;
```

**Lesson:** Reset must be synchronized to each clock domain. Using unsynchronized reset causes random initialization failures.

#### 2. Single-Bit CDC Synchronizers
```vhdl
-- 2-FF synchronizer pattern
signal ip_valid_sync1 : std_logic := '0';
signal ip_valid_sync2 : std_logic := '0';

process(clk)
begin
    if rising_edge(clk) then
        if reset = '1' then
            ip_valid_sync1 <= '0';
            ip_valid_sync2 <= '0';
        else
            ip_valid_sync1 <= ip_valid;        -- First FF (may go metastable)
            ip_valid_sync2 <= ip_valid_sync1;  -- Second FF (stable)
        end if;
    end if;
end process;
```

**Applied to ALL single-bit signals:**
- `ip_valid`, `udp_valid`, `frame_valid`
- `ip_checksum_ok`, `ip_version_err`, `ip_ihl_err`, `ip_checksum_err`
- `udp_length_err`

**Lesson:** EVERY single-bit signal crossing clock domains needs 2-FF synchronizer. Missing even one can cause intermittent failures.

#### 3. Multi-Bit CDC (Valid-Gated Capture)
```vhdl
-- Multi-bit signals captured on synchronized valid pulse
signal ip_protocol_latch : std_logic_vector(7 downto 0) := (others => '0');

process(clk)
begin
    if rising_edge(clk) then
        if reset = '1' then
            ip_protocol_latch <= (others => '0');
        elsif ip_valid_sync2 = '1' then  -- Use synchronized valid
            ip_protocol_latch <= ip_protocol;  -- Sample when stable
        end if;
    end if;
end process;
```

**Applied to multi-bit buses:**
- `ip_protocol` (8 bits)
- `ip_total_length` (16 bits)
- `byte_index` (integer)

**Lesson:** Multi-bit signals CANNOT be synchronized directly (bus skew). Use synchronized valid pulse to gate sampling.

#### 4. In-Frame Flag for Clean Boundaries
```vhdl
-- Track frame boundaries in 25 MHz domain
signal in_frame : std_logic := '0';

process(eth_rx_clk)
begin
    if rising_edge(eth_rx_clk) then
        if mdio_rst_rxclk = '1' then
            in_frame <= '0';
        else
            if rx_dv = '1' and sfd_detected = '1' then
                in_frame <= '1';  -- Frame started
            elsif rx_dv = '0' then
                in_frame <= '0';  -- Frame ended
            end if;
        end if;
    end if;
end process;
```

**Lesson:** Track state in source clock domain before crossing. Clean boundaries prevent glitches.

#### 5. XDC Timing Constraints (Critical!)
```tcl
## Mark asynchronous clock domains
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks eth_rx_clk] \
    -group [get_clocks eth_tx_clk] \
    -group [get_clocks eth_ref_clk]

## CDC Synchronizer Constraints
## Mark synchronizer flip-flops to prevent optimization and guide placement
set_property ASYNC_REG TRUE [get_cells -hier *ip_valid_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *udp_valid_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *frame_valid_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *ip_checksum_ok_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *ip_version_err_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *ip_ihl_err_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *ip_checksum_err_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *udp_length_err_sync*]
set_property ASYNC_REG TRUE [get_cells -hier *mdio_rst_rxclk_sync*]

## False paths to first stage of synchronizers (metastability allowed here)
set_false_path -to [get_cells -hier *ip_valid_sync1*]
set_false_path -to [get_cells -hier *udp_valid_sync1*]
set_false_path -to [get_cells -hier *frame_valid_sync1*]
set_false_path -to [get_cells -hier *ip_checksum_ok_sync1*]
set_false_path -to [get_cells -hier *ip_version_err_sync1*]
set_false_path -to [get_cells -hier *ip_ihl_err_sync1*]
set_false_path -to [get_cells -hier *ip_checksum_err_sync1*]
set_false_path -to [get_cells -hier *udp_length_err_sync1*]
set_false_path -to [get_cells -hier *mdio_rst_rxclk_sync1*]
```

**Lesson:**
- `ASYNC_REG` property tells tools these are synchronizer FFs (don't optimize away, keep close together)
- `set_false_path` to first stage allows metastability (first FF purpose)
- Without these constraints, tools may violate CDC integrity during placement/routing

### Debug Methodology That Worked

**Problem:** Hard to diagnose why UDP parsing fails when IP parsing works.

**Solution:** Comprehensive debug outputs added to UART formatter:

```vhdl
-- Debug fields added to MAC message
proto=11    -- IP protocol (should be 0x11 for UDP)
upok=0      -- UDP protocol check passed (udp_protocol_ok)
ulok=0      -- UDP length check passed (udp_length_ok)
frm=1       -- In-frame flag at ip_valid time
b14=45      -- Byte 14 content (IP version/IHL verification)
```

**Terminal Output Progression:**

1. **Initial:** `udp=0` (failure, no details)
2. **With debug:** `udp=0 upok=0 ulok=0 frm=1` (UDP checks failing)
3. **After debug analysis:** Discovered upok=1 only when IP checksum failed (wrong packets!)
4. **Root cause identified:** Race condition - UDP parser starting too late

**Lesson:** Strategic debug outputs reveal timing relationships. Seeing `frm=1` but `upok=0` showed timing issue, not logic bug.

### Production-Ready CDC Checklist

Based on Bug #13 resolution, use this checklist for ALL multi-clock designs:

[PASS] **1. Identify ALL CDC signals**
   - Single-bit control/status signals
   - Multi-bit data buses
   - Reset signals

[PASS] **2. Synchronize reset to EACH clock domain**
   - Use 2-FF synchronizer for reset
   - Apply synchronized reset to all registers in that domain

[PASS] **3. Apply 2-FF synchronizer to ALL single-bit CDC signals**
   - Don't skip error flags or status signals
   - Even "don't care" signals need synchronization

[PASS] **4. Use valid-gated capture for multi-bit buses**
   - Never synchronize multi-bit buses directly
   - Synchronize the valid signal (2-FF)
   - Sample bus on synchronized valid pulse

[PASS] **5. Track state in source clock domain**
   - Clean boundaries (like in_frame flag)
   - Reduces glitches during CDC

[PASS] **6. Add comprehensive XDC constraints**
   - Mark clock groups as asynchronous
   - Set ASYNC_REG property on synchronizer FFs
   - Set false path to first synchronizer stage

[PASS] **7. Verify timing closure**
   - Check for CDC violations in timing report
   - Ensure no setup/hold violations on CDC paths

[PASS] **8. Hardware stress test**
   - Test with 1000+ packets
   - Verify 100% success rate
   - Look for intermittent failures

### Key Architectural Lessons from Bug #13

####  Lesson 1: Real-Time Architecture for Streaming Data
**Problem:** Event-driven parsers waiting for signals create race conditions.

**Solution:** Trigger state machines directly on byte position, not on derived signals.

**Pattern:**
```vhdl
-- [PASS] GOOD: Position-based triggering
if byte_index = HEADER_START then
    state <= PARSE;
end if;

-- [FAIL] BAD: Signal-based triggering (creates race)
if some_valid_signal = '1' then
    state <= PARSE;
end if;
```

**When to use:**
- Streaming protocols (Ethernet, UART, SPI)
- Fixed-position headers (MAC, IP, UDP, ITCH)
- Deterministic timing requirements

####  Lesson 2: CDC Cannot Be Partial
**Problem:** Missing even one CDC signal causes random failures.

**Solution:** Systematic approach - synchronize EVERY signal crossing clock domains.

**Checklist:**
- Valid/enable signals
- Data buses 
- Error flags  ← Often forgotten!
- Status signals ← Often forgotten!
- Reset ← Critical!

**One missed signal = production failure.**

####  Lesson 3: Debug Outputs Are Investments
**Problem:** "It doesn't work" provides no actionable information.

**Solution:** Add strategic debug outputs showing signal relationships.

**Effective debug outputs:**
- Show both input and output of logic
- Display timing-critical flags (like `frm=` at ip_valid)
- Use hex for multi-bit values (easier to spot patterns)
- Keep format concise (fits on one line)

**Example:** `proto=11 upok=0 ulok=0 frm=1` instantly showed timing mismatch.

####  Lesson 4: XDC Constraints Are Not Optional
**Problem:** Design works in simulation, fails in hardware.

**Solution:** CDC constraints guide tools to preserve synchronizer integrity.

**Critical constraints:**
- `set_clock_groups -asynchronous` - Declares independent clocks
- `ASYNC_REG TRUE` - Protects synchronizer FFs from optimization
- `set_false_path` - Allows metastability in first FF

**Without these:** Tools may optimize away synchronizers or place FFs too far apart.

### Comparison: v3b (Event-Driven) vs v5 (Real-Time)

| Metric | v3b (Broken) | v5 (Fixed) | Improvement |
|--------|--------------|------------|-------------|
| **Success Rate** | ~1% | 100% | **99% improvement** |
| **Code Size** | 280+ lines | 188 lines | 33% reduction |
| **State Machine** | 5 states | 4 states | Simpler |
| **Trigger Method** | ip_valid signal | byte_index position | Deterministic |
| **CDC Sync** | Partial | Complete | Production-ready |
| **XDC Constraints** | None | Comprehensive | Timing verified |
| **Stress Test** | Failed | 1000+ packets pass | Reliable |
| **Debug Time** | 4+ hours | N/A (working) | Huge time savings |

### Trading System Relevance

**Skills Demonstrated:**

1. **Production Debugging** - Systematic root cause analysis of race conditions
2. **CDC Mastery** - Essential for multi-clock trading FPGAs (network PHY, order entry, timestamping)
3. **Real-Time Processing** - Fixed-latency parsing critical for deterministic HFT systems
4. **Stress Testing** - 1000+ packet validation mirrors production QA requirements
5. **Architectural Redesign** - Knowing when to rewrite vs patch shows engineering maturity
6. **Debug Strategy** - Strategic instrumentation enables rapid issue diagnosis

**Why This Matters for Trading:**
- **ITCH/OUCH Parsing:** Same real-time architecture applies to NASDAQ protocols
- **Multi-Clock FPGAs:** Trading systems have multiple clock domains (network, processing, memory)
- **Zero Failures:** 100% success rate requirement mirrors trading production standards
- **Deterministic Latency:** Real-time parsing guarantees fixed latency (critical for HFT)
- **Production Patterns:** CDC checklist prevents costly bugs in live trading systems

### Files Modified for Bug #13 Resolution

1. **udp_parser.vhd** - Complete rewrite (280+ → 188 lines)
2. **mii_eth_top.vhd** - CDC synchronizers, reset sync, in_frame flag, debug signals
3. **uart_formatter.vhd** - Debug outputs (proto=, upok=, ulok=, frm=)
4. **arty_a7_100t_mii.xdc** - Comprehensive CDC timing constraints
5. **README.md** - Full documentation of Bug #13 journey (1,502 lines)

---

## Project 07: ITCH 5.0 Protocol Parser - MII Timing Discovery

###  Critical Discovery: MII Byte Timing and Off-by-One Errors

**Context:** ITCH parser implemented for Nasdaq market data feeds. Initial implementation used even byte_counter values (0,2,4,6...) for field extraction, resulting in all fields showing incorrect values (StockLoc=0000, Symbol garbled).

### The MII Timing Problem

**MII Interface Characteristics:**
- Operates at 25 MHz receiving 4-bit nibbles
- Assembles bytes every 2 clock cycles
- Byte rate: 12.5 MHz (25 MHz / 2)
- Each assembled byte remains **stable for 2 consecutive clock cycles**

**Critical Discovery:**
When state machine transitions from IDLE to COUNT_BYTES on `udp_payload_start='1'`, the **type byte (byte 0) remains visible for 1 additional clock cycle**.

**Timing Diagram:**
```
Clock Cycle:     0        1        2        3        4        5
                 ↓        ↓        ↓        ↓        ↓        ↓
State:        IDLE  COUNT_BYTES  COUNT_B  COUNT_B  COUNT_B  COUNT_B
Data Visible:  TYPE     TYPE      BYTE1    BYTE1    BYTE2    BYTE2
byte_counter:   -        0         1        2        3        4
                         ↑                  ↑                 ↑
                    Type repeated!    First data byte   Second data byte
```

**Problem with Even Byte Counter (0,2,4,6...):**
```vhdl
-- WRONG: Processing on even counters
if byte_counter = 0 then
    stock_locate_reg(15 downto 8) <= udp_payload_data;  -- Gets TYPE byte!
elsif byte_counter = 2 then
    stock_locate_reg(7 downto 0) <= udp_payload_data;   -- Gets BYTE1 (wrong!)
```

**Result:** Off-by-one error for ALL fields. Type byte contaminated first field, all subsequent fields misaligned.

### The Solution: Odd Byte Counter Pattern

**Correct Implementation:**
```vhdl
-- RIGHT: Processing on ODD counters (1,3,5,7...)
if byte_counter >= 1 and (byte_counter mod 2) = 1 then
    if byte_counter = 1 then
        stock_locate_reg(15 downto 8) <= udp_payload_data;  -- Gets BYTE1 
    elsif byte_counter = 3 then
        stock_locate_reg(7 downto 0) <= udp_payload_data;   -- Gets BYTE2 
    elsif byte_counter = 5 then
        tracking_number_reg(15 downto 8) <= udp_payload_data;  -- Gets BYTE3
    -- ... and so on
    end if
end if
```

**Byte Counter Mapping Formula:**
```
Physical byte N → byte_counter = 2*N - 1

Examples:
  Byte 1  (Stock Locate MSB)    → byte_counter = 1
  Byte 11 (Order Reference MSB) → byte_counter = 21
  Byte 32 (Price MSB)           → byte_counter = 63
```

**Why This Works:**
1. Type byte captured in IDLE state when `payload_start='1'` (separate logic)
2. In COUNT_BYTES at byte_counter=0: Type byte still visible (IGNORED)
3. At byte_counter=1: First data byte (byte 1) appears - NOW process
4. At byte_counter=3: Second data byte (byte 2) appears - process
5. Pattern continues: odd counters always align with valid data bytes

### Debug Process and Discovery

**Initial Symptom:**
```
UART Output: StockLoc=0000 Track=0000 Shares=00000041 Symbol=0000000000004142
                                                ^^^^              ^^^^
                                        Should be Type=41     Should be "AAPL"
```

**Investigation Steps:**
1. Added extensive debug outputs (48 debug signals total!)
2. Captured byte_counter values when each field byte processed
3. Displayed payload_data for bytes 1-4
4. Created cycle-by-cycle history (payload_history_0 through _3)
5. Monitored state transitions and payload_valid history

**Debug Output That Revealed the Issue:**
```vhdl
-- Critical debug: Capture exact byte_counter and data for first few bytes
debug_byte1_counter <= 0  -- Processing at counter 0
debug_byte1_data    <= 41 -- Seeing TYPE byte (0x41 = 'A')
debug_byte2_counter <= 2  -- Processing at counter 2
debug_byte2_data    <= 00 -- Seeing byte 1 (stock locate high)
```

**Realization:** Processing at even counters (0,2,4...) captured:
- Counter 0 → Type byte (should skip)
- Counter 2 → Byte 1 (should be at counter 1)
- Counter 4 → Byte 2 (should be at counter 3)

All fields off by one byte position!

**Verification After Fix:**
```
Test Packet: Type=41 StockLoc=0001 Track=0F42 ... Symbol=AAPL Price=60.4856
FPGA Output: Type=41 StockLoc=0001 Track=0F42 ... Symbol=AAPL Price=60.4856
                                                                     Perfect match!
```

### ITCH Message Implementation

**Message Types Implemented:**
- **'A' (0x41):** Add Order - 36 bytes (Order ref, Buy/Sell, Shares, Symbol, Price)
- **'E' (0x45):** Order Executed - 31 bytes (Order ref, Executed shares, Match number)
- **'X' (0x58):** Order Cancel - 23 bytes (Order ref, Cancelled shares)

**Example Field Extraction (Add Order):**
```vhdl
elsif current_msg_type = x"41" and byte_counter >= 1 and (byte_counter mod 2) = 1 then
    -- Stock Locate: bytes 1-2 (counters 1, 3)
    if byte_counter = 1 then
        stock_locate_reg(15 downto 8) <= udp_payload_data;
    elsif byte_counter = 3 then
        stock_locate_reg(7 downto 0) <= udp_payload_data;

    -- Order Reference: bytes 11-18 (counters 21,23,25,27,29,31,33,35)
    elsif byte_counter = 21 then
        order_ref_reg(63 downto 56) <= udp_payload_data;  -- Byte 11 (MSB)
    elsif byte_counter = 23 then
        order_ref_reg(55 downto 48) <= udp_payload_data;  -- Byte 12
    -- ... through byte 18

    -- Symbol: bytes 24-31 (counters 47,49,51,53,55,57,59,61)
    elsif byte_counter = 47 then
        symbol_reg(63 downto 56) <= udp_payload_data;  -- Byte 24 (first char)
    -- ... through byte 31

    -- Price: bytes 32-35 (counters 63,65,67,69)
    elsif byte_counter = 63 then
        price_reg(31 downto 24) <= udp_payload_data;  -- Byte 32 (MSB)
    elsif byte_counter = 65 then
        price_reg(23 downto 16) <= udp_payload_data;  -- Byte 33
    elsif byte_counter = 67 then
        price_reg(15 downto 8) <= udp_payload_data;   -- Byte 34
    elsif byte_counter = 69 then
        price_reg(7 downto 0) <= udp_payload_data;    -- Byte 35 (LSB)
    end if;
end if;
```

### Additional Bugs Fixed

**Bug 2: Signal Name Mismatch**
- **Symptom:** Compilation would have failed (caught early)
- **Root Cause:** Signal declared as `captured_match_num` but referenced as `captured_match_number` in formatter
- **Fix:** Changed all 16 references to match declaration name
- **Lesson:** Consistent naming critical; VHDL catches this at compile time (unlike some languages)

**Bug 3: MAC Filtering Left Disabled**
- **Symptom:** Parser processing ALL network traffic (ARP, mDNS, broadcast packets)
- **Root Cause:** MAC filtering left in debug mode during byte alignment troubleshooting
- **Fix:** Re-enabled MAC address check for board MAC (0x00183E045DE7) + broadcast
- **Impact:** Without filtering, parser triggers on irrelevant packets, wasting resources and causing spurious UART output
- **Lesson:** Always re-enable production filters after debugging sessions

### Enhanced UART Formatter

**Problem:** Order Executed and Order Cancel messages only showed type - couldn't identify which order.

**Solution:** Added order reference and key fields to UART output:

```vhdl
-- Order Executed Format:
-- "[#XX] [ITCH] Type=E Ref=XXXXXXXXXXXXXXXX ExecShr=XXXXXXXX Match=XXXXXXXXXXXXXXXX\r\n"

-- Order Cancel Format:
-- "[#XX] [ITCH] Type=X Ref=XXXXXXXXXXXXXXXX CxlShr=XXXXXXXX\r\n"
```

**Benefit:** Can now trace order lifecycle:
1. `Type=A Ref=000000000F4240` - Order added
2. `Type=E Ref=000000000F4240 ExecShr=00000032` - 50 shares executed
3. `Type=X Ref=000000000F4240 CxlShr=00000019` - 25 shares cancelled

**Unused Signal Removal:**
- `first_cycle_in_count_bytes` - Declared but never used
- `payload_data_reg` - Registered copy not needed (using combinational directly)

**Code Documentation:**
- Added note that 48 debug signals can be removed once system verified stable
- Updated module header to reflect only implemented message types (A, E, X)
- Documented MII timing requirement in module comments

### Key Architectural Lessons

**Lesson 1: MII Timing is Fundamental**
- MII byte stability (2 cycles per byte) is not optional - it's how the interface works
- State machine transitions don't magically align with byte boundaries
- **Must account for transition timing in byte processing logic**
- This applies to ALL MII-based parsing, not just ITCH

**Lesson 2: Debug Infrastructure Investment**
- 48 debug signals seems excessive, but enabled rapid root cause discovery
- Cycle-by-cycle history critical for timing-related bugs
- Debug outputs showing both counter AND data values revealed the pattern
- Strategic instrumentation pays off when facing obscure timing issues

**Lesson 3: Formula-Based Byte Mapping**
- Discovered formula: `byte_counter = 2*N - 1` for physical byte N
- Enables quick calculation for any byte position
- Documents the relationship clearly in code comments
- Makes pattern obvious to future maintainers

**Lesson 4: Verification with Real Protocol Data**
- Used actual ITCH packet format from Nasdaq specification
- Tested with real field values (Order ref=1000000, Symbol=AAPL, Price=$60.4856)
- Verified every field matches expected value exactly
- Production protocols have no room for "close enough"

**Lesson 5: MAC Filtering is Essential**
- Without filtering: Parser sees ARP, mDNS, broadcast traffic
- Causes false triggers, wasted processing, confusing debug output
- **Always filter at lowest possible layer** (MAC, not application)
- Whitelist approach: Board MAC + broadcast only

### Trading System Relevance

**Skills Demonstrated:**

1. **Protocol Byte Alignment** - ITCH, FIX, OUCH all require exact byte-level parsing
2. **MII Interface Timing** - Direct PHY interfacing for minimal latency
3. **Big-Endian Field Extraction** - Network byte order standard for all trading protocols
4. **Debug Methodology** - Systematic debugging with strategic instrumentation
5. **Production Filtering** - MAC filtering mirrors production packet filtering

**Why This Matters for Trading:**

- **ITCH Protocol:** Direct experience with actual Nasdaq market data format
- **Sub-Microsecond Latency:** Hardware parsing eliminates OS/software overhead
- **Deterministic Timing:** Fixed byte-counter pattern ensures consistent latency
- **Zero Tolerance:** 100% accuracy required - one misaligned field = bad trades
- **Production Patterns:** MAC filtering, CDC synchronization, error handling

### Files Modified

1. **itch_parser.vhd** - Implemented A/E/X message parsing with odd byte_counter pattern
2. **uart_itch_formatter.vhd** - Enhanced E/X output, fixed signal name mismatch
3. **mac_parser.vhd** - Re-enabled MAC address filtering
4. **README.md** - Comprehensive documentation of MII timing discovery
5. **mii_eth_top.vhd** - Cleaned up comments, removed dead code


---

## Project 07 v3: Race Conditions and Async FIFO Architecture

###  The Ultimate Multi-Process Lesson: Sometimes You Must Redesign

**Context:** After successfully implementing 5 ITCH message types (A, E, X, S, R) in v2, encountered persistent race conditions causing message loss and duplication. 20+ debugging attempts failed to fix the fundamental architectural problem.

### The v2 Problem: Pending Flags and Race Conditions

**Architecture:** Messages crossed clock domains (25 MHz parser → 100 MHz formatter) using pending flags with edge detection.

**Race Condition Mechanism:**
```vhdl
-- 25 MHz domain (parser)
process(eth_rx_clk)
begin
    if rising_edge(eth_rx_clk) then
        if message_complete = '1' then
            pending_flag <= '1';  -- SET flag
        end if;
    end if;
end process;

-- 100 MHz domain (formatter)
process(clk)
begin
    if rising_edge(clk) then
        if transmission_complete = '1' then
            pending_flag <= '0';  -- CLEAR flag
        end if;
    end if;
end process;
```

**The Fatal Flaw:** When SET and CLEAR conditions both true in same cycle → race condition.

**Symptoms Encountered:**

| Version | Clearing Strategy | Result | Messages Lost/Duplicated |
|---------|------------------|--------|------------------------|
| v9-v17 | Clear on IDLE→SEND_* transition | Message loss | Alternating messages dropped |
| v18-v20 | Clear on SEND_*→IDLE transition | Infinite loop | Messages repeated 41+ times |
| v21-v29 | Clear on WAIT_TX→IDLE transition | Message duplication | Every message appeared twice |
| v27-v29 | Handshake signals for clearing | Multiple driver errors | Synthesis failed |

**Root Cause:** Impossible to reliably manage SET/CLEAR of flags across two processes (edge detection in one domain + FSM in another) without race conditions. This is a **fundamental architectural limitation**, not a fixable bug.

### The v3 Solution: Async FIFO with Gray Code CDC

**Complete Architectural Redesign:**

```
v2 Architecture (BROKEN):
Parser (25 MHz) → Pending Flags + Edge Detection → Formatter (100 MHz)
                   └─ Race conditions ─┘

v3 Architecture (WORKING):
Parser (25 MHz) → Encoder → Async FIFO (Gray Code CDC) → Decoder → Formatter (100 MHz)
                             └─ Natural queuing, no flags ─┘
```

**Key Components:**

1. **itch_msg_encoder.vhd** - Serializes parsed messages to 324-bit format (4-bit type + 320-bit data)
2. **async_fifo.vhd** - Dual-clock FIFO with gray code pointer synchronization (512-deep)
3. **itch_msg_decoder.vhd** - Deserializes FIFO data back to individual fields
4. **itch_msg_pkg.vhd** - Shared encoding/decoding functions

**Why This Works:**
- Messages queue naturally in FIFO (no pending flags needed)
- Gray code CDC handles pointer synchronization safely
- Write and read in completely separate clock domains
- No race conditions possible - each message written once, read once

**Results:**
- v2: Message loss, duplication, infinite loops
- v3: Zero race conditions, zero message loss, zero duplication
- Code simplified: uart_itch_formatter reduced from 677 lines to 395 lines (41% reduction)

### Two-Stage Message Capture Pattern

**Problem:** ITCH parser asserts valid signals for exactly 1 cycle (40ns @ 25 MHz). If encoder is busy writing to FIFO, it might miss the pulse.

**Solution:** Two-stage capture mechanism:

```vhdl
-- Stage 1: Always capture immediately (highest priority, never blocks)
signal captured_msg : msg_buffer_type;

-- Stage 2: Hold messages waiting for FIFO space
signal msg_buffer : msg_buffer_type;

process(clk)
begin
    if rising_edge(clk) then
        -- ALWAYS capture valid pulses immediately
        if add_order_valid = '1' then
            captured_msg.valid <= '1';
            captured_msg.msg_data <= encode_add_order(...);
        end if;

        -- Write priority: buffer first, then captured, then capture new
        if fifo_wr_full = '0' then
            if msg_buffer.valid = '1' then
                fifo_wr_data <= msg_buffer.msg_data;
                fifo_wr_en <= '1';
                msg_buffer <= captured_msg;  -- Move captured to buffer
            elsif captured_msg.valid = '1' then
                fifo_wr_data <= captured_msg.msg_data;
                fifo_wr_en <= '1';
            end if;
        elsif captured_msg.valid = '1' then
            msg_buffer <= captured_msg;  -- FIFO full, buffer it
        end if;
    end if;
end process;
```

**Guarantee:** No 1-cycle valid pulse ever missed, regardless of FIFO state or timing.

### FIFO Depth Sizing for Burst Traffic

**Challenge:** UART output at 115200 baud (~87μs per byte) is much slower than parser at 25 MHz (~40ns per byte).

**Calculation:**
- AAPL stock generates 1000+ messages/second during market hours
- Average message size: 36 bytes
- Burst rate: 36 KB/second
- FIFO @ 512 deep × 324 bits/entry = 20,736 bytes of buffering
- **Buffer duration: ~0.6 seconds of continuous messages**

**Lesson:** Proper FIFO sizing prevents overflow during burst traffic. Must account for worst-case producer/consumer rate mismatch.

### Overflow Detection - Defense Against Silent Failure

**The Risk:** With two-stage capture, if both stages full when new valid pulse arrives, message would be silently dropped.

**Solution:** Added overflow diagnostics:

```vhdl
else
    -- OVERFLOW: Both buffer and captured_msg are full
    overflow_error_reg <= '1';  -- Pulse for 1 cycle
    if overflow_count_reg /= x"FFFF" then
        overflow_count_reg <= overflow_count_reg + 1;  -- Saturating counter
    end if;
    captured_msg.valid <= '0';  -- Drop message (no choice)
end if;
```

**Visual Indicator:**
- **LD5 Blue LED:** Latches ON when overflow occurs (stays lit until board reset)
- Operator immediately knows sustained message rate exceeded capacity
- `overflow_count` readable via JTAG for quantifying loss

**Impact:** Converts potential silent failure into visible, diagnosable error. Professional systems must detect and report failure modes, even "impossible" ones.

### Decoder Timing: Read Delay Compensation

**FIFO Characteristic:** `rd_data` updates on cycle when `rd_en = '1'`, but data available **next cycle**.

**Solution:** Track previous read enable and decode on cycle AFTER read:

```vhdl
signal fifo_rd_en_prev : std_logic := '0';

process(clk)
begin
    if rising_edge(clk) then
        fifo_rd_en_prev <= fifo_rd_en;

        -- Decode on cycle AFTER FIFO read
        if fifo_rd_en_prev = '1' then
            msg_type_enc := fifo_rd_data(MSG_FIFO_WIDTH-1 downto MSG_DATA_BITS);
            msg_data := fifo_rd_data(MSG_DATA_BITS-1 downto 0);
            msg_type_reg <= decode_msg_type(msg_type_enc);
            -- Decode fields based on type...
        end if;
    end if;
end process;
```

**Lesson:** Account for FIFO read latency. Decode timing must match data availability.

### Key Architectural Lessons from v2→v3 Refactor

####  Lesson 1: Know When to Redesign vs Debug

**Problem Indicators:**
- Same category of bug reappears with different fix attempts (race conditions)
- Fixes in one area break another area (flag clearing strategies)
- Code complexity increasing without improvement (handshake signals)
- 10+ failed attempts with no convergence

**Solution Indicators:**
- Fundamental architectural limitation identified
- Industry-standard pattern exists (async FIFO for CDC)
- Redesign simplifies code (677 → 395 lines)
- Known working solution from other projects

**Decision:** After 20+ builds (v9-v29), recognized pending flag architecture was fundamentally flawed. Complete redesign with async FIFO was the right solution.

**Lesson:** Sometimes debugging is the wrong approach. Recognize architectural problems early and redesign.

####  Lesson 2: Async FIFO Eliminates CDC Race Conditions

**When to Use:**
- Crossing clock domains with multi-bit data
- Message/packet queuing between domains
- Producer/consumer with different rates
- Need for natural backpressure handling

**Benefits:**
- No pending flags needed (messages queue naturally)
- Gray code CDC provably race-free
- Built-in flow control (full/empty flags)
- Burst handling with depth sizing

**Pattern:**
```vhdl
async_fifo: entity work.async_fifo
    generic map (
        DATA_WIDTH => 324,  -- Serialized message width
        FIFO_DEPTH => 512   -- Buffer depth for burst handling
    )
    port map (
        wr_clk => src_clk,   -- Source clock domain
        wr_en  => wr_en,
        wr_data => wr_data,
        wr_full => wr_full,
        rd_clk => dst_clk,   -- Destination clock domain
        rd_en  => rd_en,
        rd_data => rd_data,
        rd_empty => rd_empty
    );
```

####  Lesson 3: Message Serialization for FIFO Transfer

**Challenge:** ITCH messages have variable fields (Order ref, symbol, price, etc.). How to pass through fixed-width FIFO?

**Solution:** Serialize all fields into fixed 324-bit format:
- 4 bits: Message type (MSG_ADD_ORDER, MSG_ORDER_EXECUTED, etc.)
- 320 bits: Union of all possible fields (largest message determines size)

**Encoding Example (Add Order):**
```vhdl
function encode_add_order(
    order_ref : std_logic_vector(63 downto 0);
    buy_sell : std_logic;
    shares : std_logic_vector(31 downto 0);
    stock_symbol : std_logic_vector(63 downto 0);
    price : std_logic_vector(31 downto 0);
    -- ... other fields
) return std_logic_vector is
    variable msg_data : std_logic_vector(MSG_DATA_BITS-1 downto 0);
begin
    msg_data(63 downto 0) := order_ref;
    msg_data(64) := buy_sell;
    msg_data(96 downto 65) := shares;
    msg_data(160 downto 97) := stock_symbol;
    msg_data(192 downto 161) := price;
    -- ... pack remaining fields
    return msg_data;
end function;
```

**Benefits:**
- Single FIFO handles all message types
- Type field indicates which fields are valid
- Decoder extracts fields based on type
- Easy to extend (add new message types to package)

####  Lesson 4: Build Version Tracking is Essential

**Challenge:** Programming wrong bitstream causes confusion about which features are implemented.

**Solution:** Auto-incrementing build version in TCL script:
1. Read `build_version.txt`
2. Increment value
3. Write back to file
4. Pass to VHDL as generic parameter
5. Display in UART output

**Benefits:**
- Verification of correct bitstream programmed
- Build history tracking (v1-v45 documented)
- Enables bisecting bugs to specific builds
- Mandatory for professional development

**Lesson:** "It works on my machine" is prevented by build tracking.

### v3 Architecture Complete - Production Ready

**Quality Metrics:**
- [PASS] Zero race conditions (async FIFO CDC)
- [PASS] Zero message loss (two-stage capture)
- [PASS] Zero message duplication (single write/read per message)
- [PASS] 100% parsing accuracy (5 message types)
- [PASS] Overflow detection with visual LED indicator
- [PASS] 512-deep FIFO handles 0.6 second bursts
- [PASS] Clean synthesis, timing closure

**Development Stats:**
- ~200 hours intensive development after business hours and incl. weekends
- 45+ tracked builds (many more untracked in Projects 1-6)
- 14 critical bugs fixed
- Major architectural refactor (v2 → v3)

**Ready For:** v4 implementation (additional message types P, Q, U, D)

### Trading System Relevance

**Skills Demonstrated:**

1. **Architectural Decision-Making** - Recognized when to redesign vs debug (20+ failed attempts → redesign)
2. **Clock Domain Crossing Mastery** - Async FIFO with gray code CDC (essential for multi-clock trading FPGAs)
3. **Burst Handling** - FIFO depth sizing based on worst-case traffic analysis
4. **Overflow Protection** - Diagnostic instrumentation prevents silent failures
5. **Message Serialization** - Protocol-agnostic FIFO transfer pattern
6. **Build Management** - Version tracking for production deployment verification

**Why This Matters for Trading:**

- **Production CDC:** Trading FPGAs have multiple clock domains (network PHY, processing, memory, timestamping)
- **Zero Data Loss:** Race conditions causing message loss are unacceptable in live trading
- **Burst Traffic:** Market open/close generates message bursts requiring proper buffering
- **Diagnostics:** Overflow detection enables capacity planning and failure analysis
- **Scalability:** Clean v3 architecture easy to extend for complete ITCH 5.0 support (v4)

### Files Created/Modified in v3 Refactor

**New Modules:**
- `async_fifo.vhd` - Dual-clock FIFO with gray code CDC (124 lines)
- `itch_msg_pkg.vhd` - Message encoding/decoding package (174 lines)
- `itch_msg_encoder.vhd` - Parser→FIFO adapter with two-stage capture (180 lines)
- `itch_msg_decoder.vhd` - FIFO→Formatter adapter with read delay compensation (169 lines)

**Rewritten:**
- `uart_itch_formatter.vhd` - Simplified to read from FIFO (677→395 lines, 41% reduction)

**Updated:**
- `mii_eth_top.vhd` - Wire async FIFO architecture, remove old CDC synchronizers, add overflow LED
- `README.md` - Comprehensive v3 documentation (885 lines total)

**Build Tracking:**
- `build_version.txt` - Auto-incremented build counter (v1-v45)

---

## Project 07 v4: Protocol Extension and Professional UX

### Extending Production Architecture with New Message Types

**Context:** v3 architecture proved rock-solid with 5 message types (S, R, A, E, X). v4 extends to 9 message types by adding D (Delete), U (Replace), P (Trade), Q (Cross Trade), plus startup banner for professional UX.

### The v4 Goal: Scalability Validation

**Challenge:** Does the v3 async FIFO architecture scale cleanly to additional message types?

**Test:** Add 4 new message types spanning:
- Simple (Order Delete - 19 bytes)
- Complex (Order Replace - 35 bytes, Trade - 44 bytes, Cross Trade - 40 bytes)
- New field types (64-bit cross shares, cross type character)

### Clean Extension Pattern - Zero Architecture Changes

**What Changed:**
1. **itch_msg_pkg.vhd** - Added 4 encode/decode functions
2. **itch_parser.vhd** - Added parsing states for D, U, P, Q
3. **itch_msg_encoder.vhd** - Added capture for 4 new valid signals
4. **itch_msg_decoder.vhd** - Added decode cases for 4 new types
5. **uart_itch_formatter.vhd** - Added formatting for 4 types + startup banner
6. **mii_eth_top.vhd** - Wired 12 new signals through component hierarchy

**What Didn't Change:**
- [PASS] Async FIFO - No modifications needed
- [PASS] Two-stage capture - Handles all message types identically
- [PASS] Clock domain crossing - No CDC changes required
- [PASS] Message serialization format - Accommodated new fields in existing 324-bit width
- [PASS] FSM structure - Clean state additions, no refactoring

**Lesson:** Good architecture scales. v3's design absorbed 80% more message types with zero architectural changes.

### Startup Banner - Professional System Feedback

**Problem:** No visual feedback when FPGA powers up. Operator doesn't know:
- If bitstream loaded successfully
- Which version is running
- If UART is working
- What capabilities are available

**Solution:** Startup banner displayed before processing messages:

```
========================================
  ITCH 5.0 Parser v4 - Arty A7-100T
  Build: v048
  Message Types: S R A E X D U P Q
========================================
Ready for ITCH messages...
```

**Implementation:**
- Added `SEND_BANNER` state to formatter FSM
- Banner formatted once on reset/power-up
- Transitions to normal `IDLE` state after banner sent
- `banner_sent` flag prevents re-sending

**Benefits:**
1. **Immediate visual confirmation** - System is alive, UART working
2. **Version identification** - Confirms correct bitstream programmed
3. **Capability advertisement** - Lists all 9 supported message types
4. **Professional appearance** - Makes system feel production-ready
5. **Debugging aid** - Helps identify communication issues vs bitstream issues

**Lesson:** Professional systems communicate their state. A simple boot banner dramatically improves operator experience.

### Hardware Validation Results

**Test Methodology:**
- Python test script with 9 message generators
- Test sequences: individual messages, lifecycle, all types, multi-symbol
- Hardware: Arty A7-100T @ 100 MHz system clock, 25 MHz PHY clock
- UART: 115200 baud

**Results (from putty.log):**
```
Build v047: 34 messages tested - all 9 types parsed correctly
Build v048: 17 messages tested - banner + all types working
```

**Message Type Coverage:**
- [PASS] **S (System Event):** 6 different event codes (O, S, Q, M, E, C) all decoded
- [PASS] **R (Stock Directory):** 6 different symbols, market categories parsed
- [PASS] **A (Add Order):** Multiple orders, symbols, prices decoded correctly
- [PASS] **E (Order Executed):** Exec shares, match numbers correct
- [PASS] **X (Order Cancel):** Cancel shares parsed
- [PASS] **D (Order Delete):** Order refs extracted correctly  NEW
- [PASS] **U (Order Replace):** Old/new refs, shares, prices all decoded  NEW
- [PASS] **P (Trade):** All fields including 64-bit match number correct  NEW
- [PASS] **Q (Cross Trade):** 64-bit shares, prices, cross types perfect  NEW

**Data Integrity Verification:**
- Prices: `0x0016ED24` = $150.25
- Prices: `0x001E8480` = $200.00
- Prices: `0x017D7840` = $2500.00
- Shares: `0x00000064` = 100
- 64-bit shares: `0x00000000000003E8` = 1000 (cross trade)

**Architecture Validation:**
- Zero message loss across 51 total test messages
- Zero message duplication
- Zero race conditions
- Message counter incrementing correctly (0x00 → 0x21, then 0x00 → 0x10)
- Startup banner displays correctly on every power-up/reprogram

### v4 Development Efficiency

**Time to Implement:**
- 1 session (~2 hours development time)
- Zero debugging required - worked first time on hardware

**Why So Fast:**
1. **v3 Architecture is Solid** - No CDC issues, no race conditions
2. **Clean Abstractions** - Encoding/decoding in package, clear separation
3. **Consistent Patterns** - Each new message type follows same template
4. **Comprehensive Testing** - Python script made validation easy

**Contrast with v2→v3:**
- v2→v3: 20+ builds, major architectural refactor, weeks of debugging
- v3→v4: 2 builds (v047, v048), zero issues, immediate success

**Lesson:** Time invested in good architecture pays massive dividends. v3's solid foundation made v4 trivial.

### Key Lessons from v4 Extension

####  Lesson 1: Scalability Validation Through Extension

**How to Test Architecture:**
- If adding features requires architectural changes → architecture is brittle
- If adding features is straightforward extension → architecture is sound

**v4 Evidence:**
- 9 message types vs 5 (80% increase)
- 12 new signals wired through hierarchy
- 4 new encode/decode functions
- Zero changes to core CDC, FIFO, or synchronization logic

**Lesson:** v3 architecture validated through successful v4 extension.

####  Lesson 2: User Experience in Hardware Systems

**Common Mistake:** Assume operator knows system state through telepathy.

**Professional Approach:**
- Boot banner on power-up
- Version display in output
- Clear "ready" indication
- Capability advertisement

**Impact:**
- Reduces debugging time (is UART working? is bitstream loaded?)
- Prevents confusion (which version is running?)
- Improves confidence (system announces it's ready)

**Lesson:** Hardware systems need UX too. Communicate with your operator.

####  Lesson 3: Incremental Validation Strategy

**v4 Test Progression:**
1. Individual message types (D, U, P, Q separately)
2. Complete lifecycle (A → U → E → P → Q → D)
3. All message types together (S, R, A, E, X, D, U, P, Q)
4. Multi-symbol testing (AAPL, GOOGL, MSFT, TSLA, AMZN, SPY, QQQ)

**Benefits:**
- Isolates issues quickly (if lifecycle fails but individual succeeds → integration problem)
- Builds confidence progressively
- Provides comprehensive coverage

**Lesson:** Test individual components, then integration, then stress testing.

### v4 Complete - Production Ready for Trading Simulation

**Quality Metrics:**
- [PASS] 9 message types (complete ITCH subset for order book simulation)
- [PASS] Zero race conditions (v3 architecture proven)
- [PASS] Zero message loss (two-stage capture + 512-deep FIFO)
- [PASS] 100% parsing accuracy (hardware validated)
- [PASS] Professional UX (startup banner)
- [PASS] Build tracking (v048+)
- [PASS] Comprehensive test infrastructure (Python generators)

**Files Created/Modified in v4:**
- `itch_msg_pkg.vhd` - Added 4 encode/decode functions
- `itch_parser.vhd` - Added D, U, P, Q parsing states
- `itch_msg_encoder.vhd` - Added 4 new message captures
- `itch_msg_decoder.vhd` - Added 4 new decode cases
- `uart_itch_formatter.vhd` - Added 4 message formats + startup banner
- `mii_eth_top.vhd` - Wired 12 new signals
- `send_itch_packets.py` - Added 3 new generators + comprehensive test functions

**Ready For:**
- Phase 3: Symbol filtering (reduce downstream processing load)
- Phase 4: Order book integration (track order lifecycle in hardware)
- Real-world testing with captured ITCH feed data

### Trading System Skills Demonstrated

1. **Protocol Extension** - Added 4 message types without breaking existing functionality
2. **Data Integrity** - Correct parsing of 64-bit fields, big-endian encoding, price conversion
3. **System UX** - Professional startup feedback, version tracking, capability advertisement
4. **Validation Methodology** - Comprehensive test suite validates all message types
5. **Architectural Maturity** - Clean extension proves v3 design is production-grade

**Why v4 Matters for Trading:**
- **Order Replace (U):** Critical for tracking price improvements, cancels+replaces in single operation
- **Trade Messages (P, Q):** Required for execution price confirmation, match number tracking
- **Order Delete (D):** Completes order lifecycle (Add → Execute/Cancel → Delete)
- **Cross Trades (Q):** Opening/closing auction prices, large block trades

v4 provides complete ITCH message coverage for simulating a simple order book with execution tracking.

---

## Project 08: Hardware Order Book - BRAM Inference Mastery

###  Critical Discovery: BRAM Inference Requires Exact Template Patterns

**Context:** Order book implementation required BRAM-based storage for orders and price levels. Initial implementation inferred LUTRAM (Distributed RAM) instead of Block RAM, causing resource waste and incorrect bid price values.

**The Problem:**
- `order_storage.vhd`: Inferred `RAM128X1D x 1040` (LUTRAM) instead of BRAM
- `price_level_table.vhd`: Inferred LUTRAM instead of BRAM
- Symptom: Bid prices consistently `0x00000000` despite orders existing
- Synthesis warning: `"Infeasible attribute ram_style = "block""` - Vivado couldn't infer BRAM

**Root Causes Identified:**

#### 1. Read-Modify-Write Pattern Prevents BRAM Inference

**Problem:** Reading from BRAM signal in write process creates read-modify-write pattern.

**Example (WRONG):**
```vhdl
process(clk)
begin
    if rising_edge(clk) then
        if wr_en = '1' then
            -- Reading from bram in write process = read-modify-write
            prev_valid := bram(to_integer(unsigned(wr_addr)))(129);
            bram(to_integer(unsigned(wr_addr))) <= wr_data;  -- Write
        end if;
    end if;
end process;
```

**Solution:** Separate read and write operations, or use separate storage for tracking.

**Example (CORRECT - Simple Dual-Port):**
```vhdl
-- Write Process (Port A) - Write-only
process(clk)
begin
    if rising_edge(clk) then
        if wr_en = '1' then
            bram(to_integer(unsigned(wr_addr))) <= wr_data;  -- Write only
            valid_bits(to_integer(unsigned(wr_addr))) <= wr_order.valid;  -- Separate array
        end if;
    end if;
end process;

-- Read Process (Port B) - Read-only
process(clk)
begin
    if rising_edge(clk) then
        if rd_en = '1' then
            rd_data <= bram(to_integer(unsigned(rd_addr)));  -- Read only
        end if;
    end if;
end process;
```

**Lesson:** BRAM templates assume simple read/write patterns. Reading in write process breaks the pattern.

#### 2. Read-First Single-Port Requires 2-Stage Pipeline

**Problem:** Single-port BRAM can't read and write simultaneously. Read-modify-write needs pipeline.

**Solution:** 2-stage pipeline following Xilinx Read-First template:

```vhdl
-- Stage 1: Capture command and read from BRAM
process(clk)
begin
    if rising_edge(clk) then
        if cmd_valid = '1' then
            pipe_cmd_type <= cmd_type;
            pipe_cmd_addr <= cmd_addr;
            pipe_cmd_price <= cmd_price;
            pipe_cmd_shares <= cmd_shares;
            bram_addr <= cmd_addr;  -- Set address for read
        end if;
        -- BRAM outputs data on next cycle
        pipe_old_level <= slv_to_price_level(bram_do);
    end if;
end process;

-- Stage 2: Modify and write back
process(clk)
begin
    if rising_edge(clk) then
        if pipe_cmd_type = CMD_ADD then
            new_level := pipe_old_level;
            new_level.total_shares := pipe_old_level.total_shares + pipe_cmd_shares;
            new_level.order_count := pipe_old_level.order_count + 1;
            new_level.valid := '1';
            bram_we <= '1';
            bram_addr <= pipe_cmd_addr;
            bram_di <= price_level_to_slv(new_level);
        end if;
    end if;
end process;
```

**Lesson:** Read-modify-write operations need explicit pipeline stages. Can't read and write in same cycle.

#### 3. `ram_style` Attribute Only Works When Pattern Matches

**Problem:** Adding `attribute ram_style : string; attribute ram_style of bram : signal is "block";` didn't help.

**Why:** Synthesis tools ignore `ram_style` attribute if code pattern doesn't match BRAM template.

**Solution:** Refactor code to match Xilinx template exactly, THEN add `ram_style` attribute.

**Lesson:** `ram_style` attribute is a hint, not a command. Code must match template first.

### Debug Journey: Systematic Root Cause Analysis

**Symptom:** Bid prices always `0x00000000`, ask prices working correctly.

**Debug Process:**

1. **Added scan address debug (`SA`):** Discovered BBO tracker stuck in IDLE, `scan_addr` not initialized
2. **Fixed scan address initialization:** Still no bid prices
3. **Added trigger/ready debug (`Tr`, `Rd`):** Discovered `bbo_trigger` never set
4. **Fixed trigger timing:** Still no bid prices
5. **Added level valid debug (`Lv`, `LdP`, `LdA`):** Discovered `LdP=0x00000000` even when `Lv=1`
6. **Fixed read pipeline timing:** Still no bid prices
7. **Added write debug (`WrA`, `WrP`, `WrS`):** Verified writes happening correctly
8. **Checked synthesis report:** Discovered LUTRAM inference instead of BRAM
9. **Refactored to BRAM templates:** Bid prices now working!

**Key Insight:** Each debug addition revealed the next layer of the problem. Systematic instrumentation enabled rapid diagnosis.

### BRAM Template Patterns

**Simple Dual-Port (order_storage):**
- Two separate processes (write port A, read port B)
- Write process: Write-only, no reads
- Read process: Read-only, no writes
- Use `shared variable` OR `signal` (both work, `signal` preferred for Simple Dual-Port)

**Read-First Single-Port (price_level_table):**
- Single process with 2-stage pipeline
- Stage 1: Read from BRAM
- Stage 2: Modify and write back
- Explicit BRAM control signals (`bram_do`, `bram_we`, `bram_addr`, `bram_di`)

**Key Differences:**
- Simple Dual-Port: Two independent ports (can read and write simultaneously to different addresses)
- Single-Port: One port (read-modify-write requires pipeline)

### Order Count Tracking Without Read-Modify-Write

**Problem:** Need to track order count (increment on add, decrement on delete), but reading old valid bit in write process prevents BRAM inference.

**Solution:** Separate `valid_bits` array for tracking:

```vhdl
-- Separate storage for valid bits (small, can be LUTRAM)
type valid_bits_t is array (0 to MAX_ORDERS-1) of std_logic;
signal valid_bits : valid_bits_t := (others => '0');

-- Order count tracking reads from valid_bits, not BRAM
process(clk)
begin
    if rising_edge(clk) then
        if wr_en = '1' then
            prev_valid := valid_bits(to_integer(unsigned(wr_addr)));  -- Read from separate array
            -- Update count based on prev_valid vs wr_order.valid
            valid_bits(to_integer(unsigned(wr_addr))) <= wr_order.valid;  -- Update tracking
        end if;
    end if;
end process;
```

**Lesson:** Separate small tracking arrays are acceptable (LUTRAM is fine for 1024 bits). Main BRAM must follow template exactly.

### Pipeline Latency Handling

**Problem:** BRAM has 1-2 cycle read latency. FSM assuming immediate data availability fails.

**Solution:** Add wait states and counters:

```vhdl
-- Wait for 2-cycle BRAM read latency
when WAIT_PRICE_CMD =>
    if wait_counter > 0 then
        wait_counter <= wait_counter - 1;
    else
        state <= NEXT_STATE;
    end if;

-- Initialize wait counter
when UPDATE_PRICE_ADD =>
    price_cmd_valid <= '1';
    wait_counter <= 2;  -- 2-cycle latency
    state <= WAIT_PRICE_CMD;
```

**Lesson:** Always account for memory latency in state machines. BRAM is not combinational - data arrives 1-2 cycles after address is set.

### Key Architectural Lessons

####  Lesson 1: BRAM Templates Are Not Suggestions

**Problem:** "Close enough" code doesn't infer BRAM. Synthesis tools are pattern-matching, not intelligent.

**Solution:** Copy Xilinx template exactly:
- Same process structure
- Same signal assignments
- Same timing patterns
- THEN add `ram_style` attribute

**Lesson:** Don't try to be clever. Follow the template exactly.

####  Lesson 2: Read-Modify-Write Needs Architecture Changes

**Problem:** Can't read and write BRAM in same cycle (single-port) or same process (breaks template).

**Solution:**
- Single-Port: Use 2-stage pipeline
- Dual-Port: Use separate ports for read and write
- Tracking: Use separate small arrays

**Lesson:** Complex operations require architectural changes, not just code fixes.

####  Lesson 3: Debug Infrastructure Enables Rapid Diagnosis

**Problem:** "Bid prices are zero" provides no actionable information.

**Solution:** Comprehensive debug outputs:
- Scan addresses (`LdA`)
- Read data (`LdP`)
- Write operations (`WrA`, `WrP`, `WrS`)
- State machine status (`St`, `Tr`, `Rd`)

**Lesson:** Strategic instrumentation enables rapid root cause diagnosis. Each debug addition revealed the next layer.

### Trading System Relevance

**Skills Demonstrated:**

1. **BRAM Architecture** - Efficient on-chip memory for order storage and price levels
2. **Memory Inference** - Production-grade BRAM inference (not LUTRAM)
3. **FSM Design** - Complex state machines for order processing and BBO tracking
4. **Pipeline Design** - 2-cycle read-modify-write pipelines
5. **Debug Methodology** - Systematic debugging with strategic instrumentation

**Why This Matters for Trading:**

- **Order Book Core:** Essential data structure for all electronic trading systems
- **Deterministic Latency:** Hardware implementation guarantees fixed processing time
- **Resource Efficiency:** BRAM vs LUTRAM affects available logic resources
- **Production Patterns:** BRAM inference, FSM design, debug infrastructure mirror production systems

---

## Project 13: UDP BBO Transmitter - Mixed-Language Integration & Timing Closure

###  Critical Lesson 1: SystemVerilog/VHDL Mixed-Language Wrapper Pattern

**The Challenge:** Integration of SystemVerilog module (`eth_udp_send`) using interfaces (`IEthPhy`, `IIpInfo`) into VHDL top-level design.

**Wrong Approach:** Direct instantiation of SystemVerilog interfaces in VHDL
```vhdl
-- This DOES NOT WORK - interfaces are not entities
IEthPhy_inst: entity work.IEthPhy port map (...);
IIpInfo_inst: entity work.IIpInfo port map (...);
```

**Right Approach:** SystemVerilog wrapper that flattens interfaces to individual ports

```systemverilog
module eth_udp_send_wrapper (
    // Flattened IEthPhy signals
    output logic eth_ref_clk,
    output logic eth_rstn,
    input logic eth_tx_clk,
    output logic eth_tx_en,
    output logic [3:0] eth_txd,

    // Flattened IIpInfo signals
    input logic [31:0] ip_src,
    input logic [47:0] mac_src,
    // ...
);
    // Instantiate interfaces internally
    IEthPhy eth();
    IIpInfo ip_info();

    // Connect flat ports to interface
    assign eth.ref_clk = clk25;
    assign eth_ref_clk = eth.ref_clk;
    // ...

    // Instantiate actual module with interfaces
    eth_udp_send eth_udp_send_inst (
        .eth(eth),
        .ip_info(ip_info),
        // ...
    );
endmodule
```

**VHDL Instantiation:**
```vhdl
eth_udp_send_inst: entity work.eth_udp_send_wrapper
    port map (
        eth_ref_clk => open,  -- Generated internally
        eth_rstn => open,     -- Generated internally
        eth_tx_clk => eth_tx_clk,
        eth_tx_en => eth_tx_en,
        eth_txd => eth_txd,
        ip_src => x"C0A800D4",  -- Individual signals, not interface
        mac_src => MY_MAC_ADDR,
        -- ...
    );
```

**Lesson:** SystemVerilog interfaces cannot cross language boundaries. Wrapper pattern flattens interfaces for VHDL compatibility while preserving interface-based design internally.

---

###  Critical Lesson 2: XDC Timing Constraints for Generated vs PHY Clocks

**The Challenge:** Timing violations (WNS=-0.863ns) on TX path even with correct design.

**Root Cause:** TX outputs constrained to wrong clock domain (`eth_tx_clk` from PHY instead of `clk_25mhz` generated clock).

**Wrong XDC:**
```tcl
## eth_tx_clk is from PHY, but eth_udp_send doesn't use it!
set_output_delay -clock eth_tx_clk -max 10.0 [get_ports {eth_txd[*] eth_tx_en}]
```

**Right XDC:**
```tcl
## CRITICAL: eth_udp_send uses clk25 (clk_25mhz) not eth_tx_clk
## Define clk_25mhz as generated clock
create_generated_clock -name clk_25mhz \
    -source [get_pins -hierarchical -filter {NAME =~ "*ref_clock_gen/CLKOUT0"}] \
    -divide_by 1 \
    [get_pins -hierarchical -filter {NAME =~ "*ref_clk_bufg/O"}]

## Constrain TX outputs to actual clock domain used
set_output_delay -clock clk_25mhz -max 8.0 [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock clk_25mhz -min -2.0 [get_ports {eth_txd[*] eth_tx_en}]

## Mark eth_tx_clk as false path since it's not used
set_false_path -from [get_clocks eth_tx_clk]
set_false_path -to [get_clocks eth_tx_clk]
```

**Lesson:** Always constrain outputs to the actual clock domain driving them. Generated clocks must be explicitly defined in XDC with correct source pin. Unused clocks from PHY should be marked as false paths.

**Why This Matters:**
- eth_udp_send internally uses `clk25` (generated from PLL) for TX state machine
- PHY's `eth_tx_clk` is not used by the design (design is clock-source mode, not slave mode)
- Constraining to wrong clock causes Vivado to analyze impossible timing paths
- Result: False violations or missed real violations

---

###  Critical Lesson 3: Pipeline State Machine for Timing Closure

**The Challenge:** Combinational arithmetic in nibble extraction violated timing (complex index calculations).

**Initial Implementation (Failed Timing):**
```vhdl
when WRITE_NIBBLES =>
    if wr_busy = '0' then
        -- Complex arithmetic in single cycle
        byte_index := nibble_index / 2;
        if (nibble_index mod 2) = 1 then
            wr_d <= packet_data(byte_index)(3 downto 0);  -- Lower nibble
        else
            wr_d <= packet_data(byte_index)(7 downto 4);  -- Upper nibble
        end if;
        wr_en <= '1';
        nibble_index <= nibble_index - 1;
    end if;
```

**Timing-Optimized Implementation:**
```vhdl
-- Separate calculation and write into 2 states
signal nibble_to_write : std_logic_vector(3 downto 0);

when CALC_NIBBLE =>
    -- Pipeline stage 1: Calculate and register nibble
    byte_index := wr_i / 2;
    is_lower_nibble := (wr_i mod 2) = 1;

    if is_lower_nibble then
        nibble_to_write <= packet_vector(8*byte_index + 3 downto 8*byte_index);
    else
        nibble_to_write <= packet_vector(8*byte_index + 7 downto 8*byte_index + 4);
    end if;

    state <= WRITE_NIBBLE;

when WRITE_NIBBLE =>
    -- Pipeline stage 2: Write pre-registered nibble
    if wr_busy = '0' then
        wr_d <= nibble_to_write;  -- No arithmetic here!
        wr_en <= '1';
        wr_i <= wr_i - 1;
        state <= CALC_NIBBLE;
    end if;
```

**Lesson:** Separate complex arithmetic from registered outputs. Pre-register computed values to reduce combinational delay.

**Additional Optimization:** Changed from `packet_data` byte array to `packet_vector` single vector for simpler nibble extraction (slice indexing vs array+bit indexing).

---

###  Lesson 4: UDP Packet Format and Nibble Write Order

**Nibble Write Pattern (from fpga-ethernet-udp reference):**
```systemverilog
// Lower nibble first (odd index), then upper nibble (even index)
wr_d <= eth_d[8 * (wr_i >> 1) + 4 * ((~wr_i) & 1)+:4];
```

**Translation to VHDL:**
```vhdl
byte_index := wr_i / 2;
is_lower_nibble := (wr_i mod 2) = 1;

if is_lower_nibble then
    nibble_to_write <= packet_vector(8*byte_index + 3 downto 8*byte_index);
else
    nibble_to_write <= packet_vector(8*byte_index + 7 downto 8*byte_index + 4);
end if;
```

**Result:** BBO data appears at bytes 228-255 of 256-byte payload (due to nibble reversal).

**Packet Structure:**
- Bytes 0-227: Padding (zeros)
- Bytes 228-255: BBO data (Symbol + Bid/Ask/Spread)
- Big-endian format for multi-byte integers
- Fixed-point prices (4 decimal places: `1,495,000 = $149.50`)

**Lesson:** Understanding reference nibble write order critical for correct data placement. Binary protocol requires careful byte order documentation for client parsers.

---

###  Lesson 5: Production Trading System UDP Architecture

**Why UDP for BBO Distribution:**
- **Low Latency:** No TCP handshake/ACK overhead
- **Multicast Capable:** Single packet → multiple receivers
- **Fire-and-Forget:** Order book updates are snapshots, not state transitions
- **Trading Standard:** Exchange market data feeds use UDP multicast

**Architecture Pattern:**
```
FPGA Order Book (100 MHz)
    ↓
BBO UDP Formatter (100 MHz)
    ↓ (nibble writes)
eth_udp_send (clk25 = 25 MHz)
    ↓
MII TX (25 MHz, 4-bit nibbles)
    ↓
Ethernet PHY
    ↓
UDP/IP Packet (192.168.0.212:5000 → 192.168.0.93:5000)
```

**Key Decisions:**
- **UART for Debug Only:** Frees UART for debug messages, UDP handles market data
- **256-Byte Payload:** Matches eth_udp_send MIN_DATA_BYTES (padding acceptable for low-frequency BBO updates)
- **Broadcast MAC:** Allows any receiver on LAN to capture BBO updates
- **Binary Format:** More efficient than ASCII/JSON for high-frequency updates

**Lesson:** Separate data plane (UDP market data) from control plane (UART debug). Binary protocols with fixed-size payloads simplify FPGA formatting logic.

---

**Key Achievements:**
1. **Mixed-Language Integration** - SystemVerilog wrapper pattern for VHDL interoperability
2. **Timing Closure** - Correct XDC constraints for generated clocks, pipelined state machine
3. **UDP Transmission** - Real-time BBO distribution with **312 ns** ITCH-to-UDP latency (4-point hardware-measured)
4. **Production Pattern** - Standard trading system architecture (UDP market data, UART debug)
5. **Binary Protocol** - Efficient packet format with Python/C++ parsing support

**Why This Matters for Trading:**
- **Standard Architecture:** Production trading systems use UDP for market data distribution
- **Language Flexibility:** Ability to integrate existing IP (SystemVerilog eth_udp_send) into VHDL system
- **Timing Discipline:** XDC constraint mastery essential for meeting strict latency requirements
- **Protocol Design:** Binary format design and documentation skills directly applicable to exchange feeds

---

## Projects 9-12: Application Layer - Multi-Protocol Distribution Architecture

###  Critical Decision: Protocol Selection for Different Client Types

**The Challenge:** How to distribute FPGA BBO data to diverse application types (desktop, mobile, IoT)?

**Wrong Approach:** Use single protocol for everything
- [FAIL] TCP for mobile → Poor handling of unreliable networks (WiFi/cellular)
- [FAIL] MQTT for desktop → Unnecessary broker latency for localhost
- [FAIL] Kafka for ESP32 → Too heavy for 520KB RAM microcontroller

**Right Approach:** Multi-protocol gateway matching protocol to use case

```
FPGA → C++ Gateway ─┬→ TCP (localhost:9999) → Java Desktop
                    ├→ MQTT (broker:1883) → ESP32 IoT + Mobile App
                    └→ Kafka (broker:9092) → Future Analytics
```

**Lesson:** Match protocol to client requirements:
- **TCP:** Desktop apps (low latency, persistent connection, localhost)
- **MQTT:** Mobile/IoT (lightweight, unreliable networks, low power, QoS)
- **Kafka:** Backend services (data persistence, replay, analytics, microservices)

---

### Project 09: C++ Order Gateway - Multi-Protocol Publisher

####  Lesson 1: Protocol Independence Through Gateway Pattern

**Architecture:**
```cpp
class OrderGateway {
    UartReader uart;           // Read from FPGA
    BboParser parser;          // Hex → Decimal

    // Three independent publishers
    TcpServer tcpServer;       // Desktop clients
    MqttPublisher mqttPub;     // IoT/Mobile clients
    KafkaProducer kafkaProd;   // Analytics (future)
};
```

**Benefits:**
- FPGA doesn't know about protocols (just UART output)
- Clients don't know about FPGA (just JSON input)
- Add/remove protocols without changing FPGA or clients
- Each protocol optimized for its use case

**Lesson:** Gateway pattern decouples producers from consumers, enabling protocol diversity.

---

####  Lesson 2: MQTT v3.1.1 vs v5.0 Compatibility

**Problem:** MQTTnet 5.x defaults to MQTT v5.0, but ESP32/mobile need v3.1.1

**Symptoms:**
- .NET MAUI app connects, but ESP32 fails
- C++ gateway publishes, but mobile app times out
- Broker logs show "Protocol version mismatch"

**Root Cause:** Protocol version negotiation
- MQTTnet 5.x → MQTT v5.0 by default
- ESP32 PubSubClient → MQTT v3.1.1 only
- Mosquitto broker → Supports both, but clients must match

**Solution:** Force MQTT v3.1.1 for compatibility

```csharp
// .NET MAUI Mobile App (MQTTnet 5.x)
var options = new MqttClientOptionsBuilder()
    .WithProtocolVersion(MqttProtocolVersion.V311)  // ← Critical!
    .WithTcpServer(_brokerUrl, _port)
    .Build();
```

```cpp
// ESP32 (PubSubClient - always v3.1.1)
PubSubClient mqtt(wifiClient);  // Already v3.1.1
mqtt.connect(CLIENT_ID, MQTT_USER, MQTT_PASS);
```

**Lesson:** When supporting multiple MQTT clients, force lowest common protocol version.

---

####  Lesson 3: Kafka for Future vs Active Use

**Decision:** Implement Kafka producer, but no consumers yet

**Rationale:**
- Gateway complexity: Minimal (librdkafka already integrated)
- Future flexibility: Can add Kafka consumers anytime without gateway changes
- Current need: None (TCP + MQTT sufficient for active clients)

**Future Use Cases for Kafka:**
1. **Time-Series Database:** Write all BBO updates to InfluxDB/TimescaleDB
2. **Historical Replay:** Backtesting engine consuming past market data
3. **Analytics Pipelines:** Spark/Flink for real-time computations
4. **Machine Learning:** Feature generation from live + historical data
5. **Compliance:** Immutable audit log for regulatory requirements

**Lesson:** Build infrastructure before you need it, if cost is minimal. Gateway publishes to Kafka now, consumers can be added when needed.

---

### Project 10: ESP32 IoT Ticker - MQTT for Low Power

####  Lesson 1: Why MQTT is Perfect for IoT

**ESP32 Constraints:**
- 520KB RAM (no room for Kafka client)
- Battery powered (need low power protocol)
- WiFi (unreliable network, connection drops)
- Limited CPU (240MHz dual-core, not x86)

**MQTT Advantages:**
- Lightweight (QoS 0 = fire-and-forget, minimal overhead)
- Handles disconnects (broker queues messages with QoS 1/2)
- Native ESP32 library (PubSubClient)
- Low power (sleep between messages, wake on WiFi)
- Small payload (JSON, not Kafka binary protocol)

**Comparison:**

| Protocol | RAM Usage | Power | Reconnect | ESP32 Library |
|----------|-----------|-------|-----------|---------------|
| MQTT | ~5KB | Low | Automatic | [PASS] PubSubClient |
| Kafka | ~50KB+ | High | Manual | [FAIL] None |
| TCP | ~10KB | Medium | Manual | [PASS] WiFiClient |

**Lesson:** IoT devices need lightweight protocols with graceful disconnects. MQTT designed for this.

---

####  Lesson 2: TFT Display Update Throttling

**Problem:** MQTT messages arrive faster than TFT can refresh (50-100ms per update)

**Naive Approach:**
```cpp
void callback(char* topic, byte* payload, unsigned int length) {
    parseBbo(payload);
    tft.fillScreen(TFT_BLACK);  // Clear screen
    drawBbo(currentBbo);        // Redraw
}
// Result: Flickering, slow, unreadable
```

**Production Approach:**
```cpp
unsigned long lastUpdate = 0;
const unsigned long UPDATE_INTERVAL = 500;  // 500ms minimum

void callback(char* topic, byte* payload, unsigned int length) {
    parseBbo(payload);  // Always parse (update data)
    // But only redraw if enough time passed
    if (millis() - lastUpdate > UPDATE_INTERVAL) {
        drawBbo(currentBbo);
        lastUpdate = millis();
    }
}
```

**Lesson:** Decouple data updates from UI updates. Always parse incoming data, but throttle expensive rendering.

---

### Project 11: .NET MAUI Mobile App - MQTT for Cross-Platform

####  Lesson 1: Why NOT Kafka for Mobile

**Android Compatibility Issues:**
- Confluent.Kafka → Native librdkafka.so (x86/ARM builds required)
- APK size bloat (native libraries for all architectures)
- Background service restrictions (Android 12+ kills long-running Kafka consumers)
- Battery drain (persistent TCP connections)

**MQTT Wins for Mobile:**
- MQTTnet → Pure .NET (no native dependencies)
- Works on Android/iOS/Windows without changes
- Handles network switching (WiFi → 4G seamlessly)
- QoS levels (0 = fire-forget for battery, 1 = guaranteed delivery)
- Small payload overhead

**Lesson:** Mobile apps should use MQTT or WebSocket, never Kafka directly. Leave Kafka for backend services.

---

####  Lesson 2: MQTTnet 5.x Breaking Changes

**Problem:** Upgrading .NET 8 → .NET 10 required MQTTnet 4.x → 5.x

**Breaking Changes:**

| MQTTnet 4.x | MQTTnet 5.x | Impact |
|-------------|-------------|--------|
| `e.Reason?.ToString()` | `e.Reason.ToString()` | `Reason` now non-nullable enum |
| `new MqttFactory()` | `new MqttClientFactory()` | Factory renamed |
| Auto v5.0 protocol | Must force v3.1.1 | ESP32 compatibility |

**Build Error:**
```csharp
// [FAIL] MQTTnet 5.x ERROR
var reason = e.Reason?.ToString() ?? "Unknown";
// CS0023: Operator '?' cannot be applied to operand of type 'MqttClientDisconnectReason'

// [PASS] MQTTnet 5.x FIX
var reason = e.Reason.ToString();  // Enum is non-nullable now
```

**Lesson:** Major version upgrades break APIs. Always check migration guides. Test thoroughly.

---

####  Lesson 3: MVVM Toolkit Property Generation

**Problem:** Compiler warnings when accessing private fields directly

```csharp
// [FAIL] Causes MVVM Toolkit warning
[ObservableProperty]
private string _brokerUrl = "192.168.0.2";

private void Connect() {
    _mqttService = new MqttService(_brokerUrl, _port);  // Warning!
}
```

**Reason:** `[ObservableProperty]` generates public `BrokerUrl` property. Using `_brokerUrl` bypasses property change notifications.

**Solution:** Use generated properties

```csharp
[ObservableProperty]
private string _brokerUrl = "192.168.0.2";  // Generates 'BrokerUrl'

private void Connect() {
    _mqttService = new MqttService(BrokerUrl, Port);  // [PASS] Use generated property
}
```

**Lesson:** Source generators create boilerplate code. Use generated members, not private fields.

---

### Project 12: Java Desktop Terminal - TCP for Low Latency

####  Lesson 1: Why TCP for Desktop Applications

**Desktop Advantages:**
- localhost = < 1ms latency (no network hops)
- Persistent connection (no broker overhead)
- Simple request/response model
- Native Java Socket API (no external dependencies)

**MQTT/Kafka Overhead:**
- MQTT: Broker adds 5-20ms latency (even on localhost)
- Kafka: Consumer group coordination, offset management
- Both: Authentication, heartbeats, QoS/acknowledgments

**Performance Comparison (localhost):**

| Protocol | Latency | CPU Usage | Complexity |
|----------|---------|-----------|------------|
| TCP | < 1ms | ~1% | Simple |
| MQTT | 5-20ms | ~3% | Broker required |
| Kafka | 10-50ms | ~5% | Consumer groups |

**Lesson:** For desktop apps on localhost, TCP is simplest and fastest. Only use message brokers if you need their features (persistence, multiple consumers, etc.).

---

####  Lesson 2: JavaFX Thread Confinement

**Problem:** Network I/O updates UI from background thread → crash

```java
// [FAIL] CRASHES - UI update from network thread
private void onBboReceived(BboUpdate bbo) {
    bboTable.getItems().add(bbo);  // IllegalStateException!
}
```

**Reason:** JavaFX UI components are not thread-safe. Must update from FX Application Thread.

**Solution:** Platform.runLater()

```java
// [PASS] WORKS - Marshals to FX thread
private void onBboReceived(BboUpdate bbo) {
    Platform.runLater(() -> {
        bboTable.getItems().add(bbo);  // Safe on FX thread
    });
}
```

**Lesson:** Desktop UI frameworks require thread confinement. Always marshal UI updates to correct thread (JavaFX = `Platform.runLater()`, WPF = `Dispatcher.Invoke()`, Swing = `SwingUtilities.invokeLater()`).

---

####  Lesson 3: JSON Streaming with Newline Delimiters

**Problem:** TCP is byte stream, not message stream. How to separate JSON objects?

**Naive Approach:** Wait for `}`
```java
// [FAIL] BREAKS on nested objects
String json = "";
while ((char c = reader.read()) != '}') {
    json += c;
}
// Fails: {"bid":{"price":150.75,"shares":100}} ← multiple '}'
```

**Production Approach:** Newline-delimited JSON

**C++ Gateway:**
```cpp
std::string json = bbo.toJson();
tcpClient.send(json + "\n");  // ← One message per line
```

**Java Client:**
```java
BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream()));
String line;
while ((line = reader.readLine()) != null) {  // ← Read until '\n'
    BboUpdate bbo = gson.fromJson(line, BboUpdate.class);
    onBboReceived(bbo);
}
```

**Lesson:** For JSON over TCP, use newline delimiters (one JSON object per line). Simple, robust, compatible with standard tools (jq, grep).

---

### Key Architectural Lessons: Projects 9-12

####  Lesson 1: Protocol Selection is a System Design Decision

**Trade-offs:**

| Use Case | Protocol | Why |
|----------|----------|-----|
| Desktop trading terminal | TCP | Low latency, simple, localhost |
| ESP32 IoT display | MQTT | Lightweight, low power, WiFi resilience |
| Mobile app (Android/iOS) | MQTT | Cross-platform, handles network switching |
| Backend analytics | Kafka | Data persistence, replay, microservices |

**Lesson:** Don't force one protocol for everything. Match protocol to client requirements.

---

####  Lesson 2: Gateway Pattern Enables Protocol Diversity

**Without Gateway (Tightly Coupled):**
```
FPGA → Kafka → Java Desktop [FAIL] (Kafka overhead for desktop)
FPGA → TCP → ESP32 [FAIL] (No TCP on ESP32)
FPGA → MQTT → Analytics [FAIL] (MQTT not designed for data pipelines)
```

**With Gateway (Loosely Coupled):**
```
FPGA → C++ Gateway ─┬→ TCP → Java Desktop
                    ├→ MQTT → ESP32
                    ├→ MQTT → Mobile
                    └→ Kafka → Analytics
```

**Lesson:** Gateway/adapter pattern is essential for heterogeneous systems. Decouple producers from consumers.

---

####  Lesson 3: Cross-Platform Development Has Hidden Costs

**Challenges Encountered:**

1. **MQTTnet 5.x Breaking Changes** (.NET 8 → .NET 10 upgrade)
   - Solution: Read migration guides, test thoroughly

2. **MQTT v3.1.1 vs v5.0 Compatibility** (ESP32 vs mobile app)
   - Solution: Force v3.1.1 for all clients

3. **Native Library Dependencies** (Kafka on Android)
   - Solution: Use pure .NET/Java libraries (MQTTnet, not Confluent.Kafka)

4. **Thread Confinement** (JavaFX, .NET MAUI)
   - Solution: Platform.runLater(), MainThread.InvokeOnMainThreadAsync()

**Lesson:** Cross-platform means dealing with lowest common denominator. Test on all target platforms early.

---

### Trading System Skills Demonstrated (Projects 9-12)

**C++ Systems Programming:**
- Multi-threaded architecture (UART reader, TCP server, MQTT publisher)
- Boost.Asio for async I/O
- Protocol libraries (libmosquitto, librdkafka)
- RAII and modern C++17/20 patterns (C++17 for Project 9, C++20 for Projects 14-16)

**Mobile Development:**
- .NET MAUI cross-platform framework
- MVVM architecture with CommunityToolkit
- Async programming (async/await)
- Mobile-optimized protocols (MQTT)

**Java Desktop Development:**
- JavaFX UI framework
- Multi-threading and thread confinement
- TCP socket programming
- Maven build system

**IoT/Embedded:**
- ESP32 WiFi microcontroller
- MQTT client (PubSubClient)
- TFT display driver (SPI interface)
- Arduino framework

**Protocol Knowledge:**
- TCP (byte streams, newline delimiters)
- MQTT (QoS levels, v3.1.1 vs v5.0, broker architecture)
- Kafka (producers, topics, partitions)
- JSON serialization/deserialization

**System Architecture:**
- Multi-protocol gateway pattern
- Protocol selection trade-offs
- Loose coupling through middleware
- Scalability and extensibility

---

## Project 15-16: Order Execution Loop - Key Lessons

### Lesson 1: Bidirectional IPC Requires Careful Design

**Problem:** Market Maker (Project 15) needs to send orders AND receive fills from Order Execution Engine (Project 16)

**Wrong Approach (Shared State):**
```cpp
// [FAIL] Shared variables with mutexes (high latency, deadlock risk)
std::mutex order_mutex;
std::queue<OrderRequest> pending_orders;

std::mutex fill_mutex;
std::queue<FillNotification> pending_fills;
```

**Right Approach (Dual Ring Buffers):**
```cpp
// [PASS] Two separate Disruptor ring buffers (lock-free, unidirectional)
OrderRingBuffer order_ring("/dev/shm/order_ring_mm");  // P15 → P16
FillRingBuffer fill_ring("/dev/shm/fill_ring_oe");    // P16 → P15
```

**Why It Matters:**
- **Unidirectional flow:** Each ring has single writer, single reader (no contention)
- **Lock-free:** Atomic sequence cursors enable sub-microsecond latency
- **Shared memory:** Zero-copy IPC via `/dev/shm`
- **Predictable:** No mutexes, no condition variables, no deadlocks

**Lesson:** For bidirectional IPC, use two unidirectional channels instead of one bidirectional channel

---

### Lesson 2: Sequencer.is_available() Method Critical for Consumers

**Problem:** OrderRingBuffer and FillRingBuffer consumers need to check if data is available before reading

**Initial Implementation (Missing Method):**
```cpp
// [FAIL] Compilation error: no is_available() method
if (consumer.is_available(seq)) {
    auto event = consumer.read(seq);
}
// error: 'class disruptor::Sequencer' has no member named 'is_available'
```

**Solution (Added to Sequencer.h):**
```cpp
// [PASS] Check if sequence is available for consumption
bool is_available(int64_t sequence) const {
    return sequence <= cursor_.load(std::memory_order_acquire);
}
```

**Why It Matters:**
- Consumers must know if producer has published data at a sequence
- Prevents reading uninitialized/stale data
- Enables non-blocking polling in busy-wait loops
- Standard Disruptor pattern for consumer sequencing

**Lesson:** When implementing Disruptor pattern, consumers MUST check sequence availability before reading

---

### Lesson 3: OrderProducer Namespace Issue

**Problem:** Compilation failed with "OrderProducer is not a member of 'mm'"

**Initial Code (Wrong):**
```cpp
// [FAIL] Assumed OrderProducer was in mm namespace
std::unique_ptr<mm::OrderProducer> order_producer_;
```

**Reality Check:**
```cpp
// OrderProducer definition (no namespace)
class OrderProducer {
    // ...
};
```

**Solution:**
```cpp
// [PASS] OrderProducer is in global namespace
std::unique_ptr<OrderProducer> order_producer_;
```

**Why It Matters:**
- Assumptions about code structure can be wrong
- Always verify namespace/scope before using
- Good practice: Check header files for actual declarations
- Namespace pollution: Sometimes classes intentionally live in global namespace

**Lesson:** Don't assume namespace membership. Verify declarations in header files.

---

### Lesson 4: Config-Driven Feature Flags for Optional Integration

**Problem:** Not all users want order execution enabled (testing, phased rollout, etc.)

**Wrong Approach (Always Enabled):**
```cpp
// [FAIL] Order execution always active
OrderProducer order_producer(order_ring_path, fill_ring_path);
```

**Right Approach (Config Flag):**
```cpp
// [PASS] Optional integration via config
struct Config {
    bool enable_order_execution = false;  // Default: disabled
    std::string order_ring_path = "/dev/shm/order_ring_mm";
    std::string fill_ring_path = "/dev/shm/fill_ring_oe";
};

// In constructor
if (config_.enable_order_execution) {
    try {
        order_producer_ = std::make_unique<OrderProducer>(
            config_.order_ring_path, config_.fill_ring_path);
    } catch (const std::exception& e) {
        logger_->error("Failed to initialize order producer: {}", e.what());
    }
}
```

**Why It Matters:**
- **Phased rollout:** Test market maker without order execution first
- **Graceful degradation:** System works even if Project 16 isn't running
- **Configuration flexibility:** Different environments (dev/test/prod) have different needs
- **Error handling:** Catch failures during initialization, log clearly

**Lesson:** Use feature flags for optional integrations. Default to disabled for safety.

---

### Lesson 5: FIX Protocol is Verbose But Explicit

**Problem:** Need industry-standard order execution protocol

**Alternative 1 (Binary Protocol):**
```cpp
// [FAIL] Custom binary format (compact but non-standard)
struct OrderMessage {
    char order_id[16];
    char symbol[8];
    char side;
    uint32_t quantity;
    uint32_t price;
};  // 37 bytes
```

**Alternative 2 (FIX 4.2 Protocol):**
```cpp
// [PASS] FIX 4.2 (verbose but industry-standard)
8=FIX.4.2|9=XXX|35=D|49=MM|56=OE|11=MM0000000001|21=1|55=AAPL|
54=1|38=100|40=2|44=150.00|60=20251126-14:30:00|10=XXX|
// ~120 bytes
```

**Trade-offs:**

| Aspect | Binary Protocol | FIX 4.2 Protocol |
|--------|----------------|------------------|
| **Size** | 37 bytes (compact) | ~120 bytes (verbose) |
| **Speed** | Faster (less parsing) | Slower (field parsing) |
| **Standard** | [FAIL] Custom (not portable) | [PASS] Industry standard |
| **Debugging** | [FAIL] Hex dumps (hard to read) | [PASS] Human-readable ASCII |
| **Interop** | [FAIL] Only works with custom code | [PASS] Works with all FIX systems |
| **Resume** | [FAIL] Need custom docs | [PASS] FIX spec is the doc |

**Why FIX Wins:**
- **Portability:** Any FIX-compliant system can parse messages
- **Debugging:** Human-readable format (8=FIX.4.2|35=D|55=AAPL)
- **Resume value:** FIX experience is highly valued in trading firms
- **Industry standard:** All exchanges, brokers, trading systems use FIX

**Lesson:** For trading systems, use FIX protocol even if it's verbose. The benefits outweigh the overhead.

---

### Lesson 6: Simulated Exchange vs Real Exchange

**Implementation Choice:**
```cpp
// Simulated Exchange (Project 16)
bool match_order(const OrderRequest& order, FillNotification& fill) {
    // Immediate fill at order price (100% fill rate)
    fill.fill_qty = order.quantity;
    fill.avg_price = order.price;
    fill.exec_type = '2';  // Trade
    fill.ord_status = '2';  // Filled
    return true;
}
```

**vs Real Exchange:**
```cpp
// Real Exchange (Production)
bool match_order(const OrderRequest& order, Book& book) {
    // Check if liquidity exists at price
    if (!book.has_liquidity(order.price, order.side)) {
        return false;  // Reject (no fill)
    }

    // Partial fills possible
    uint32_t filled_qty = book.match(order.price, order.quantity, order.side);

    // Order may rest in book
    if (filled_qty < order.quantity) {
        book.add_order(order, order.quantity - filled_qty);
    }

    return filled_qty > 0;
}
```

**Differences:**

| Aspect | Simulated Exchange | Real Exchange |
|--------|-------------------|---------------|
| **Fill Rate** | 100% (always fills) | Variable (depends on liquidity) |
| **Partial Fills** | No (always full fill) | Yes (common) |
| **Rejections** | Never | Yes (no liquidity, risk checks) |
| **Order Book** | Not maintained | Full limit order book |
| **Complexity** | Simple (~50 LOC) | Complex (~5000+ LOC) |
| **Purpose** | Testing order flow | Production trading |

**Why Simulated is Sufficient for Testing:**
- Validates order execution loop (Project 15 → 16 → 15)
- Tests FIX protocol encoding/decoding
- Verifies Disruptor bidirectional communication
- Confirms position tracking with fills
- Portfolio demonstration value

**Lesson:** Start with simulated exchange for testing. Add realistic matching engine later if needed.

---

### Lesson 7: processFills() Must Be Called in Main Loop

**Problem:** Market Maker generates orders but doesn't process fills

**Initial Code (Missing):**
```cpp
// [FAIL] Main loop without fill processing
while (running) {
    handle_bbo_update();  // Receives BBO, generates quotes
    // Fills pile up in ring buffer, position never updates!
}
```

**Solution (Added processFills):**
```cpp
// [PASS] Main loop with fill processing
while (running) {
    handle_bbo_update();     // BBO → Quote generation
    processFills();          // Read fills → Update position
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

void processFills() {
    if (!order_producer_) return;

    trading::FillNotification fill;
    while (order_producer_->try_read_fill(fill)) {
        int shares = (fill.side == 'B') ?
                     static_cast<int>(fill.fill_qty) :
                     -static_cast<int>(fill.fill_qty);
        position_.addFill(fill.get_symbol(), shares, fill.avg_price);

        logger_->info("Fill processed: {} {} shares @ ${:.2f}",
                     fill.get_symbol(), shares, fill.avg_price / 10000.0);
    }
}
```

**Why It Matters:**
- **Position accuracy:** Without processing fills, position tracker is stale
- **Risk management:** Incorrect position → incorrect risk limits
- **PnL calculation:** Realized PnL requires fill processing
- **Order generation:** Position skew depends on accurate position

**Lesson:** Bidirectional communication requires processing BOTH directions in main loop.

---

### Lesson 8: Shared Memory Cleanup and Lifecycle

**Problem:** Ring buffer files persist in `/dev/shm` after process exits

**Initial Code (No Cleanup):**
```cpp
// [FAIL] Ring buffers created but never cleaned up
OrderRingBuffer order_ring("/dev/shm/order_ring_mm");
```

**File Accumulation:**
```bash
ls /dev/shm/
# order_ring_mm  (from previous run)
# order_ring_mm  (from current run - ERROR: already exists!)
# fill_ring_oe
```

**Solution (Manual Cleanup Required):**
```bash
# Clean up before running
rm /dev/shm/order_ring_mm /dev/shm/fill_ring_oe

# Or in startup script
#!/bin/bash
rm -f /dev/shm/order_ring_mm /dev/shm/fill_ring_oe
./market_maker_fsm
```

**Better Solution (RAII Cleanup in Destructor):**
```cpp
// [PASS] Clean up in destructor
class OrderProducer {
    ~OrderProducer() {
        if (order_ring_path_) {
            unlink(order_ring_path_);  // Remove shared memory file
        }
        if (fill_ring_path_) {
            unlink(fill_ring_path_);
        }
    }
};
```

**Why It Matters:**
- **Resource leaks:** Shared memory files persist after crash/exit
- **Restart failures:** Can't create ring buffer if file already exists
- **Disk space:** `/dev/shm` is RAM-backed, leaks reduce available memory
- **Cleanup scripts:** Production systems need cleanup in startup scripts

**Lesson:** Shared memory requires explicit cleanup. Use RAII or startup scripts.

---

## Summary: Project 15-16 Integration

**What Was Built:**
- **Project 15 (Market Maker):** OrderProducer class, processFills() method, config flag
- **Project 16 (Order Execution):** Full exchange simulator, FIX 4.2 protocol, Disruptor consumer/producer
- **Integration:** Bidirectional Disruptor communication (orders + fills)

**Key Technologies Learned:**
- Bidirectional IPC with dual ring buffers
- FIX 4.2 protocol (NewOrderSingle, ExecutionReport)
- Shared memory lifecycle management
- Config-driven feature flags
- Lock-free sequencing patterns

**Performance Achieved:**
- Order processing: ~1 μs
- Fill notification: <1 μs
- Round-trip latency: ~2 μs

**Resume Value:**
- Complete order execution loop (market maker → exchange → fills → position)
- Industry-standard FIX protocol implementation
- Sub-microsecond IPC with LMAX Disruptor
- Production patterns: feature flags, error handling, RAII cleanup

---

**Last Updated:** Projects 1-18 Complete - Full Trading System with Order Execution (November 2025)

**Development Time:** 360+ hours

This document grows with each project and includes lessons from all phases.

---

## Project 14-15: XDP + Disruptor Ultra-Low-Latency IPC (November 2025)

### 1. Shared Memory Requires Fixed-Size Data Structures

**Problem:** `std::string` and `std::vector` contain pointers that become invalid across process boundaries.

**Why Pointers Break in Shared Memory:**
```cpp
// Process A creates shared memory with this struct:
struct BBOData {
    std::string symbol;  // Contains pointer to heap: 0x12345678
};

// Process B maps the same shared memory and sees:
struct BBOData {
    std::string symbol;  // Still sees pointer 0x12345678
                         // BUT 0x12345678 is in Process A's address space!
                         // Accessing it → SEGFAULT
};
```

**Solution - Use Fixed-Size Arrays:**
```cpp
// Shared-memory safe version:
struct BBOData {
    char symbol[16];  // Fixed-size, no pointers

    void set_symbol(const std::string& sym) {
        std::strncpy(symbol, sym.c_str(), 15);
        symbol[15] = '\0';
    }

    std::string get_symbol() const {
        return std::string(symbol);
    }
};
```

**Same Problem with std::vector:**
```cpp
// WRONG - std::vector allocates heap memory
template<typename T>
class RingBuffer {
    std::vector<T> buffer_;  // Pointer to heap, invalid in other process
};

// RIGHT - fixed-size array
template<typename T, size_t N>
class RingBuffer {
    T buffer_[N];  // Fixed-size, no dynamic allocation
};
```

**Lesson:** Shared memory can only contain POD (Plain Old Data) types or structs with fixed-size arrays. Any dynamic allocation (std::string, std::vector, smart pointers) will crash.

**Why This Matters for Trading:**
- High-frequency trading systems use shared memory IPC extensively
- LMAX Disruptor pattern is industry standard for ultra-low-latency IPC
- Understanding memory layout critical for performance-critical systems

---

### 2. XDP Queue Must Match Hardware RSS Configuration

**Problem:** AF_XDP socket must bind to the queue where packets actually arrive, determined by NIC's Receive Side Scaling (RSS).

**Debugging Process:**
```bash
# Check which queue receives UDP port 5000 packets:
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep "XDP:"

# Output shows actual queue:
<idle>-0 [015] ..s2. 4150.970766: bpf_trace_printk: XDP: rx_queue_index=2
```

**Solution:**
```bash
# Bind XDP socket to correct queue:
sudo ./order_gateway 0.0.0.0 5000 \
    --use-xdp \
    --xdp-queue-id 2 \  # Match actual hardware queue!
    --xdp-interface eno2
```

**Why Queue Mismatch Causes No Packets:**
- XDP program populates XSK map with socket for specific queue
- Packets arriving on different queue → XSK map lookup returns NULL
- Packet gets passed to kernel network stack instead of userspace socket

**Lesson:** Always verify actual packet arrival queue using BPF tracing before binding XDP socket. Hardware RSS configuration varies by NIC model.

**Why This Matters for Trading:**
- XDP is kernel bypass technology used in HFT for sub-microsecond latency
- Proper configuration essential - silent failures waste hours of debugging
- Understanding NIC hardware behavior critical for low-latency systems

---

### 3. Signal Handlers Must Be Minimal - Let Main Loop Clean Up

**Problem:** Calling complex functions (like `stop()`) in signal handlers caused immediate process termination, skipping performance summary and cleanup.

**Wrong Approach:**
```cpp
void signalHandler(int signal) {
    spdlog::info("Shutting down...");
    g_running = false;
    if (g_listener) {
        g_listener->stop();  // WRONG - complex operation in signal handler
    }
}
// Result: Process terminates immediately, no performance metrics printed
```

**Right Approach:**
```cpp
void signalHandler(int signal) {
    spdlog::info("Shutting down...");
    g_running = false;  // Just set flag, nothing else
}

int main() {
    while (g_running) {
        // Main loop...
    }

    // Clean up happens here, after loop exits naturally:
    if (g_listener) {
        g_listener->stop();
    }
    g_parse_latency.printSummary("Project 15 (Disruptor)");
}
```

**Why Signal Handlers Must Be Minimal:**
- Signal handlers interrupt normal execution flow asynchronously
- Calling non-reentrant functions (I/O, mutexes, complex logic) → undefined behavior
- Best practice: Set atomic flag, let main loop handle cleanup

**Lesson:** Signal handlers should only set flags. Complex cleanup belongs in main loop after controlled exit.

**Why This Matters for Trading:**
- Production systems require graceful shutdown for metrics collection
- Proper cleanup prevents shared memory leaks (` /dev/shm` files left behind)
- Performance monitoring depends on shutdown code executing fully

---

### 4. Latency Measurement Best Practices - Timestamp at Data Creation

**Problem:** Measuring only processing time (FIFO write, read operations) misses true end-to-end latency.

**Wrong Approaches:**
```cpp
// WRONG 1: Measure only FIFO write time
auto start = now();
fifo.write(data);
auto latency = now() - start;  // Misses actual processing

// WRONG 2: Measure only read time
auto start = now();
auto data = fifo.read();  // Includes timeout polling!
auto latency = now() - start;  // Includes wait time, not processing time

// WRONG 3: Different clock sources
// Producer:
auto ts = system_clock::now();
// Consumer:
auto now = steady_clock::now();  // WRONG - incompatible clocks!
```

**Right Approach:**
```cpp
// Producer (Project 14):
bbo.timestamp_ns = get_timestamp_ns();  // Timestamp at creation
ring_buffer_->publish(bbo);

// Consumer (Project 15):
gateway::BBOData bbo = impl->read_bbo();
auto now_ns = get_timestamp_ns();  // Same clock source!
uint64_t latency_ns = now_ns - bbo.timestamp_ns;  // True end-to-end
monitor_->recordLatency(latency_ns);
```

**Key Principles:**
1. **Timestamp at data creation** (earliest point in pipeline)
2. **Measure at processing completion** (latest point in pipeline)
3. **Use same clock source everywhere** (high_resolution_clock)
4. **Store timestamp in data structure** (travels with data through pipeline)

**Lesson:** End-to-end latency measurement requires timestamping at data origin and measuring at final processing point, using consistent clock source.

**Why This Matters for Trading:**
- Trading systems need wire-to-decision latency, not component timings
- Benchmarking requires consistent measurement methodology
- Sub-microsecond accuracy demands proper clock selection

---

### 5. LMAX Disruptor Pattern - Lock-Free IPC Architecture

**Architecture Components:**

**1. Ring Buffer (Power-of-2 Size):**
```cpp
template<typename T, size_t N>
class RingBuffer {
    static_assert((N & (N - 1)) == 0);  // Must be power of 2

    T& operator[](int64_t sequence) {
        return buffer_[sequence & buffer_mask_];  // Fast modulo
    }

private:
    T buffer_[N];  // Fixed-size array
    const size_t buffer_mask_ = N - 1;
};
```

**Why Power-of-2:** `sequence & mask` is faster than `sequence % size`.

**2. Sequencer (Atomic Cursors):**
```cpp
class Sequencer {
    alignas(64) std::atomic<int64_t> cursor_;           // Producer cursor
    alignas(64) std::atomic<int64_t> consumer_cursor_;  // Consumer cursor

    int64_t next() {  // Producer: claim next slot
        int64_t current = cursor_.load(std::memory_order_relaxed);
        int64_t next_seq = current + 1;
        int64_t wrap_point = next_seq - buffer_size_;

        // Wait for consumer to consume old data before wrapping:
        while (wrap_point > consumer_cursor_.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        return next_seq;
    }

    void publish(int64_t sequence) {
        cursor_.store(sequence, std::memory_order_release);
    }
};
```

**Why Cache-Line Alignment:** `alignas(64)` prevents false sharing between producer/consumer.

**3. Memory Ordering:**
- `memory_order_relaxed`: No synchronization, fastest
- `memory_order_acquire`: Read barrier, see all previous writes
- `memory_order_release`: Write barrier, all previous writes visible

**Performance Results:**
- **Disruptor IPC:** 0.50 μs (shared memory access)
- **TCP IPC:** 12-15 μs (syscalls, kernel stack, protocol overhead)
- **Improvement:** 24-30× faster

**Lesson:** Lock-free ring buffers with atomic operations achieve sub-microsecond IPC latency, eliminating need for kernel involvement.

**Why This Matters for Trading:**
- LMAX Disruptor is proven technology (used in real exchanges)
- Understanding lock-free patterns essential for HFT systems
- Shared memory IPC is standard for co-located trading strategies

---

### 6. Performance Optimization Journey - Know When to Stop

**Optimization Phases:**
1. **Baseline (UART):** 10.67 μs - Serial communication bottleneck
2. **Standard UDP:** 0.34 μs - 31× faster
3. **RT Optimization:** 0.20 μs - SCHED_FIFO + CPU isolation
4. **XDP Kernel Bypass:** 0.04 μs - 267× faster than UART
5. **XDP + Disruptor:** 4.13 μs end-to-end - 3× faster than TCP IPC

**Key Insight:** Each optimization phase had diminishing returns. XDP (0.04 μs) achieved sub-microsecond packet processing. Further optimization (0.04 → 0.02 μs) would require hardware timestamping or custom NIC drivers with minimal practical benefit.

**When to Stop Optimizing:**
- **Bottleneck moved:** From packet processing (0.04 μs) to business logic (3.23 μs)
- **Cost vs Benefit:** Hardware timestamping costs $10k+, gains 20-30 ns
- **Good Enough:** 4.13 μs end-to-end competitive with commercial HFT systems

**Lesson:** Optimize systematically, measure at each step, stop when bottleneck moves to business logic or cost exceeds benefit.

**Why This Matters for Trading:**
- Real HFT firms face same optimization decisions
- Understanding where latency lives guides architecture choices
- Sub-microsecond packet processing enables microsecond-level strategies

---

### Trading System Skills Demonstrated (Projects 14-15)

**Ultra-Low-Latency Systems:**
- XDP kernel bypass (AF_XDP + eBPF)
- LMAX Disruptor lock-free IPC
- POSIX shared memory management
- Atomic operations and memory ordering

**System Programming:**
- Real-time scheduling (SCHED_FIFO)
- CPU affinity and core isolation
- Signal handling and graceful shutdown
- Performance measurement and benchmarking

**Data Structure Design:**
- Fixed-size arrays for shared memory
- Cache-line alignment (false sharing prevention)
- Power-of-2 ring buffers (fast modulo)
- Template metaprogramming (compile-time sizing)

**Debugging Methodology:**
- BPF tracing (queue identification)
- Shared memory inspection (`ls -lh /dev/shm`)
- Latency profiling (P50/P95/P99 metrics)
- Systematic root cause analysis

**References for Disruptor Implementation:**
- [Imperial HFT - GitHub Repository](https://github.com/0burak/imperial_hft) - Source of Disruptor implementation classes
- [Low-Latency Trading Systems - Thesis](https://arxiv.org/abs/2309.04259) - Burak Gunduz thesis on HFT systems with Disruptor pattern
- [Imperial HFT Explanation Video](https://www.youtube.com/watch?v=65XoXkh6VcY) - Video explanation of Disruptor implementation for trading systems

---

## Projects 19-23: PCIe Integration - XDMA and AXI-Stream (December 2025)

### PCIe IP Selection: XDMA vs AXI Memory Mapped

**Problem:** Needed PCIe data path for BBO output. Two Xilinx IP options:
- **AXI Memory Mapped PCIe** - Direct BAR access, complex AXI interconnect
- **XDMA** - DMA engine with AXI-Stream interface, simpler integration

**Solution:** Used XDMA IP for streaming data:
- AXI-Stream interface matches our packet-based BBO data naturally
- Built-in DMA eliminates need for custom DMA engine
- H2C (Host to Card) and C2H (Card to Host) channels
- Interrupt support for completion notification

**Lesson:** XDMA is ideal for streaming data; AXI MM better for register/memory access.

### PCIe Gen2 Lane Width Issues (AX7203)

**Problem:** AX7203 board designed for Gen2 x4, but only x1 link established.

**Investigation:**
- Checked XDMA IP configuration (x4 enabled)
- Verified constraints file lane assignments
- lspci showed Gen2 x1 instead of x4

**Root Cause:** Hardware limitation or slot configuration. The FPGA/board combination limited to x1.

**Workaround:** Gen2 x1 provides 500 MB/s (5 GT/s), sufficient for BBO packets (48 bytes @ ~10K/sec = 0.5 MB/s).

**Lesson:** Always verify actual link width with `lspci -vvv`. Design for minimum required bandwidth, not theoretical maximum.

### Clock Domain Crossing for PCIe

**Problem:** Order book runs at 200 MHz (system clock), PCIe XDMA at 250 MHz (from PCIe refclk).

**Solution:** Async FIFO (bbo_cdc_fifo.vhd) between domains:
```
Order Book (200 MHz) → CDC FIFO → AXI-Stream (250 MHz) → XDMA
```

**Critical Details:**
- Gray code pointers for safe CDC
- Proper synchronizer chains (2-3 FF)
- Almost-full/almost-empty flags with margin

**Lesson:** Always use proven async FIFO primitives for CDC. Never assume "close enough" frequencies are synchronous.

### BBO Spread Timing Bug (Stale Values)

**Problem:** bbo_verify showed incorrect spread values:
```
BBO #4: Bid=$312.12, Ask=$319.22, Spread=$7.10  ✓
BBO #5: Bid=$321.02, Ask=$321.84, Spread=$7.10  ✗ (should be $0.82)
```

**Investigation:**
1. Traced through bbo_tracker.vhd spread calculation - logic correct
2. Found BBO scan takes ~7168 cycles (512 levels × 7 cycles × 2 sides)
3. Multi-symbol arbiter outputs BBO every 1000 cycles
4. Timing mismatch: New scan may not complete before next output

**Root Cause:** Race condition between BBO scan completion and arbiter output timing.

**Workaround:** Calculate spread on host side from bid/ask prices:
```c
/* bbo_verify.c - Calculate spread locally */
if (pkt->ask_price > pkt->bid_price) {
    calculated_spread = pkt->ask_price - pkt->bid_price;
} else {
    calculated_spread = 0;  /* Crossed market */
}
```

**Proper Fix (TODO):** Add handshaking between bbo_tracker and arbiter to ensure scan complete before output.

**Lesson:** Multi-cycle operations need explicit completion signaling. "Ready" signals must account for full operation latency.

### Crossed Markets in Test Data

**Problem:** Spread calculation showed negative values (unsigned underflow) during testing.

**Investigation:** With limited test data (100-1000 messages per symbol), order book builds incrementally. Early state may have:
- Only bid orders (no asks yet)
- Only ask orders (no bids yet)
- Crossed market (bid > ask) temporarily

**Solution:** Handle crossed markets explicitly:
```c
if (ask_price > bid_price) {
    spread = ask_price - bid_price;
} else {
    spread = 0;  /* Crossed or no spread */
}
```

**Lesson:** Test data may not represent steady-state market conditions. Always handle edge cases in market data.

### BRAM Initialization vs Reset

**Problem:** Order book BRAM retained stale data between test runs.

**Investigation:**
- BRAM initialization only happens at FPGA configuration (bitstream load)
- Reset signal clears registers but not BRAM contents
- Xilinx BRAM primitives: INIT_xx attributes set power-on values only

**Solution:** Added BRAM clear state machine that runs after reset:
```vhdl
type clear_state_t is (CLEAR_IDLE, CLEAR_ACTIVE, CLEAR_DONE);
-- On reset, iterate through all addresses writing zeros
```

**Lesson:** BRAM != registers. Reset behavior must be explicitly designed. Consider clear time in system startup.

### AXI-Stream Packet Formatting

**BBO Packet Structure (48 bytes):**
```
Bytes 0-7:   Symbol (8-char ASCII, padded)
Bytes 8-11:  Bid Price (32-bit, 4 decimal fixed-point)
Bytes 12-15: Bid Size (32-bit shares)
Bytes 16-19: Ask Price (32-bit, 4 decimal fixed-point)
Bytes 20-23: Ask Size (32-bit shares)
Bytes 24-27: Spread (32-bit, 4 decimal fixed-point)
Bytes 28-31: T1 Timestamp (ITCH receive)
Bytes 32-35: T2 Timestamp (Order book update)
Bytes 36-39: T3 Timestamp (PCIe queue)
Bytes 40-43: T4 Timestamp (PCIe transmit)
Bytes 44-47: Sequence Number
```

**AXI-Stream Signals:**
- `tdata[63:0]`: 64-bit data bus (6 beats per packet)
- `tvalid`: Data valid
- `tready`: Backpressure from XDMA
- `tlast`: End of packet marker
- `tkeep[7:0]`: Byte enables (all 1s except last beat)

**Lesson:** Fixed packet size simplifies AXI-Stream logic. tlast must align with actual packet boundary.

### Host-Side XDMA Access

**Driver Setup:**
```bash
# Load Xilinx XDMA driver
sudo modprobe xdma

# Device nodes created:
/dev/xdma0_c2h_0  # Card-to-Host channel 0
/dev/xdma0_h2c_0  # Host-to-Card channel 0
/dev/xdma0_user   # User interrupts
```

**Reading BBO Packets:**
```c
int fd = open("/dev/xdma0_c2h_0", O_RDONLY);
while (1) {
    ssize_t n = read(fd, buffer, sizeof(bbo_packet_t));
    if (n == sizeof(bbo_packet_t)) {
        process_bbo(buffer);
    }
}
```

**Lesson:** XDMA provides simple file-based interface. No custom kernel driver needed for basic streaming.

### Project File Organization

**Problem:** Large projects accumulate unused files, making navigation difficult.

**Solution:** Created PROJECT_STRUCTURE.md documenting:
- Build configuration (top module, target, scripts)
- RTL hierarchy (only files in build)
- Unused files section
- Data flow diagram
- Key signals reference

**Lesson:** Document project structure early. Update when files added/removed. Helps future debugging.

### PCIe Skills Demonstrated (Projects 19-23)

**PCIe Fundamentals:**
- XDMA IP configuration and instantiation
- AXI-Stream interface design
- Clock domain crossing to PCIe domain
- Link training and width negotiation

**Vivado Block Design:**
- XDMA IP customization
- Block design wrapper generation
- Constraint file integration with block design

**Host Integration:**
- XDMA Linux driver usage
- C host applications for PCIe data
- Packet parsing and verification

**Debugging Techniques:**
- lspci for link status verification
- ILA for AXI-Stream signal capture
- Host-side packet dumps for data verification

---

**Last Updated:** Projects 1-23 - PCIe BBO Output Integration (December 2025)

**Development Time:** 560+ hours

This document grows with each project and includes lessons from all phases.
