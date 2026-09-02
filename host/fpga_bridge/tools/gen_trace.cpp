// gen_trace
//
// Phase 23's trace-replay testbench, host-side half: generates the exact
// same 1,000,000-order workload (generate_workload(seed=42), byte-for-
// byte identical to bounded_matching_engine_bench.cpp and
// fpga_bridge_bench.cpp), runs it through the golden BoundedMatchingEngine
// C++ reference at the real N_LEVELS=16/M_ORDERS=8 bounds, and dumps one
// CSV line per order: the input plus the reference's expected result.
// sim/tb_trace_replay.sv reads this file, drives bounded_order_book (RTL,
// same real bounds) with the same inputs, and compares actual vs
// expected order by order - built specifically to root-cause
// fpga_docs/bugs.md #11's real, reproducible 53.275% (hardware) vs 72.4%
// (C++ reference) reject-rate gap on identical input, which hardware
// experimentation alone couldn't pin down further.
//
// Host tool only (x86, runs once to produce the trace file) - not
// cross-compiled, not run on the board.
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

#include "bounded_matching_engine/bounded_matching_engine.hpp"

using fpga_ref::BoundedMatchingEngine;
using fpga_ref::Side;

namespace {

struct SyntheticOrder {
    uint64_t order_id;
    Side side;
    int32_t price;
    uint32_t qty;
};

// Byte-for-byte identical to bounded_matching_engine_bench.cpp /
// fpga_bridge_bench.cpp's generate_workload() - see either for the full
// tuning history in comments, not repeated here.
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

int main(int argc, char** argv) {
    const std::size_t kIterations = (argc > 1) ? static_cast<std::size_t>(std::atoll(argv[1])) : 1'000'000;
    const char* out_path = (argc > 2) ? argv[2] : "trace.csv";

    const auto workload = generate_workload(kIterations, /*seed=*/42);
    BoundedMatchingEngine<16, 8> eng; // real bounds, matching RTL exactly

    FILE* f = std::fopen(out_path, "w");
    if (f == nullptr) {
        std::fprintf(stderr, "failed to open %s for writing\n", out_path);
        return 1;
    }

    std::fprintf(f, "order_id,side,price,qty,rejected,trade_qty,trade_price,trade_id\n");
    for (const auto& o : workload) {
        const auto r = eng.submit_limit_order(o.order_id, o.side, o.price, o.qty);
        std::fprintf(f, "%llu,%d,%d,%u,%d,%u,%d,%llu\n", static_cast<unsigned long long>(o.order_id),
                     static_cast<int>(o.side), o.price, o.qty, r.rejected ? 1 : 0, r.total_filled_qty,
                     r.last_trade_price, static_cast<unsigned long long>(r.last_trade_id));
    }

    std::fclose(f);
    std::fprintf(stderr, "wrote %zu orders to %s\n", kIterations, out_path);
    return 0;
}
