#!/bin/bash
#
# Integration Test: XDP + Disruptor
# Project 14 (Producer) with XDP kernel bypass → Shared Memory → Project 15 (Consumer)
#

set -e

echo "========================================="
echo "XDP + Disruptor Integration Test"
echo "========================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
PROJECT_14_DIR="/work/projects/fpga-trading-systems/14-order-gateway-cpp"
PROJECT_15_DIR="/work/projects/fpga-trading-systems/15-market-maker"
XDP_INTERFACE="eno2"
XDP_QUEUE_ID="0"
UDP_PORT="5000"

echo -e "${YELLOW}Prerequisites:${NC}"
echo "1. Both projects built successfully"
echo "2. Root privileges (sudo) available"
echo "3. XDP interface: $XDP_INTERFACE"
echo "4. UDP port: $UDP_PORT"
echo ""

# Check builds
if [ ! -f "$PROJECT_14_DIR/build/order_gateway" ]; then
    echo -e "${RED}Error: Project 14 not built${NC}"
    exit 1
fi

if [ ! -f "$PROJECT_15_DIR/build/market_maker" ]; then
    echo -e "${RED}Error: Project 15 not built${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Both executables found${NC}"
echo ""

# Cleanup any existing shared memory
echo -e "${YELLOW}Cleaning up shared memory...${NC}"
rm -f /dev/shm/bbo_ring_gateway 2>/dev/null || true
echo -e "${GREEN}✓ Shared memory cleaned${NC}"
echo ""

# Instructions
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Testing Instructions (3 Terminals):${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo -e "${GREEN}STEP 1: Terminal 1 - Start Project 14 (Producer):${NC}"
echo "cd /work/projects/fpga-trading-systems"
echo "./start_project14.sh"
echo ""
echo -e "${YELLOW}Wait for: \"[Disruptor] Shared memory ring buffer created\"${NC}"
echo -e "${YELLOW}Wait for: \"Gateway running. Press Ctrl+C to stop.\"${NC}"
echo ""
echo -e "${GREEN}STEP 2: Terminal 2 - Start Project 15 (Consumer):${NC}"
echo "cd /work/projects/fpga-trading-systems"
echo "./start_project15.sh"
echo ""
echo -e "${YELLOW}Wait for: \"Connected to Order Gateway (Disruptor Mode)\"${NC}"
echo -e "${YELLOW}Wait for: \"Market Maker FSM running\"${NC}"
echo ""
echo -e "${GREEN}STEP 3: Terminal 3 - Send test BBO:${NC}"
echo "echo '[BBO:AAPL    ]Bid:0x0016E360 (0x00000064) | Ask:0x0016D99C (0x000000C8) | Spr:0x00001388' | nc -u 127.0.0.1 $UDP_PORT"
echo ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Expected Output in Terminal 2:${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo "Expected output:"
echo "  - BBO received with symbol: AAPL"
echo "  - Latency < 1 μs (sub-microsecond!)"
echo "  - FSM state transitions"
echo "  - Quote generation"
echo ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Architecture:${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo "FPGA → UDP → XDP (kernel bypass) → Project 14 → Disruptor → Project 15"
echo "              (eno2)                 (Producer)   (shared    (Consumer)"
echo "                                                   memory)"
echo ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Performance Comparison:${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo "TCP Mode (previous):     ~12.73 μs end-to-end latency"
echo "XDP + Disruptor Mode:     < 1 μs end-to-end latency"
echo "Performance Gain:         >12x faster"
echo ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Manual Commands (if not using scripts):${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo -e "${GREEN}Terminal 1:${NC}"
echo "cd $PROJECT_14_DIR/build"
echo "sudo ./order_gateway 0.0.0.0 $UDP_PORT --enable-disruptor --use-xdp --xdp-interface $XDP_INTERFACE --xdp-queue-id $XDP_QUEUE_ID --enable-rt --disable-tcp --disable-mqtt --disable-kafka --disable-logger --quiet"
echo ""
echo -e "${GREEN}Terminal 2:${NC}"
echo "cd $PROJECT_15_DIR/build"
echo "sudo ./market_maker"
echo ""
echo -e "${GREEN}Ready to test!${NC}"
