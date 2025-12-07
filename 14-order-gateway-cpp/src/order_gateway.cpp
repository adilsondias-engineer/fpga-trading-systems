#include "order_gateway.h"
#include "common/rt_config.h"
#include <spdlog/spdlog.h>
#include <chrono>
#include <thread>
#include <iomanip>
#include <cmath>
#include <sstream>

namespace gateway
{

    OrderGateway::OrderGateway(const Config &config)
        : config_(config), running_(false), stopped_(true), ring_buffer_(nullptr)
    {
        // Initialize Disruptor shared memory if enabled
        if (config_.enable_disruptor) {
            try {
                ring_buffer_ = disruptor::SharedMemoryManager<
                    disruptor::BboRingBuffer>::create("gateway");
                spdlog::info("[Disruptor] Shared memory ring buffer created");
            } catch (const std::exception& e) {
                spdlog::error("[Disruptor] Failed to create ring buffer: {}", e.what());
                config_.enable_disruptor = false;
            }
        }

        // Initialize components
        try
        {
            // Create FPGA listener (DPDK, XDP, or UDP) if enabled
            if (config_.enable_fpga) {
#ifdef USE_DPDK
                if (config_.use_dpdk) {
                    try {
                        if (config_.enable_dpdk_debug) {
                            spdlog::debug("[DPDK] Creating DPDK listener on interface: {}", config_.dpdk_interface);
                        }
                        dpdk_listener_ = std::make_unique<DPDKListener>(config_.dpdk_interface, config_.udp_port, config_.dpdk_queue_id, config_.enable_dpdk_debug);
                        // Set perf monitor immediately after creation (before any auto-start in read_bbo)
                        dpdk_listener_->setPerfMonitor(&parse_latency_);
                        if (config_.enable_dpdk_debug) {
                            spdlog::debug("[DPDK] DPDK listener created (interface: {}, port: {})", config_.dpdk_interface, config_.udp_port);
                        }
                    } catch (const std::exception& e) {
                        spdlog::warn("[DPDK] Failed to create DPDK listener: {}, falling back to XDP/UDP", e.what());
                        config_.use_dpdk = false;
                    }
                }
#endif
#ifdef USE_XDP
                if (!config_.use_dpdk && config_.use_xdp) {
                    try {
                        if (config_.enable_xdp_debug) {
                            spdlog::debug("[XDP] Creating XDP listener on interface: {}", config_.xdp_interface);
                        }
                        xdp_listener_ = std::make_unique<XDPListener>(config_.xdp_interface, config_.udp_port, config_.xdp_queue_id, config_.enable_xdp_debug);
                        // Set perf monitor immediately after creation (before any auto-start in read_bbo)
                        xdp_listener_->setPerfMonitor(&parse_latency_);
                        if (config_.enable_xdp_debug) {
                            spdlog::debug("[XDP] XDP listener created (interface: {}, port: {})", config_.xdp_interface, config_.udp_port);
                        }
                    } catch (const std::exception& e) {
                        spdlog::warn("[XDP] Failed to create XDP listener: {}, falling back to UDP", e.what());
                        config_.use_xdp = false;
                    }
                }
#endif

                if (!config_.use_dpdk && !config_.use_xdp) {
                    udp_listener_ = std::make_unique<UDPListener>(config_.udp_ip, config_.udp_port);
                    // Set perf monitor for UDP listener
                    udp_listener_->setPerfMonitor(&parse_latency_);
                }
            }

            // Create Binance WebSocket client if enabled
            if (config_.enable_binance && !config_.binance_symbols.empty()) {
                binance_client_ = std::make_unique<BinanceWSClient>(
                    config_.binance_symbols,
                    config_.binance_stream_type);
                // Set perf monitor for Binance client
                binance_client_->setPerfMonitor(&binance_parse_latency_);
            }
            
            tcp_server_ = std::make_unique<TCPServer>(config_.tcp_port);

            // Initialize MQTT if broker URL is provided
            if (!config_.disable_mqtt && !config_.mqtt_broker_url.empty())
            {
                mqtt_ = std::make_unique<MQTT>(
                    config_.mqtt_broker_url,
                    config_.mqtt_client_id,
                    config_.mqtt_username,
                    config_.mqtt_password);
                mqtt_->connect();
            }

            // Initialize Kafka if broker URL is provided
            if (!config_.disable_kafka && !config_.kafka_broker_url.empty())
            {
                kafka_ = std::make_unique<KafkaProducer>(
                    config_.kafka_broker_url,
                    config_.kafka_client_id);
            }

            // Initialize CSV logger if file is provided
            if (!config_.disable_logger && !config_.csv_file.empty())
            {
                csv_logger_ = std::make_unique<CSVLogger>(config_.csv_file);
            }

            // Start TCP server
            if (!config_.disable_tcp)
            {
                tcp_server_->start();
            }
        }
        catch (const std::exception &e)
        {
            spdlog::error("Failed to initialize OrderGateway: {}", e.what());
            throw;
        }
    }

