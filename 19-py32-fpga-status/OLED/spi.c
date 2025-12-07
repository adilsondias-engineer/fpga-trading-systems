#include "spi.h"
#include "py32f0xx_hal_spi.h"
#include "py32f0xx_hal_gpio.h"
#include "py32f0xx_bsp_printf.h"
#include "py32f030x8.h"  // For SPI register bit definitions
#include <stdio.h>

// SPI1 handle (must be accessible from MSP callback)
SPI_HandleTypeDef hspi1;

// Debug flag - set to 1 to enable verbose SPI debugging
#define SPI_DEBUG_ENABLE 0

// GPIO pins for SPI1
// PA5 - SCK (SPI1_SCK, AF0)
// PA6 - MISO (SPI1_MISO, AF0)
// PA7 - MOSI (SPI1_MOSI, AF0)
// PA4 - CS (GPIO, manual control)

void SPI_Init(void)
{
    // Configure SPI1 parameters
    // GPIO configuration will be done in HAL_SPI_MspInit() callback
    hspi1.Instance = SPI1;
    hspi1.Init.Mode = SPI_MODE_MASTER;
    hspi1.Init.Direction = SPI_DIRECTION_2LINES;
    hspi1.Init.DataSize = SPI_DATASIZE_8BIT;
    hspi1.Init.CLKPolarity = SPI_POLARITY_LOW;      // CPOL = 0
    hspi1.Init.CLKPhase = SPI_PHASE_1EDGE;          // CPHA = 0 (SPI Mode 0)
    hspi1.Init.NSS = SPI_NSS_SOFT;
    hspi1.Init.BaudRatePrescaler = SPI_BAUDRATEPRESCALER_256;  // 48MHz / 256 = 187.5 kHz
    hspi1.Init.FirstBit = SPI_FIRSTBIT_MSB;
    hspi1.Init.SlaveFastMode = SPI_SLAVE_FAST_MODE_DISABLE;  // Not used in master mode, but required field
    
    if (HAL_SPI_Init(&hspi1) != HAL_OK)
    {
        // Error handler
        while(1);
    }
    
    // Configure CS pin (GPIO, not part of SPI peripheral)
    GPIO_InitTypeDef GPIO_InitStruct = {0};
    __HAL_RCC_GPIOA_CLK_ENABLE();
    
    GPIO_InitStruct.Pin = GPIO_PIN_4;
    GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
    GPIO_InitStruct.Pull = GPIO_NOPULL;
    GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);
    
    // Set CS high (idle)
    HAL_GPIO_WritePin(GPIOA, GPIO_PIN_4, GPIO_PIN_SET);
}

uint8_t SPI_Transfer(uint8_t data)
{
    uint8_t rx_data = 0;
    HAL_StatusTypeDef status;
    
    status = HAL_SPI_TransmitReceive(&hspi1, &data, &rx_data, 1, HAL_MAX_DELAY);
    
#if SPI_DEBUG_ENABLE
    if (status != HAL_OK) {
        printf("[SPI] Transfer ERROR: status=%d\r\n", status);
    } else {
        printf("[SPI] TX:0x%02X RX:0x%02X\r\n", data, rx_data);
    }
#endif
    
    return rx_data;
}

void SPI_CS_Assert(void)
{
    HAL_GPIO_WritePin(GPIOA, GPIO_PIN_4, GPIO_PIN_RESET);  // CS = LOW
#if SPI_DEBUG_ENABLE
    printf("[SPI] CS ASSERT (LOW)\r\n");
#endif
}

void SPI_CS_Deassert(void)
{
    HAL_GPIO_WritePin(GPIOA, GPIO_PIN_4, GPIO_PIN_SET);    // CS = HIGH
#if SPI_DEBUG_ENABLE
    printf("[SPI] CS DEASSERT (HIGH)\r\n");
#endif
}

