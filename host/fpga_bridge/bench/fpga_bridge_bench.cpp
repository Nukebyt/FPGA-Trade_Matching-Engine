// Real-hardware benchmark for fpga_matching_core, driven through
// fpga_bridge.hpp's /dev/mem harness. Deliberately reuses the exact same
// generate_workload() as
// host/bounded_matching_engine/bench/bounded_matching_engine_bench.cpp
// (same seed, same distribution) so this run's trades/reject-rate are
// directly comparable to that ARM/x86/QEMU C++-reference run
// (fpga_docs/bugs.md #4/#6) - same order sequence in, so the resulting
// order-book states and trades should match, not just the timing
// methodology. Copied rather than shared via a common header, matching
// this project's existing "self-contained equivalent per binary" choice
// (see that file's own top comment) - this one also needs to build
// standalone for the ARM cross-compiler with no extra include paths.
//
// Reports two latency numbers per Phase 26's planned four-way comparison
// (fpga-roadmap.md):
//   - fabric-internal: fpga_matching_core's own LATENCY_CYCLES register,
//     core_clk cycles from START accept to DONE (currently core_clk ==
//     avs_clk == CLOCK_50 = 50MHz nominal, no TimeQuest-closed Fmax yet -
//     see fpga_docs/bugs.md and roadmap Phase 23/24 notes)
//   - HPS-observed round-trip: wall-clock ns/event around the whole
//     submit_limit_order() call, i.e. the honest "if you deployed this"
//     number including the LWH2F bridge/MMIO hop
#include <algorithm>
#include <chrono>
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

// See bounded_matching_engine_bench.cpp for the full history of why this
// generator looks the way it does (offset +-3, mid clamped to +-50 band)
// - not repeated here, that file is the source of truth for the
// reasoning, this is a byte-for-byte copy of the resulting generator.
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

// Phase 26 (fpga-roadmap.md) needs mean/median/p50/p99 for both numbers
// this harness produces - fabric-internal latency (row 3) and
// HPS-observed round-trip (row 4) - not just the aggregate means this
// file used to report alone.
struct LatencyStats {
    double mean;
    double median;
    double p99;
};

template <typename T>
LatencyStats compute_stats(std::vector<T>& samples) {
    std::sort(samples.begin(), samples.end());
    const std::size_t n = samples.size();
    double sum = 0.0;
    for (T v : samples) sum += static_cast<double>(v);
    const double mean = sum / static_cast<double>(n);
    const double median = static_cast<double>(samples[n / 2]);
    const double p99 = static_cast<double>(samples[static_cast<std::size_t>(0.99 * static_cast<double>(n - 1))]);
    return LatencyStats{mean, median, p99};
}

} // namespace

int main() {
    constexpr std::size_t kIterations = 1'000'000;
    const auto workload = generate_workload(kIterations, /*seed=*/42);

    FpgaMatchingCore core; // opens/mmaps /dev/mem - throws on failure (e.g. not running as root)

    uint64_t total_filled = 0;
    uint64_t reject_count = 0;
    std::vector<uint32_t> latency_cycles_samples;
    std::vector<double> round_trip_ns_samples;
    latency_cycles_samples.reserve(kIterations);
    round_trip_ns_samples.reserve(kIterations);

    const auto start = std::chrono::steady_clock::now();
    for (const auto& o : workload) {
        const auto t0 = std::chrono::steady_clock::now();
        const auto result = core.submit_limit_order(o.order_id, o.side, o.price, o.qty);
        const auto t1 = std::chrono::steady_clock::now();
        round_trip_ns_samples.push_back(std::chrono::duration<double, std::nano>(t1 - t0).count());
        total_filled += result.trade_qty;
        if (result.rejected) ++reject_count;
        latency_cycles_samples.push_back(result.latency_cycles);
    }
    const auto end = std::chrono::steady_clock::now();

    const double elapsed_ns = std::chrono::duration<double, std::nano>(end - start).count();
    const double ns_per_event = elapsed_ns / static_cast<double>(kIterations);
    const double events_per_sec = 1e9 / ns_per_event;
    const double reject_pct = 100.0 * static_cast<double>(reject_count) / static_cast<double>(kIterations);
    constexpr double kNominalClockNs = 20.0; // CLOCK_50 = 50MHz, avs_clk == core_clk in this pass

    const LatencyStats cycle_stats = compute_stats(latency_cycles_samples);
    const LatencyStats round_trip_stats = compute_stats(round_trip_ns_samples);

    std::printf("fpga_matching_core<16,8> real hardware, mixed workload, %zu events\n", kIterations);
    std::printf("  HPS-observed round-trip (host wall clock, row 4):\n");
    std::printf("    total time:      %.3f ms (aggregate timer, %.2f ns/event)\n", elapsed_ns / 1e6,
                 ns_per_event);
    std::printf("    events/sec:      %.0f\n", events_per_sec);
    std::printf("    per-event mean:  %.2f ns\n", round_trip_stats.mean);
    std::printf("    per-event p50:   %.2f ns\n", round_trip_stats.median);
    std::printf("    per-event p99:   %.2f ns\n", round_trip_stats.p99);
    std::printf("  fabric-internal (fpga_matching_core's own LATENCY_CYCLES register, row 3):\n");
    std::printf("    mean cycles:     %.2f (%.2f ns at nominal 50MHz)\n", cycle_stats.mean,
                 cycle_stats.mean * kNominalClockNs);
    std::printf("    p50 cycles:      %.2f (%.2f ns at nominal 50MHz)\n", cycle_stats.median,
                 cycle_stats.median * kNominalClockNs);
    std::printf("    p99 cycles:      %.2f (%.2f ns at nominal 50MHz)\n", cycle_stats.p99,
                 cycle_stats.p99 * kNominalClockNs);
    std::printf("  total filled qty:  %llu\n", static_cast<unsigned long long>(total_filled));
    std::printf("  rejected:          %llu / %zu (%.3f%%)\n", static_cast<unsigned long long>(reject_count),
                 kIterations, reject_pct);

    return 0;
}
