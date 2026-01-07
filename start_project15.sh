#!/bin/bash
#
# Start Project 15 (Consumer) with Disruptor
#

set -e

echo "========================================="
echo "Starting Project 15 (Consumer)"
echo "Disruptor Mode"
echo "========================================="

# Check if shared memory exists
if [ ! -e "/dev/shm/bbo_ring_gateway" ]; then
    echo ""
    echo "WARNING: Shared memory not found!"
    echo "Make sure Project 14 is running with --enable-disruptor"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

cd /work/projects/fpga-trading-systems/15-cpp-market-maker/build

echo ""
echo "Starting Market Maker with:"
echo "  - Disruptor: ENABLED (config.json)"
echo "  - Real-time: ENABLED"
echo "  - CPU cores: 2,3"
echo ""

sudo ./market_maker
