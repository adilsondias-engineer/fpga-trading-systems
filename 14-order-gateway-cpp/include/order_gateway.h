#pragma once

#include "udp_listener.h"
#include "bbo_parser.h"
#ifdef USE_XDP
#include "xdp_listener.h"
#endif
#include "binance_ws_client.h"
#include "tcp_server.h"
#include "csv_logger.h"
#include "mqtt.h"
#include "kafka_producer.h"
#include "common/perf_monitor.h"
#include "disruptor/BboRingBuffer.h"
#include "disruptor/SharedMemoryManager.h"

#include <string>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>
#include <memory>
#include <chrono>
#include <unordered_map>

namespace gateway
{

    /**
     * Order Gateway
     * Multi-protocol publisher for FPGA BBO data
     *
     * Architecture:
     * - UDP Thread: Continuously reads from FPGA UDP
     * - Publish Thread: Fan-out to TCP/MQTT/Kafka
     * - Thread-safe Queue: Decouples UDP reading from publishing
     */
    class OrderGateway
    {
    public:
        /**
         * Configuration structure
         */
        struct Config
        {
            std::string udp_ip;
            int udp_port = 5000;
            int tcp_port = 9999;
            std::string csv_file;
            
            // XDP configuration
            bool use_xdp = false;
            std::string xdp_interface = "eno2";
            int xdp_queue_id = 0;
            bool enable_xdp_debug = false;


            // MQTT configuration
            std::string mqtt_broker_url;
            std::string mqtt_client_id;
            std::string mqtt_username;
            std::string mqtt_password;
            std::string mqtt_topic;

            // Kafka configuration
            std::string kafka_broker_url;
            std::string kafka_client_id;
            std::string kafka_topic;
            bool disable_kafka = false;
            bool disable_mqtt = false;
            bool disable_tcp = false;
            bool disable_logger = false;

            // Real-time optimization
            bool enable_rt = false;

            // Quiet mode (suppress console BBO output)
            bool quiet_mode = false;

            // Benchmark mode (single-threaded, no queue, parse-only)
            bool benchmark_mode = false;

            // Disruptor mode (shared memory ring buffer for Project 15)
            bool enable_disruptor = false;

            // FPGA feed configuration
            bool enable_fpga = true;  // Enable FPGA UDP/XDP feed (default: true)

            // Binance WebSocket configuration
            bool enable_binance = false;
            std::vector<std::string> binance_symbols;  // e.g., {"BTCUSDT", "ETHUSDT"}
            std::string binance_stream_type = "bookTicker";  // Stream type
        };

        /**
         * Constructor
         * @param config Configuration parameters
         */
        explicit OrderGateway(const Config &config);

        /**
         * Destructor - stops threads and cleans up
         */
        ~OrderGateway();

        /**
         * Start the gateway (starts threads)
         */
        void start();

        /**
         * Stop the gateway (graceful shutdown)
         */
        void stop();

        /**
         * Check if gateway is running
         */
        bool isRunning() const;

        /**
         * Wait for gateway to stop
         */
        void wait();

    private:
        // Configuration
        Config config_;

        // Components
        std::unique_ptr<UDPListener> udp_listener_;
#ifdef USE_XDP
        std::unique_ptr<XDPListener> xdp_listener_;
#endif
        std::unique_ptr<BinanceWSClient> binance_client_;
        std::unique_ptr<TCPServer> tcp_server_;
        std::unique_ptr<MQTT> mqtt_;
        std::unique_ptr<KafkaProducer> kafka_;
        std::unique_ptr<CSVLogger> csv_logger_;

        // Disruptor shared memory ring buffer
        disruptor::BboRingBuffer* ring_buffer_;

        // Thread-safe queue for BBO updates
        std::queue<BBOData> bbo_queue_;
        std::mutex queue_mutex_;
        std::condition_variable queue_cv_;
        static constexpr size_t MAX_QUEUE_SIZE = 10000; // 10k messages

        // Threading
        std::thread udp_thread_;
        std::thread binance_thread_;
        std::thread publish_thread_;
        std::atomic<bool> running_;
        std::atomic<bool> stopped_;

        // Last printed BBO per symbol to suppress duplicate console spam
        std::unordered_map<std::string, BBOData> last_printed_bbo_by_symbol_;

        // Thread functions
        void udpThreadFunc();
        void binanceThreadFunc();
        void publishThreadFunc();

        // Binance callback
        void onBinanceBBO(const BBOData& bbo);

        // Helper functions
        void publishBBO(const BBOData &bbo);
        void logBBO(const BBOData &bbo);

        // Performance monitoring
        gateway::PerfMonitor parse_latency_;  // For FPGA (UDP/XDP) feed
        gateway::PerfMonitor binance_parse_latency_;  // For Binance WebSocket feed
    };

} // namespace gateway
