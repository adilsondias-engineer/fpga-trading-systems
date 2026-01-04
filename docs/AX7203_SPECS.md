# ALINX AX7203 FPGA Development Board Specifications

**Board:** ALINX AX7203 (AC7200 SoM + Carrier Board)
**Manufacturer:** [ALINX Electronic Technology](https://www.en.alinx.com/)
**Part Number:** AX7203B

---

## FPGA Core

| Specification | Value |
|---------------|-------|
| **FPGA Part Number** | AMD/Xilinx Artix-7 XC7A200T-2FBG484I |
| **Package** | BGA-484 |
| **Logic Cells** | 215,360 |
| **Slice LUTs** | 134,600 |
| **Slice Registers** | 269,200 |
| **Block RAM (36Kb)** | 365 (13.14 Mb total) |
| **Block RAM (18Kb)** | 730 |
| **DSP48E1 Slices** | 740 |
| **GTP Transceivers** | 4 (up to 6.6 Gb/s per channel) |
| **I/O Banks** | 10 |
| **Max User I/O** | 285 |
| **Speed Grade** | -2 (industrial temperature range) |

**Comparison to XC7A100T (Arty A7-100T):**

| Resource | XC7A100T | XC7A200T | Increase |
|----------|----------|----------|----------|
| Logic Cells | 101,440 | 215,360 | **2.1×** |
| Slice LUTs | 63,400 | 134,600 | **2.1×** |
| Slice Registers | 126,800 | 269,200 | **2.1×** |
| Block RAM (36Kb) | 135 | 365 | **2.7×** |
| DSP Slices | 240 | 740 | **3.1×** |
| GTP Transceivers | 0 | 4 | **+4** |

---

## Memory Subsystem

### DDR3 SDRAM

| Specification | Value |
|---------------|-------|
| **Capacity** | 1 GB (8 Gbit) |
| **Chips** | 2× Micron MT41J256M16HA-125 |
| **Per Chip Capacity** | 4 Gbit (256M × 16) |
| **Data Bus Width** | 32-bit |
| **Clock Frequency** | 400 MHz |
| **Data Rate** | 800 MT/s (DDR3-800) |
| **Bandwidth** | 25.6 Gb/s (3.2 GB/s) |

### Flash Storage

| Specification | Value |
|---------------|-------|
| **QSPI Flash** | 128 Mb (16 MB) |
| **Configuration** | Quad SPI mode |
| **Usage** | FPGA bitstream storage, user data |

### EEPROM

| Specification | Value |
|---------------|-------|
| **Part Number** | 24LC04 |
| **Capacity** | 4 Kbit (512 Bytes) |
| **Interface** | I2C |
| **Usage** | Board ID, calibration data |

---

## Clock Sources

| Clock | Frequency | Type | Usage |
|-------|-----------|------|-------|
| **System Clock** | 200 MHz | LVDS Differential | Main FPGA system clock, DDR3 reference |
| **GTP Reference** | 125 MHz | LVDS Differential | GTP transceiver reference, Ethernet PHY |

**Crystal:** Sitime high-precision LVDS differential oscillators

---

## Ethernet Interfaces

### Gigabit Ethernet (×2)

| Specification | Value |
|---------------|-------|
| **Speed** | 10/100/1000 Mbps |
| **PHY Chip** | Realtek RTL8211E-VB-CG |
| **Interface** | RGMII (Reduced Gigabit MII) |
| **RGMII Clock** | 125 MHz (Gigabit), 25 MHz (100M), 2.5 MHz (10M) |
| **Connector** | RJ-45 with integrated magnetics |
| **LEDs** | Link/Activity indicators |

**Key Difference from Arty A7:**
- **AX7203:** Gigabit Ethernet with RGMII interface (4-bit DDR data @ 125 MHz)
- **Arty A7:** 10/100 Mbps with MII interface (4-bit SDR data @ 25 MHz)

### RGMII Interface Signals

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `rgmii_rxc` | Input | 1 | RX clock (125 MHz Gigabit) |
| `rgmii_rxd` | Input | 4 | RX data (DDR) |
| `rgmii_rx_ctl` | Input | 1 | RX control (DV + ERR) |
| `rgmii_txc` | Output | 1 | TX clock (125 MHz Gigabit) |
| `rgmii_txd` | Output | 4 | TX data (DDR) |
| `rgmii_tx_ctl` | Output | 1 | TX control (EN + ERR) |
| `phy_reset_n` | Output | 1 | PHY reset (active low) |

---

## HDMI Interfaces

### HDMI Output

| Specification | Value |
|---------------|-------|
| **Resolution** | Up to 1080p @ 60Hz |
| **Interface** | TMDS via FPGA I/O |
| **Connector** | Standard HDMI Type A |

### HDMI Input

| Specification | Value |
|---------------|-------|
| **Resolution** | Up to 1080p @ 60Hz |
| **Interface** | TMDS via FPGA I/O |
| **Connector** | Standard HDMI Type A |

---

## PCIe Interface

| Specification | Value |
|---------------|-------|
| **Generation** | PCIe 2.0 |
| **Lanes** | ×4 |
| **Speed per Lane** | 5.0 GT/s |
| **Total Bandwidth** | 2 GB/s (bidirectional) |
| **Form Factor** | Standard PCIe edge connector |

---

## Expansion Interfaces

### 40-Pin Expansion Headers (×2)

| Pin Type | Count per Header | Total |
|----------|------------------|-------|
| **User I/O** | 34 | 68 |
| **5V Power** | 1 | 2 |
| **3.3V Power** | 2 | 4 |
| **Ground** | 3 | 6 |

**Pitch:** 2.54mm (0.1 inch) standard

### XADC Connector

| Specification | Value |
|---------------|-------|
| **Analog Inputs** | Up to 17 differential channels |
| **Resolution** | 12-bit ADC |
| **Sample Rate** | 1 MSPS |

---

## User Interface

### LEDs

| LED | Location | Function |
|-----|----------|----------|
| PWR | Carrier | Power indicator |
| RXD | Carrier | UART receive activity |
| TXD | Carrier | UART transmit activity |
| LED[3:0] | Carrier | User-programmable |
| LED | Core | Core board status |

### Buttons

| Button | Function |
|--------|----------|
| KEY1 | User button 1 |
| KEY2 | User button 2 |
| RESET | System reset (active low) |

---

## Communication Interfaces

### UART (Debug/Configuration)

| Specification | Value |
|---------------|-------|
| **USB-UART Chip** | Silicon Labs CP2102GM |
| **Connector** | Mini USB |
| **Baud Rate** | Up to 1 Mbps |
| **Default** | 115200 baud, 8N1 |

### MicroSD Card

| Specification | Value |
|---------------|-------|
| **Modes** | SD mode, SPI mode |
| **Capacity** | Up to 32 GB (SDHC) |
| **Usage** | Data logging, configuration files |

---

## Power Supply

| Specification | Value |
|---------------|-------|
| **Input Voltage** | 12V DC |
| **Connector** | Barrel jack (5.5mm × 2.1mm) |
| **Current** | ~2A typical |
| **On-Board Regulators** | 3.3V, 1.8V, 1.0V, 0.9V |

---

## Physical Specifications

| Specification | Value |
|---------------|-------|
| **Dimensions** | 188 × 111 mm |
| **Form Factor** | Core board + Carrier board |
| **Core Board** | AC7200 SoM (System on Module) |
| **Inter-Board Connector** | High-speed board-to-board |
| **Mounting** | 4× M3 mounting holes |

---

## Development Tools

| Tool | Version | Notes |
|------|---------|-------|
| **AMD Vivado Design Suite** | 2024.1+ / 2025.1 | Full synthesis, implementation, debug |
| **Constraints File** | .xdc | Board-specific pin assignments |
| **Programming** | JTAG via Xilinx Platform Cable or on-board USB |

---

## Target Applications

- **High-Frequency Trading (HFT):** Low-latency market data processing
- **Software-Defined Radio (SDR):** High-bandwidth signal processing
- **Machine Vision:** Real-time image processing with HDMI I/O
- **Fiber Optic Communications:** GTP transceivers for high-speed serial
- **PCIe Accelerators:** Custom compute offload cards
- **Network Processing:** Gigabit Ethernet packet processing

---

## Resources

### Official Documentation

- [ALINX AX7203 Product Page](https://www.en.alinx.com/Product/FPGA-Development-Boards/Artix-7/AX7203.html)
- [AX7203 User Manual (PDF)](https://www.alinx.com/public/upload/file/AX7203_User_Manual.pdf)
- [AMD Partner Page](https://www.xilinx.com/products/boards-and-kits/1-1s6r42o.html)

### Xilinx Documentation

- [DS181: Artix-7 FPGAs Data Sheet](https://docs.xilinx.com/v/u/en-US/ds181_Artix_7_Data_Sheet)
- [UG471: 7 Series SelectIO Resources](https://docs.xilinx.com/v/u/en-US/ug471_7Series_SelectIO)
- [UG472: 7 Series Clocking Resources](https://docs.xilinx.com/v/u/en-US/ug472_7Series_Clocking)
- [UG473: 7 Series Memory Resources](https://docs.xilinx.com/v/u/en-US/ug473_7Series_Memory_Resources)

### Related Resources

- [RTL8211E Gigabit Ethernet PHY Datasheet](https://www.realtek.com/en/products/communications-network-ics/item/rtl8211e-vb-vl-cg)
- [RGMII Interface Specification v2.0](https://web.archive.org/web/20160303212629/http://www.hp.com/rnd/pdfs/RGMIIv2_0_final_hp.pdf)

---

## Migration Notes (from Arty A7-100T)

### Key Differences

| Feature | Arty A7-100T | AX7203 |
|---------|--------------|--------|
| **FPGA** | XC7A100T-1CSG324C | XC7A200T-2FBG484I |
| **Ethernet** | MII 10/100 Mbps | RGMII Gigabit |
| **PHY** | TI DP83848J | Realtek RTL8211E |
| **DDR3** | 256 MB | 1 GB |
| **Flash** | 16 MB Quad-SPI | 16 MB Quad-SPI |
| **GTP** | None | 4× (6.6 Gb/s) |
| **PCIe** | None | Gen2 ×4 |
| **HDMI** | Via PMOD | Native (In + Out) |

### Migration Considerations

1. **Ethernet Interface:**
   - Replace MII modules with RGMII equivalents
   - Implement DDR I/O primitives (ODDR/IDDR) for data lines
   - TX clock requires 90° phase shift for RGMII compliance
   - MMCM for clock generation (125 MHz + 125 MHz @ 90°)

2. **Pin Assignments:**
   - Complete re-mapping required (different package/board)
   - Use AX7203 XDC template from ALINX

3. **Clock Domains:**
   - System clock changes: 100 MHz (Arty) → 200 MHz (AX7203)
   - Ethernet clock: 25 MHz (MII) → 125 MHz (RGMII)

4. **Resources:**
   - 2.7× more BRAM available
   - 3.1× more DSP slices available
   - Consider expanded order book capacity

---

_Last Updated: December 2025_
