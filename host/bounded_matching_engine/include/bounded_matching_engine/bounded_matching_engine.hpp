#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace fpga_ref {

enum class Side : uint8_t { kBuy = 0, kSell = 1 };

// Mirrors fpga_matching_core's register-level report exactly: aggregate
// filled quantity across every fill this order caused, and only the
// LAST fill's price - not the low_latency_trading_infra software
// project's std::vector<Trade> per submission. See the class comment
// below for why this isn't market::MatchingEngine reused.
struct SubmitResult {
    uint32_t total_filled_qty = 0; // aggregate across every fill this order caused
    int32_t  last_trade_price = 0; // last fill's price (resting side's price); 0 if no fill
    uint64_t last_trade_id    = 0; // 0 if no fill
    bool     rejected = false;     // true if an unfilled remainder could not rest
};

// Bounded, single-instrument price-time-priority matching engine - the
// software reference low_latency_trading_infra/docs/adr/
// ADR-007-fpga-bounded-order-book.md holds to the exact same
// N_LEVELS/M_ORDERS bounds, aggregate trade-reporting convention, and
// reject-only-on-rest overflow semantics as
// d10_standard_golden_top/rtl/bounded_order_book.sv, so Phase 26's
// four-way comparison is apples-to-apples (bounded vs. bounded) rather
// than comparing a hardware core against software's genuinely unbounded
// std::map-based book.
//
// Deliberately NOT market::MatchingEngine (low_latency_trading_infra
// matching-engine/) reused or adapted: that class returns a full
// std::vector<Trade> per submission and has no capacity bound at all -
// retrofitting hardware's bounds and aggregate-report contract onto it
// would mean constraining it until it no longer resembles that class in
// any meaningful way. Written fresh instead, deliberately mirroring its
// price-time-priority algorithm and trade-price convention exactly
// (docs/matching-engine.md: a trade always executes at the RESTING
// order's price, price improvement for the aggressor) while exposing a
// different, hardware-matched API.
//
// Storage is a plain N_LEVELS-element array per side, scanned linearly
// for best price - NOT a std::map, deliberately. docs/order-book.md's
// own benchmark found std::map beats a flat sorted vector by 5.7x under
// realistic order flow, but that result is about *thousands* of active
// price levels; it doesn't automatically hold at N_LEVELS=16, where a
// branch-predictable, fully cache-resident linear scan plausibly has
// less real overhead than a red-black tree's pointer-chasing and
// per-node heap allocation. This class exists partly to test that
// on-target rather than assume it - see bench/bounded_matching_engine_bench.cpp.
template <std::size_t N_LEVELS = 16, std::size_t M_ORDERS = 8>
class BoundedMatchingEngine {
public:
    // Limit order only - mirrors both the wire protocol (every ADD_ORDER
    // carries a price) and fpga_matching_core's register map (no
    // separate market-order opcode). CANCEL/MODIFY are out of scope, the
    // same named limitation as the hardware core (ADR-007).
    SubmitResult submit_limit_order(uint64_t order_id, Side side, int32_t price, uint32_t qty) {
        SubmitResult result{};
        uint32_t remaining = qty;

        auto& opposite = opposite_side(side);
        // want_max: incoming BUY crosses the opposite SELL side's best
        // (lowest) price; incoming SELL crosses the opposite BUY side's
        // best (highest) price - so the reduction wants max exactly when
        // the incoming order is a SELL.
        const bool opp_wants_max = (side == Side::kSell);

        while (remaining > 0) {
            std::optional<std::size_t> best_idx = find_best(opposite, opp_wants_max);
            if (!best_idx) break; // no opposite-side liquidity at all

            Level& lvl = opposite[*best_idx];
            const bool crosses = (side == Side::kBuy) ? (price >= lvl.price) : (price <= lvl.price);
            if (!crosses) break;

            RestingOrder& front = lvl.orders[0]; // front = index 0 = oldest = time priority
            const uint32_t trade_qty = (remaining < front.qty) ? remaining : front.qty;

            result.total_filled_qty += trade_qty;
            result.last_trade_price = lvl.price; // resting side's price - price improvement
            ++trade_id_ctr_;
            result.last_trade_id = trade_id_ctr_;
            remaining -= trade_qty;

            if (trade_qty == front.qty) {
                // Fully consumed - pop front, shift the rest down.
                for (std::size_t k = 0; k + 1 < lvl.count; ++k) {
                    lvl.orders[k] = lvl.orders[k + 1];
                }
                --lvl.count;
                if (lvl.count == 0) lvl.valid = false;
            } else {
                // Partially consumed -> our order is fully filled
                // (trade_qty == remaining-before-decrement in this
                // branch). Reduce the resting order's qty in place,
                // preserving its time priority.
                front.qty -= trade_qty;
            }
        }

        if (remaining > 0) {
            rest_remainder(side, order_id, price, remaining, result);
        }

        return result;
    }

private:
    struct RestingOrder {
        uint64_t order_id = 0;
        uint32_t qty = 0;
    };

    struct Level {
        bool valid = false;
        int32_t price = 0;
        std::size_t count = 0;
        std::array<RestingOrder, M_ORDERS> orders{};
    };

    using LevelArray = std::array<Level, N_LEVELS>;

    LevelArray buy_levels_{};
    LevelArray sell_levels_{};
    uint64_t trade_id_ctr_ = 0;

    LevelArray& own_side(Side s) { return s == Side::kBuy ? buy_levels_ : sell_levels_; }
    LevelArray& opposite_side(Side s) { return s == Side::kBuy ? sell_levels_ : buy_levels_; }

    static std::optional<std::size_t> find_best(const LevelArray& levels, bool want_max) {
        std::optional<std::size_t> best;
        for (std::size_t i = 0; i < N_LEVELS; ++i) {
            if (!levels[i].valid) continue;
            if (!best) { best = i; continue; }
            if (want_max ? (levels[i].price > levels[*best].price)
                         : (levels[i].price < levels[*best].price)) {
                best = i;
            }
        }
        return best;
    }

    // Mirrors bounded_order_book.sv's ST_REST exactly, including the
    // specific edge case worth naming: if a level at this exact price
    // already exists but is full (count == M_ORDERS), this rejects -
    // it does NOT fall back to trying a free slot elsewhere. An order
    // either joins its own price's level or opens a brand-new one;
    // never "helps" by resting at the wrong price.
    void rest_remainder(Side side, uint64_t order_id, int32_t price, uint32_t qty, SubmitResult& result) {
        LevelArray& own = own_side(side);

        std::optional<std::size_t> match_idx;
        for (std::size_t i = 0; i < N_LEVELS; ++i) {
            if (own[i].valid && own[i].price == price) { match_idx = i; break; }
        }

        if (match_idx && own[*match_idx].count < M_ORDERS) {
            Level& lvl = own[*match_idx];
            lvl.orders[lvl.count] = RestingOrder{order_id, qty};
            ++lvl.count;
            return;
        }

        if (!match_idx) {
            std::optional<std::size_t> free_idx;
            for (std::size_t i = 0; i < N_LEVELS; ++i) {
                if (!own[i].valid) { free_idx = i; break; }
            }
            if (free_idx) {
                Level& lvl = own[*free_idx];
                lvl.valid = true;
                lvl.price = price;
                lvl.count = 1;
                lvl.orders[0] = RestingOrder{order_id, qty};
                return;
            }
        }

        result.rejected = true;
    }
};

} // namespace fpga_ref
