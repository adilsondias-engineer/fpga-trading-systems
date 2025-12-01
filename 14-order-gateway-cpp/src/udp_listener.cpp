/*
UDP Listener
Listens for UDP packets from FPGA and parses them into BBOData
*/

#include "udp_listener.h"
#include <spdlog/spdlog.h>
#include <chrono>

namespace gateway {

    UDPListener::UDPListener(const std::string& ip_address, int port)
        : ip_address_(ip_address), port_(port)
    {
        buffer_.resize(2048);
        boost::system::error_code ec;

        // Determine bind address
        boost::asio::ip::address bind_addr;
        if (ip_address_.empty() || ip_address_ == "0.0.0.0" || ip_address_ == "::" || ip_address_ == "*")
        {
            bind_addr = boost::asio::ip::address_v4::any();
        }
        else
        {
            bind_addr = boost::asio::ip::make_address(ip_address_, ec);
            if (ec)
            {
                // Resolve hostname to an address
                boost::asio::ip::udp::resolver resolver(io_);
                auto results = resolver.resolve(boost::asio::ip::udp::v4(), ip_address_, std::to_string(port_), ec);
                if (!ec && results.begin() != results.end())
                {
                    bind_addr = results.begin()->endpoint().address();
                }
                else
                {
                    // Fallback to any address if resolution fails
                    bind_addr = boost::asio::ip::address_v4::any();
                }
            }
        }

        boost::asio::ip::udp::endpoint bind_ep(bind_addr, static_cast<unsigned short>(port_));
        socket_.open(bind_ep.protocol(), ec);
        if (ec) {
            throw std::runtime_error(std::string("UDP socket open failed: ") + ec.message());
        }
        socket_.set_option(boost::asio::socket_base::reuse_address(true), ec);
        socket_.bind(bind_ep, ec);
        if (ec) {
            throw std::runtime_error(std::string("UDP socket bind failed: ") + ec.message());
        }
    }

    UDPListener::~UDPListener()
    {
        stop();
    }

    void UDPListener::start()
    {
        run();
    }

    void UDPListener::run()
    {
        if (!running_)
        {
            std::unique_lock<std::mutex> lock(mutex_);
            running_ = true;
            
            thread_ = std::thread(&UDPListener::thread_func, this);
            condition_.notify_one();
        }
    }

    void UDPListener::stop()
    {
        if (running_)
        {
            std::unique_lock<std::mutex> lock(mutex_);
            running_ = false;
            condition_.notify_one();
            boost::system::error_code ec;
            socket_.close(ec);
            io_.stop();
            // Wake any readers waiting on the BBO queue
            bbo_queue_condition_.notify_all();
            if (thread_.joinable())
            {
                thread_.join();
            }
        }
    }

    void UDPListener::on_receive(const boost::system::error_code& error, std::size_t bytes_transferred)
    {
        if (!error)
        {
            // Measure parse latency
            BBOData bbo;
            if (perf_monitor_) {
                gateway::LatencyMeasurement measure(*perf_monitor_);
                bbo = BBOParser::parseBBOData(buffer_.data(), bytes_transferred);
                // Measurement ends here (destructor runs at end of scope)
            } else {
                bbo = BBOParser::parseBBOData(buffer_.data(), bytes_transferred);
            }

            if (bbo.valid)
            {
                process_bbo(bbo);
            }
        }   
        else
        {
            std::cerr << "Invalid BBO data" << std::endl;
        }
        // schedule next receive
        if (running_)
        {
            socket_.async_receive_from(
                boost::asio::buffer(buffer_), sender_endpoint_,
                [this](const boost::system::error_code& ec, std::size_t bytes) { this->on_receive(ec, bytes); });
        }
    }

    void UDPListener::thread_func()
    {
        io_.restart();
        // kick off first receive
        socket_.async_receive_from(
            boost::asio::buffer(buffer_), sender_endpoint_,
            [this](const boost::system::error_code& ec, std::size_t bytes) { this->on_receive(ec, bytes); });
        io_.run();
    }

    BBOData UDPListener::read_bbo()
    {
        // Lazy start
        if (!running_)
        {
            run();
        }
        std::unique_lock<std::mutex> lock(bbo_queue_mutex_);
        bbo_queue_condition_.wait(lock, [this] { return !bbo_queue_.empty() || !running_; });
        if (!running_ && bbo_queue_.empty())
        {
            throw std::runtime_error("UDP listener stopped");
        }
        BBOData bbo = bbo_queue_.front();
        bbo_queue_.pop();
        return bbo;
    }

    void UDPListener::process_bbo(const BBOData& bbo)
    {
        // In benchmark mode, skip queue entirely (just measure parse latency)
        if (benchmark_mode_)
        {
            return;
        }

        std::unique_lock<std::mutex> lock(bbo_queue_mutex_);
        if (bbo_queue_.size() >= MAX_QUEUE_SIZE)
        {
            std::cerr << "Warning: BBO queue full, dropping oldest message" << std::endl;
            bbo_queue_.pop();    // Drop oldest message
        }
        bbo_queue_.push(bbo);
        bbo_queue_condition_.notify_one();  // Notify any waiting threads
    }

    bool UDPListener::isRunning() const
    {
        return running_;
    }
}