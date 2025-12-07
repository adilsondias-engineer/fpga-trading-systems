#include "py32f0xx_hal_dma.h"
#include "py32f0xx_hal_i2c.h"
#include "py32f0xx_bsp_printf.h"
#include "ssd1306.h"
#include "spi.h"
#include <py32f0xx_hal_rcc.h>
#include <py32f0xx_hal_led.h>
#include <py32f030x8.h>
#include <py32f0xx_hal_gpio.h>
#include <string.h>
#include <stdio.h>

#define I2C_ADDRESS        0x3D     // host address 0xA0 
#define I2C_STATE_READY    0
#define I2C_STATE_BUSY_TX  1
#define I2C_STATE_BUSY_RX  2

I2C_HandleTypeDef I2cHandle;

// FPGA status structure
typedef struct {
    uint32_t order_count;
    uint32_t bbo_count;
    uint32_t latency_p50;
    uint32_t status;
    uint32_t symbol_en;
    uint32_t threshold;
} fpga_status_t;

fpga_status_t fpga_status;

void APP_ErrorHandler(void);
static void APP_I2C_Config(void);
static void UpdateOLEDDisplay(fpga_status_t *status);

void gpioInit(void){
	
	GPIO_InitTypeDef GPIO_InitStruct;
	__HAL_RCC_GPIOA_CLK_ENABLE();
	
	GPIO_InitStruct.Pin = GPIO_PIN_11;
	GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
	GPIO_InitStruct.Pull = GPIO_PULLUP;
	GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
	
	HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);

}

int main(void)
{
    char buf[64];
    
    // Initialize GPIO (green LED)
    gpioInit();
    
    // Initialize HAL
    HAL_Init();
    
    // Initialize UART for debug output
    BSP_USART_Config();
    printf("\r\n=================================\r\n");
    printf("PY32F030 + FPGA Integration\r\n");
    printf("SystemClk: %ld Hz\r\n", SystemCoreClock);
    printf("=================================\r\n");
    
    // Initialize I2C for OLED
    APP_I2C_Config();
    
    // Initialize OLED display
    uint8_t res = SSD1306_Init();
    printf("OLED init: %d\r\n", res);
    
    // Initialize SPI for FPGA communication
    SPI_Init();
    printf("SPI initialized\r\n");
    
    // Print SPI status for debugging
    SPI_PrintStatus();
    
    // Display startup screen
    SSD1306_Fill(0);
    SSD1306_GotoXY(0, 0);
    SSD1306_Puts("FPGA Trading", &Font_11x18, 1);
    SSD1306_GotoXY(0, 20);
    SSD1306_Puts("System", &Font_11x18, 1);
    SSD1306_GotoXY(0, 40);
    SSD1306_Puts("Initializing...", &Font_6x10, 1);
    SSD1306_UpdateScreen();
    HAL_Delay(100);
    
    // Initialize FPGA status structure
    memset(&fpga_status, 0, sizeof(fpga_status_t));
    
    printf("Starting main loop...\r\n");
    printf("Polling FPGA every 100ms\r\n\r\n");
    

    uint32_t display_uart = 0;
    // Main loop: Poll FPGA and update display
    while(1)
    {
        // Poll FPGA status registers via SPI
        fpga_status.order_count = FPGA_ReadRegister(FPGA_REG_ORDER_COUNT);
        fpga_status.bbo_count = FPGA_ReadRegister(FPGA_REG_BBO_COUNT);
        fpga_status.latency_p50 = FPGA_ReadRegister(FPGA_REG_LATENCY_P50);
        fpga_status.status = FPGA_ReadRegister(FPGA_REG_STATUS);
        fpga_status.symbol_en = FPGA_ReadRegister(FPGA_REG_SYMBOL_EN);
        fpga_status.threshold = FPGA_ReadRegister(FPGA_REG_THRESHOLD);
        
        // Update OLED display with FPGA status
        UpdateOLEDDisplay(&fpga_status);
        
        if(display_uart == 1){
          // Debug output via UART
          printf("Orders: %lu | BBO: %lu | Lat: %lu ns | Status: 0x%08lX |  Symbol: %lu |Threshold: %lu \r\n",
                fpga_status.order_count,
                fpga_status.bbo_count,
                fpga_status.latency_p50,
                fpga_status.status,
                fpga_status.symbol_en,
                fpga_status.threshold);
        }
        // Toggle green LED to show activity
        HAL_GPIO_TogglePin(GPIOA, GPIO_PIN_11);
        
        // Update every 100ms
        HAL_Delay(1000);
        display_uart = !display_uart;
    }
}

static void APP_I2C_Config(void)
{
  I2cHandle.Instance             = I2C;
  I2cHandle.Init.ClockSpeed      = 100000;        // 100KHz ~ 400KHz
  I2cHandle.Init.DutyCycle       = I2C_DUTYCYCLE_16_9;
  I2cHandle.Init.OwnAddress1     = I2C_ADDRESS;
  I2cHandle.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
  I2cHandle.Init.NoStretchMode   = I2C_NOSTRETCH_DISABLE;
  if (HAL_I2C_Init(&I2cHandle) != HAL_OK)
  {
    APP_ErrorHandler();
  }
}

void APP_I2C_Transmit(uint8_t devAddress, uint8_t memAddress, uint8_t *pData, uint16_t len)
{
  HAL_I2C_Mem_Write(&I2cHandle, devAddress, memAddress, I2C_MEMADD_SIZE_8BIT, pData, len, 5000);
}

void APP_ErrorHandler(void)
{
  while (1);
}

// Update OLED display with FPGA trading system status
static void UpdateOLEDDisplay(fpga_status_t *status)
{
    char buf[32];
    
    // Clear screen
    SSD1306_Fill(0);
    
    // Title bar
    SSD1306_GotoXY(0, 0);
    SSD1306_Puts("FPGA Trading", &Font_6x10, 1);
    SSD1306_DrawLine(0, 10, 127, 10, 1);
    
    // Order count (line 1)
    SSD1306_GotoXY(0, 14);
    snprintf(buf, sizeof(buf), "Orders: %lu", status->order_count);
    SSD1306_Puts(buf, &Font_6x10, 1);
    
    // BBO count (line 2)
    SSD1306_GotoXY(0, 24);
    snprintf(buf, sizeof(buf), "BBO Upd: %lu", status->bbo_count);
    SSD1306_Puts(buf, &Font_6x10, 1);
    
    // Latency (line 3)
    SSD1306_GotoXY(0, 34);
    snprintf(buf, sizeof(buf), "Lat: %lu ns", status->latency_p50);
    SSD1306_Puts(buf, &Font_6x10, 1);
    
    // Status indicator (line 4)
    SSD1306_GotoXY(0, 44);
    if (status->status & 0x01) {
        SSD1306_Puts("Status: RUNNING", &Font_6x10, 1);
    } else {
        SSD1306_Puts("Status: STOPPED", &Font_6x10, 1);
    }
    
    // Threshold (line 5, bottom)
    SSD1306_GotoXY(0, 54);
    snprintf(buf, sizeof(buf), "Thr: %lu", status->threshold);
    SSD1306_Puts(buf, &Font_6x10, 1);
    
    // Update display
    SSD1306_UpdateScreen();
}

#ifdef  USE_FULL_ASSERT
/**
  * @brief  Export assert error source and line number
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  while (1);
}
#endif /* USE_FULL_ASSERT */
