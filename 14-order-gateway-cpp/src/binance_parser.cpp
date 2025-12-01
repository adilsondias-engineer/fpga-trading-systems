#include "binance_parser.h"
#include <nlohmann/json.hpp>
#include <chrono>
#include <stdexcept>
#include <cmath>

namespace gateway
{

    BBOData BinanceParser::parseBookTicker(const std::string& json_str)
    {
        BBOData bbo = {};

        try
        {
            auto json_obj = nlohmann::json::parse(json_str);

            // Check if combined stream format (has "stream" and "data" fields)
            if (json_obj.contains("stream") && json_obj.contains("data"))
            {
                return parseCombinedStream(json_str);
            }

            // Direct bookTicker format (data object directly)
            if (!json_obj.contains("s") || !json_obj.contains("b") || 
                !json_obj.contains("B") || !json_obj.contains("a") || 
                !json_obj.contains("A"))
            {
                bbo.valid = false;
                return bbo;
            }

            std::string symbol = json_obj["s"].get<std::string>();
            std::string bid_price_str = json_obj["b"].get<std::string>();
            std::string bid_qty_str = json_obj["B"].get<std::string>();
            std::string ask_price_str = json_obj["a"].get<std::string>();
            std::string ask_qty_str = json_obj["A"].get<std::string>();

            return parseBookTickerData(symbol, bid_price_str, bid_qty_str, 
                                      ask_price_str, ask_qty_str);
        }
        catch (const std::exception&)
        {
            bbo.valid = false;
            return bbo;
        }
    }

    BBOData BinanceParser::parseCombinedStream(const std::string& json_str)
    {
        BBOData bbo = {};

        try
        {
            auto json_obj = nlohmann::json::parse(json_str);

            if (!json_obj.contains("stream") || !json_obj.contains("data"))
            {
                bbo.valid = false;
                return bbo;
            }

            std::string stream_name = json_obj["stream"].get<std::string>();

            // Only process bookTicker streams
            if (stream_name.find("@bookTicker") == std::string::npos)
            {
                bbo.valid = false;
                return bbo;
            }

            auto data_obj = json_obj["data"];

            if (!data_obj.contains("s") || !data_obj.contains("b") || 
                !data_obj.contains("B") || !data_obj.contains("a") || 
                !data_obj.contains("A"))
            {
                bbo.valid = false;
                return bbo;
            }

            std::string symbol = data_obj["s"].get<std::string>();
            std::string bid_price_str = data_obj["b"].get<std::string>();
            std::string bid_qty_str = data_obj["B"].get<std::string>();
            std::string ask_price_str = data_obj["a"].get<std::string>();
            std::string ask_qty_str = data_obj["A"].get<std::string>();

            return parseBookTickerData(symbol, bid_price_str, bid_qty_str, 
                                      ask_price_str, ask_qty_str);
        }
        catch (const std::exception&)
        {
            bbo.valid = false;
            return bbo;
        }
    }

    BBOData BinanceParser::parseBookTickerData(const std::string& symbol,
                                               const std::string& bid_price_str,
                                               const std::string& bid_qty_str,
                                               const std::string& ask_price_str,
                                               const std::string& ask_qty_str)
    {
        BBOData bbo = {};

        try
        {
            bbo.set_symbol(symbol);

            // Convert string prices to double (Binance uses strings for precision)
            bbo.bid_price = std::stod(bid_price_str);
            bbo.ask_price = std::stod(ask_price_str);

            // Convert string quantities to uint32_t (round to nearest integer)
            double bid_qty_double = std::stod(bid_qty_str);
            double ask_qty_double = std::stod(ask_qty_str);
            bbo.bid_shares = static_cast<uint32_t>(std::round(bid_qty_double));
            bbo.ask_shares = static_cast<uint32_t>(std::round(ask_qty_double));

            // Calculate spread
            if (bbo.bid_price > 0.0 && bbo.ask_price > 0.0)
            {
                bbo.spread = bbo.ask_price - bbo.bid_price;
            }
            else
            {
                bbo.spread = 0.0;
            }

            bbo.timestamp_ns = get_timestamp_ns();
            bbo.valid = true;
        }
        catch (const std::exception&)
        {
            bbo.valid = false;
        }

        return bbo;
    }

    int64_t BinanceParser::get_timestamp_ns()
    {
        auto now = std::chrono::high_resolution_clock::now();
        auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
            now.time_since_epoch()).count();
        return nanoseconds;
    }

} // namespace gateway

