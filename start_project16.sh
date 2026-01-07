#!/bin/bash
# Project 16 - Order Execution Engine + Simulated Exchange Startup Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Project 16: Order Execution Engine + Simulated Exchange${NC}"
echo "=================================================================="

# Check if executables exist
if [ ! -f "16-cpp-order-execution/build/simulated_exchange" ] || [ ! -f "16-cpp-order-execution/build/order_execution_engine" ]; then
    echo -e "${RED}Error: Executables not found. Please build Project 16 first:${NC}"
    echo "  cd 16-cpp-order-execution/build"
    echo "  cmake -DCMAKE_TOOLCHAIN_FILE=/tools/vcpkg/scripts/buildsystems/vcpkg.cmake .."
    echo "  make"
    exit 1
fi

# Clean up any existing shared memory
echo -e "${YELLOW}Cleaning up existing shared memory...${NC}"
rm -f /dev/shm/order_ring_mm /dev/shm/fill_ring_oe

# Check if config file exists
if [ ! -f "16-cpp-order-execution/config.json" ]; then
    echo -e "${RED}Error: config.json not found in 16-cpp-order-execution/${NC}"
    exit 1
fi

# Copy config to build directory
cp 16-cpp-order-execution/config.json 16-cpp-order-execution/build/

# Start simulated exchange in background
echo -e "${GREEN}Starting Simulated Exchange on port 5001...${NC}"
cd 16-cpp-order-execution/build
./simulated_exchange &
EXCHANGE_PID=$!
cd ../..

# Wait for exchange to initialize
sleep 2

# Start order execution engine
echo -e "${GREEN}Starting Order Execution Engine...${NC}"
cd 16-cpp-order-execution/build
./order_execution_engine &
OE_PID=$!
cd ../..

echo ""
echo -e "${GREEN}Project 16 started successfully!${NC}"
echo "=================================================================="
echo -e "Simulated Exchange PID: ${EXCHANGE_PID}"
echo -e "Order Execution Engine PID: ${OE_PID}"
echo ""
echo -e "${YELLOW}To enable order execution in Project 15:${NC}"
echo "  1. Edit 15-cpp-market-maker/config.json"
echo "  2. Set 'enable_order_execution': true"
echo "  3. Start Project 14 (./start_project14.sh)"
echo "  4. Start Project 15 (./start_project15.sh)"
echo ""
echo -e "${YELLOW}To stop Project 16:${NC}"
echo "  kill $EXCHANGE_PID $OE_PID"
echo ""
echo -e "${YELLOW}Logs:${NC}"
echo "  Watch order flow: tail -f 16-cpp-order-execution/build/*.log"
echo ""
echo -e "${GREEN}Press Ctrl+C to stop all processes${NC}"

# Wait for processes
wait
