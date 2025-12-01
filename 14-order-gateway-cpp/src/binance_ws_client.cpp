#include "binance_ws_client.h"
#include "common/perf_monitor.h"
#include <spdlog/spdlog.h>
#include <nlohmann/json.hpp>
#include <boost/beast/core/buffers_to_string.hpp>
#include <boost/asio/steady_timer.hpp>
#include <iostream>
#include <sstream>
#include <thread>
#include <chrono>
#include <algorithm>
#include <cctype>

namespace gateway
{

    BinanceWSClient::BinanceWSClient(const std::vector<std::string>& symbols,
                                    const std::string& stream_type)
        : symbols_(symbols)
        , stream_type_(stream_type)
        , host_("stream.binance.com")
        , port_("9443")
        , resolver_(ioc_)
        , ctx_(boost::asio::ssl::context::tlsv12_client)
        , running_(false)
        , should_stop_(false)
        , reconnect_attempts_(0)
        , last_reconnect_time_(std::chrono::steady_clock::now())
        , last_ping_time_(std::chrono::steady_clock::now())
        , ping_timer_(ioc_)
        , read_timer_(ioc_)
    {
        // Configure SSL context
        ctx_.set_default_verify_paths();
        ctx_.set_verify_mode(boost::asio::ssl::verify_peer);
    }

    BinanceWSClient::~BinanceWSClient()
    {
        stop();
    }

    void BinanceWSClient::start(BBOCallback callback)
    {
        if (running_)
        {
            return;
        }

        if (symbols_.empty())
        {
            spdlog::error("[Binance] No symbols configured");
            return;
        }

        bbo_callback_ = callback;
        should_stop_ = false;
        running_ = true;

        worker_thread_ = std::thread(&BinanceWSClient::workerThreadFunc, this);

        spdlog::info("[Binance] WebSocket client started ({} symbols)", symbols_.size());
    }

    void BinanceWSClient::stop()
    {
        if (!running_)
        {
            return;
        }

        spdlog::info("[Binance] Stopping WebSocket client...");
        should_stop_ = true;
        running_ = false;

        // Cancel all pending async operations first
        ping_timer_.cancel();
        read_timer_.cancel();

        // Close WebSocket connection synchronously (this will cancel pending async_read)
        if (ws_ && ws_->is_open())
        {
            try
            {
                boost::beast::error_code ec;
                // Use synchronous close to immediately cancel async operations
                ws_->close(boost::beast::websocket::close_code::normal, ec);
                if (ec && ec != boost::asio::error::operation_aborted)
                {
                    spdlog::debug("[Binance] Close error: {}", ec.message());
                }
            }
            catch (const std::exception& e)
            {
                spdlog::debug("[Binance] Exception during close: {}", e.what());
            }
            catch (...)
            {
                // Ignore other errors during shutdown
            }
        }

        // Stop io_context (this will cause ioc_.run() to return)
        ioc_.stop();

        // Wait for worker thread
        if (worker_thread_.joinable())
        {
            worker_thread_.join();
        }

        spdlog::info("[Binance] WebSocket client stopped");
    }

    bool BinanceWSClient::isRunning() const
    {
        return running_;
    }

    std::string BinanceWSClient::getStatus() const
    {
        if (!running_)
        {
            return "Stopped";
        }
        if (ws_ && ws_->is_open())
        {
            return "Connected";
        }
        return "Connecting";
    }

    void BinanceWSClient::workerThreadFunc()
    {
        while (!should_stop_)
        {
            try
            {
                if (connect())
                {
                    if (subscribe())
                    {
                        reconnect_attempts_ = 0;
                        // Start async operations
                        schedulePing();
                        doRead();
                        // Run io_context to process async operations
                        ioc_.run();
                        // If we get here, io_context stopped (connection lost or shutdown)
                        if (should_stop_)
                        {
                            break;  // Exit immediately if stopping
                        }
                        // If we get here, io_context stopped (connection lost)
                        ioc_.restart();
                    }
                }

                // Connection lost or failed
                if (!should_stop_)
                {
                    handleReconnect();
                }
            }
            catch (const std::exception& e)
            {
                spdlog::error("[Binance] Worker thread exception: {}", e.what());
                if (!should_stop_)
                {
                    handleReconnect();
                }
            }
        }

        running_ = false;
        spdlog::debug("[Binance] Worker thread exiting");
    }

