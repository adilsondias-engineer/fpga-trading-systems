#pragma once

#include <string>
#include <cstdint>
#include <cstring>

namespace gateway {

/**
 * Best Bid/Offer (BBO) data structure
 * Shared between Project 14 (Order Gateway) and Project 15 (Market Maker)
 *
 * IMPORTANT: Uses fixed-size char array for symbol instead of std::string
 * because this struct is used in shared memory between processes.
 * std::string contains pointers that are invalid across process boundaries.
 */
struct BBOData {
    static constexpr size_t SYMBOL_MAX_LEN = 16;
    char symbol[SYMBOL_MAX_LEN];  // Fixed-size for shared memory compatibility
    double bid_price;
    uint32_t bid_shares;
    double ask_price;
    uint32_t ask_shares;
    double spread;
    int64_t timestamp_ns;
    bool valid;

    // 4-Point FPGA Latency Timestamps (all 125 MHz = 8 ns per cycle)
    // T1: ITCH parse (125 MHz RGMII RX domain)
    // T2: itch_cdc_fifo write (125 MHz RGMII RX domain, before 200 MHz crossing)
    // T3: bbo_fifo read (125 MHz TX domain, after 200 MHz crossing)
    // T4: UDP TX start (125 MHz TX domain)
    // Latency A = (T2 - T1) * 8 ns  (ITCH parse to CDC FIFO write)
    // Latency B = (T4 - T3) * 8 ns  (bbo_fifo read to TX start)
    // Total FPGA Latency = A + B
    uint32_t fpga_ts_t1;        // T1: ITCH parse (125 MHz RGMII RX cycle count)
    uint32_t fpga_ts_t2;        // T2: itch_cdc_fifo write (125 MHz RGMII RX cycle count)
    uint32_t fpga_ts_t3;        // T3: bbo_fifo read (125 MHz TX cycle count)
    uint32_t fpga_ts_t4;        // T4: TX start (125 MHz TX cycle count)
    double fpga_latency_a_us;   // Latency A: ITCH parse to CDC FIFO write
    double fpga_latency_b_us;   // Latency B: bbo_fifo read to TX start
    double fpga_latency_us;     // Total FPGA latency = A + B

    // Legacy fields for backward compatibility
    uint32_t fpga_rx_timestamp;  // Alias for T1 (backward compatibility)
    uint32_t fpga_tx_timestamp;  // Alias for T4 (backward compatibility)

    BBOData() :
        bid_price(0.0), bid_shares(0),
        ask_price(0.0), ask_shares(0),
        spread(0.0), timestamp_ns(0), valid(false),
        fpga_ts_t1(0), fpga_ts_t2(0), fpga_ts_t3(0), fpga_ts_t4(0),
        fpga_latency_a_us(0.0), fpga_latency_b_us(0.0), fpga_latency_us(0.0),
        fpga_rx_timestamp(0), fpga_tx_timestamp(0) {
        std::memset(symbol, 0, SYMBOL_MAX_LEN);
    }

    // Helper to set symbol from std::string
    void set_symbol(const std::string& sym) {
        std::strncpy(symbol, sym.c_str(), SYMBOL_MAX_LEN - 1);
        symbol[SYMBOL_MAX_LEN - 1] = '\0';  // Ensure null termination
    }

    // Helper to get symbol as std::string
    std::string get_symbol() const {
        return std::string(symbol);
    }
};

}  // namespace gateway
