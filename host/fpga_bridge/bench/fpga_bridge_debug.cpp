// Debug variant of fpga_bridge_bench.cpp - flags the FIRST order whose
// reported trade_qty exceeds its own submitted qty (structurally
// impossible per bounded_order_book.sv's FSM: reg_total_filled only ever
// accumulates trade_qty <= reg_remaining_qty, which starts at in_qty and
// only decreases). Prints the order and a few of its neighbors for
// context, then stops - a sharp, minimal reproduction beats scanning a
// full 1,000,000-event summary. See fpga_docs/bugs.md #10/#11.
#include <cstdio>
#include <random>
#include <vector>

#include "fpga_bridge/fpga_bridge.hpp"

using fpga_bridge::FpgaMatchingCore;
using fpga_bridge::Side;

namespace {

struct SyntheticOrder {
    uint64_t order_id;
    Side side;
    int32_t price;
    uint32_t qty;
};

std::vector<SyntheticOrder> generate_workload(std::size_t count, uint64_t seed) {
    std::vector<SyntheticOrder> orders;
    orders.reserve(count);

    std::mt19937_64 rng(seed);
    std::uniform_int_distribution<int> side_dist(0, 1);
    std::uniform_int_distribution<int32_t> offset_dist(-3, 3);
    std::uniform_int_distribution<int32_t> mid_walk_dist(-2, 2);
    std::uniform_int_distribution<uint32_t> qty_dist(1, 500);

    constexpr int32_t kMidCenter = 10000;
    constexpr int32_t kMidBand = 50;
    int32_t mid = kMidCenter;

    for (std::size_t i = 0; i < count; ++i) {
        mid += mid_walk_dist(rng);
        if (mid > kMidCenter + kMidBand) mid = kMidCenter + kMidBand;
        if (mid < kMidCenter - kMidBand) mid = kMidCenter - kMidBand;
        const Side side = side_dist(rng) == 0 ? Side::kBuy : Side::kSell;
        const int32_t price = mid + offset_dist(rng);
        const uint32_t qty = qty_dist(rng);
        orders.push_back(SyntheticOrder{static_cast<uint64_t>(i) + 1, side, price, qty});
    }
    return orders;
}

} // namespace

int main() {
    constexpr std::size_t kIterations = 1'000'000;
    const auto workload = generate_workload(kIterations, /*seed=*/42);

    FpgaMatchingCore core;

    int flagged = 0;
    for (std::size_t i = 0; i < workload.size() && flagged < 10; ++i) {
        const auto& o = workload[i];
        const auto result = core.submit_limit_order(o.order_id, o.side, o.price, o.qty);
        if (result.trade_qty > o.qty) {
            std::printf("[IMPOSSIBLE] i=%zu order_id=%llu side=%d price=%d qty=%u -> trade_qty=%u (> submitted qty!) rejected=%d latency=%u\n",
                        i, static_cast<unsigned long long>(o.order_id), static_cast<int>(o.side), o.price, o.qty,
                        result.trade_qty, result.rejected ? 1 : 0, result.latency_cycles);
            ++flagged;
        }
    }

    if (flagged == 0) {
        std::printf("No impossible trade_qty found in first %zu events\n", kIterations);
    } else {
        std::printf("Flagged %d impossible results (stopped early)\n", flagged);
    }

    return 0;
}