    OrderGateway::~OrderGateway()
    {
        stop();

        // Cleanup Disruptor shared memory
        if (ring_buffer_) {
            disruptor::SharedMemoryManager<disruptor::BboRingBuffer>::destroy("gateway", ring_buffer_);
            ring_buffer_ = nullptr;
        }
    }

    void OrderGateway::start()
    {
        if (running_)
        {
            return; // Already running
        }

        running_ = true;
        stopped_ = false;

        // Verify RT capabilities if enabled
        if (config_.enable_rt)
        {
            spdlog::info("[RT] Real-time optimizations enabled");
            if (!RTConfig::verifyRTCapabilities())
            {
                spdlog::warn("[RT] RT capabilities verification failed");
            }
        }

        // Start FPGA listener (DPDK/XDP/UDP) if enabled
        if (config_.enable_fpga) {
#ifdef USE_DPDK
            if (config_.use_dpdk && dpdk_listener_ && !dpdk_listener_->isRunning())
            {
                dpdk_listener_->start();
            }
            else
#endif
#ifdef USE_XDP
            if (!config_.use_dpdk && config_.use_xdp && xdp_listener_ && !xdp_listener_->isRunning())
            {
                xdp_listener_->start();
            }
            else
#endif
            if (!config_.use_dpdk && !config_.use_xdp && udp_listener_ && !udp_listener_->isRunning())
            {
                // Enable benchmark mode in UDPListener to skip queue operations
                if (config_.benchmark_mode)
                {
                    udp_listener_->setBenchmarkMode(true);
                }

                udp_listener_->start();
            }
        }

        // Start Binance WebSocket client if enabled
        if (config_.enable_binance && binance_client_)
        {
            binance_client_->start([this](const BBOData& bbo) {
                this->onBinanceBBO(bbo);
            });
        }

        // Benchmark mode: skip threads, process directly in UDP callback
        if (config_.benchmark_mode)
        {
            spdlog::info("[BENCHMARK] Single-threaded mode enabled (no queue overhead)");
            // No threads needed - processing happens in UDP callback
        }
        else
        {
            // Start FPGA thread if enabled
            if (config_.enable_fpga) {
                udp_thread_ = std::thread(&OrderGateway::udpThreadFunc, this);
            }

            // Start Binance thread if enabled
            if (config_.enable_binance && binance_client_) {
                binance_thread_ = std::thread(&OrderGateway::binanceThreadFunc, this);
            }

            // Start publishing thread
            publish_thread_ = std::thread(&OrderGateway::publishThreadFunc, this);
        }

        // Apply RT optimizations if enabled (only in normal mode, not benchmark)
        if (config_.enable_rt && !config_.benchmark_mode)
        {
            spdlog::info("[RT] Applying real-time optimizations...");

            // FPGA thread (DPDK/XDP/UDP): highest priority, pinned to core 2
            // This thread handles DPDK, XDP, and UDP listeners
            if (config_.enable_fpga && udp_thread_.joinable()) {
                std::string mode = "UDP";
#ifdef USE_DPDK
                if (config_.use_dpdk) mode = "DPDK";
#endif
#ifdef USE_XDP
                if (!config_.use_dpdk && config_.use_xdp) mode = "XDP";
#endif
                if (!RTConfig::applyRTOptimization(
                        udp_thread_.native_handle(),
                        ThreadConfig::UDP_XDP_LISTENER_PRIORITY,
                        ThreadConfig::UDP_XDP_LISTENER_CPU))
                {
                    spdlog::warn("[RT] Failed to optimize FPGA {} thread", mode);
                }
                else
                {
                    spdlog::info("[RT] FPGA {} thread optimized: priority {}, CPU core {}", 
                                mode, ThreadConfig::UDP_XDP_LISTENER_PRIORITY, ThreadConfig::UDP_XDP_LISTENER_CPU);
                }
            }

            // Binance thread: high priority, pinned to core 4
            if (config_.enable_binance && binance_thread_.joinable()) {
                if (!RTConfig::applyRTOptimization(
                        binance_thread_.native_handle(),
                        ThreadConfig::BINANCE_LISTENER_PRIORITY,
                        ThreadConfig::BINANCE_LISTENER_CPU))  // Core 6 for Binance
                {
                    spdlog::warn("[RT] Failed to optimize Binance thread");
                }
                else
                {
                    spdlog::info("[RT] Binance thread optimized: priority {}, CPU core {}", 
                                ThreadConfig::BINANCE_LISTENER_PRIORITY, ThreadConfig::BINANCE_LISTENER_CPU);
                }
            }

            // Publish thread: high priority, pinned to core 3
            if (!RTConfig::applyRTOptimization(
                    publish_thread_.native_handle(),
                    ThreadConfig::TCP_SERVER_PRIORITY,
                    ThreadConfig::TCP_SERVER_CPU))
            {
                spdlog::warn("[RT] Failed to optimize publish thread");
            }

            spdlog::info("[RT] Real-time optimizations applied");
        }

        spdlog::info("Order Gateway started");
        if (config_.enable_fpga) {
            std::string mode = "UDP mode";
#ifdef USE_XDP
            if (config_.use_xdp) {
                mode = "XDP mode";
            }
#endif
            spdlog::info("  FPGA Feed: {} @ {} port ({})", config_.udp_ip, config_.udp_port, mode);
        } else {
            spdlog::info("  FPGA Feed: Disabled");
        }
        if (config_.enable_binance && binance_client_) {
            std::ostringstream symbols_str;
            for (size_t i = 0; i < config_.binance_symbols.size(); ++i) {
                if (i > 0) symbols_str << ", ";
                symbols_str << config_.binance_symbols[i];
            }
            spdlog::info("  Binance Feed: {} symbols ({})", config_.binance_symbols.size(), symbols_str.str());
        } else {
            spdlog::info("  Binance Feed: Disabled");
        }
        spdlog::info("  TCP Port: {}", config_.tcp_port);
        if (mqtt_)
        {
            spdlog::info("  MQTT Broker: {}", config_.mqtt_broker_url);
            spdlog::info("  MQTT Topic: {}", config_.mqtt_topic);
        }
        if (kafka_)
        {
            spdlog::info("  Kafka Broker: {}", config_.kafka_broker_url);
            spdlog::info("  Kafka Topic: {}", config_.kafka_topic);
        }
        if (csv_logger_)
        {
            spdlog::info("  CSV Log: {}", config_.csv_file);
        }
    }

