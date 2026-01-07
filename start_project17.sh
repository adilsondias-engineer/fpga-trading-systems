#!/bin/bash

# Project 17: Hardware Timestamping Demo Startup Script
# This script starts the timestamp_demo application

set -e

PROJECT_DIR="17-cpp-hardware-timestamping"
BUILD_DIR="${PROJECT_DIR}/build"
EXECUTABLE="timestamp_demo"
CONFIG_FILE="${PROJECT_DIR}/config.json"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Project 17: Hardware Timestamping Demo${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if project directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    echo -e "${RED}ERROR: Project directory '${PROJECT_DIR}' not found${NC}"
    exit 1
fi

# Check if build directory exists
if [ ! -d "$BUILD_DIR" ]; then
    echo -e "${YELLOW}Build directory not found, creating and building...${NC}"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    cmake ..
    make -j$(nproc)
    cd - > /dev/null
else
    # Check if executable exists
    if [ ! -f "${BUILD_DIR}/${EXECUTABLE}" ]; then
        echo -e "${YELLOW}Executable not found, building...${NC}"
        cd "$BUILD_DIR"
        make -j$(nproc)
        cd - > /dev/null
    fi
fi

# Verify executable exists
if [ ! -f "${BUILD_DIR}/${EXECUTABLE}" ]; then
    echo -e "${RED}ERROR: Failed to build ${EXECUTABLE}${NC}"
    exit 1
fi

echo -e "${GREEN}Starting ${EXECUTABLE}...${NC}"
echo ""

# Run the executable
cd "$BUILD_DIR"
./${EXECUTABLE} "../${CONFIG_FILE##*/}"
