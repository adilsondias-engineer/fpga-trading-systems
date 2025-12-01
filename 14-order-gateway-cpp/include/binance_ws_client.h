#pragma once

#include "binance_parser.h"
#include "bbo_data.h"
#include <boost/beast/core.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/beast/websocket/ssl.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/stream.hpp>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>
#include <functional>
#include <chrono>

namespace gateway {
    class PerfMonitor;  // Forward declaration
}

namespace gateway
{

    /**
     * Binance WebSocket Client
     * Connects to Binance WebSocket streams and receives BBO updates
     *
     * Features:
     *   - SSL/TLS encrypted connection
     *   - Automatic reconnection on disconnect
     *   - Ping/pong keepalive (every 20 seconds)
     *   - Thread-safe BBO data queue
     *   - Combined stream support (multiple symbols)
     */
    class BinanceWSClient
    {
    public:
        /**
         * Callback function type for BBO updates
         * Called when new BBO data is received
         */
        using BBOCallback = std::function<void(const BBOData&)>;

        /**
         * Constructor
         * @param symbols List of symbols to subscribe (e.g., {"BTCUSDT", "ETHUSDT"})
         * @param stream_type Stream type (default: "bookTicker")
         */
        explicit BinanceWSClient(const std::vector<std::string>& symbols,
                                const std::string& stream_type = "bookTicker");

        /**
         * Destructor - stops connection and cleans up
         */
        ~BinanceWSClient();

        /**
         * Start WebSocket connection and begin receiving messages
         * @param callback Function called for each BBO update
         */
        void start(BBOCallback callback);

        /**
         * Stop WebSocket connection
         */
        void stop();

        /**
         * Check if client is running
         * @return true if connected and running
         */
        bool isRunning() const;

        /**
         * Get connection status string
         * @return Status description
         */
        std::string getStatus() const;

        /**
         * Set performance monitor for latency measurement
         * @param monitor Pointer to PerfMonitor instance
         */
        void setPerfMonitor(gateway::PerfMonitor* monitor) { perf_monitor_ = monitor; }

    private:
        // WebSocket connection components
        boost::asio::io_context ioc_;
        boost::asio::ssl::context ctx_;
        using ws_stream_type = boost::beast::websocket::stream<
            boost::beast::ssl_stream<boost::beast::tcp_stream>>;
        std::unique_ptr<ws_stream_type> ws_;
        boost::asio::ip::tcp::resolver resolver_;

        // Configuration
        std::vector<std::string> symbols_;
        std::string stream_type_;
        std::string host_;
        std::string port_;

        // Threading
        std::thread worker_thread_;
        std::atomic<bool> running_;
        std::atomic<bool> should_stop_;

        // Callback
        BBOCallback bbo_callback_;

        // Reconnection state
        std::atomic<int> reconnect_attempts_;
        std::chrono::steady_clock::time_point last_reconnect_time_;
        static constexpr int MAX_RECONNECT_ATTEMPTS = 10;
        static constexpr int RECONNECT_DELAY_MS = 1000;

        // Ping/pong keepalive
        std::chrono::steady_clock::time_point last_ping_time_;
        static constexpr int PING_INTERVAL_SEC = 20;

        // Async operation state
        boost::beast::flat_buffer read_buffer_;
        boost::asio::steady_timer ping_timer_;
        boost::asio::steady_timer read_timer_;

        // Performance monitoring
        gateway::PerfMonitor* perf_monitor_ = nullptr;

        /**
         * Worker thread function
         */
        void workerThreadFunc();
        
        /**
         * Start async read operation
         */
        void doRead();
        
        /**
         * Handle async read completion
         */
        void onRead(boost::beast::error_code ec, std::size_t bytes_transferred);
        
        /**
         * Schedule next ping
         */
        void schedulePing();

        /**
         * Connect to Binance WebSocket endpoint
         * @return true if connection successful
         */
        bool connect();

        /**
         * Subscribe to streams
         * @return true if subscription successful
         */
        bool subscribe();

        /**
         * Send ping frame for keepalive
         */
        void sendPing();

        /**
         * Handle reconnection with exponential backoff
         */
        void handleReconnect();

        /**
         * Build combined stream URL
         * @return Stream URL path
         */
        std::string buildStreamUrl() const;
    };

} // namespace gateway

