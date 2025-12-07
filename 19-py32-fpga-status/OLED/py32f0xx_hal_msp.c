/**
  ******************************************************************************
  * @file    py32f0xx_hal_msp.c
  * @author  MCU Application Team
  * @brief   This file provides code for the MSP Initialization
  *          and de-Initialization codes.
  ******************************************************************************
  * @attention
  *
  * <h2><center>&copy; Copyright (c) Puya Semiconductor Co.
  * All rights reserved.</center></h2>
  *
  * <h2><center>&copy; Copyright (c) 2016 STMicroelectronics.
  * All rights reserved.</center></h2>
  *
  * This software component is licensed by ST under BSD 3-Clause license,
  * the "License"; You may not use this file except in compliance with the
  * License. You may obtain a copy of the License at:
  *                        opensource.org/licenses/BSD-3-Clause
  *
  ******************************************************************************
  */

/* Includes ------------------------------------------------------------------*/
#include "py32f0xx_hal.h"
#include <py32f0xx_hal_i2c.h>
#include <py32f0xx_hal_spi.h>
#include <py32f0xx_hal_rcc.h>
#include <py32f0xx_hal_gpio.h>
#include <py32f030x8.h>
#include <py32f0xx_hal_gpio_ex.h>

/* Private typedef -----------------------------------------------------------*/
/* Private define ------------------------------------------------------------*/
/* Private macro -------------------------------------------------------------*/
/* Private variables ---------------------------------------------------------*/
/* Private function prototypes -----------------------------------------------*/
/* External functions --------------------------------------------------------*/

/**
  * @brief  Configure the Flash prefetch and the Instruction cache,
  *         the time base source, NVIC and any required global low level hardware
  *         by calling the HAL_MspInit() callback function from HAL_Init()
  *         
  */
void HAL_MspInit(void)
{
}

void HAL_I2C_MspInit(I2C_HandleTypeDef *hi2c)
{
  GPIO_InitTypeDef GPIO_InitStruct;

  __HAL_RCC_I2C_CLK_ENABLE();
  __HAL_RCC_GPIOF_CLK_ENABLE();

  /**
  PF1     ------> I2C1_SCL
  PF0     ------> I2C1_SDA
  */
  GPIO_InitStruct.Pin = GPIO_PIN_1 | GPIO_PIN_0;
  GPIO_InitStruct.Mode = GPIO_MODE_AF_OD;
  GPIO_InitStruct.Pull = GPIO_PULLUP;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
  GPIO_InitStruct.Alternate = GPIO_AF12_I2C;
  HAL_GPIO_Init(GPIOF, &GPIO_InitStruct);

  __HAL_RCC_I2C_FORCE_RESET();
  __HAL_RCC_I2C_RELEASE_RESET();
}

/**
  * @brief SPI MSP Initialization
  *        This function configures the hardware resources used for SPI1
  * @param hspi: SPI handle pointer
  * @retval None
  */
void HAL_SPI_MspInit(SPI_HandleTypeDef* hspi)
{
    GPIO_InitTypeDef GPIO_InitStruct = {0};
    
    if(hspi->Instance == SPI1)
    {
        // Enable SPI1 and GPIOA clocks
        __HAL_RCC_SPI1_CLK_ENABLE();
        __HAL_RCC_GPIOA_CLK_ENABLE();
        
        /**
         * SPI1 GPIO Configuration (PY32F030x8)
         * PA5  ------> SPI1_SCK  (AF0)
         * PA6  ------> SPI1_MISO (AF0)
         * PA7  ------> SPI1_MOSI (AF0)
         * PA4  ------> CS (configured separately in SPI_Init as GPIO output)
         */
        
        // Configure SCK first (needs pull-up/pull-down based on CLKPolarity)
        GPIO_InitStruct.Pin = GPIO_PIN_5;
        GPIO_InitStruct.Mode = GPIO_MODE_AF_PP;
        // Set pull based on clock polarity (official example pattern)
        if (hspi->Init.CLKPolarity == SPI_POLARITY_LOW)
        {
            GPIO_InitStruct.Pull = GPIO_PULLDOWN;
        }
        else
        {
            GPIO_InitStruct.Pull = GPIO_PULLUP;
        }
        GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
        GPIO_InitStruct.Alternate = GPIO_AF0_SPI1;
        HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);
        
        // Configure MISO and MOSI together (same settings)
        GPIO_InitStruct.Pin = GPIO_PIN_6 | GPIO_PIN_7;  // MISO | MOSI
        GPIO_InitStruct.Mode = GPIO_MODE_AF_PP;
        GPIO_InitStruct.Pull = GPIO_NOPULL;  // No pull for MISO/MOSI
        GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
        GPIO_InitStruct.Alternate = GPIO_AF0_SPI1;
        HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);
    }
}

/**
  * @brief SPI MSP De-Initialization
  *        This function frees the hardware resources used for SPI1
  * @param hspi: SPI handle pointer
  * @retval None
  */
void HAL_SPI_MspDeInit(SPI_HandleTypeDef* hspi)
{
    if(hspi->Instance == SPI1)
    {
        __HAL_RCC_SPI1_CLK_DISABLE();
        HAL_GPIO_DeInit(GPIOA, GPIO_PIN_4 | GPIO_PIN_5 | GPIO_PIN_6 | GPIO_PIN_7);
    }
}

/************************ (C) COPYRIGHT Puya *****END OF FILE******************/
