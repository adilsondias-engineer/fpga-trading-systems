/*
DPDK Listener Implementation
High-performance packet reception using Data Plane Development Kit (DPDK)

This implementation uses the IGC PMD (Poll Mode Driver) for Intel I225/I226 NICs.
DPDK provides userspace kernel bypass for ultra-low latency packet processing.

Key DPDK Concepts:
- EAL (Environment Abstraction Layer): Initializes DPDK, manages memory, CPU cores
- PMD (Poll Mode Driver): Userspace driver for specific NIC hardware
- Port: DPDK abstraction for a network interface
- Queue: RX/TX queue for packet processing
- mbuf: DPDK's packet buffer structure (zero-copy)
*/

#include "dpdk_listener.h"
#include "common/perf_monitor.h"
#include <spdlog/spdlog.h>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// DPDK includes
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_udp.h>

namespace gateway {

// Static flag to track if DPDK EAL is initialized
static bool dpdk_initialized = false;
static int dpdk_argc = 0;
static char** dpdk_argv = nullptr;

DPDKListener::DPDKListener(const std::string& iface, int port, int queue_id, bool enable_debug)
    : iface_(iface), port_(port), queue_id_(queue_id), enable_debug_(enable_debug) {
    
    if (enable_debug_) {
        spdlog::debug("[DPDK] Initializing DPDK listener on interface: {}, port: {}", iface, port);
    }
    
    // Initialize DPDK EAL (must be done once, before any DPDK operations)
    if (!dpdk_initialized) {
        // DPDK EAL arguments
        // Note: In a real application, these would come from command-line args
        // For now, we use minimal configuration
        static const char* eal_args[] = {
            "order_gateway",  // Program name
            "-l", "0",        // Core list (use core 0)
            "--huge-dir", "/dev/hugepages",  // Hugepage directory
            "--file-prefix", "gateway",      // File prefix for shared memory
            // Note: PCI is enabled by default (needed for NIC access)
            nullptr
        };
        
        // Count args
        int argc = 0;
        while (eal_args[argc] != nullptr) argc++;
        
        // Convert to mutable char** for rte_eal_init
        std::vector<char*> argv_vec;
        for (int i = 0; i < argc; i++) {
            argv_vec.push_back(const_cast<char*>(eal_args[i]));
        }
        argv_vec.push_back(nullptr);
        
        // Initialize DPDK EAL
        int ret = rte_eal_init(argc, argv_vec.data());
        if (ret < 0) {
            std::string error_msg = "Failed to initialize DPDK EAL: " + std::string(rte_strerror(rte_errno));
            error_msg += "\n\nTroubleshooting steps:";
            error_msg += "\n1. Ensure hugepages are configured:";
            error_msg += "\n   sudo sysctl vm.nr_hugepages=1024";
            error_msg += "\n2. Check if interface is bound to DPDK driver:";
            error_msg += "\n   dpdk-devbind.py --status";
            error_msg += "\n3. If using igb_uio and getting PCI mapping errors, try vfio-pci instead:";
            error_msg += "\n   # Unbind from current driver:";
            error_msg += "\n   sudo dpdk-devbind.py --unbind 0000:07:00.0";
            error_msg += "\n   # Bind to vfio-pci (requires IOMMU enabled):";
            error_msg += "\n   sudo modprobe vfio-pci";
            error_msg += "\n   sudo dpdk-devbind.py --bind=vfio-pci 0000:07:00.0";
            error_msg += "\n4. If vfio-pci doesn't work, ensure IOMMU is enabled in BIOS and kernel:";
            error_msg += "\n   Check: dmesg | grep -i iommu";
            error_msg += "\n   Kernel boot params should include: intel_iommu=on iommu=pt";
            throw std::runtime_error(error_msg);
        }
        
        dpdk_initialized = true;
        if (enable_debug_) {
            spdlog::debug("[DPDK] DPDK EAL initialized successfully");
        }
    }
    
    // Find port ID from interface name
    port_id_ = find_port_id(iface);
    
    // Setup port and queues
    try {
        setup_port();
        if (enable_debug_) {
            spdlog::debug("[DPDK] DPDK listener initialized successfully on port {}", port_id_);
        }
    } catch (const std::exception& e) {
        throw;
    }
}

DPDKListener::~DPDKListener() {
    stop();
    
    // Note: DPDK cleanup is typically done at program exit
    // We don't call rte_eal_cleanup() here as other components might still use DPDK
}

void DPDKListener::start() {
    if (!running_) {
        running_ = true;
        if (enable_debug_) {
            spdlog::debug("[DPDK] DPDK listener started on port {} queue {}", port_id_, queue_id_);
        }
    }
}

void DPDKListener::stop() {
    if (running_) {
        running_ = false;
        if (enable_debug_) {
            spdlog::debug("[DPDK] DPDK listener stopped");
        }
    }
}

bool DPDKListener::isRunning() const {
    return running_;
}

uint16_t DPDKListener::find_port_id(const std::string& iface) {
    // Iterate through all available DPDK ports
    uint16_t port_count = rte_eth_dev_count_avail();
    
    if (port_count == 0) {
        throw std::runtime_error("No DPDK ports available. "
                               "Ensure interface is bound to DPDK: "
                               "sudo dpdk-devbind.py --bind=igc_uio " + iface);
    }
    
    if (enable_debug_) {
        spdlog::debug("[DPDK] Found {} DPDK port(s), searching for interface: {}", port_count, iface);
    }
    
    // Try to find port by name
    // Note: DPDK port names might differ from system interface names
    // In practice, you'd use dpdk-devbind.py to bind interfaces and get port IDs
    for (uint16_t port_id = 0; port_id < port_count; port_id++) {
        struct rte_eth_dev_info dev_info;
        if (rte_eth_dev_info_get(port_id, &dev_info) != 0) {
            continue;
        }
        
        // Check if this port matches our interface
        // Note: This is simplified - in practice, you'd match by PCI address or MAC
        if (enable_debug_) {
            spdlog::debug("[DPDK] Port {}: driver={}, max_rx_queues={}, max_tx_queues={}",
                         port_id, dev_info.driver_name, dev_info.nb_rx_queues, dev_info.nb_tx_queues);
        }
    }
    
    // For now, use port 0 (first available port)
    // In production, you'd match by PCI address or use a port mapping
    if (enable_debug_) {
        spdlog::debug("[DPDK] Using port 0 (first available). "
                     "For production, match by PCI address or MAC address");
    }
    
    return 0;
}

void DPDKListener::setup_port() {
    // Get device information
    struct rte_eth_dev_info dev_info;
    int ret = rte_eth_dev_info_get(port_id_, &dev_info);
    if (ret != 0) {
        throw std::runtime_error("Failed to get device info for port " + 
                               std::to_string(port_id_) + ": " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    if (enable_debug_) {
        spdlog::debug("[DPDK] Port {} info: driver={}, max_rx_queues={}, max_tx_queues={}",
                     port_id_, dev_info.driver_name, dev_info.max_rx_queues, dev_info.max_tx_queues);
    }
    
    // Configure RX queue
    configure_rx_queue(port_id_, queue_id_);
    
    // Start port
    start_port(port_id_);
}

void DPDKListener::configure_rx_queue(uint16_t port_id, uint16_t queue_id) {
    // Configure number of RX/TX queues
    struct rte_eth_conf port_conf = {};
    port_conf.rxmode.mq_mode = RTE_ETH_MQ_RX_NONE;  // No multi-queue RSS for now
    
    // Enable hardware offloads if supported
    port_conf.rxmode.offloads = 0;
    
    int ret = rte_eth_dev_configure(port_id, 1, 1, &port_conf);  // 1 RX queue, 1 TX queue
    if (ret != 0) {
        throw std::runtime_error("Failed to configure port " + 
                               std::to_string(port_id) + ": " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    // Setup RX queue
    // Note: In production, you'd create a mempool for mbufs
    // For simplicity, we use the default mempool
    struct rte_mempool* mbuf_pool = rte_pktmbuf_pool_create(
        "MBUF_POOL",                    // Pool name
        8192,                           // Number of mbufs
        256,                            // Cache size
        0,                              // Private data size
        RTE_MBUF_DEFAULT_BUF_SIZE,     // Buffer size
        rte_socket_id()                 // Socket ID
    );
    
    if (mbuf_pool == nullptr) {
        throw std::runtime_error("Failed to create mbuf pool: " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    ret = rte_eth_rx_queue_setup(port_id, queue_id, RX_RING_SIZE,
                                  rte_eth_dev_socket_id(port_id),
                                  nullptr, mbuf_pool);
    if (ret != 0) {
        throw std::runtime_error("Failed to setup RX queue " + 
                               std::to_string(queue_id) + " on port " + 
                               std::to_string(port_id) + ": " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    // Setup TX queue (required even if we don't transmit)
    ret = rte_eth_tx_queue_setup(port_id, 0, TX_RING_SIZE,
                                 rte_eth_dev_socket_id(port_id),
                                 nullptr);
    if (ret != 0) {
        throw std::runtime_error("Failed to setup TX queue on port " + 
                               std::to_string(port_id) + ": " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    if (enable_debug_) {
        spdlog::debug("[DPDK] Configured RX queue {} on port {} (ring_size={})",
                     queue_id, port_id, RX_RING_SIZE);
    }
}

void DPDKListener::start_port(uint16_t port_id) {
    // Start the port
    int ret = rte_eth_dev_start(port_id);
    if (ret != 0) {
        throw std::runtime_error("Failed to start port " + 
                               std::to_string(port_id) + ": " + 
                               std::string(rte_strerror(rte_errno)));
    }
    
    // Enable promiscuous mode to receive all packets
    ret = rte_eth_promiscuous_enable(port_id);
    if (ret != 0) {
        spdlog::warn("[DPDK] Failed to enable promiscuous mode on port {}: {}",
                    port_id, rte_strerror(rte_errno));
    }
    
    if (enable_debug_) {
        spdlog::debug("[DPDK] Port {} started successfully", port_id);
    }
}

BBOData DPDKListener::read_bbo() {
    if (!running_) {
        start();
    }
    
    uint8_t buffer[2048];  // Max packet size
    size_t len = 0;
    
    // Poll for packets (blocking)
    while (running_) {
        try {
            if (poll_packet(buffer, len)) {
                // Validate buffer length before parsing
                if (len == 0 || len > 2048) {
                    if (enable_debug_) {
                        spdlog::warn("[DPDK] Invalid packet length: {}", len);
                    }
                    continue;
                }
                
                // Parse BBO data with latency tracking
                BBOData bbo;
                if (perf_monitor_) {
                    gateway::LatencyMeasurement measure(*perf_monitor_);
                    bbo = BBOParser::parseBBOData(buffer, len);
                } else {
                    bbo = BBOParser::parseBBOData(buffer, len);
                }
                
                if (bbo.valid) {
                    return bbo;
                }
            }
        } catch (const std::exception& e) {
            // Log parsing errors but continue processing
            if (enable_debug_) {
                spdlog::error("[DPDK] ERROR in read_bbo: {}", e.what());
            }
            // Continue to next packet instead of crashing
        } catch (...) {
            // Catch any other exceptions
            if (enable_debug_) {
                spdlog::error("[DPDK] ERROR: Unknown exception in read_bbo");
            }
            // Continue to next packet
        }
        
        // Small sleep to avoid busy-waiting
        rte_delay_us_block(10);  // DPDK delay function (10 microseconds)
    }
    
    throw std::runtime_error("DPDK listener stopped");
}

bool DPDKListener::poll_packet(uint8_t* buffer, size_t& len) {
    // Receive burst of packets from DPDK
    uint16_t nb_rx = rte_eth_rx_burst(port_id_, queue_id_, rx_pkts_, RX_BURST_SIZE);
    
    if (nb_rx == 0) {
        return false;  // No packets available
    }
    
    // Process first packet (for simplicity, we process one at a time)
    // In production, you'd process the entire burst
    struct rte_mbuf* pkt = rx_pkts_[0];
    
    // Extract UDP payload
    // DPDK mbuf contains the full Ethernet frame
    struct rte_ether_hdr* eth_hdr = rte_pktmbuf_mtod(pkt, struct rte_ether_hdr*);
    
    // Check if it's an IP packet
    if (rte_be_to_cpu_16(eth_hdr->ether_type) != RTE_ETHER_TYPE_IPV4) {
        // Free mbuf and continue
        rte_pktmbuf_free(pkt);
        return false;
    }
    
    // Get IP header
    struct rte_ipv4_hdr* ip_hdr = (struct rte_ipv4_hdr*)(eth_hdr + 1);
    
    // Check if it's UDP
    if (ip_hdr->next_proto_id != IPPROTO_UDP) {
        rte_pktmbuf_free(pkt);
        return false;
    }
    
    // Get UDP header
    struct rte_udp_hdr* udp_hdr = (struct rte_udp_hdr*)((uint8_t*)ip_hdr + 
                                                         (ip_hdr->version_ihl & 0x0F) * 4);
    
    // Check UDP port
    uint16_t src_port = rte_be_to_cpu_16(udp_hdr->src_port);
    uint16_t dst_port = rte_be_to_cpu_16(udp_hdr->dst_port);
    
    if (dst_port != port_) {
        // Not our port, free and continue
        rte_pktmbuf_free(pkt);
        return false;
    }
    
    // Get UDP payload
    uint8_t* payload = (uint8_t*)(udp_hdr + 1);
    uint16_t payload_len = rte_be_to_cpu_16(udp_hdr->dgram_len) - sizeof(struct rte_udp_hdr);
    
    // Copy payload to buffer
    if (payload_len > 2048) {
        payload_len = 2048;  // Cap at buffer size
    }
    
    rte_memcpy(buffer, payload, payload_len);
    len = payload_len;
    
    // Free mbuf (DPDK zero-copy: we've copied the data we need)
    rte_pktmbuf_free(pkt);
    
    // Free remaining mbufs in burst (we only processed the first one)
    for (uint16_t i = 1; i < nb_rx; i++) {
        rte_pktmbuf_free(rx_pkts_[i]);
    }
    
    return true;
}

} // namespace gateway

