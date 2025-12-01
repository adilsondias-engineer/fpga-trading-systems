#pragma once
#include <string>
#include <memory>
#include "order_types.h"
#include "position_tracker.h"
#include "order_producer.h"
#include <spdlog/spdlog.h>
#include "spdlog/sinks/stdout_color_sinks.h"

namespace mm {

enum class State {
    IDLE,
    CALCULATE,
    QUOTE,
    RISK_CHECK,
    ORDER_GEN,
    WAIT_FILL
};

class MarketMakerFSM {
public:
    struct Config {
        double min_spread_bps = 5.0;
        double edge_bps = 2.0;
        int max_position = 500;
        double position_skew_bps = 1.0;
        int quote_size = 100;
        double max_notional = 100000.0;
        bool enable_order_execution = false;
        std::string order_ring_path = "order_ring_mm";
        std::string fill_ring_path = "fill_ring_oe";
    };

    explicit MarketMakerFSM(const Config& config);

    // Main event handler
    void onBboUpdate(const BBO& bbo);

    // Process fill notifications (call this in main loop)
    void processFills();

    // State getters
    State getState() const { return state_; }
    const PositionTracker& getPosition() const { return position_; }

private:
    // State handlers
    void handleCalculate(const BBO& bbo);
    void handleQuote(const BBO& bbo);
    void handleRiskCheck();
    void handleOrderGen();
    void handleWaitFill();
    
    // Helper functions
    double calculateFairValue(const BBO& bbo);
    Quote generateQuote(double fair_value, const BBO& bbo);
    bool checkRiskLimits(const Quote& quote);
    void simulateFill(const BBO& bbo);
    
    // State
    State state_;
    Config config_;
    PositionTracker position_;
    Quote current_quote_;
    double cached_fair_value_;
    std::shared_ptr<spdlog::logger> logger_;
    std::unique_ptr<OrderProducer> order_producer_;
    uint64_t order_sequence_;
};

} // namespace mm
