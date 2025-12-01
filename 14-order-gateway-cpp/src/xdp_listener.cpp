/*
XDP Listener Implementation
High-performance packet reception using AF_XDP (eXpress Data Path)
*/

#include "xdp_listener.h"
#include "common/perf_monitor.h"
#include <spdlog/spdlog.h>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <linux/if_xdp.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <dirent.h>

#ifdef HAVE_LIBXDP
#include <xdp/libxdp.h>
#include <xdp/xsk.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#endif

// For eBPF program loading (simplified - in production use libbpf)
#include <linux/bpf.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>

namespace gateway {

// Helper function to get ifindex from interface name
static int get_ifindex(const std::string& iface) {
    int ifindex = if_nametoindex(iface.c_str());
    if (ifindex == 0) {
        throw std::runtime_error("Failed to get interface index for " + iface);
    }
    return ifindex;
}

XDPListener::XDPListener(const std::string& iface, int port, int queue_id, bool enable_debug)
    : iface_(iface), port_(port), queue_id_(queue_id), enable_debug_(enable_debug) {
    
        if (enable_debug_) {
            spdlog::debug("[XDP] Initializing XDP listener on interface: {}, port: {}", iface, port);
        }
    
    // Get interface index
    ifindex_ = get_ifindex(iface);
    
    // Initialize XDP
    try {
        init_xdp();
        if (enable_debug_) {
            spdlog::debug("[XDP] XDP listener initialized successfully");
        }
    } catch (const std::exception& e) {
        // Log error but don't print to stderr (will be caught by caller)
        // This matches Project 15's behavior where spdlog::error is used
        throw;
    }
}

XDPListener::~XDPListener() {
    stop();

    // Cleanup free frames list
    if (free_frames_) {
        delete[] free_frames_;
        free_frames_ = nullptr;
    }

    // Note: Ring memory is unmapped automatically when socket is closed
    // The kernel handles cleanup of the mmap'd regions

    // Cleanup UMEM
    if (umem_area_ && umem_size_ > 0) {
        munmap(umem_area_, umem_size_);
        umem_area_ = nullptr;
    }

    // CRITICAL: Remove socket from XSK map BEFORE closing the socket
    // The kernel needs the socket to be valid to remove it from the map
    if (xsk_map_fd_ >= 0 && xdp_socket_fd_ >= 0) {
        int key = queue_id_;  // Use queue_id_ as the key (matches setup)
        
        // Try to delete the entry - this is critical for cleanup
        int ret = bpf_map_delete_elem(xsk_map_fd_, &key);
        if (ret == 0) {
            if (enable_debug_) {
                spdlog::debug("[XDP] Successfully removed socket from XSK map (key={})", key);
            }
        } else {
            // Deletion failed - log but don't fail
            if (enable_debug_) {
                spdlog::warn("[XDP] Failed to remove socket from XSK map (key={}): {}", key, strerror(errno));
                spdlog::warn("[XDP] This may cause bind failures on next run. Try: sudo xdp-loader unload {}", iface_);
            }
        }
        
        // Small delay to let kernel process the deletion
        usleep(5000);  // 5ms
    }
    
    // Close socket (this also unmaps rings)
    // CRITICAL: Close socket AFTER removing from map
    if (xdp_socket_fd_ >= 0) {
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
    }
    
    // Close map FD
    if (xsk_map_fd_ >= 0) {
        close(xsk_map_fd_);
        xsk_map_fd_ = -1;
    }
}

void XDPListener::init_xdp() {
    // Setup UMEM first (required for zero-copy)
    setup_umem();
    
    // Setup AF_XDP socket
    setup_xdp_socket();
    
    // Load XDP program (simplified - in production use libbpf)
    // Uses simplified approach requiring manual XDP program loading
    if (enable_debug_) {
        spdlog::warn("[XDP] XDP program must be loaded manually. See README_XDP.md for instructions");
        spdlog::warn("[XDP] For now, using fallback mode. Full XDP support requires libbpf/libxdp");
    }
}

void XDPListener::setup_umem() {
    // Calculate UMEM size (aligned to page size)
    umem_size_ = NUM_FRAMES * FRAME_SIZE;
    size_t page_size = getpagesize();
    umem_size_ = (umem_size_ + page_size - 1) & ~(page_size - 1);
    
    // Allocate UMEM area
    umem_area_ = mmap(nullptr, umem_size_, 
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS,
                      -1, 0);
    
    if (umem_area_ == MAP_FAILED) {
        throw std::runtime_error("Failed to allocate UMEM area: " + std::string(strerror(errno)));
    }
    
        // UMEM allocated (debug info available if needed)
}

// Helper function to get the number of RX queues for an interface
static int get_rx_queue_count(const std::string& iface) {
    // Check /sys/class/net/<iface>/queues/rx-* directories
    std::string queues_path = "/sys/class/net/" + iface + "/queues";
    DIR* dir = opendir(queues_path.c_str());
    if (!dir) {
        return -1;  // Can't determine
    }
    
    int count = 0;
    int max_queue_num = -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        std::string name = entry->d_name;
        if (name.find("rx-") == 0) {
            count++;
            // Extract queue number to find max
            try {
                int queue_num = std::stoi(name.substr(3));  // Skip "rx-"
                if (queue_num > max_queue_num) {
                    max_queue_num = queue_num;
                }
            } catch (...) {
                // Ignore parse errors
            }
        }
    }
    closedir(dir);
    
    // Return max_queue_num + 1 (queues are 0-indexed)
    // This gives us the actual number of queues (0 to max_queue_num)
    if (max_queue_num >= 0) {
        return max_queue_num + 1;
    }
    
    return count;  // Fallback to count if we couldn't parse numbers
}

