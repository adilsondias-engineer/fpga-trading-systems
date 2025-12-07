/*
DPDK Listener
High-performance packet reception using Data Plane Development Kit (DPDK)
Userspace kernel bypass for ultra-low latency packet processing

This implementation uses the IGC PMD (Poll Mode Driver) for Intel I225/I226 NICs.
*/

#pragma once

#include <string>
#include <memory>
#include "bbo_parser.h"

// Forward declare DPDK types to avoid including headers in header file
// The implementation will include the full DPDK headers
struct rte_mbuf;

namespace gateway {

    class PerfMonitor;  // Forward declaration

    class DPDKListener {
    public:
        /**
         * Create DPDK listener for high-performance packet reception
         * 
         * @param iface Network interface name (e.g., "eno2")
         * @param port UDP port to filter (e.g., 5000)
         * @param queue_id RX queue ID (default: 0)
         * @param enable_debug Enable debug logging (default: false)
         * 
         * Note: DPDK requires:
         * - Hugepages configured (e.g., sudo sysctl vm.nr_hugepages=1024)
         * - Interface bound to DPDK (use dpdk-devbind.py)
         * - Root privileges or CAP_NET_RAW + CAP_NET_ADMIN
         */
        explicit DPDKListener(const std::string& iface, int port, int queue_id = 0, bool enable_debug = false);
        ~DPDKListener();

        // Start receiving packets (non-blocking)
        void start();
        
        // Stop receiving packets
        void stop();
        
        // Read next BBO packet (blocking)
        BBOData read_bbo();
        
        // Check if listener is running
        bool isRunning() const;

        // Set performance monitor (optional)
        void setPerfMonitor(PerfMonitor* monitor) { perf_monitor_ = monitor; }

    private:
        // DPDK port ID
        uint16_t port_id_{0};
        
        // RX queue ID
        uint16_t queue_id_{0};
        
        // UDP port to filter
        int port_;
        
        // Interface name
        std::string iface_;
        
        // Running state
        bool running_{false};
        
        // Debug logging enabled
        bool enable_debug_{false};

        // RX burst size (packets per poll)
        static constexpr uint16_t RX_BURST_SIZE = 64;
        
        // Number of RX descriptors per queue
        static constexpr uint16_t RX_RING_SIZE = 2048;
        
        // Number of TX descriptors per queue (not used for RX-only)
        static constexpr uint16_t TX_RING_SIZE = 1024;

        // RX packet buffers (using global namespace rte_mbuf from DPDK)
        ::rte_mbuf* rx_pkts_[RX_BURST_SIZE];

        // Initialize DPDK EAL (Environment Abstraction Layer)
        void init_dpdk(int argc, char** argv);
        
        // Setup DPDK port and queues
        void setup_port();
        
        // Poll for packets (non-blocking)
        bool poll_packet(uint8_t* buffer, size_t& len);
        
        // Find DPDK port ID from interface name
        uint16_t find_port_id(const std::string& iface);
        
        // Configure RX queue
        void configure_rx_queue(uint16_t port_id, uint16_t queue_id);
        
        // Start DPDK port
        void start_port(uint16_t port_id);

        // Performance monitoring
        PerfMonitor* perf_monitor_ = nullptr;
    };

} // namespace gateway

