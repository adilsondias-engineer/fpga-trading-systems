#!/bin/bash
#
# Start Project 14 (Producer) with XDP + Disruptor
#

set -e

# Configuration
XDP_INTERFACE="eno2"
XDP_QUEUE_ID="1"  # Packets arriving on queue 2
UDP_PORT="5000"

echo "========================================="
echo "Starting Project 14 (Producer)"
echo "XDP + Disruptor Mode"
echo "========================================="

# Cleanup any existing shared memory
echo "Cleaning up shared memory..."
rm -f /dev/shm/bbo_ring_gateway 2>/dev/null || true
#sudo xdp-loader unload eno2 -a 2>/dev/null
cd /work/projects/fpga-trading-systems/14-cpp-order-gateway/build
sudo xdp-loader load -m native -s xdp eno2 xdp_prog.o
echo ""
echo "Starting Order Gateway with:"
echo "  - XDP interface: $XDP_INTERFACE"
echo "  - XDP queue ID: $XDP_QUEUE_ID"
echo "  - UDP port: $UDP_PORT"
echo "  - Disruptor: ENABLED"
echo "  - Real-time: ENABLED"
echo "  - TCP/MQTT/Kafka: DISABLED (using Disruptor only)"
echo ""
# --enable-xdp-debug
sudo ./order_gateway