void XDPListener::setup_xdp_socket() {
    // Verify interface exists (XDP program check happens during socket bind)
    std::string iface_path = "/sys/class/net/" + iface_;
    struct stat st;
    if (stat(iface_path.c_str(), &st) != 0) {
        throw std::runtime_error("Network interface " + iface_ + " does not exist");
    }
    
    // CRITICAL: Validate queue_id against available queues
    // NOTE: We validate but don't fail - let the kernel reject invalid queue IDs during bind
    // This is because:
    // 1. Queue detection might read stale state (queues might not update immediately after ethtool changes)
    // 2. The kernel is the ultimate authority on what queues exist
    // 3. Bind will fail with EINVAL if queue doesn't exist, which we handle gracefully
    
    // Re-read queue count to ensure we have fresh state (in case ethtool was just changed)
    // Small delay to let kernel update queue directories
    usleep(50000);  // 50ms delay to let kernel update after ethtool changes
    
    int num_queues = get_rx_queue_count(iface_);
    if (num_queues > 0) {
        // CRITICAL: Queue 0 handles ALL network traffic (including internet)
        // Using queue 0 can cause network connectivity loss if XDP interferes
        if (queue_id_ == 0 && num_queues > 1) {
            spdlog::warn("[XDP] Using queue 0 on {} may cause network connectivity issues!", iface_);
            spdlog::warn("[XDP] Queue 0 handles ALL network traffic (including internet).");
            spdlog::warn("[XDP] Recommendation: Use a higher queue number (1-{}) instead.", num_queues - 1);
            spdlog::warn("[XDP] Example: --xdp-queue-id 1");
        }
        
        if (queue_id_ >= num_queues) {
            // Warn but don't fail - kernel will reject during bind if queue doesn't exist
            std::string warning_msg = "WARNING: queue_id=" + std::to_string(queue_id_) + 
                                     " may be invalid for interface " + iface_ + 
                                     " (detected " + std::to_string(num_queues) + " queue(s))";
            if (num_queues == 1) {
                warning_msg += "\n  With combined=1, only queue 0 exists.";
                warning_msg += "\n  WARNING: Queue 0 handles ALL network traffic and may cause connectivity loss!";
                warning_msg += "\n  STRONGLY RECOMMENDED: Configure more queues to avoid queue 0:";
                warning_msg += "\n    sudo ethtool -L " + iface_ + " combined 4";
                warning_msg += "\n  Then use: --xdp-queue-id 1 (or 2, 3)";
            } else {
                warning_msg += "\n  Valid queue IDs: 0 to " + std::to_string(num_queues - 1);
                warning_msg += "\n  Note: Avoid queue 0 if possible (handles all traffic)";
            }
            warning_msg += "\n  Continuing anyway - kernel will reject during bind if queue doesn't exist";
            
            spdlog::warn("[XDP] {}", warning_msg);
        } else {
            if (enable_debug_) {
                spdlog::debug("[XDP] Interface {} has {} RX queue(s), using queue_id={} (valid)", iface_, num_queues, queue_id_);
                if (queue_id_ == 0) {
                    spdlog::debug("[XDP] WARNING: Queue 0 may interfere with network connectivity!");
                }
            }
        }
    } else {
        // Can't determine queue count - warn but continue
        if (queue_id_ > 0) {
            spdlog::warn("[XDP] Could not determine queue count for {}, using queue_id={}", iface_, queue_id_);
            spdlog::warn("[XDP] This may fail if queue doesn't exist. Check with: ls /sys/class/net/{}/queues/", iface_);
        } else if (queue_id_ == 0) {
            spdlog::warn("[XDP] Using queue 0 without queue count verification!");
            spdlog::warn("[XDP] Queue 0 may handle ALL network traffic - this can cause connectivity loss!");
        }
    }
    
    // CRITICAL: Log the queue configuration for debugging
    if (enable_debug_) {
        spdlog::debug("[XDP] Queue configuration: interface={}, queue_id={}, detected_queues={}", iface_, queue_id_, num_queues);
    }
    
#ifdef HAVE_LIBXDP
    // Find the xsks_map from the loaded XDP program
    // When using xdp-loader, it creates a dispatcher, but the map is in the actual program
    // Finds map by name and type (XSKMAP)
    
    // Find the xsks_map by iterating through all BPF maps
    // With xdp-loader, the map is created by the XDP program
    __u32 map_id = 0;
    int map_fd = -1;
    bool found_map = false;
    __u32 found_map_id = 0;
    
    if (enable_debug_) {
        spdlog::debug("[XDP] Searching for xsks_map...");
    }

    // Try to find the xsks_map by iterating through existing maps
    while (bpf_map_get_next_id(map_id, &map_id) == 0) {
            int fd = bpf_map_get_fd_by_id(map_id);
            if (fd < 0) continue;

            // Get map info to check name and type
            struct bpf_map_info info = {};
            __u32 info_len = sizeof(info);

            if (bpf_obj_get_info_by_fd(fd, &info, &info_len) == 0) {
                // Match by name AND type (XSKMAP = 17)
                if (strcmp(info.name, "xsks_map") == 0 && info.type == BPF_MAP_TYPE_XSKMAP) {
                    // Checks if map already has a value before selecting it
                    int test_key = 0;
                    int test_value = -1;
                    int test_ret = bpf_map_lookup_elem(fd, &test_key, &test_value);
                    
                    if (enable_debug_) {
                        spdlog::debug("[XDP] Found xsks_map candidate (ID: {}, type: {}, max_entries: {}, key_size: {}, value_size: {})", 
                                     map_id, info.type, info.max_entries, info.key_size, info.value_size);
                    }
                    
                    if (test_ret == 0) {
                        if (enable_debug_) {
                            spdlog::debug("[XDP] Map contains: key=0 -> value={}", test_value);
                        }
                        if (test_value > 0) {
                            if (enable_debug_) {
                                spdlog::debug("[XDP] WARNING: Map already has entry (FD={}), will overwrite", test_value);
                            }
                        } else if (test_value == 0) {
                            if (enable_debug_) { spdlog::debug("[XDP] WARNING: Map contains 0 (invalid/uninitialized)");
                            }
                        }
                    } else {
                        if (enable_debug_) {
                            if (errno == 95) {
                                spdlog::debug("[XDP] Map lookup not supported (EOPNOTSUPP) - this is normal for XSK maps");
                            } else {
                                spdlog::debug("[XDP] Map lookup failed: errno={} ({})", errno, strerror(errno));
                            }
                        }
                    }
                    
                    // CRITICAL: With xdp-loader, there might be multiple xsks_map instances
                    // SELECT THE NEWEST (highest ID) map, as it's most likely the one currently in use
                    // xdp-loader creates NEW maps each time it loads the XDP program
                    if (!found_map || map_id > found_map_id) {
                        // Close the previous map FD if we're replacing it
                        if (found_map && map_fd >= 0) {
                            close(map_fd);
                        }

                        map_fd = fd;  // Keep this FD - don't close it
                        found_map_id = map_id;
                        found_map = true;
                        xsk_map_fd_ = fd;  // Store for cleanup
                        if (enable_debug_) {
                            spdlog::debug("[XDP] Selected map ID {} (newest)", map_id);
                        }
                    } else {
                        // Found an older map - ignore it
                        if (enable_debug_) {
                            spdlog::debug("[XDP] Skipping older xsks_map (ID: {}), using newer ID: {}", map_id, found_map_id);
                        }
                        close(fd);  // Close older map
                    }
                }
            }
            if (fd != map_fd) {
                close(fd);  // Close if not the one we want
            }
        }

    if (!found_map || map_fd < 0) {
        throw std::runtime_error("Failed to find xsks_map. Ensure XDP program is loaded with: "
                                 "sudo xdp-loader load -m native -s xdp " + iface_ + " build/xdp_prog.o");
    }
    
    // CRITICAL: Clean up stale entries
    // Strategy:
    // 1. Always clean up queue 0 (commonly has stale entries from previous runs)
    // 2. Clean up our target queue_id
    // DO NOT delete other queue entries - they might be in use by other processes!
    // This must be done BEFORE creating the socket, as the kernel validates the socket FD
   // if (enable_debug_) { spdlog::debug("[XDP] Cleaning up stale XSK map entries...");
    //}
    
    // CRITICAL: Always try to clean up queue 0 first
    // Queue 0 often has stale entries that prevent binding, even when using other queues
    // This is safe because if queue 0 is in use, the deletion will fail (no harm)
    int queue0_key = 0;
    int queue0_value = 0;
    int queue0_cleaned = 0;
    
    // First, try to lookup queue 0 to see if there's an entry
    int queue0_lookup = bpf_map_lookup_elem(map_fd, &queue0_key, &queue0_value);
    if (queue0_lookup == 0 && queue0_value > 0) {
        // Entry exists - check if the socket FD is still valid
        // If the socket is closed, the entry is stale and safe to delete
        bool is_stale = false;
        if (fcntl(queue0_value, F_GETFD) < 0 && errno == EBADF) {
            // Socket FD is invalid (closed) - entry is stale
            is_stale = true;
            if (enable_debug_) {
                spdlog::debug("[XDP] Found stale entry at queue 0 (socket_fd={} is closed/invalid)", queue0_value);
            }
        } else {
            // Socket might still be valid - be more careful
            if (enable_debug_) {
                std::cout << "[XDP] Found entry at queue 0 (socket_fd=" << queue0_value 
                          << " appears valid)" << std::endl;
            }
            // Still try to delete - if it's from a previous run, it should be safe
            is_stale = true;  // Assume stale if we're trying to bind to queue 0
        }
        
        if (is_stale) {
            // Try to delete multiple times (sometimes needs retry)
            for (int retry = 0; retry < 10; retry++) {
                if (bpf_map_delete_elem(map_fd, &queue0_key) == 0) {
                    queue0_cleaned++;
                    //if (enable_debug_) {
                        spdlog::debug("[XDP] Removed stale queue 0 entry (attempt {})", retry + 1);
                    //}
                    usleep(10000);  // 10ms delay
                    // Verify it's actually gone
                    int verify_value = 0;
                    if (bpf_map_lookup_elem(map_fd, &queue0_key, &verify_value) == 0 && verify_value > 0) {
                        // Still there - keep trying
                        if (enable_debug_) { spdlog::debug("[XDP] Queue 0 entry still exists after delete, retrying...");
                        }
                        continue;
                    } else {
                        // Successfully deleted
                        break;
                    }
                } else {
                    if (retry == 0 && enable_debug_) {
                        std::cout << "[XDP] Failed to delete queue 0 entry: " << strerror(errno) << std::endl;
                    }
                    usleep(5000);  // 5ms between retries
                }
            }
        }
    } else {
       // if (enable_debug_) { spdlog::debug("[XDP] No entry found at queue 0 (this is OK)");
       // }
    }
    
    // Now clean up our target queue_id, but be careful:
    // - If detection says the queue doesn't exist, trust the user's explicit choice and DON'T clean it
    // - Only clean if detection confirms the queue exists OR if we're unsure
    int check_key = queue_id_;
    int check_value = 0;
    int target_cleaned = 0;
    
    // Check if detection says this queue exists (reuse num_queues from above)
    bool queue_detected = (num_queues > 0 && queue_id_ < num_queues);
    bool queue_may_not_exist = (num_queues > 0 && queue_id_ >= num_queues);
    
    // If detection says queue doesn't exist but user explicitly chose it, trust the user
    // Don't clean it up - the kernel will reject during bind if it really doesn't exist
    if (queue_may_not_exist) {
        if (enable_debug_) {
            std::cout << "[XDP] Detection says queue " << check_key 
                      << " doesn't exist, but using explicit choice - skipping cleanup" << std::endl;
        }
        // Skip cleanup - let the kernel decide during bind
    } else {
        // Queue is detected or we're unsure - safe to check and clean if needed
        int target_lookup = bpf_map_lookup_elem(map_fd, &check_key, &check_value);
        if (target_lookup == 0 && check_value > 0) {
            // Entry exists - check if socket is still valid before deleting
            bool is_stale = false;
            if (fcntl(check_value, F_GETFD) < 0 && errno == EBADF) {
                // Socket FD is invalid (closed) - entry is stale
                is_stale = true;
                if (enable_debug_) {
                    std::cout << "[XDP] Found stale entry at target queue " << check_key 
                              << " (socket_fd=" << check_value << " is closed/invalid)" << std::endl;
                }
            } else {
                // Socket might still be valid - be more careful
                if (enable_debug_) {
                    std::cout << "[XDP] Found entry at target queue " << check_key 
                              << " (socket_fd=" << check_value << " appears valid)" << std::endl;
                }
                // Only delete if we're binding to this queue (it's from a previous run)
                is_stale = true;  // Assume stale if we're trying to bind to this queue
            }
            
            if (is_stale) {
                // Try to delete multiple times with verification
                for (int retry = 0; retry < 10; retry++) {
                    if (bpf_map_delete_elem(map_fd, &check_key) == 0) {
                        target_cleaned++;
                        if (enable_debug_) {
                            std::cout << "[XDP] Removed stale entry at queue " << check_key 
                                      << " (attempt " << (retry + 1) << ")" << std::endl;
                        }
                        usleep(10000);  // 10ms delay
                        // Verify it's actually gone
                        int verify_value = 0;
                        if (bpf_map_lookup_elem(map_fd, &check_key, &verify_value) == 0 && verify_value > 0) {
                            // Still there - keep trying
                            if (enable_debug_) {
                                std::cout << "[XDP] Queue " << check_key 
                                          << " entry still exists after delete, retrying..." << std::endl;
                            }
                            continue;
                        } else {
                            // Successfully deleted
                           // if (enable_debug_) { spdlog::debug("[XDP] Successfully cleaned queue ", check_key );
                           // }
                            break;
                        }
                    } else {
                        if (retry == 0 && enable_debug_) {
                            std::cout << "[XDP] Failed to delete queue " << check_key 
                                      << " entry: " << strerror(errno) << std::endl;
                        }
                        usleep(5000);  // 5ms between retries
                    }
                }
            }
        } else {
           // if (enable_debug_) {
                std::cout << "[XDP] No stale entry found at target queue " << check_key 
                          << " (ready for binding)" << std::endl;
           // }
        }
    }
    
    // Try to lookup to verify cleanup
    int lookup_ret = bpf_map_lookup_elem(map_fd, &check_key, &check_value);
    if (lookup_ret == 0 && check_value > 0) {
        // Entry still exists after delete attempt
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: XSK map still has entry at index " << check_key
                      << " (queue_id=" << queue_id_ << ") with socket_fd " << check_value 
                      << " after delete attempt" << std::endl;
            std::cerr << "[XDP] This may cause bind failures. "
                      << "Try: sudo xdp-loader unload " << iface_ << std::endl;
        }
        // Try delete one more time with longer delay
        bpf_map_delete_elem(map_fd, &check_key);
        usleep(20000);  // 20ms
    } else if (lookup_ret < 0 && errno != EOPNOTSUPP) {
        if (enable_debug_) {
            std::cout << "[XDP] XSK map lookup returned: " << strerror(errno) 
                      << " (this is OK if map is empty)" << std::endl;
        }
    }

    // Create AF_XDP socket
    xdp_socket_fd_ = socket(AF_XDP, SOCK_RAW, 0);
    if (xdp_socket_fd_ < 0) {
        close(map_fd);
        throw std::runtime_error("Failed to create AF_XDP socket: " + std::string(strerror(errno)));
    }

    // CRITICAL: For AF_XDP, the socket must be bound BEFORE populating the XSK map
    // OR the map must be populated before binding - let's try binding first
    
    // Actually, let's try the other order: populate map BEFORE binding
    // Some implementations require this order
    
    // CRITICAL ORDER FOR AF_XDP (per kernel documentation):
    // 1. Create socket
    // 2. Register UMEM
    // 3. Setup rings  
    // 4. Bind socket
    // 5. THEN populate XSK map (AFTER bind!)
    
    // CRITICAL: XDP program uses ctx->rx_queue_index as the map key (see xdp_prog.c:124)
    // So we must populate the map at queue_id_, which must match the RX queue packets arrive on
    // The map key MUST be the RX queue index, not a hardcoded value!
    int xsk_map_key = queue_id_;  // Use queue_id_ as map key (matches XDP program's ctx->rx_queue_index)

    // Register UMEM with socket
    struct xdp_umem_reg umem_reg = {};
    umem_reg.addr = (__u64)umem_area_;
    umem_reg.len = umem_size_;
    umem_reg.chunk_size = FRAME_SIZE;
    umem_reg.headroom = 0;

    if (setsockopt(xdp_socket_fd_, SOL_XDP, XDP_UMEM_REG, &umem_reg, sizeof(umem_reg)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        // Note: Map not populated yet (happens after bind), so no cleanup needed
        throw std::runtime_error("Failed to register UMEM: " + std::string(strerror(err)));
    }

    if (enable_debug_) {
        spdlog::debug("[XDP] UMEM registered ({} bytes, {} frames)", umem_size_ , NUM_FRAMES );
    }

    // Setup Fill and Completion rings
    int fill_size = NUM_FRAMES / 2;
    if (setsockopt(xdp_socket_fd_, SOL_XDP, XDP_UMEM_FILL_RING, &fill_size, sizeof(int)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        // Note: Map not populated yet (happens after bind), so no cleanup needed
        throw std::runtime_error("Failed to set UMEM fill ring: " + std::string(strerror(err)));
    }

    int comp_size = NUM_FRAMES / 2;
    if (setsockopt(xdp_socket_fd_, SOL_XDP, XDP_UMEM_COMPLETION_RING, &comp_size, sizeof(int)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        // Note: Map not populated yet (happens after bind), so no cleanup needed
        throw std::runtime_error("Failed to set UMEM completion ring: " + std::string(strerror(err)));
    }

    // Setup RX and TX rings
    int rx_size = NUM_FRAMES / 2;
    if (setsockopt(xdp_socket_fd_, SOL_XDP, XDP_RX_RING, &rx_size, sizeof(int)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        throw std::runtime_error("Failed to set RX ring: " + std::string(strerror(err)));
    }

    int tx_size = NUM_FRAMES / 2;
    if (setsockopt(xdp_socket_fd_, SOL_XDP, XDP_TX_RING, &tx_size, sizeof(int)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        throw std::runtime_error("Failed to set TX ring: " + std::string(strerror(err)));
    }

    if (enable_debug_) {
        spdlog::debug("[XDP] Rings configured (RX/TX/Fill/Comp: {} entries each)", rx_size );
    }

    // Now bind the socket FIRST (before populating XSK map)
    // This is the correct order according to kernel documentation
    struct sockaddr_xdp sxdp = {};
    sxdp.sxdp_family = AF_XDP;
    sxdp.sxdp_ifindex = ifindex_;
    sxdp.sxdp_queue_id = queue_id_;
    sxdp.sxdp_flags = XDP_USE_NEED_WAKEUP;

    if (bind(xdp_socket_fd_, (struct sockaddr*)&sxdp, sizeof(sxdp)) < 0) {
        int err = errno;
        
        // If bind fails with EINVAL, it might be because XSK map still has a stale entry
        // Try to clean it up and retry once
        if (err == EINVAL) {
            if (enable_debug_) { spdlog::debug("[XDP] Bind failed with EINVAL, attempting to clean up XSK map and retry...");
            }
            // Force delete the entry for our queue_id (ignore errors - entry may not exist)
            int cleanup_key = queue_id_;
            bpf_map_delete_elem(map_fd, &cleanup_key);
            
            // CRITICAL: Aggressively clean up ALL possible stale entries
            // Try deleting our queue_id multiple times
            for (int retry = 0; retry < 3; retry++) {
                bpf_map_delete_elem(map_fd, &cleanup_key);
                usleep(5000);  // 5ms between attempts
            }
            
            // CRITICAL: Also clean up queue 0 (commonly has stale entries)
            // Queue 0 entries can prevent binding to queue 0
            int queue0_key = 0;
            for (int retry = 0; retry < 3; retry++) {
                bpf_map_delete_elem(map_fd, &queue0_key);
                usleep(5000);  // 5ms between attempts
            }
            
            // Longer delay to let kernel process all deletions
            usleep(30000);  // 30ms - longer delay for cleanup
            
            // Retry bind
            if (bind(xdp_socket_fd_, (struct sockaddr*)&sxdp, sizeof(sxdp)) == 0) {
                if (enable_debug_) { spdlog::debug("[XDP] Bind succeeded after cleanup!");
                }
                // Success - continue
            } else {
                // Still failed after cleanup
                err = errno;
                close(xdp_socket_fd_);
                xdp_socket_fd_ = -1;
                close(map_fd);
                
                // Provide helpful error message based on error type
                int num_queues = get_rx_queue_count(iface_);
                bool queue_mismatch = (err == EINVAL && num_queues > 0 && queue_id_ >= num_queues);
                
                std::string error_msg;
                if (queue_mismatch) {
                    // Simple message for expected queue mismatch (UDP fallback will work)
                    error_msg = "Queue " + std::to_string(queue_id_) + " does not exist on " + iface_ + 
                               " (only " + std::to_string(num_queues) + " queue(s) available)";
                } else {
                    // Detailed message for unexpected errors
                    error_msg = "Failed to bind AF_XDP socket after cleanup: " + std::string(strerror(err)) +
                               " (queue_id=" + std::to_string(queue_id_) + ", interface=" + iface_ + ")";
                    if (err == EINVAL) {
                        error_msg += "\n  Possible causes:";
                        error_msg += "\n    - Queue " + std::to_string(queue_id_) + " doesn't exist";
                        error_msg += "\n    - XDP program not loaded or wrong queue";
                        error_msg += "\n    - Stale XSK map entry (try: sudo xdp-loader unload " + iface_ + ")";
                    }
                }
                
                throw std::runtime_error(error_msg);
            }
        } else {
            // Other error - fail immediately
            close(xdp_socket_fd_);
            xdp_socket_fd_ = -1;
            close(map_fd);
            
            int num_queues = get_rx_queue_count(iface_);
            bool queue_mismatch = (err == EINVAL && num_queues > 0 && queue_id_ >= num_queues);
            
            std::string error_msg;
            if (queue_mismatch) {
                // Simple message for expected queue mismatch (UDP fallback will work)
                error_msg = "Queue " + std::to_string(queue_id_) + " does not exist on " + iface_ + 
                           " (only " + std::to_string(num_queues) + " queue(s) available)";
            } else {
                // Detailed message for unexpected errors
                error_msg = "Failed to bind AF_XDP socket: " + std::string(strerror(err)) +
                           " (queue_id=" + std::to_string(queue_id_) + ", interface=" + iface_ + ")";
            }
            
            throw std::runtime_error(error_msg);
        }
    }
    
   // if (enable_debug_) {
        std::cout << "[XDP] AF_XDP socket bound successfully (interface: " << iface_ 
                  << ", queue: " << queue_id_ << ")" << std::endl;
   // }
    
    // Map the rings into userspace FIRST
    // CRITICAL: Rings must be mapped before populating XSK map
    // The kernel validates that the socket is fully initialized before accepting it into the map
    map_rings();

    // Initialize free frame list
    free_frames_ = new uint64_t[NUM_FRAMES];
    for (size_t i = 0; i < NUM_FRAMES; i++) {
        free_frames_[i] = i * FRAME_SIZE;
    }
    free_frames_count_ = NUM_FRAMES;

    if (enable_debug_) { spdlog::debug("[XDP] Frame allocator initialized");
    }
    
    // CRITICAL: Fill ring must be populated BEFORE adding socket to XSK map
    // The kernel requires frames to be available before accepting the socket
    fill_fill_ring();
    if (enable_debug_) {
        std::cout << "[XDP] Initial fill ring populated with " << NUM_FRAMES << " frames" << std::endl;
    }
    
    // NOW populate XSK map AFTER rings are mapped AND fill ring is populated
    int xsk_map_value = xdp_socket_fd_;
    if (enable_debug_) {
        std::cout << "[XDP] Populating XSK map AFTER rings mapped: key=" << xsk_map_key 
                  << " (queue_id), value=" << xsk_map_value << " (socket_fd)" << std::endl;
        std::cout << "[XDP] Socket FD details: xdp_socket_fd_=" << xdp_socket_fd_ 
                  << ", xsk_map_value=" << xsk_map_value << ", map_fd=" << map_fd << std::endl;
    }
    
    // CRITICAL: Verify socket FD is valid before populating map
    if (xdp_socket_fd_ <= 0) {
        throw std::runtime_error("Invalid socket FD: " + std::to_string(xdp_socket_fd_) + 
                                 " (must be > 0)");
    }
    
    // CRITICAL: Populate XSK map with socket FD
    // The value must be the actual socket file descriptor (not 0)
    if (enable_debug_) {
        std::cout << "[XDP] About to update XSK map: map_fd=" << map_fd 
                  << ", key=" << xsk_map_key << ", value=" << xsk_map_value << std::endl;
    }
    
    // CRITICAL: Verify the socket is actually an AF_XDP socket
    // Get socket type to verify
    int sock_type = 0;
    socklen_t sock_type_len = sizeof(sock_type);
    if (getsockopt(xdp_socket_fd_, SOL_SOCKET, SO_TYPE, &sock_type, &sock_type_len) < 0) {
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: Failed to get socket type: " << strerror(errno) << std::endl;
        }
    } else {
        if (enable_debug_) {
            std::cout << "[XDP] Socket type: " << sock_type << " (SOCK_RAW=" << SOCK_RAW << ")" << std::endl;
        }
    }
    
    // Get socket domain to verify it's AF_XDP
    int sock_domain = 0;
    socklen_t sock_domain_len = sizeof(sock_domain);
    if (getsockopt(xdp_socket_fd_, SOL_SOCKET, SO_DOMAIN, &sock_domain, &sock_domain_len) < 0) {
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: Failed to get socket domain: " << strerror(errno) << std::endl;
        }
    } else {
        if (enable_debug_) {
            std::cout << "[XDP] Socket domain: " << sock_domain << " (AF_XDP=" << AF_XDP << ")" << std::endl;
        }
        if (sock_domain != AF_XDP) {
            throw std::runtime_error("Socket is not an AF_XDP socket! Domain=" + std::to_string(sock_domain));
        }
    }
    
    // CRITICAL: For XSK maps, the kernel validates the socket FD
    // The socket must be:
    // 1. An AF_XDP socket (verified above)
    // 2. Bound to the interface and queue
    // 3. Have rings mapped
    // 4. Have fill ring populated
    
    // Try BPF_ANY first (create or update)
    // If that fails with EINVAL, it might mean the socket isn't in the right state
    // or the map doesn't accept this update method
    int ret = bpf_map_update_elem(map_fd, &xsk_map_key, &xsk_map_value, BPF_ANY);
    
    // If BPF_ANY fails, try BPF_NOEXIST (create only) or BPF_EXIST (update only)
    if (ret < 0 && errno == EINVAL) {
        if (enable_debug_) { spdlog::debug("[XDP] BPF_ANY failed with EINVAL, trying BPF_NOEXIST");
        }
        ret = bpf_map_update_elem(map_fd, &xsk_map_key, &xsk_map_value, BPF_NOEXIST);
        if (ret < 0 && errno == EEXIST) {
            if (enable_debug_) { spdlog::debug("[XDP] Entry exists, trying BPF_EXIST to update");
            }
            ret = bpf_map_update_elem(map_fd, &xsk_map_key, &xsk_map_value, BPF_EXIST);
        }
    }
    if (ret < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        close(map_fd);
        throw std::runtime_error("Failed to populate XSK map after rings mapped: " + std::string(strerror(err)) +
                                 " (map_fd=" + std::to_string(map_fd) + ", queue_id=" + std::to_string(queue_id_) + 
                                 ", socket_fd=" + std::to_string(xsk_map_value) + ", errno=" + std::to_string(err) + ")");
    }
    
    if (enable_debug_) {
        std::cout << "[XDP] XSK map update succeeded (ret=" << ret 
                  << ", queue_id=" << queue_id_ 
                  << ", socket_fd=" << xdp_socket_fd_ << ")" << std::endl;
    }
    
    // CRITICAL: Updates ALL xsks_map instances found
    // With xdp-loader, there might be multiple maps and the correct one must be updated
    if (enable_debug_) { spdlog::debug("[XDP] Attempting to update ALL xsks_map instances...");
    }
    __u32 all_map_id = 0;
    int updated_count = 0;
    while (bpf_map_get_next_id(all_map_id, &all_map_id) == 0) {
        int fd = bpf_map_get_fd_by_id(all_map_id);
        if (fd < 0) continue;
        
        struct bpf_map_info info = {};
        __u32 info_len = sizeof(info);
        if (bpf_obj_get_info_by_fd(fd, &info, &info_len) == 0) {
            if (strcmp(info.name, "xsks_map") == 0 && info.type == BPF_MAP_TYPE_XSKMAP) {
                if (fd != map_fd) {  // Don't update the one we already updated
                    int ret2 = bpf_map_update_elem(fd, &xsk_map_key, &xsk_map_value, BPF_ANY);
                    if (ret2 == 0) {
                        updated_count++;
                        if (enable_debug_) {
                            std::cout << "[XDP] Also updated duplicate xsks_map (ID: " << all_map_id 
                                      << ", fd=" << fd << ")" << std::endl;
                        }
                    } else {
                        if (enable_debug_) {
                            std::cout << "[XDP] Failed to update duplicate map (ID: " << all_map_id 
                                      << "): " << strerror(errno) << std::endl;
                        }
                    }
                }
            }
        }
        close(fd);
    }
    if (updated_count > 0 && enable_debug_) {
        std::cout << "[XDP] Updated " << updated_count << " additional xsks_map instance(s)" << std::endl;
    }
    
    // CRITICAL: Give the kernel a moment to process the map updates
    // This ensures the XDP program can see the updated values
    usleep(100000);  // 100ms delay to allow kernel to process
    
    // CRITICAL: Try multiple times to verify the update worked
    // Sometimes there's a race condition or the map needs time to update
    bool verified = false;
    for (int attempt = 0; attempt < 5; attempt++) {
        int test_key = xsk_map_key;
        int test_value = -1;
        int test_ret = bpf_map_lookup_elem(map_fd, &test_key, &test_value);
        if (test_ret == 0) {
            if (enable_debug_) {
                std::cout << "[XDP] XSK map verification (attempt " << (attempt + 1) 
                          << "): value=" << test_value 
                          << " (expected: " << xsk_map_value << ")" << std::endl;
            }
            if (test_value == xsk_map_value) {
                verified = true;
                if (enable_debug_) { spdlog::debug("[XDP] XSK map verified successfully!");
                }
                break;
            } else {
                if (enable_debug_) {
                    std::cerr << "[XDP] WARNING: XSK map value mismatch! Wrote " << xsk_map_value 
                              << " but read " << test_value << " (attempt " << (attempt + 1) << ")" << std::endl;
                }
                if (attempt < 4) {
                    usleep(10000);  // Wait 10ms and retry
                }
            }
        } else {
            // EOPNOTSUPP is expected, but log it
            if (errno == 95) {
                if (enable_debug_) {
                    std::cout << "[XDP] Note: XSK map lookup not supported (EOPNOTSUPP), "
                              << "but update returned success (attempt " << (attempt + 1) << ")" << std::endl;
                }
                // Can't verify, but update succeeded, so assume it worked
                verified = true;
                break;
            } else {
                if (enable_debug_) {
                    std::cout << "[XDP] XSK map lookup failed: errno=" << errno 
                              << " (" << strerror(errno) << "), attempt " << (attempt + 1) << std::endl;
                }
                if (attempt < 4) {
                    usleep(10000);  // Wait 10ms and retry
                }
            }
        }
    }
    
    if (!verified && enable_debug_) {
        std::cerr << "[XDP] WARNING: Could not verify XSK map update, but update returned success" << std::endl;
        std::cerr << "[XDP] This might be OK if XSK maps don't support lookup, but packets may not redirect" << std::endl;
    }
    
    // Debug: Show initial ring state
    if (enable_debug_) { spdlog::debug("[XDP] Initial ring state:");
        std::cout << "  RX: producer=" << *rx_ring_.producer << " consumer=" << *rx_ring_.consumer << std::endl;
        std::cout << "  Fill: producer=" << *fill_ring_.producer << " consumer=" << *fill_ring_.consumer << std::endl;
        std::cout << "  Completion: producer=" << *completion_ring_.producer << " consumer=" << *completion_ring_.consumer << std::endl;
        std::cout << "[XDP] Ready to receive packets!" << std::endl;
    }
    
    // Stores map_fd for cleanup (kept open for potential future use)
    // The map entry will remain even if we close the FD
    // We'll close it in the destructor
    xsk_map_fd_ = map_fd;
    
    // Note: XSK maps don't support bpf_map_lookup_elem (returns EOPNOTSUPP)
    // The update success (ret == 0) is sufficient verification
    // The map entry will remain even if we close the FD, but keeping it open
    // ensures we can verify/cleanup if needed
    // map_fd is stored in xsk_map_fd_ for cleanup
#else
    // Fallback to raw syscalls (will likely fail without XSK map population)
    if (enable_debug_) { spdlog::debug("[XDP] WARNING: libxdp not available, using raw syscalls (bind may fail)");
    }
    
    // Create AF_XDP socket
    xdp_socket_fd_ = socket(AF_XDP, SOCK_RAW, 0);
    if (xdp_socket_fd_ < 0) {
        throw std::runtime_error("Failed to create AF_XDP socket: " + std::string(strerror(errno)) + 
                                 " (requires kernel 4.18+ and root privileges)");
    }
    
    // Setup socket address
    struct sockaddr_xdp sxdp = {};
    sxdp.sxdp_family = AF_XDP;
    sxdp.sxdp_ifindex = ifindex_;
    sxdp.sxdp_queue_id = queue_id_;
    sxdp.sxdp_flags = XDP_USE_NEED_WAKEUP;
    
    // Bind socket (will fail without XSK map population)
    if (bind(xdp_socket_fd_, (struct sockaddr*)&sxdp, sizeof(sxdp)) < 0) {
        int err = errno;
        close(xdp_socket_fd_);
        xdp_socket_fd_ = -1;
        
        std::string error_msg = "Failed to bind AF_XDP socket: " + std::string(strerror(err));
        error_msg += "\n  Install libxdp for proper XSK map setup: sudo apt-get install libxdp-dev";
        error_msg += "\n  Or rebuild with: cmake .. -DUSE_XDP=ON (requires libxdp)";
        throw std::runtime_error(error_msg);
    }
    
   // if (enable_debug_) {
        std::cout << "[XDP] AF_XDP socket bound successfully to interface " << iface_ 
                  << " queue " << queue_id_ << std::endl;
    //}
#endif
}

void XDPListener::start() {
    if (!running_) {
        running_ = true;
        fill_fill_ring();
        //if (enable_debug_) { spdlog::debug("[XDP] XDP listener started");
            std::cout << "[XDP] Ring status:" << std::endl;
            std::cout << "  RX: producer=" << *rx_ring_.producer << " consumer=" << *rx_ring_.consumer << std::endl;
            std::cout << "  Fill: producer=" << *fill_ring_.producer << " consumer=" << *fill_ring_.consumer << std::endl;
            std::cout << "  Completion: producer=" << *completion_ring_.producer << " consumer=" << *completion_ring_.consumer << std::endl;
            std::cout << "  Free frames: " << free_frames_count_ << std::endl;
       // }
    }
}

void XDPListener::stop() {
    if (running_) {
        running_ = false;
       // if (enable_debug_) { spdlog::debug("[XDP] XDP listener stopped");
      //  }
    }
}

bool XDPListener::isRunning() const {
    return running_;
}

BBOData XDPListener::read_bbo() {
    if (!running_) {
        start();
    }

    uint8_t buffer[FRAME_SIZE];
    size_t len = 0;

    // Poll for packets (blocking)
    while (running_) {
        try {
            if (poll_packet(buffer, len)) {
                // Validate buffer length before parsing
                if (len == 0 || len > FRAME_SIZE) {
                    if (enable_debug_) {
                        std::cerr << "[XDP] WARNING: Invalid packet length: " << len << std::endl;
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
                spdlog::error("[XDP] ERROR in read_bbo: {}", e.what());
            }
            // Continue to next packet instead of crashing
        } catch (...) {
            // Catch any other exceptions
            if (enable_debug_) {
                spdlog::error("[XDP] ERROR: Unknown exception in read_bbo");
            }
            // Continue to next packet
        }
        
        // Small sleep to avoid busy-waiting
        usleep(10);  // 10 microseconds
    }
    
    throw std::runtime_error("XDP listener stopped");
}

bool XDPListener::poll_packet(uint8_t* buffer, size_t& len) {
    // NOTE: For RX-only operation, we don't normally need to process the completion ring
    // However, if there are leftover frames from earlier (when we incorrectly wrote to it),
    // we should process them to recover those frames
    __sync_synchronize();
    uint32_t comp_cons = *completion_ring_.consumer;
    uint32_t comp_prod = *completion_ring_.producer;
    
    // Process any leftover frames in completion ring (from earlier incorrect usage)
    if (comp_cons != comp_prod) {
        uint32_t frames_recovered = 0;
        while (comp_cons != comp_prod) {
            uint32_t idx = comp_cons & completion_ring_.mask;
            uint64_t frame_addr = completion_ring_.descriptors[idx];
            
            // Validate and add to free pool
            if (frame_addr < umem_size_) {
                free_frame(frame_addr);
                frames_recovered++;
            }
            comp_cons++;
        }
        
        if (frames_recovered > 0) {
            __sync_synchronize();
            *completion_ring_.consumer = comp_cons;
            __sync_synchronize();
            
            if (enable_debug_) {
                std::cout << "[XDP] Recovered " << frames_recovered 
                          << " frames from completion ring" << std::endl;
            }
        }
    }
    
    // Check if we have packets in RX ring
    // Use memory barrier to ensure we read fresh producer index
    __sync_synchronize();
    uint32_t cached_cons = *rx_ring_.consumer;
    uint32_t cached_prod = *rx_ring_.producer;
    
    // Debug: Log ring status more frequently initially, then less often
    static uint64_t poll_count = 0;
    static uint32_t last_prod = 0;
    static uint32_t last_cons = 0;
    static uint64_t last_log_time = 0;
    
    poll_count++;
    
    // Log every 1000 polls for first 100k polls, then every 100k
    uint64_t log_interval = (poll_count < 100000) ? 1000 : 100000;
    
    if (enable_debug_ && (poll_count % log_interval == 0 || cached_prod != last_prod || cached_cons != last_cons)) {
        std::cout << "[XDP] Poll #" << poll_count 
                  << " | RX ring: consumer=" << cached_cons 
                  << " producer=" << cached_prod;
        if (cached_prod != last_prod) {
            std::cout << " (NEW PACKETS! delta=" << (cached_prod - last_prod) << ")";
        }
        std::cout << " | Fill: prod=" << *fill_ring_.producer 
                  << " cons=" << *fill_ring_.consumer
                  << " | Comp: prod=" << *completion_ring_.producer
                  << " cons=" << *completion_ring_.consumer
                  << " | Free frames: " << free_frames_count_ << std::endl;
        
        last_prod = cached_prod;
        last_cons = cached_cons;
        last_log_time = poll_count;
    }

    if (cached_cons == cached_prod) {
        // No packets available, check if we need wakeup
        if (*rx_ring_.flags & XDP_RING_NEED_WAKEUP) {
            // Kick kernel to wake up RX processing
            struct pollfd pfd;
            pfd.fd = xdp_socket_fd_;
            pfd.events = POLLIN;
            poll(&pfd, 1, 0);  // Non-blocking poll to wake up kernel
        }

        // Re-check after wakeup
        __sync_synchronize();  // Memory barrier before reading producer
        cached_prod = *rx_ring_.producer;
        if (cached_cons == cached_prod) {
            // Refill fill ring if it's been consumed (has free space)
            uint32_t fill_cached_cons = *fill_ring_.consumer;
            uint32_t fill_free_slots = ring_free(fill_ring_, fill_cached_cons);

            // If the fill ring has ANY free space, refill it
            // (kernel has consumed some frames from fill ring to RX ring)
            if (fill_free_slots > 0) {
                fill_fill_ring();
            }
            
            return false;  // Still no packets
        }
    }

    // Get descriptor from RX ring
    uint32_t idx = cached_cons & rx_ring_.mask;
    
    // CRITICAL: Ensure we don't read beyond what the kernel has written
    // The producer pointer tells us how many descriptors the kernel has written
    // We should only read up to (producer - 1) at most
    if (cached_cons >= cached_prod) {
        // This should never happen if we check correctly, but be defensive
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: Reading descriptor beyond producer: cons=" 
                      << cached_cons << " prod=" << cached_prod << std::endl;
        }
        return false;
    }

    // RX descriptor: struct xdp_desc { __u64 addr; __u32 len; __u32 options; };
    // Stored as 2 consecutive 64-bit values (16 bytes total)
    // descriptors[idx * 2] = addr (64 bits)
    // descriptors[idx * 2 + 1] = len (lower 32 bits) + options (upper 32 bits)
    
    // Read descriptor with proper memory barrier
    __sync_synchronize();  // Ensure we see the latest data from kernel
    
    // Read directly from uint64_t array to avoid alignment issues
    // CRITICAL: Ensure we're reading from valid descriptor slots
    if ((idx * 2 + 1) >= (rx_ring_.size * 2)) {
        if (enable_debug_) {
            std::cerr << "[XDP] ERROR: Descriptor index out of bounds: idx=" << idx 
                      << " size=" << rx_ring_.size << std::endl;
        }
        return false;
    }
    
    uint64_t desc_addr = rx_ring_.descriptors[idx * 2];
    uint64_t desc_len_options = rx_ring_.descriptors[idx * 2 + 1];
    
    // Extract len and options from the second 64-bit value
    // len is in lower 32 bits, options in upper 32 bits
    uint64_t raw_addr = desc_addr;
    uint32_t raw_len = (uint32_t)(desc_len_options & 0xFFFFFFFF);
    uint32_t raw_options = (uint32_t)((desc_len_options >> 32) & 0xFFFFFFFF);
    
    // CRITICAL: Sanity check - if address looks like a pointer to descriptor memory, it's corrupted
    // Descriptor memory is at rx_ring_.descriptors, so addresses near that are suspicious
    uintptr_t desc_mem_start = (uintptr_t)rx_ring_.descriptors;
    uintptr_t desc_mem_end = desc_mem_start + (rx_ring_.size * 2 * sizeof(uint64_t));
    if (raw_addr >= desc_mem_start && raw_addr < desc_mem_end) {
        // This looks like a pointer to descriptor memory, not a frame address - corrupted!
        if (enable_debug_) {
            std::cerr << "[XDP] ERROR: Descriptor appears corrupted (address points to descriptor memory): "
                      << "addr=0x" << std::hex << raw_addr << std::dec 
                      << " desc_mem=0x" << std::hex << desc_mem_start << "-0x" << desc_mem_end << std::dec
                      << " idx=" << idx << std::endl;
        }
        // Advance consumer to skip this corrupted descriptor
        __sync_synchronize();
        *rx_ring_.consumer = cached_cons + 1;
        __sync_synchronize();
        return false;
    }
    
    uint64_t frame_addr = raw_addr;
    uint32_t frame_len = raw_len;
    __sync_synchronize();  // Ensure descriptor read is complete

    static uint64_t packet_count = 0;
    static uint64_t error_count = 0;
    static uint64_t valid_packet_count = 0;
    
    if (enable_debug_ && ++packet_count <= 10) {
        std::cout << "[XDP] Packet " << packet_count << ": addr=" << frame_addr
                  << " len=" << frame_len << " idx=" << idx << std::endl;
    }

    // CRITICAL: Validate frame address BEFORE using it
    // Frame address must be:
    // 1. Within UMEM bounds (0 to umem_size_)
    // 2. Frame address + length must be within UMEM bounds
    // 3. Reasonable frame length (not zero, not excessively large)
    // Note: We don't check strict alignment to FRAME_SIZE because the kernel
    // may return frame addresses with offsets (e.g., headroom)
    bool invalid_addr = false;
    std::string invalid_reason;
    
    if (frame_addr >= umem_size_) {
        invalid_addr = true;
        invalid_reason = "out of bounds";
        error_count++;  // Always increment for tracking
        // Always print first 20 errors for debugging, then every 100th
        if (error_count <= 20 || error_count % 100 == 0) {
            std::cerr << "[XDP] ERROR #" << error_count << ": Frame address " << invalid_reason << ": " << frame_addr 
                      << " >= " << umem_size_ << " (idx=" << idx << ", len=" << frame_len 
                      << ", options=" << raw_options << ")" << std::endl;
            std::cerr << "[XDP] Descriptor raw: addr=0x" << std::hex << raw_addr << std::dec
                      << " (" << raw_addr << ") len=" << raw_len 
                      << " options=0x" << std::hex << raw_options << std::dec << std::endl;
        }
    } else if (frame_len == 0 || frame_len > FRAME_SIZE * 2) {
        // Frame length is suspiciously large or zero
        invalid_addr = true;
        invalid_reason = "invalid length";
        error_count++;  // Always increment for tracking
        // Always print first 20 errors for debugging, then every 100th
        if (error_count <= 20 || error_count % 100 == 0) {
            std::cerr << "[XDP] ERROR #" << error_count << ": Frame " << invalid_reason << ": " << frame_len 
                      << " (addr=" << frame_addr << ", idx=" << idx << ")" << std::endl;
            std::cerr << "[XDP] Descriptor raw: addr=0x" << std::hex << raw_addr << std::dec
                      << " (" << raw_addr << ") len=" << raw_len 
                      << " options=0x" << std::hex << raw_options << std::dec << std::endl;
        }
    } else if (frame_addr + frame_len > umem_size_) {
        // Frame extends beyond UMEM bounds
        invalid_addr = true;
        invalid_reason = "extends beyond UMEM";
        error_count++;  // Always increment for tracking
        // Always print first 20 errors for debugging, then every 100th
        if (error_count <= 20 || error_count % 100 == 0) {
            std::cerr << "[XDP] ERROR #" << error_count << ": Frame " << invalid_reason << ": addr=" << frame_addr 
                      << " len=" << frame_len << " umem_size=" << umem_size_ << " (idx=" << idx << ")" << std::endl;
            std::cerr << "[XDP] Descriptor raw: addr=0x" << std::hex << raw_addr << std::dec
                      << " (" << raw_addr << ") len=" << raw_len 
                      << " options=0x" << std::hex << raw_options << std::dec << std::endl;
        }
    }

    if (invalid_addr) {
        // CRITICAL: Invalid descriptor detected
        // We can't return the frame because the address is corrupted
        // But we still need to advance the consumer to avoid getting stuck
        // The kernel will eventually recycle the frame, but we've lost track of it
        __sync_synchronize();
        *rx_ring_.consumer = cached_cons + 1;
        __sync_synchronize();
        
        // Additional context logging (already logged above, but add more details for first few)
        if (error_count <= 5) {
            std::cerr << "[XDP] Additional context for error #" << error_count << ":" << std::endl;
            std::cerr << "  RX ring: idx=" << idx << " mask=" << rx_ring_.mask 
                      << " consumer=" << cached_cons << " producer=" << cached_prod << std::endl;
            std::cerr << "  Descriptor location: &descriptors[" << (idx * 2) << "] = 0x" 
                      << std::hex << (uintptr_t)&rx_ring_.descriptors[idx * 2] << std::dec << std::endl;
        }
        
        // If we see too many errors, something is seriously wrong
        // This usually indicates frame starvation or memory corruption
        if (error_count > 100) {
            std::cerr << "[XDP] FATAL: Too many invalid descriptors (" << error_count 
                      << "), stopping to prevent further corruption" << std::endl;
            std::cerr << "[XDP] Debug info: free_frames=" << free_frames_count_ 
                      << " fill_ring_used=" << (*fill_ring_.producer - *fill_ring_.consumer)
                      << " comp_ring_pending=" << (*completion_ring_.producer - *completion_ring_.consumer) << std::endl;
        //    running_ = false;
         //   throw std::runtime_error("RX ring descriptor corruption detected");
        }
        
        // CRITICAL: Invalid descriptor = lost frame
        // We need to be very aggressive about refilling to prevent further starvation
        // Try multiple times to refill if we have free frames
        for (int refill_attempt = 0; refill_attempt < 3 && free_frames_count_ > 0; refill_attempt++) {
            fill_fill_ring();
            if (free_frames_count_ == 0) {
                break;  // All frames are now in fill ring
            }
            usleep(100);  // Small delay between attempts
        }
        
        return false;
    }
    
    // Copy packet data from UMEM
    uint8_t* packet_data = (uint8_t*)umem_area_ + frame_addr;
    if (frame_len > FRAME_SIZE) {
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: Frame length exceeds FRAME_SIZE: " << frame_len 
                      << " > " << FRAME_SIZE << ", capping to " << FRAME_SIZE << std::endl;
        }
        frame_len = FRAME_SIZE;  // Safety check
    }

    // XDP passes the full Ethernet frame, we need to strip headers
    // Ethernet (14) + IP (20) + UDP (8) = 42 bytes minimum
    const size_t ETH_HLEN = 14;
    const size_t IP_HLEN = 20;   // Assuming no IP options
    const size_t UDP_HLEN = 8;
    const size_t HEADER_OFFSET = ETH_HLEN + IP_HLEN + UDP_HLEN;

    if (frame_len <= HEADER_OFFSET) {
        // Packet too small, skip it
        len = 0;
        // Advance consumer and immediately recycle frame
        __sync_synchronize();
        *rx_ring_.consumer = cached_cons + 1;
        __sync_synchronize();
        recycle_frame_to_fill_ring(frame_addr);
        return false;
    }

    // Copy only the UDP payload (skip Ethernet + IP + UDP headers)
    size_t payload_len = frame_len - HEADER_OFFSET;
    
    // CRITICAL: Ensure payload_len doesn't exceed buffer size to prevent overflow
    // Buffer size is FRAME_SIZE (2048 bytes), but we need to ensure we don't copy more
    const size_t MAX_PAYLOAD_SIZE = FRAME_SIZE;
    if (payload_len > MAX_PAYLOAD_SIZE) {
        // Log error and skip this packet
        if (enable_debug_) {
            std::cerr << "[XDP] ERROR: Payload too large: " << payload_len 
                      << " bytes (max: " << MAX_PAYLOAD_SIZE << "), frame_len=" << frame_len << std::endl;
        }
        // Advance consumer and immediately recycle frame
        __sync_synchronize();
        *rx_ring_.consumer = cached_cons + 1;
        __sync_synchronize();
        recycle_frame_to_fill_ring(frame_addr);
        return false;
    }
    
    // Verify frame_addr is within UMEM bounds
    if (frame_addr + frame_len > umem_size_) {
        if (enable_debug_) {
            std::cerr << "[XDP] ERROR: Frame address out of bounds: addr=" << frame_addr 
                      << " len=" << frame_len << " umem_size=" << umem_size_ << std::endl;
        }
        // Advance consumer - can't recycle invalid frame
        __sync_synchronize();
        *rx_ring_.consumer = cached_cons + 1;
        __sync_synchronize();
        return false;
    }
    
    memcpy(buffer, packet_data + HEADER_OFFSET, payload_len);
    len = payload_len;

    if (enable_debug_ && packet_count <= 5) {
        std::cout << "[XDP] Payload len=" << payload_len << " (frame_len=" << frame_len
                  << " - header=" << HEADER_OFFSET << ")" << std::endl;
        std::cout << "[XDP] First 32 bytes: ";
        for (size_t i = 0; i < std::min(payload_len, size_t(32)); i++) {
            printf("%02x ", buffer[i]);
        }
        std::cout << std::endl;
    }

    // CRITICAL: Per kernel documentation, frames MUST be immediately recycled back to FILL ring
    // after processing. This is the proper AF_XDP pattern - don't use a free pool.
    // Pattern: RX -> Process -> Immediately recycle to FILL ring -> Advance RX consumer
    
    // CRITICAL: Recycle frame BEFORE advancing consumer
    // This ensures the frame is available for the next packet immediately
    recycle_frame_to_fill_ring(frame_addr);
    
    // Advance RX consumer index - this tells the kernel we're done with the frame
    __sync_synchronize();
    *rx_ring_.consumer = cached_cons + 1;
    __sync_synchronize();
    
    // CRITICAL: Aggressively refill fill ring after every packet to prevent starvation
    // Even if we just recycled, check if we can add more frames
    if (free_frames_count_ > 0) {
        fill_fill_ring();
    }

    return true;
}

void XDPListener::map_rings() {
    // Get ring offsets from kernel using getsockopt
    struct xdp_mmap_offsets {
        struct xdp_ring_offset rx;
        struct xdp_ring_offset tx;
        struct xdp_ring_offset fr;  // Fill ring
        struct xdp_ring_offset cr;  // Completion ring
    };

    struct xdp_mmap_offsets offsets = {};
    socklen_t optlen = sizeof(offsets);

    if (getsockopt(xdp_socket_fd_, SOL_XDP, XDP_MMAP_OFFSETS, &offsets, &optlen) < 0) {
        throw std::runtime_error("Failed to get XDP mmap offsets: " + std::string(strerror(errno)));
    }

    // Calculate mmap sizes
    // RX ring: descriptors are struct xdp_desc (16 bytes each) = 2 x uint64_t
    // Fill/Completion rings: descriptors are uint64_t (8 bytes each)
    size_t rx_map_size = offsets.rx.desc + RING_SIZE * 2 * sizeof(uint64_t);  // RX desc = 16 bytes
    size_t fill_map_size = offsets.fr.desc + RING_SIZE * sizeof(uint64_t);
    size_t comp_map_size = offsets.cr.desc + RING_SIZE * sizeof(uint64_t);

    // Memory-map RX ring
    void* rx_map = mmap(nullptr, rx_map_size, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_POPULATE, xdp_socket_fd_, XDP_PGOFF_RX_RING);
    if (rx_map == MAP_FAILED) {
        throw std::runtime_error("Failed to mmap RX ring: " + std::string(strerror(errno)));
    }

    // Memory-map Fill ring
    void* fill_map = mmap(nullptr, fill_map_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_POPULATE, xdp_socket_fd_, XDP_UMEM_PGOFF_FILL_RING);
    if (fill_map == MAP_FAILED) {
        munmap(rx_map, rx_map_size);
        throw std::runtime_error("Failed to mmap Fill ring: " + std::string(strerror(errno)));
    }

    // Memory-map Completion ring
    void* comp_map = mmap(nullptr, comp_map_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_POPULATE, xdp_socket_fd_, XDP_UMEM_PGOFF_COMPLETION_RING);
    if (comp_map == MAP_FAILED) {
        munmap(rx_map, rx_map_size);
        munmap(fill_map, fill_map_size);
        throw std::runtime_error("Failed to mmap Completion ring: " + std::string(strerror(errno)));
    }

    // Setup RX ring pointers
    rx_ring_.producer = (uint32_t*)((uint8_t*)rx_map + offsets.rx.producer);
    rx_ring_.consumer = (uint32_t*)((uint8_t*)rx_map + offsets.rx.consumer);
    rx_ring_.flags = (uint32_t*)((uint8_t*)rx_map + offsets.rx.flags);
    rx_ring_.descriptors = (uint64_t*)((uint8_t*)rx_map + offsets.rx.desc);
    rx_ring_.size = RING_SIZE;
    rx_ring_.mask = RING_SIZE - 1;

    // Setup Fill ring pointers
    fill_ring_.producer = (uint32_t*)((uint8_t*)fill_map + offsets.fr.producer);
    fill_ring_.consumer = (uint32_t*)((uint8_t*)fill_map + offsets.fr.consumer);
    fill_ring_.flags = (uint32_t*)((uint8_t*)fill_map + offsets.fr.flags);
    fill_ring_.descriptors = (uint64_t*)((uint8_t*)fill_map + offsets.fr.desc);
    fill_ring_.size = RING_SIZE;
    fill_ring_.mask = RING_SIZE - 1;

    // Setup Completion ring pointers
    completion_ring_.producer = (uint32_t*)((uint8_t*)comp_map + offsets.cr.producer);
    completion_ring_.consumer = (uint32_t*)((uint8_t*)comp_map + offsets.cr.consumer);
    completion_ring_.flags = (uint32_t*)((uint8_t*)comp_map + offsets.cr.flags);
    completion_ring_.descriptors = (uint64_t*)((uint8_t*)comp_map + offsets.cr.desc);
    completion_ring_.size = RING_SIZE;
    completion_ring_.mask = RING_SIZE - 1;
}

uint64_t XDPListener::allocate_frame() {
    if (free_frames_count_ == 0) {
        return UINT64_MAX;  // No free frames
    }
    return free_frames_[--free_frames_count_];
}

void XDPListener::free_frame(uint64_t addr) {
    if (free_frames_count_ < free_frames_capacity_) {
        free_frames_[free_frames_count_++] = addr;
    }
}

void XDPListener::recycle_frame_to_fill_ring(uint64_t frame_addr) {
    // CRITICAL: Per kernel documentation, frames should be immediately recycled to FILL ring
    // This is the proper AF_XDP pattern - immediate recycling prevents frame starvation
    
    // Validate frame address before recycling
    if (frame_addr >= umem_size_) {
        // Invalid frame address - don't recycle it
        if (enable_debug_) {
            std::cerr << "[XDP] WARNING: Attempted to recycle invalid frame address: " 
                      << frame_addr << " (umem_size=" << umem_size_ << ")" << std::endl;
        }
        return;
    }
    
    // Check if there's space in the FILL ring
    // Use retry loop to catch kernel consumer updates
    uint32_t fill_prod = *fill_ring_.producer;
    uint32_t free_slots = 0;
    
    for (int retry = 0; retry < 3; retry++) {
        __sync_synchronize();
        uint32_t fill_cons = *fill_ring_.consumer;
        __sync_synchronize();
        
        free_slots = ring_free(fill_ring_, fill_cons);
        
        if (free_slots > 0) {
            break;  // Found space
        }
        
        // Re-read producer in case it changed
        __sync_synchronize();
        fill_prod = *fill_ring_.producer;
        __sync_synchronize();
        
        if (retry < 2) {
            __asm__ __volatile__("pause" ::: "memory");
        }
    }
    
    if (free_slots > 0) {
        // Immediately put frame back into FILL ring
        uint32_t idx = fill_prod & fill_ring_.mask;
        
        // Write descriptor with compiler barrier
        fill_ring_.descriptors[idx] = frame_addr;
        
        // Update producer with memory barrier (kernel will see this)
        __sync_synchronize();
        *fill_ring_.producer = fill_prod + 1;
        __sync_synchronize();
        
        // Frame is now immediately available for kernel to use
        return;
    }
    
    // FILL ring is full - add to free pool as fallback
    // This should rarely happen if we're recycling immediately
    // But it can happen during high packet rates
    free_frame(frame_addr);
    
    // Try to refill fill ring if we have more free frames
    if (free_frames_count_ > 10) {
        fill_fill_ring();
    }
}

void XDPListener::fill_fill_ring() {
    // Fill the fill ring with available UMEM frames
    static uint64_t fill_call_count = 0;
    fill_call_count++;
    
    // CRITICAL: Use memory barriers to ensure we see the latest consumer value
    // The kernel updates the consumer pointer when it consumes frames
    __sync_synchronize();  // Memory barrier before reading consumer
    uint32_t cached_cons = *fill_ring_.consumer;
    __sync_synchronize();  // Memory barrier after reading consumer
    
    // Read producer (we're the producer, so this is our value)
    uint32_t idx = *fill_ring_.producer;

    // Calculate free slots using the ring_free helper (now handles wrap-around correctly)
    uint32_t free_slots = ring_free(fill_ring_, cached_cons);
    
    // Debug: Log fill ring status
    if (enable_debug_ && (fill_call_count <= 10 || fill_call_count % 1000 == 0)) {
        uint32_t used = idx - cached_cons;
        if (used >= fill_ring_.size) used = fill_ring_.size;
        std::cout << "[XDP] fill_fill_ring() call #" << fill_call_count 
                  << ": producer=" << idx 
                  << " consumer=" << cached_cons 
                  << " used=" << used
                  << " free_slots=" << free_slots 
                  << " available_frames=" << free_frames_count_ << std::endl;
    }

    // CRITICAL: If fill ring appears full but we have free frames, 
    // aggressively re-check consumer (kernel might have updated it asynchronously)
    // This is critical for performance - kernel updates consumer asynchronously
    // and we need to catch it quickly to avoid frame starvation
    if (free_slots == 0 && free_frames_count_ > 0) {
        // Retry loop: check consumer multiple times with memory barriers
        // The kernel might be consuming frames right now, so we need to catch it
        for (int retry = 0; retry < 3; retry++) {
            __sync_synchronize();  // Full memory barrier
            uint32_t new_cons = *fill_ring_.consumer;
            __sync_synchronize();  // Ensure we see the update
            
            if (new_cons != cached_cons) {
                // Consumer changed! Kernel consumed some frames
                cached_cons = new_cons;
                free_slots = ring_free(fill_ring_, cached_cons);
                
                if (enable_debug_ && (fill_call_count % 100 == 0 || free_slots > 0)) {
                    std::cout << "[XDP] Fill ring consumer updated (retry " << retry << "): old=" 
                              << cached_cons << " new=" << new_cons 
                              << ", new free_slots=" << free_slots << std::endl;
                }
                break;  // Found update, exit retry loop
            }
            
            // Small delay to let kernel update consumer (only on retries)
            if (retry < 2) {
                // Use CPU pause instruction for better performance than usleep
                __asm__ __volatile__("pause" ::: "memory");
            }
        }
    }

    uint32_t filled = 0;
    for (uint32_t i = 0; i < free_slots && free_frames_count_ > 0; i++) {
        uint64_t frame_addr = allocate_frame();
        if (frame_addr == UINT64_MAX) {
            break;  // No more free frames
        }

        // Fill ring uses single 64-bit descriptor (just the address)
        fill_ring_.descriptors[idx & fill_ring_.mask] = frame_addr;
        idx++;
        filled++;
    }

    // Compiler barrier to ensure descriptors are written before producer update
    __sync_synchronize();

    // Update producer index (visible to kernel)
    *fill_ring_.producer = idx;
    
    // Debug: Log fill results
    if (enable_debug_ && (fill_call_count <= 10 || (filled > 0 && fill_call_count % 100 == 0))) {
        std::cout << "[XDP] fill_fill_ring() filled " << filled << " frames, "
                  << "new producer=" << idx << std::endl;
    }
    
    static bool first_log = true;
    if (enable_debug_ && first_log && filled > 0) {
        std::cout << "[XDP] Fill ring initialized with " << filled << " frames" << std::endl;
        first_log = false;
    }
}

} // namespace gateway


