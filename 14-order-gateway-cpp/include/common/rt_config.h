#ifndef RT_CONFIG_H
#define RT_CONFIG_H

#include <pthread.h>
#include <sched.h>
#include <iostream>
#include <cstring>
#include <cerrno>

namespace gateway {

/**
 * @brief Real-time thread configuration utilities
 *
 * Provides SCHED_FIFO scheduling and CPU core pinning for low-latency threads.
 * Requires CAP_SYS_NICE capability: sudo setcap cap_sys_nice=eip ./order_gateway
 */
class RTConfig {
public:
    /**
     * @brief Set SCHED_FIFO real-time scheduling policy
     *
     * @param thread Native thread handle
     * @param priority Priority level (1-99, higher = more priority)
     * @return true on success, false on failure
     */
    static bool setRealtimeScheduling(pthread_t thread, int priority) {
        struct sched_param param;
        param.sched_priority = priority;

        int result = pthread_setschedparam(thread, SCHED_FIFO, &param);
        if (result != 0) {
            std::cerr << "[RT] Failed to set SCHED_FIFO priority " << priority
                      << ": " << std::strerror(result) << std::endl;
            std::cerr << "[RT] Ensure CAP_SYS_NICE capability: sudo setcap cap_sys_nice=eip ./order_gateway"
                      << std::endl;
            return false;
        }

        std::cout << "[RT] Set SCHED_FIFO priority " << priority << " for thread" << std::endl;
        return true;
    }

    /**
     * @brief Pin thread to specific CPU core
     *
     * @param thread Native thread handle
     * @param cpu_id CPU core ID (0-N)
     * @return true on success, false on failure
     */
    static bool setCPUAffinity(pthread_t thread, int cpu_id) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        CPU_SET(cpu_id, &cpuset);

        int result = pthread_setaffinity_np(thread, sizeof(cpu_set_t), &cpuset);
        if (result != 0) {
            std::cerr << "[RT] Failed to set CPU affinity to core " << cpu_id
                      << ": " << std::strerror(result) << std::endl;
            return false;
        }

        std::cout << "[RT] Pinned thread to CPU core " << cpu_id << std::endl;
        return true;
    }

    /**
     * @brief Apply full RT optimization (SCHED_FIFO + CPU pinning)
     *
     * @param thread Native thread handle
     * @param priority SCHED_FIFO priority (1-99)
     * @param cpu_id CPU core to pin to
     * @return true if both operations succeeded, false otherwise
     */
    static bool applyRTOptimization(pthread_t thread, int priority, int cpu_id) {
        bool sched_ok = setRealtimeScheduling(thread, priority);
        bool affinity_ok = setCPUAffinity(thread, cpu_id);
        return sched_ok && affinity_ok;
    }

    /**
     * @brief Verify RT capabilities are available
     *
     * @return true if RT scheduling is available
     */
    static bool verifyRTCapabilities() {
        int min_priority = sched_get_priority_min(SCHED_FIFO);
        int max_priority = sched_get_priority_max(SCHED_FIFO);

        if (min_priority == -1 || max_priority == -1) {
            std::cerr << "[RT] SCHED_FIFO not available on this system" << std::endl;
            return false;
        }

        std::cout << "[RT] SCHED_FIFO priority range: " << min_priority
                  << "-" << max_priority << std::endl;
        return true;
    }
};

/**
 * @brief Thread configuration for OrderGateway
 *
 * Defines priority levels and CPU core assignments for different threads
 */
struct ThreadConfig {
    // Priority levels (SCHED_FIFO range: 1-99, higher = more priority)
    static constexpr int BINANCE_LISTENER_PRIORITY = 80; // Highest - critical path
    static constexpr int UDP_XDP_LISTENER_PRIORITY = 80;    // Highest - critical path
    static constexpr int TCP_SERVER_PRIORITY = 70;      // High - TCP distribution
    static constexpr int MQTT_PUBLISHER_PRIORITY = 60;  // Medium - MQTT distribution
    static constexpr int KAFKA_PRODUCER_PRIORITY = 50;  // Medium - Kafka distribution
    

    // CPU core assignments (isolated cores: 2-6)
    static constexpr int UDP_XDP_LISTENER_CPU = 2;          // Core 2 - UDP/XDP receive + parse
    static constexpr int TCP_SERVER_CPU = 3;            // Core 3 - TCP distribution
    static constexpr int MQTT_PUBLISHER_CPU = 4;        // Core 4 - MQTT distribution
    static constexpr int KAFKA_PRODUCER_CPU = 5;        // Core 5 - Kafka distribution
    static constexpr int BINANCE_LISTENER_CPU = 6;      // Core 6 - Binance WebSocket
};

} // namespace gateway

#endif // RT_CONFIG_H
