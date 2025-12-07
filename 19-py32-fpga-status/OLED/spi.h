#ifndef SPI_H
#define SPI_H

#include <stdint.h>
#include "py32f0xx_hal.h"

// FPGA register addresses (must match spi_slave.vhd)
#define FPGA_REG_ORDER_COUNT  0
#define FPGA_REG_BBO_COUNT    1
#define FPGA_REG_LATENCY_P50  2
#define FPGA_REG_STATUS       3
#define FPGA_REG_SYMBOL_EN    4
#define FPGA_REG_THRESHOLD    5

// SPI commands (must match FPGA spi_slave.vhd)
#define CMD_READ  0x01
#define CMD_WRITE 0x02

// Function prototypes
void SPI_Init(void);
uint8_t SPI_Transfer(uint8_t data);
void SPI_CS_Assert(void);
void SPI_CS_Deassert(void);

// High-level FPGA register access
uint32_t FPGA_ReadRegister(uint8_t addr);
void FPGA_WriteRegister(uint8_t addr, uint32_t value);

// Debug/diagnostic functions
void SPI_PrintStatus(void);
void SPI_TestLoopback(void);

#endif // SPI_H