    void OrderGateway::stop()
    {
        if (!running_)
        {
            return; // Already stopped
        }

        // Print performance statistics BEFORE joining threads
        if (config_.enable_fpga && parse_latency_.count() > 0) {
            std::string mode = "UDP";
#ifdef USE_DPDK
            if (config_.use_dpdk) mode = "DPDK";
#endif
#ifdef USE_XDP
            if (!config_.use_dpdk && config_.use_xdp) mode = "XDP";
#endif
            parse_latency_.printSummary("Project 14 FPGA (" + mode + ")");
            parse_latency_.saveToFile("project14_fpga_latency.csv");
        }
        
        if (config_.enable_binance && binance_parse_latency_.count() > 0) {
            binance_parse_latency_.printSummary("Project 14 Binance (WebSocket)");
            binance_parse_latency_.saveToFile("project14_binance_latency.csv");
        }

        spdlog::info("Stopping Order Gateway...");
        
        // Set running_ to false FIRST to prevent new messages from being queued
        running_ = false;

        if (!config_.benchmark_mode)
        {
            // Notify threads to wake up
            queue_cv_.notify_all();
        }

        // Stop Binance client
        if (binance_client_)
        {
            binance_client_->stop();
            spdlog::info("Binance client stopped");
        }

        // Stop FPGA listeners
#ifdef USE_XDP
        if (xdp_listener_)
        {
            xdp_listener_->stop();
            spdlog::info("XDP listener stopped");
        }
#endif
        if (udp_listener_)
        {
            udp_listener_->stop();
            spdlog::info("UDP listener stopped");
        }

        if (!config_.benchmark_mode)
        {
            // Wait for threads to finish
            if (udp_thread_.joinable())
            {
                udp_thread_.join();
            }

            if (binance_thread_.joinable())
            {
                binance_thread_.join();
            }

            if (publish_thread_.joinable())
            {
                publish_thread_.join();
            }
        }

        // Cleanup connections
        if (mqtt_)
        {
            mqtt_->disconnect();
            spdlog::info("MQTT disconnected");
        }

        if (kafka_)
        {
            kafka_->flush();
            spdlog::info("Kafka flushed");
        }

        stopped_ = true;
        spdlog::info("Order Gateway stopped");
    }

