# ALINX AX7325B FPGA Development Board Specifications

**Board:** ALINX AX7325B
**Manufacturer:** [ALINX Electronic Technology](https://www.en.alinx.com/)
**Used in:** Projects 31-35 (10GbE PHY, TCP ITCH Parser, 3-FPGA Appliance)

---

## FPGA Core

| Specification | Value |
|---------------|-------|
| **FPGA Part Number** | AMD/Xilinx Kintex-7 XC7K325T-2FFG900I |
| **Family** | Kintex-7 |
| **Package** | FFG900 (BGA-900, 31×31mm) |
| **Logic Cells** | 326,080 |
| **Slice LUTs** | 203,800 |
| **Slice Registers** | 407,600 |
| **Block RAM (36Kb)** | 445 (16.02 Mb total) |
| **Block RAM (18Kb)** | 890 |
| **DSP48E1 Slices** | 840 |
| **GTX Transceivers** | 16 (up to 12.5 Gb/s per channel) |
| **I/O Banks** | 10 HR + 4 HP |
| **Max User I/O** | 500 |
| **Speed Grade** | -2 (industrial temperature range) |
| **PCIe** | Gen2 x8 capable |

**Comparison to Previous Boards:**

| Resource | XC7A100T (Arty) | XC7A200T (AX7203) | XC7K325T (AX7325B) |
|----------|-----------------|-------------------|---------------------|
| Logic Cells | 101,440 | 215,360 | **326,080** |
| Block RAM (36Kb) | 135 | 365 | **445** |
| DSP Slices | 240 | 740 | **840** |
| Transceivers | 0 (none) | 4 GTP (6.6 Gb/s) | **16 GTX (12.5 Gb/s)** |
| Max Transceiver Rate | N/A | 6.6 Gb/s | **12.5 Gb/s** |
| Ethernet | MII 100M | RGMII 1G | **10GbE SFP+** |

---

## High-Speed Serial (GTX Transceivers)

| Specification | Value |
|---------------|-------|
| **GTX Quads** | 4 (QUAD 115, 116, 117, 118) |
| **Total GTX Lanes** | 16 |
| **Max Line Rate** | 12.5 Gb/s per lane |
| **Reference Clock** | 156.25 MHz differential (on-board oscillator) |
| **REFCLK Pins** | G8/G7 (MGTREFCLK0_117) |
| **QPLL Range** | 5.93-12.5 Gb/s |
| **CPLL Range** | 1.6-6.6 Gb/s |

### SFP+ Interfaces

| Specification | Value |
|---------------|-------|
| **SFP+ Cages** | 2 |
| **SFP+ 0 TX** | K2/K1 (GTX QUAD 117, Lane 0) |
| **SFP+ 0 RX** | K6/K5 (GTX QUAD 117, Lane 0) |
| **TX Disable** | T28 (active high) |
| **Rate Select** | Active, directly controlled |
| **Module Detect** | Available via I2C |

### Verified SFP+ Configuration (Projects 33-34)

| Parameter | Value |
|-----------|-------|
| **Protocol** | 10GBASE-R (IEEE 802.3 Clause 49) |
| **Line Rate** | 10.3125 Gb/s |
| **Encoding** | 64B/66B |
| **QPLL Divider** | REFCLK × 66 = 10.3125 Gb/s |
| **TXOUTCLK** | 161.13 MHz (10.3125 GHz / 64) |
| **XGMII Width** | 64-bit @ 161.13 MHz |

---

## Clock Resources

| Clock | Frequency | Pins | Usage |
|-------|-----------|------|-------|
| System Clock | 200 MHz | AE10/AF10 (LVDS) | General logic, MIG controller |
| SFP+ REFCLK | 156.25 MHz | G8/G7 (MGTREFCLK) | GTX QPLL reference for 10GbE |
| User Clock | 100 MHz | (varies) | Auxiliary |

**Clock Management:**
- MMCME2_ADV available for clock synthesis
- BUFG global clock buffers (32 available)
- BUFR regional clock buffers
- GTX TXOUTCLK/RXOUTCLK for transceiver domains

---

## Memory Subsystem

### DDR3 SDRAM

| Specification | Value |
|---------------|-------|
| **Capacity** | 1 GB |
| **Interface Width** | 64-bit |
| **Data Rate** | DDR3-1600 (800 MHz) |
| **Bandwidth** | 12.8 GB/s peak |

### Flash Storage

| Specification | Value |
|---------------|-------|
| **QSPI Flash** | 128 Mb (16 MB) |
| **Configuration** | Quad SPI mode |
| **Usage** | FPGA bitstream storage |

---

## Board Interfaces

| Interface | Controller/PHY | Connector | Notes |
|-----------|---------------|-----------|-------|
| **SFP+ ×2** | GTX transceivers | LC duplex cage | 10GbE fiber or DAC |
| **PCIe** | GTX (Gen2 x4/x8) | Edge connector | DMA capable |
| **DDR3** | MIG IP | SODIMM/BGA | 64-bit bus |
| **UART** | CP2102 USB-UART | Micro-USB | 115200 baud debug |
| **JTAG** | On-board | Micro-USB | Programming/debug |
| **GPIO** | LVCMOS33 | Headers | LEDs, buttons, expansion |
| **FMC** | HP bank | FMC-HPC | High-pin-count mezzanine |

### Debug LEDs

| LED | Pin | IOSTANDARD | Usage (Project 33-34) |
|-----|-----|------------|----------------------|
| LED0 | A22 | LVCMOS33 | QPLL Lock |
| LED1 | C19 | LVCMOS33 | GTX Ready |
| LED2 | B22 | LVCMOS33 | PCS Block Lock |
| LED3 | C22 | LVCMOS33 | Aurora Up / Activity |

### UART Debug

| Pin | Signal | IOSTANDARD |
|-----|--------|------------|
| AG28 | PHY Reset | LVCMOS33 |
| (CP2102) | UART TX/RX | 3.3V via USB |

---

## Power Supply

| Rail | Voltage | Usage |
|------|---------|-------|
| VCCINT | 1.0V | FPGA core logic |
| VCCAUX | 1.8V | Auxiliary logic |
| VCCO (HP) | 1.2-1.8V | High-performance I/O banks |
| VCCO (HR) | 3.3V | High-range I/O banks |
| MGTAVCC | 1.0V | GTX analog core |
| MGTAVTT | 1.2V | GTX TX/RX termination |
| VCC3V3 | 3.3V | Board peripherals |

---

## 10GbE Test Hardware (Verified Working)

The AX7325B was tested with 10GbE using fiber optics. DAC cables did NOT work with this board's SFP+ cage.

| Component | Product | Specs |
|-----------|---------|-------|
| SFP+ Modules | 10G SFP+ Fiber Transceiver | SR MM850nm, 300m range, Duplex LC |
| Fiber Cable | Tunghey OM3 LC to LC Patch Cable | Multimode Duplex 50/125um, 15M, LS-ZH |
| 10GbE Switch | Binardat 8-Port 10G Managed Switch | 4x10G RJ45 + 4x10G SFP+, 160Gbps, L3 |
| PC NIC | Binardat 10G PCIe Network Adapter | Aquantia AQC107 chip, RJ45 |

**Test Topology:**
```
PC (AQC107 10G RJ45) <--RJ45--> Switch (Binardat) <--Fiber+SFP+--> AX7325B
```

---

## Key Differences from AX7203

| Feature | AX7203 (Artix-7) | AX7325B (Kintex-7) |
|---------|-------------------|---------------------|
| FPGA Family | Artix-7 | **Kintex-7** |
| Transceiver Type | GTP (6.6 Gb/s) | **GTX (12.5 Gb/s)** |
| 10GbE Capable | No | **Yes** |
| SFP+ Cages | 0 | **2** |
| DSP Slices | 740 | 840 |
| Block RAM | 13.14 Mb | **16.02 Mb** |
| PCIe | Gen2 x4 | **Gen2 x8** |
| Max I/O | 285 | **500** |
| Price Range | ~$200 | ~$500 |

---

## Reference Documentation

## Reference Documentation

- **User Manual:** [AX7325B](https://www.en.alinx.com/Product/FPGA-Development-Boards/Kintex-7/AX7325B.html)
- **UG476:** [7 Series GTX/GTH Transceivers](https://docs.amd.com/r/en-US/ug476_7Series_Transceivers)
- **DS182:** [Kintex-7 FPGAs Data Sheet](https://docs.amd.com/v/u/en-US/ds182_Kintex_7_Data_Sheet)
- **UG476:** [7 Series GTX/GTH Transceivers](https://docs.amd.com/r/en-US/ug476_7Series_Transceivers)
- **DS182:** [Kintex-7 FPGAs Data Sheet](https://docs.amd.com/v/u/en-US/ds182_Kintex_7_Data_Sheet)

---

_Last updated: Project 34 (TCP ITCH Parser) - hardware verified with 10GbE fiber_
