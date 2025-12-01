#include "order_gateway.h"

#include <fstream>
#include <stdexcept>
#include <csignal>
#include <memory>
#include <sstream>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <nlohmann/json.hpp>

using namespace gateway;

// Global gateway instance for signal handler
std::unique_ptr<OrderGateway> g_gateway;

void signal_handler(int signal)
{
    spdlog::info("Shutdown signal received ({})", signal);
    if (g_gateway)
    {
        g_gateway->stop();
    }
}

void print_usage(const char *program_name)
{
    spdlog::info("Usage: {} [config_file]", program_name);
    spdlog::info("");
    spdlog::info("Arguments:");
    spdlog::info("  config_file  - Path to config.json file (default: config.json)");
    spdlog::info("");
    spdlog::info("Example:");
    spdlog::info("  {} config.json", program_name);
    spdlog::info("  {} /path/to/config.json", program_name);
}

OrderGateway::Config load_config(const std::string& config_file)
{
    OrderGateway::Config config;

    std::ifstream config_stream(config_file);
    if (!config_stream.is_open())
    {
        throw std::runtime_error("Failed to open config file: " + config_file);
    }

    try
    {
        nlohmann::json config_json;
        config_stream >> config_json;

        // Load log level
        if (config_json.contains("log_level"))
        {
            std::string log_level = config_json["log_level"].get<std::string>();
            if (log_level == "trace") spdlog::set_level(spdlog::level::trace);
            else if (log_level == "debug") spdlog::set_level(spdlog::level::debug);
            else if (log_level == "info") spdlog::set_level(spdlog::level::info);
            else if (log_level == "warn") spdlog::set_level(spdlog::level::warn);
            else if (log_level == "error") spdlog::set_level(spdlog::level::err);
            else if (log_level == "critical") spdlog::set_level(spdlog::level::critical);
        }

        // Load FPGA configuration
        if (config_json.contains("fpga"))
        {
            auto& fpga = config_json["fpga"];
            if (fpga.contains("enable"))
            {
                config.enable_fpga = fpga["enable"];
            }
            if (fpga.contains("udp_ip"))
            {
                config.udp_ip = fpga["udp_ip"].get<std::string>();
            }
            if (fpga.contains("udp_port"))
            {
                config.udp_port = fpga["udp_port"];
            }
#ifdef USE_XDP
            if (fpga.contains("use_xdp"))
            {
                config.use_xdp = fpga["use_xdp"];
            }
            if (fpga.contains("xdp_interface"))
            {
                config.xdp_interface = fpga["xdp_interface"].get<std::string>();
            }
            if (fpga.contains("xdp_queue_id"))
            {
                config.xdp_queue_id = fpga["xdp_queue_id"];
            }
            if (fpga.contains("enable_xdp_debug"))
            {
                config.enable_xdp_debug = fpga["enable_xdp_debug"];
            }
#endif
        }

        // Load Binance configuration
        if (config_json.contains("binance"))
        {
            auto& binance = config_json["binance"];
            if (binance.contains("enable"))
            {
                config.enable_binance = binance["enable"];
            }
            if (binance.contains("symbols"))
            {
                config.binance_symbols = binance["symbols"].get<std::vector<std::string>>();
            }
            if (binance.contains("stream_type"))
            {
                config.binance_stream_type = binance["stream_type"].get<std::string>();
            }
        }

        // Load TCP configuration
        if (config_json.contains("tcp"))
        {
            auto& tcp = config_json["tcp"];
            if (tcp.contains("enable"))
            {
                config.disable_tcp = !tcp["enable"];
            }
            if (tcp.contains("port"))
            {
                config.tcp_port = tcp["port"];
            }
        }

        // Load MQTT configuration
        if (config_json.contains("mqtt"))
        {
            auto& mqtt = config_json["mqtt"];
            if (mqtt.contains("enable"))
            {
                config.disable_mqtt = !mqtt["enable"];
            }
            if (mqtt.contains("broker_url"))
            {
                config.mqtt_broker_url = mqtt["broker_url"].get<std::string>();
            }
            if (mqtt.contains("client_id"))
            {
                config.mqtt_client_id = mqtt["client_id"].get<std::string>();
            }
            if (mqtt.contains("username"))
            {
                config.mqtt_username = mqtt["username"].get<std::string>();
            }
            if (mqtt.contains("password"))
            {
                config.mqtt_password = mqtt["password"].get<std::string>();
            }
            if (mqtt.contains("topic"))
            {
                config.mqtt_topic = mqtt["topic"].get<std::string>();
            }
        }

        // Load Kafka configuration
        if (config_json.contains("kafka"))
        {
            auto& kafka = config_json["kafka"];
            if (kafka.contains("enable"))
            {
                config.disable_kafka = !kafka["enable"];
            }
            if (kafka.contains("broker_url"))
            {
                config.kafka_broker_url = kafka["broker_url"].get<std::string>();
            }
            if (kafka.contains("client_id"))
            {
                config.kafka_client_id = kafka["client_id"].get<std::string>();
            }
            if (kafka.contains("topic"))
            {
                config.kafka_topic = kafka["topic"].get<std::string>();
            }
        }

        // Load CSV logger configuration
        if (config_json.contains("csv_logger"))
        {
            auto& csv = config_json["csv_logger"];
            if (csv.contains("enable"))
            {
                config.disable_logger = !csv["enable"];
            }
            if (csv.contains("file"))
            {
                config.csv_file = csv["file"].get<std::string>();
            }
        }

        // Load Disruptor configuration
        if (config_json.contains("disruptor"))
        {
            auto& disruptor = config_json["disruptor"];
            if (disruptor.contains("enable"))
            {
                config.enable_disruptor = disruptor["enable"];
            }
            // Note: shm_name is handled internally by Disruptor, not needed here
        }

        // Load performance configuration
        if (config_json.contains("performance"))
        {
            auto& perf = config_json["performance"];
            if (perf.contains("enable_rt"))
            {
                config.enable_rt = perf["enable_rt"];
            }
            if (perf.contains("quiet_mode"))
            {
                config.quiet_mode = perf["quiet_mode"];
            }
            if (perf.contains("benchmark_mode"))
            {
                config.benchmark_mode = perf["benchmark_mode"];
            }
        }

        spdlog::info("Loaded config from {}", config_file);
    }
    catch (const std::exception& e)
    {
        throw std::runtime_error("Failed to parse config file: " + std::string(e.what()));
    }

    return config;
}

int main(int argc, char **argv)
{
    // Initialize spdlog
    auto console = spdlog::stdout_color_mt("order_gateway");
    spdlog::set_default_logger(console);
    spdlog::set_level(spdlog::level::info);  // Default to info

    std::string config_file = "config.json";
    if (argc > 1)
    {
        config_file = argv[1];
    }

    // Install signal handler for graceful shutdown
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    try
    {
        // Load configuration from JSON file
        OrderGateway::Config config = load_config(config_file);

        // Create and start gateway
        g_gateway = std::make_unique<OrderGateway>(config);
        g_gateway->start();

        spdlog::info("Gateway running. Press Ctrl+C to stop.");
        spdlog::info("");

        // Wait for gateway to stop
        g_gateway->wait();

        spdlog::info("");
        spdlog::info("Gateway stopped.");
    }
    catch (const std::exception &e)
    {
        spdlog::error("Error: {}", e.what());
        return 1;
    }

    return 0;
}