    bool BinanceWSClient::connect()
    {
        try
        {
            // Resolve hostname
            auto const results = resolver_.resolve(host_, port_);

            // Create WebSocket stream with SSL
            ws_ = std::make_unique<boost::beast::websocket::stream<
                boost::beast::ssl_stream<boost::beast::tcp_stream>>>(
                ioc_, ctx_);

            // Set SNI hostname
            if (!SSL_set_tlsext_host_name(ws_->next_layer().native_handle(), host_.c_str()))
            {
                boost::beast::error_code ec{static_cast<int>(::ERR_get_error()),
                                           boost::asio::error::get_ssl_category()};
                spdlog::error("[Binance] SSL SNI error: {}", ec.message());
                return false;
            }

            // Connect TCP socket
            boost::beast::get_lowest_layer(*ws_).connect(results);

            // Perform SSL handshake
            ws_->next_layer().handshake(boost::asio::ssl::stream_base::client);

            // Perform WebSocket handshake
            std::string path = buildStreamUrl();
            ws_->handshake(host_, path);

            spdlog::info("[Binance] Connected to {}:{}", host_, port_);
            last_ping_time_ = std::chrono::steady_clock::now();
            return true;
        }
        catch (const std::exception& e)
        {
            spdlog::error("[Binance] Connection error: {}", e.what());
            return false;
        }
    }

    bool BinanceWSClient::subscribe()
    {
        try
        {
            // For combined streams, subscription is done via URL path, not message
            // The handshake already subscribed to the streams, so just need to verify connection
            spdlog::info("[Binance] Subscribed to {} streams via combined stream URL", symbols_.size());
            
            // Log the stream URL for debugging
            std::string path = buildStreamUrl();
            spdlog::debug("[Binance] Stream URL: {}", path);
            
            return true;
        }
        catch (const std::exception& e)
        {
            spdlog::error("[Binance] Subscription error: {}", e.what());
            return false;
        }
    }

    void BinanceWSClient::doRead()
    {
        // Check should_stop_ first before any operations
        if (should_stop_)
        {
            ioc_.stop();
            return;
        }

        if (!ws_ || !ws_->is_open())
        {
            ioc_.stop();
            return;
        }

        // Set read timeout (30 seconds)
        read_timer_.expires_after(std::chrono::seconds(30));
        read_timer_.async_wait([this](boost::beast::error_code ec) {
            if (!ec && ws_ && ws_->is_open())
            {
                spdlog::warn("[Binance] Read timeout, closing connection");
                boost::beast::error_code close_ec;
                ws_->close(boost::beast::websocket::close_code::normal, close_ec);
                ioc_.stop();
            }
        });

        // Clear buffer for new read
        read_buffer_.consume(read_buffer_.size());

        // Start async read
        ws_->async_read(
            read_buffer_,
            [this](boost::beast::error_code ec, std::size_t bytes_transferred) {
                onRead(ec, bytes_transferred);
            });
    }

