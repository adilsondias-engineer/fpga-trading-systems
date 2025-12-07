cmake_minimum_required(VERSION 3.20)
project(OrderGateway C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add vcpkg installed directory to CMAKE_PREFIX_PATH if it exists
if(EXISTS "${CMAKE_SOURCE_DIR}/vcpkg_installed/x64-linux/share")
    list(APPEND CMAKE_PREFIX_PATH "${CMAKE_SOURCE_DIR}/vcpkg_installed/x64-linux/share")
    message(STATUS "Added vcpkg_installed to CMAKE_PREFIX_PATH")
endif()

find_package(eclipse-paho-mqtt-c CONFIG REQUIRED)
find_package(RdKafka CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(nlohmann_json CONFIG QUIET)

# Define _WIN32_WINNT for Windows
if(WIN32)
    add_definitions(-D_WIN32_WINNT=0x0601)
endif()

# Set default build type to Debug if not specified
# This is required for single-config generators (like Ninja) to work properly with IntelliSense
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
    message(STATUS "CMAKE_BUILD_TYPE not set, defaulting to Debug")
endif()

# Generate compile_commands.json for IntelliSense
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)
include_directories(${CMAKE_SOURCE_DIR}/../common)

# Option to enable XDP support
option(USE_XDP "Enable AF_XDP support for kernel bypass" OFF)

# Option to enable DPDK support
option(USE_DPDK "Enable DPDK support for userspace kernel bypass" OFF)

# Source files
set(SOURCES
    src/main.cpp
    src/order_gateway.cpp
    src/udp_listener.cpp
    src/bbo_parser.cpp
    src/binance_parser.cpp
    src/binance_ws_client.cpp
    src/tcp_server.cpp
    src/csv_logger.cpp
    src/mqtt.cpp
    src/kafka_producer.cpp
)

# Add XDP listener source if enabled
if(USE_XDP)
    list(APPEND SOURCES src/xdp_listener.cpp)
    message(STATUS "XDP support enabled")
    
    # Try to find libbpf and libxdp (required for proper XDP support)
    find_path(LIBBPF_INCLUDE_DIR bpf/bpf.h)
    find_library(LIBBPF_LIBRARY bpf)
    
    # Find libxdp (required for XSK map population)
    find_path(LIBXDP_INCLUDE_DIR xdp/libxdp.h)
    find_library(LIBXDP_LIBRARY xdp)
    
    if(LIBBPF_INCLUDE_DIR AND LIBBPF_LIBRARY AND LIBXDP_INCLUDE_DIR AND LIBXDP_LIBRARY)
        message(STATUS "libbpf found: ${LIBBPF_LIBRARY}")
        message(STATUS "libxdp found: ${LIBXDP_LIBRARY}")
        set(HAVE_LIBXDP TRUE)
    else()
        message(WARNING "libxdp not found - XDP bind will fail. Install: sudo apt-get install libxdp-dev")
        set(HAVE_LIBXDP FALSE)
    endif()
else()
    message(STATUS "XDP support disabled (use -DUSE_XDP=ON to enable)")
endif()

# Add DPDK listener source if enabled
if(USE_DPDK)
    list(APPEND SOURCES src/dpdk_listener.cpp)
    message(STATUS "DPDK support enabled")
    
    # Find DPDK using pkg-config (preferred method)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(DPDK QUIET libdpdk)
    endif()
    
    # Alternative: Find DPDK by DPDK_ROOT environment variable or CMake variable
    if(NOT DPDK_FOUND)
        if(DEFINED ENV{DPDK_ROOT})
            set(DPDK_ROOT $ENV{DPDK_ROOT})
        endif()
        
        if(DPDK_ROOT)
            set(DPDK_INCLUDE_DIR "${DPDK_ROOT}/include")
            set(DPDK_LIB_DIR "${DPDK_ROOT}/lib")
            
            # Find DPDK libraries (common ones)
            find_library(DPDK_RTE_EAL NAMES rte_eal PATHS ${DPDK_LIB_DIR})
            find_library(DPDK_RTE_ETHDEV NAMES rte_ethdev PATHS ${DPDK_LIB_DIR})
            find_library(DPDK_RTE_MBUF NAMES rte_mbuf PATHS ${DPDK_LIB_DIR})
            find_library(DPDK_RTE_MEMPOOL NAMES rte_mempool PATHS ${DPDK_LIB_DIR})
            find_library(DPDK_RTE_NET NAMES rte_net PATHS ${DPDK_LIB_DIR})
            
            if(DPDK_RTE_EAL AND DPDK_RTE_ETHDEV AND DPDK_RTE_MBUF)
                set(DPDK_FOUND TRUE)
                set(DPDK_INCLUDE_DIRS ${DPDK_INCLUDE_DIR})
                set(DPDK_LIBRARIES 
                    ${DPDK_RTE_EAL}
                    ${DPDK_RTE_ETHDEV}
                    ${DPDK_RTE_MBUF}
                    ${DPDK_RTE_MEMPOOL}
                    ${DPDK_RTE_NET}
                )
                message(STATUS "DPDK found via DPDK_ROOT: ${DPDK_ROOT}")
            endif()
        endif()
    endif()
    
    # System-wide DPDK installation (try common paths)
    if(NOT DPDK_FOUND)
        find_path(DPDK_INCLUDE_DIR rte_eal.h
            PATHS
                /usr/include/dpdk
                /usr/local/include/dpdk
                /opt/dpdk/include
        )
        
        if(DPDK_INCLUDE_DIR)
            # Try to find libraries in common locations
            find_library(DPDK_RTE_EAL NAMES rte_eal
                PATHS
                    /usr/lib/x86_64-linux-gnu
                    /usr/lib64
                    /usr/local/lib
                    /opt/dpdk/lib
            )
            
            if(DPDK_RTE_EAL)
                set(DPDK_FOUND TRUE)
                set(DPDK_INCLUDE_DIRS ${DPDK_INCLUDE_DIR})
                # DPDK libraries are typically linked via pkg-config, but try to find them
                message(STATUS "DPDK found in system paths: ${DPDK_INCLUDE_DIR}")
                message(STATUS "DPDK library: ${DPDK_RTE_EAL}")
                message(WARNING "DPDK system installation detected. Ensure all DPDK libraries are available.")
                message(WARNING "Recommended: Install DPDK via package manager or set DPDK_ROOT")
            endif()
        endif()
    endif()
    
    if(DPDK_FOUND)
        message(STATUS "DPDK include dirs: ${DPDK_INCLUDE_DIRS}")
        message(STATUS "DPDK libraries: ${DPDK_LIBRARIES}")
        target_include_directories(order_gateway PRIVATE ${DPDK_INCLUDE_DIRS})
        target_compile_definitions(order_gateway PRIVATE USE_DPDK)
        set(HAVE_DPDK TRUE)
    else()
        message(WARNING "DPDK not found!")
        message(WARNING "Install DPDK:")
        message(WARNING "  1. Download from: https://www.dpdk.org/downloads/")
        message(WARNING "  2. Build: meson build && ninja -C build")
        message(WARNING "  3. Install: sudo ninja -C build install")
        message(WARNING "  4. Or set DPDK_ROOT environment variable to DPDK installation path")
        set(HAVE_DPDK FALSE)
    endif()
else()
    message(STATUS "DPDK support disabled (use -DUSE_DPDK=ON to enable)")
endif()

# Executable
add_executable(order_gateway ${SOURCES})

# Note: DPDK libraries must be linked after executable is created
# This is done below in the DPDK configuration section

# Link Paho MQTT C library (synchronous client)
target_link_libraries(order_gateway PRIVATE eclipse-paho-mqtt-c::paho-mqtt3a-static eclipse-paho-mqtt-c::paho-mqtt3c-static eclipse-paho-mqtt-c::paho-mqtt3as-static eclipse-paho-mqtt-c::paho-mqtt3cs-static)

# Link Kafka libraries (using librdkafka C++ API)
# rdkafka::rdkafka++ target links C++ API and pulls C core transitively
target_link_libraries(order_gateway PRIVATE RdKafka::rdkafka++)

# Link pthread library (required for RT scheduling and CPU pinning)
find_package(Threads REQUIRED)
target_link_libraries(order_gateway PRIVATE Threads::Threads)

# Link DPDK libraries if enabled
if(USE_DPDK AND HAVE_DPDK)
    if(DPDK_LIBRARIES)
        target_link_libraries(order_gateway PRIVATE ${DPDK_LIBRARIES})
    elseif(DPDK_LDFLAGS)
        # If pkg-config was used, link via flags
        target_link_options(order_gateway PRIVATE ${DPDK_LDFLAGS})
    else()
        # Try to link common DPDK libraries
        target_link_libraries(order_gateway PRIVATE
            rte_eal
            rte_ethdev
            rte_mbuf
            rte_mempool
            rte_net
            rte_ether
            rte_ip
            rte_udp
        )
    endif()
    message(STATUS "DPDK libraries linked")
endif()

# Link spdlog for logging
target_link_libraries(order_gateway PRIVATE spdlog::spdlog)

# Link nlohmann_json for JSON parsing (Binance WebSocket)
if(nlohmann_json_FOUND)
    target_link_libraries(order_gateway PRIVATE nlohmann_json::nlohmann_json)
    message(STATUS "nlohmann_json found: ${nlohmann_json_VERSION}")
else()
    message(WARNING "nlohmann_json not found - Binance integration will not compile")
    message(WARNING "Install via vcpkg: vcpkg install nlohmann-json")
endif()

# Boost.Asio integration
# Try to find Boost (works with vcpkg if vcpkg toolchain is set)
find_package(Boost REQUIRED COMPONENTS system thread)

if(Boost_FOUND)
    message(STATUS "Boost found: ${Boost_VERSION}")
    message(STATUS "Boost include dirs: ${Boost_INCLUDE_DIRS}")
    
    # Link Boost.System (required for Boost.Asio error codes)
    if(TARGET Boost::system AND TARGET Boost::thread)
        target_link_libraries(order_gateway PRIVATE Boost::system Boost::thread)
    elseif(TARGET boost_system AND TARGET boost_thread)
        target_link_libraries(order_gateway PRIVATE boost_system boost_thread)
    else()
        # Fallback: link the library directly
        find_library(BOOST_SYSTEM_LIB 
            NAMES boost_system
                  libboost_system
            PATHS ${Boost_LIBRARY_DIRS}
        )
        if(BOOST_SYSTEM_LIB AND BOOST_THREAD_LIB    )
            target_link_libraries(order_gateway PRIVATE ${BOOST_SYSTEM_LIB} ${BOOST_THREAD_LIB})
        else()
            message(WARNING "Boost.System library not found, but headers should still work")
        endif()
    endif()
    
    # Add Boost include directory
    if(Boost_INCLUDE_DIRS)
        target_include_directories(order_gateway PRIVATE ${Boost_INCLUDE_DIRS})
    endif()
    
    # Define preprocessor macro to indicate Boost.Asio is available
    target_compile_definitions(order_gateway PRIVATE USE_BOOST_ASIO)
    message(STATUS "Boost.Asio configured successfully")
else()
    message(FATAL_ERROR 
        "Boost not found!\n"
        "Install Boost using one of these methods:\n"
        "  1. vcpkg: vcpkg install boost-system\n"
        "  2. Download from: https://www.boost.org/\n"
        "  3. Set Boost_ROOT to your Boost installation directory"
    )
endif()

# Configure XDP support after target is created
if(USE_XDP)
    target_compile_definitions(order_gateway PRIVATE USE_XDP)
    
    # Link libbpf and libxdp if found
    if(HAVE_LIBXDP)
        target_include_directories(order_gateway PRIVATE ${LIBBPF_INCLUDE_DIR} ${LIBXDP_INCLUDE_DIR})
        target_link_libraries(order_gateway PRIVATE ${LIBBPF_LIBRARY} ${LIBXDP_LIBRARY})
        target_compile_definitions(order_gateway PRIVATE HAVE_LIBXDP)
        message(STATUS "XDP support enabled with libxdp")
    else()
        message(WARNING "XDP enabled but libxdp not found - XDP bind will fail")
    endif()
    
    # Build cleanup tool if libbpf is available (separate from HAVE_LIBXDP check)
    if(LIBBPF_INCLUDE_DIR AND LIBBPF_LIBRARY)
        add_executable(cleanup_xsk_map cleanup_xsk_map.c)
        set_target_properties(cleanup_xsk_map PROPERTIES LINKER_LANGUAGE C)
        target_include_directories(cleanup_xsk_map PRIVATE ${LIBBPF_INCLUDE_DIR})
        target_link_libraries(cleanup_xsk_map PRIVATE ${LIBBPF_LIBRARY})
        message(STATUS "XDP cleanup tool will be built")
    endif()
    
    # Compile eBPF program
    find_program(CLANG_EXECUTABLE clang)
    if(CLANG_EXECUTABLE)
        set(XDP_PROG_SRC "${CMAKE_SOURCE_DIR}/xdp/xdp_prog.c")
        set(XDP_PROG_OBJ "${CMAKE_BINARY_DIR}/xdp_prog.o")
        
        # Find kernel headers
        execute_process(
            COMMAND uname -r
            OUTPUT_VARIABLE KERNEL_VERSION
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        
        execute_process(
            COMMAND uname -m
            OUTPUT_VARIABLE ARCH
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        
        # Map architecture names (x86_64 -> x86)
        if(ARCH STREQUAL "x86_64")
            set(KERNEL_ARCH "x86")
        else()
            set(KERNEL_ARCH ${ARCH})
        endif()
        
        # Find kernel source/build directory
        set(KERNEL_BUILD "")
        if(EXISTS "/lib/modules/${KERNEL_VERSION}/build")
            set(KERNEL_BUILD "/lib/modules/${KERNEL_VERSION}/build")
        elseif(EXISTS "/usr/src/linux-headers-${KERNEL_VERSION}")
            set(KERNEL_BUILD "/usr/src/linux-headers-${KERNEL_VERSION}")
        endif()
        
        # Build include flags - use kernel build directory as base
        set(INCLUDE_FLAGS "")
        
        if(KERNEL_BUILD)
            # Architecture-specific UAPI includes FIRST (for asm/ includes)
            if(EXISTS "${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/generated/uapi")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/generated/uapi")
            endif()
            if(EXISTS "${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/uapi")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/uapi")
            endif()
            if(EXISTS "${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/generated")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include/generated")
            endif()
            if(EXISTS "${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/arch/${KERNEL_ARCH}/include")
            endif()
            
            # Main UAPI includes
            if(EXISTS "${KERNEL_BUILD}/include/uapi")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/include/uapi")
            endif()
            if(EXISTS "${KERNEL_BUILD}/include/generated/uapi")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/include/generated/uapi")
            endif()
            
            # Main include directory
            if(EXISTS "${KERNEL_BUILD}/include")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/include")
            endif()
            
            # Tools/include (for bpf helpers)
            if(EXISTS "${KERNEL_BUILD}/tools/include")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/tools/include")
            endif()
            
            # Tools/lib/bpf (for bpf helpers)
            if(EXISTS "${KERNEL_BUILD}/tools/lib/bpf")
                list(APPEND INCLUDE_FLAGS "-I${KERNEL_BUILD}/tools/lib/bpf")
            endif()
        endif()
        
        # Fallback to system includes
        list(APPEND INCLUDE_FLAGS "-I/usr/include")
        list(APPEND INCLUDE_FLAGS "-I/usr/include/x86_64-linux-gnu")
        
        # Also check for libbpf headers
        if(LIBBPF_INCLUDE_DIR)
            list(APPEND INCLUDE_FLAGS "-I${LIBBPF_INCLUDE_DIR}")
        endif()
        
        # Check if kernel has BTF support
        execute_process(
            COMMAND test -f /sys/kernel/btf/vmlinux
            RESULT_VARIABLE BTF_AVAILABLE
        )
        
        if(BTF_AVAILABLE EQUAL 0)
            message(STATUS "Kernel BTF support detected - compiling with BTF")
            set(BPF_FLAGS "-g")  # Include debug info for BTF
        else()
            message(STATUS "Kernel BTF not available - compiling without BTF")
            set(BPF_FLAGS "")
        endif()
        
        add_custom_command(
            OUTPUT ${XDP_PROG_OBJ}
            COMMAND ${CLANG_EXECUTABLE}
                -O2
                -target bpf
                ${BPF_FLAGS}
                -c ${XDP_PROG_SRC}
                -o ${XDP_PROG_OBJ}
                ${INCLUDE_FLAGS}
                -Wno-unused-value
                -Wno-pointer-sign
                -Wno-compare-distinct-pointer-types
                -Wno-gnu-variable-sized-type-not-at-end
                -Wno-address-of-packed-member
                -Wno-tautological-compare
                -Wno-unknown-warning-option
            DEPENDS ${XDP_PROG_SRC}
            COMMENT "Compiling eBPF/XDP program"
            VERBATIM
        )
        
        add_custom_target(xdp_prog ALL DEPENDS ${XDP_PROG_OBJ})
        
        # Install the eBPF object file
        install(FILES ${XDP_PROG_OBJ} DESTINATION bin RENAME xdp_prog.o)
        
        message(STATUS "eBPF program will be compiled to: ${XDP_PROG_OBJ}")
    else()
        message(WARNING "clang not found - eBPF program will not be compiled automatically")
        message(WARNING "Install clang: sudo apt-get install clang")
    endif()
endif()

# Installation
install(TARGETS order_gateway DESTINATION bin)
# Linux-specific optimizations
if(UNIX AND NOT APPLE)
    target_compile_options(order_gateway PRIVATE -march=native -O3)
endif()
# Print build information
message(STATUS "Build configuration:")
message(STATUS "  CMAKE_BUILD_TYPE: ${CMAKE_BUILD_TYPE}")
message(STATUS "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}")
message(STATUS "  CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}")
message(STATUS "  CMAKE_CXX_STANDARD: ${CMAKE_CXX_STANDARD}")