    bool OrderGateway::isRunning() const
    {
        return running_;
    }

    void OrderGateway::wait()
    {
        if (config_.benchmark_mode)
        {
            // In benchmark mode, UDP listener runs in main thread via io_context
            // Just sleep and let Boost.Asio handle everything
            while (running_)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
        else
        {
            // Normal mode: wait for worker threads
            while (running_)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
    }

    void OrderGateway::udpThreadFunc()
    {
        std::string mode = "UDP";
#ifdef USE_DPDK
        if (config_.use_dpdk) mode = "DPDK";
#endif
#ifdef USE_XDP
        if (!config_.use_dpdk && config_.use_xdp) mode = "XDP";
#endif
        spdlog::info("FPGA {} thread started", mode);

        while (running_)
        {
            try
            {
                BBOData bbo;
                
#ifdef USE_DPDK
                // Use DPDK listener if enabled
                if (config_.use_dpdk && dpdk_listener_)
                {
                    bbo = dpdk_listener_->read_bbo();
                }
                else
#endif
#ifdef USE_XDP
                // Use XDP listener if enabled
                if (!config_.use_dpdk && config_.use_xdp && xdp_listener_)
                {
                    bbo = xdp_listener_->read_bbo();
                }
                else
#endif
                {
                    // Use UDP listener (fallback or default)
                    if (!udp_listener_)
                    {
                        break;
                    }
                    bbo = udp_listener_->read_bbo();
                }
                
                // Process BBO (same for both XDP and UDP)
                if (bbo.valid)
                {
                    if (config_.benchmark_mode)
                    {
                        // Benchmark mode: just parse, don't queue
                        // Processing already done in callback
                    }
                    else
                    {
                        // Normal mode: add to queue (only if still running)
                        if (running_)
                        {
                            std::unique_lock<std::mutex> lock(queue_mutex_);
                            
                            // Double-check after acquiring lock
                            if (!running_)
                            {
                                break; // Exit thread if shutting down
                            }
                            
                            if (bbo_queue_.size() >= MAX_QUEUE_SIZE)
                            {
                                bbo_queue_.pop(); // Drop oldest
                            }
                            bbo_queue_.push(bbo);
                            queue_cv_.notify_one();
                        }
                    }
                }
            }
            catch (const std::exception &e)
            {
                std::string mode = config_.use_xdp ? "XDP" : "UDP";
                spdlog::error("[ERROR] FPGA {} thread exception: {} (type: {})", mode, e.what(), typeid(e).name());

                // Check if listener is still running
#ifdef USE_XDP
                if (config_.use_xdp && xdp_listener_)
                {
                    if (!xdp_listener_->isRunning())
                    {
                        spdlog::error("[ERROR] XDP listener stopped, stopping gateway");
                        running_ = false;
                        break;
                    }
                }
                else
#endif
                if (udp_listener_ && !udp_listener_->isRunning())
                {
                    spdlog::error("[ERROR] UDP listener stopped, stopping gateway");
                    running_ = false;
                    break;
                }

                // Small delay before retrying to avoid tight exception loop
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            catch (...)
            {
                // Catch any other exceptions (not derived from std::exception)
                std::string mode = config_.use_xdp ? "XDP" : "UDP";
                spdlog::error("[ERROR] FPGA {} thread: Unknown exception caught (not std::exception)", mode);
                
                // Check if listener is still running
#ifdef USE_XDP
                if (config_.use_xdp && xdp_listener_)
                {
                    if (!xdp_listener_->isRunning())
                    {
                        spdlog::error("[ERROR] XDP listener stopped after unknown exception, stopping gateway");
                        running_ = false;
                        break;
                    }
                }
                else
#endif
                if (udp_listener_ && !udp_listener_->isRunning())
                {
                    spdlog::error("[ERROR] UDP listener stopped after unknown exception, stopping gateway");
                    running_ = false;
                    break;
                }

                // Small delay before retrying
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }

        std::string mode = config_.use_xdp ? "XDP" : "UDP";
        spdlog::info("FPGA {} thread stopped", mode);
    }

    void OrderGateway::binanceThreadFunc()
    {
        spdlog::info("Binance WebSocket thread started");

        // Binance client handles its own connection loop
        // This thread just waits for the client to stop
        while (running_ && binance_client_ && binance_client_->isRunning())
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        spdlog::info("Binance WebSocket thread stopped");
    }

    void OrderGateway::onBinanceBBO(const BBOData& bbo)
    {
        if (!bbo.valid)
        {
            return;
        }

        // Don't queue if gateway is shutting down
        if (!running_)
        {
            return;
        }

        if (config_.benchmark_mode)
        {
            // Benchmark mode: just parse, don't queue
            return;
        }

        // Add to queue (same as FPGA data)
        std::unique_lock<std::mutex> lock(queue_mutex_);
        
        // Check again after acquiring lock (double-check pattern)
        if (!running_)
        {
            return;
        }
        
        if (bbo_queue_.size() >= MAX_QUEUE_SIZE)
        {
            bbo_queue_.pop(); // Drop oldest
        }
        bbo_queue_.push(bbo);
        queue_cv_.notify_one();
    }

    void OrderGateway::publishThreadFunc()
    {
        spdlog::info("Publish thread started");

        while (running_ || !bbo_queue_.empty())
        {
            BBOData bbo;
            bool has_data = false;

            // Wait for data or timeout
            {
                std::unique_lock<std::mutex> lock(queue_mutex_);

                // Wait for data or shutdown
                queue_cv_.wait_for(lock, std::chrono::milliseconds(100), [this]
                                   { return !bbo_queue_.empty() || !running_; });

                if (!bbo_queue_.empty())
                {
                    bbo = bbo_queue_.front();
                    bbo_queue_.pop();
                    has_data = true;
                }
            }

            if (has_data)
            {
                // Publish to all protocols (only if still running)
                if (running_)
                {
                    publishBBO(bbo);

                    // Log to CSV if enabled
                    if (csv_logger_)
                    {
                        logBBO(bbo);
                    }
                }

                // Console output (only if not in quiet mode and still running)
                // Suppress output after shutdown to avoid confusing logs
                if (running_ && !config_.quiet_mode)
                {
                    // Suppress duplicate prints for the same symbol unless values changed
                    auto changed = [](const BBOData& prev, const BBOData& curr) {
                        auto diff = [](double a, double b) { return std::fabs(a - b) > 0.00005; };
                        return diff(prev.bid_price, curr.bid_price) ||
                               diff(prev.ask_price, curr.ask_price) ||
                               diff(prev.spread,    curr.spread)    ||
                               prev.bid_shares != curr.bid_shares   ||
                               prev.ask_shares != curr.ask_shares;
                    };
                    bool should_print = true;
                    auto it = last_printed_bbo_by_symbol_.find(bbo.symbol);
                    if (it != last_printed_bbo_by_symbol_.end() && !changed(it->second, bbo))
                    {
                        should_print = false;
                    }
                    last_printed_bbo_by_symbol_[bbo.symbol] = bbo;

                    if (should_print)
                    {
                        // Log BBO update (format prices to 4 decimals)
                        std::ostringstream oss;
                        oss << "[" << bbo.symbol << "] "
                            << "Bid: " << std::fixed << std::setprecision(4) << bbo.bid_price
                            << " (" << bbo.bid_shares << ") | ";
                        if (bbo.ask_price > 0.0 && bbo.ask_shares > 0)
                        {
                            oss << "Ask: " << std::fixed << std::setprecision(4) << bbo.ask_price
                                << " (" << bbo.ask_shares << ") | ";
                        }
                        else
                        {
                            oss << "Ask: - (-) | ";
                        }
                        oss << "Spread: " << std::fixed << std::setprecision(4) << bbo.spread;
                        spdlog::info(oss.str());
                    }
                }
            }
        }

        spdlog::info("Publish thread stopped");
    }

    void OrderGateway::publishBBO(const BBOData &bbo)
    {
        // Publish to Disruptor shared memory if enabled (non-blocking)
        if (config_.enable_disruptor && ring_buffer_) {
            if (!ring_buffer_->try_publish(bbo)) {
                // Buffer full - drop message to prevent blocking
                static uint64_t dropped_count = 0;
                if (++dropped_count % 1000 == 0) {
                    spdlog::warn("Dropped {} BBO messages due to full ring buffer", dropped_count);
                }
            }
        }

        // Early exit if all distribution is disabled
        bool needs_json = !config_.disable_tcp ||
                         (mqtt_ && mqtt_->isConnected()) ||
                         (kafka_ && kafka_->isConnected());

        if (!needs_json)
        {
            return;
        }

        // Convert to JSON only if needed
        std::string json = bbo_to_json(bbo);

        // Publish to TCP (broadcast to all connected clients)
        try
        {
            if (!config_.disable_tcp)
            {
                tcp_server_->broadcast(json);
            }
        }
        catch (const std::exception &e)
        {
            spdlog::error("TCP broadcast error: {}", e.what());
        }

        // Publish to MQTT
        if (mqtt_ && mqtt_->isConnected())
        {
            try
            {
                mqtt_->publish(config_.mqtt_topic, json);
            }
            catch (const std::exception &e)
            {
                spdlog::error("MQTT publish error: {}", e.what());
            }
        }

        // Publish to Kafka
        if (kafka_ && kafka_->isConnected())
        {
            try
            {
                kafka_->publish(config_.kafka_topic, json);
            }
            catch (const std::exception &e)
            {
                spdlog::error("Kafka publish error: {}", e.what());
            }
        }
    }

    void OrderGateway::logBBO(const BBOData &bbo)
    {
        if (csv_logger_)
        {
            try
            {
                csv_logger_->log(bbo);
            }
            catch (const std::exception &e)
            {
                spdlog::error("CSV log error: {}", e.what());
            }
        }
    }

} // namespace gateway
