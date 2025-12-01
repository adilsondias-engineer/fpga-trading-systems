#pragma once

#include "bbo_data.h"
#include <string>
#include <cstdint>

namespace gateway
{

    /**
     * Binance WebSocket Message Parser
     * Converts Binance JSON messages to BBOData structure
     *
     * Supported stream types:
     *   - bookTicker: Best bid/ask updates (real-time)
     *   - depth@100ms: Partial order book depth (100ms updates)
     */
    class BinanceParser
    {
    public:
        /**
         * Parse bookTicker message from Binance WebSocket
         * @param json_str JSON string from Binance stream
         * @return BBOData struct (valid=false on parse error)
         *
         * Message format:
         * {
         *   "stream": "btcusdt@bookTicker",
         *   "data": {
         *     "u": 400900217,
         *     "s": "BTCUSDT",
         *     "b": "43250.00",
         *     "B": "0.5",
         *     "a": "43251.00",
         *     "A": "1.2"
         *   }
         * }
         */
        static BBOData parseBookTicker(const std::string& json_str);

        /**
         * Parse combined stream wrapper message
         * Extracts stream name and data payload
         * @param json_str Combined stream JSON message
         * @return BBOData struct (valid=false if not bookTicker stream)
         */
        static BBOData parseCombinedStream(const std::string& json_str);

    private:
        /**
         * Get current timestamp in nanoseconds since Unix epoch
         * @return Timestamp in nanoseconds
         */
        static int64_t get_timestamp_ns();

        /**
         * Parse bookTicker data object
         * @param data_obj JSON data object (from "data" field)
         * @return BBOData struct
         */
        static BBOData parseBookTickerData(const std::string& symbol, 
                                          const std::string& bid_price_str,
                                          const std::string& bid_qty_str,
                                          const std::string& ask_price_str,
                                          const std::string& ask_qty_str);
    };

} // namespace gateway

