cmake_minimum_required (VERSION 3.16.3 FATAL_ERROR)

project(fpga_status  LANGUAGES  C CXX)

add_compile_definitions(${PUYA_CHIP})
set(CMAKE_EXECUTABLE_SUFFIX ".elf")

execute_process(COMMAND bash -c "pyocd list | grep -Po '[0-9a-z]{48}'" OUTPUT_VARIABLE OCD_PROBE OUTPUT_STRIP_TRAILING_WHITESPACE)
configure_file(${CMAKE_SOURCE_DIR}/pyocd/pyocd.in ${CMAKE_BINARY_DIR}/pyocd.yaml)

add_subdirectory(puya_libs)
target_include_directories(PuyaBSP PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/OLED)

#add_executable(${PROJECT_NAME} OLED/py32f0xx_it.c OLED/py32f0xx_hal_msp.c OLED/main.c )
add_executable(${PROJECT_NAME} OLED/py32f0xx_it.c OLED/py32f0xx_hal_msp.c OLED/spi.c OLED/ssd1306.c OLED/ascii_fonts.c OLED/main.c )
target_link_libraries(${PROJECT_NAME} PUBLIC $<TARGET_OBJECTS:PuyaBSP>)
target_include_directories(${PROJECT_NAME} PRIVATE $<TARGET_PROPERTY:PuyaBSP,INTERFACE_INCLUDE_DIRECTORIES>)

add_custom_target(flash
    COMMENT "Flashing software on Puya board"
    COMMAND  pyocd load --pack ${CMAKE_SOURCE_DIR}/pyocd/Puya.PY32F0xx_DFP.1.1.7.pack --target ${PUYA_CHIP} ${CMAKE_BINARY_DIR}/fpga_status.elf -e auto -v --format elf
    )
add_dependencies(flash ${PROJECT_NAME})