    void BinanceWSClient::onRead(boost::beast::error_code ec, std::size_t bytes_transferred)
    {
        // Cancel read timeout
        read_timer_.cancel();

        // Check if we should stop before processing
        if (should_stop_)
        {
            spdlog::debug("[Binance] Stopping, ignoring read completion");
            ioc_.stop();
            return;
        }

        if (ec)
        {
            if (ec == boost::beast::websocket::error::closed ||
                ec == boost::asio::error::operation_aborted)
            {
                spdlog::info("[Binance] Connection closed");
                ioc_.stop();
                return;
            }
            else
            {
                spdlog::warn("[Binance] Read error: {}", ec.message());
                ioc_.stop();
                return;
            }
        }

        if (bytes_transferred == 0)
        {
            // No data, continue reading if not stopping
            if (!should_stop_)
            {
                doRead();
            }
            return;
        }

        // Check again after bytes_transferred check
        if (should_stop_)
        {
            spdlog::debug("[Binance] Stopping, skipping message processing");
            ioc_.stop();
            return;
        }

        try
        {
            // Convert buffer to string
            std::string message = boost::beast::buffers_to_string(read_buffer_.data());
            spdlog::debug("[Binance] Received message: {}", message);

            // Parse and process message with latency measurement
            BBOData bbo;
            if (perf_monitor_) {
                gateway::LatencyMeasurement measure(*perf_monitor_);
                bbo = BinanceParser::parseCombinedStream(message);
            } else {
                bbo = BinanceParser::parseCombinedStream(message);
            }

            // Check should_stop_ before calling callback
            if (!should_stop_ && bbo.valid && bbo_callback_)
            {
                spdlog::debug("[Binance] BBO: {} bid={} ask={}", bbo.symbol, bbo.bid_price, bbo.ask_price);
                bbo_callback_(bbo);
            }
            else if (!bbo.valid)
            {
                spdlog::debug("[Binance] Invalid BBO or ping/pong message");
            }
        }
        catch (const std::exception& e)
        {
            spdlog::warn("[Binance] Message processing error: {}", e.what());
        }

        // Continue reading only if not stopping
        if (!should_stop_ && ws_ && ws_->is_open())
        {
            doRead();
        }
        else
        {
            // Stop io_context if we're shutting down
            ioc_.stop();
        }
    }

    void BinanceWSClient::schedulePing()
    {
        if (should_stop_ || !ws_ || !ws_->is_open())
        {
            return;
        }

        // Schedule ping in PING_INTERVAL_SEC seconds
        ping_timer_.expires_after(std::chrono::seconds(PING_INTERVAL_SEC));
        ping_timer_.async_wait([this](boost::beast::error_code ec) {
            if (!ec && ws_ && ws_->is_open() && !should_stop_)
            {
                sendPing();
                last_ping_time_ = std::chrono::steady_clock::now();
                schedulePing();  // Schedule next ping
            }
        });
    }

    void BinanceWSClient::sendPing()
    {
        try
        {
            if (ws_ && ws_->is_open())
            {
                ws_->ping(boost::beast::websocket::ping_data{});
            }
        }
        catch (const std::exception& e)
        {
            spdlog::warn("[Binance] Ping error: {}", e.what());
        }
    }

    void BinanceWSClient::handleReconnect()
    {
        int attempts = reconnect_attempts_.fetch_add(1) + 1;

        if (attempts > MAX_RECONNECT_ATTEMPTS)
        {
            spdlog::error("[Binance] Max reconnection attempts reached");
            should_stop_ = true;
            return;
        }

        // Exponential backoff: delay = 1000ms * 2^(attempts-1)
        int delay_ms = RECONNECT_DELAY_MS * (1 << (attempts - 1));
        if (delay_ms > 30000)  // Cap at 30 seconds
        {
            delay_ms = 30000;
        }

        spdlog::info("[Binance] Reconnecting in {}ms (attempt {}/{})", 
                    delay_ms, attempts, MAX_RECONNECT_ATTEMPTS);

        std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));

        // Reset WebSocket
        ws_.reset();
        ioc_.restart();
    }

    std::string BinanceWSClient::buildStreamUrl() const
    {
        // Build combined stream URL: /stream?streams=btcusdt@bookTicker/ethusdt@bookTicker
        // Binance requires lowercase symbols
        std::ostringstream oss;
        oss << "/stream?streams=";

        for (size_t i = 0; i < symbols_.size(); ++i)
        {
            if (i > 0)
            {
                oss << "/";
            }
            // Convert symbol to lowercase (Binance requirement)
            std::string symbol_lower = symbols_[i];
            std::transform(symbol_lower.begin(), symbol_lower.end(), symbol_lower.begin(), ::tolower);
            oss << symbol_lower << "@" << stream_type_;
        }

        return oss.str();
    }

} // namespace gateway