// High-level FPGA register read
uint32_t FPGA_ReadRegister(uint8_t addr)
{
    uint32_t value = 0;
    uint8_t byte0, byte1, byte2, byte3;
    
#if SPI_DEBUG_ENABLE
    printf("\r\n[FPGA] READ Register 0x%02X\r\n", addr);
#endif
    
    SPI_CS_Assert();
    
    // Send READ command
    SPI_Transfer(CMD_READ);
    
    // Send register address
    SPI_Transfer(addr);
    
    // Read 32-bit value (MSB first)
    byte0 = SPI_Transfer(0x00);
    byte1 = SPI_Transfer(0x00);
    byte2 = SPI_Transfer(0x00);
    byte3 = SPI_Transfer(0x00);
    
    value  = ((uint32_t)byte0) << 24;
    value |= ((uint32_t)byte1) << 16;
    value |= ((uint32_t)byte2) << 8;
    value |= ((uint32_t)byte3);
    
    SPI_CS_Deassert();
    
#if SPI_DEBUG_ENABLE
    printf("[FPGA] READ Result: 0x%08lX (bytes: 0x%02X 0x%02X 0x%02X 0x%02X)\r\n", 
           value, byte0, byte1, byte2, byte3);
#endif
    
    return value;
}

// High-level FPGA register write
void FPGA_WriteRegister(uint8_t addr, uint32_t value)
{
    uint8_t byte0, byte1, byte2, byte3;
    
#if SPI_DEBUG_ENABLE
    printf("\r\n[FPGA] WRITE Register 0x%02X = 0x%08lX\r\n", addr, value);
#endif
    
    SPI_CS_Assert();
    
    // Send WRITE command
    SPI_Transfer(CMD_WRITE);
    
    // Send register address
    SPI_Transfer(addr);
    
    // Send 32-bit value (MSB first)
    byte0 = (value >> 24) & 0xFF;
    byte1 = (value >> 16) & 0xFF;
    byte2 = (value >> 8) & 0xFF;
    byte3 = value & 0xFF;
    
    SPI_Transfer(byte0);
    SPI_Transfer(byte1);
    SPI_Transfer(byte2);
    SPI_Transfer(byte3);
    
    SPI_CS_Deassert();
    
#if SPI_DEBUG_ENABLE
    printf("[FPGA] WRITE Complete (bytes: 0x%02X 0x%02X 0x%02X 0x%02X)\r\n", 
           byte0, byte1, byte2, byte3);
#endif
}

// Print SPI status for debugging
void SPI_PrintStatus(void)
{
    printf("\r\n=== SPI Status ===\r\n");
    printf("SPI1 Instance: 0x%08lX\r\n", (uint32_t)hspi1.Instance);
    printf("SPI State: %d\r\n", hspi1.State);
    printf("SPI Error: 0x%08lX\r\n", hspi1.ErrorCode);
    if (hspi1.Instance != NULL) {
        printf("SPI CR1: 0x%08lX\r\n", hspi1.Instance->CR1);
        printf("SPI CR2: 0x%08lX\r\n", hspi1.Instance->CR2);
        printf("SPI SR: 0x%08lX\r\n", hspi1.Instance->SR);
        printf("SPI Enabled: %s\r\n", (hspi1.Instance->CR1 & SPI_CR1_SPE) ? "YES" : "NO");
        printf("SPI TXE: %s\r\n", (hspi1.Instance->SR & SPI_SR_TXE) ? "YES" : "NO");
        printf("SPI RXNE: %s\r\n", (hspi1.Instance->SR & SPI_SR_RXNE) ? "YES" : "NO");
        printf("SPI BSY: %s\r\n", (hspi1.Instance->SR & SPI_SR_BSY) ? "YES" : "NO");
    } else {
        printf("SPI Instance is NULL!\r\n");
    }
    printf("==================\r\n\r\n");
}

// Test SPI loopback (connect MOSI to MISO for this test)
void SPI_TestLoopback(void)
{
    uint8_t test_data[] = {0x01, 0x02, 0x03, 0xAA, 0x55, 0xFF};
    uint8_t rx_data;
    int i;
    
    printf("\r\n=== SPI Loopback Test ===\r\n");
    printf("Connect MOSI to MISO for this test!\r\n");
    
    SPI_CS_Assert();
    
    for (i = 0; i < 6; i++) {
        rx_data = SPI_Transfer(test_data[i]);
        printf("TX: 0x%02X -> RX: 0x%02X %s\r\n", 
               test_data[i], rx_data, 
               (test_data[i] == rx_data) ? "OK" : "FAIL");
    }
    
    SPI_CS_Deassert();
    
    printf("=== Loopback Test Complete ===\r\n\r\n");
}

