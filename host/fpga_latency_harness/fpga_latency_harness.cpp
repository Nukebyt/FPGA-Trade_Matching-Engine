// Phase 27 (fpga-roadmap.md): long-running rolling-window comparison
// harness. Runs on the DE10's ARM cores (needs /dev/mem for the real
// FPGA), continuously drives the SAME synthetic ADD_ORDER stream through
// both row 2 (BoundedMatchingEngine, ARM software reference) and rows
// 3/4 (FpgaMatchingCore, real hardware - fabric-internal latency and
// HPS round-trip), and every kWindowMs writes a JSON snapshot of that
// window's mean/p50/p99/reject-rate to a fixed local path.
//
// Deliberately does NOT link Kafka directly - see the architecture
// decision in fpga-roadmap.md Phase 27: no ARM cross-compile of
// librdkafka exists in this project, so a separate x86-side forwarder
// (low_latency_trading_infra/fpga-latency/) pulls this snapshot over
// SSH and republishes it to the real `fpga-latency` Kafka topic and the
// `fpga_latency:latest` Redis key. This binary's only job is producing
// a correct, fresh snapshot file - same "self-contained equivalent per
// binary" convention as fpga_bridge_bench.cpp/gen_trace.cpp (no shared
// header with the git-tracked project, this whole host/ tree is
// deliberately outside it).
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <fstream>
#include <random>
#include <vector>

#include "bounded_matching_engine/bounded_matching_engine.hpp"
#include "fpga_bridge/fpga_bridge.hpp"

using fpga_bridge::FpgaMatchingCore;
using fpga_ref::BoundedMatchingEngine;

namespace {

constexpr int kWindowMs = 500; // matches this project's established Redis/broadcast cadence
constexpr const char* kSnapshotPath = "/tmp/fpga_latency_snapshot.json";
constexpr const char* kSnapshotTmpPath = "/tmp/fpga_latency_snapshot.json.tmp";

volatile std::sig_atomic_t g_stop = 0;
void handle_signal(int) { g_stop = 1; }

struct SyntheticOrder {
    uint64_t order_id;
    fpga_ref::Side ref_side;
    fpga_bridge::Side fpga_side;
    int32_t price;
    uint32_t qty;
};

// Same generator shape as gen_trace.cpp/fpga_bridge_bench.cpp/
// bounded_matching_engine_bench.cpp (seed=42, mid-band random walk) -
// but called incrementally forever rather than pre-generating a fixed
// 1M-order vector, since this process is long-running.
class WorkloadStream {
   public:
    explicit WorkloadStream(uint64_t seed) : rng_(seed) {}

    SyntheticOrder next() {
        mid_ += mid_walk_dist_(rng_);
        if (mid_ > kMidCenter + kMidBand) mid_ = kMidCenter + kMidBand;
        if (mid_ < kMidCenter - kMidBand) mid_ = kMidCenter - kMidBand;
        const bool is_buy = side_dist_(rng_) == 0;
        const int32_t price = mid_ + offset_dist_(rng_);
        const uint32_t qty = qty_dist_(rng_);
        return SyntheticOrder{++next_id_, is_buy ? fpga_ref::Side::kBuy : fpga_ref::Side::kSell,
                               is_buy ? fpga_bridge::Side::kBuy : fpga_bridge::Side::kSell, price, qty};
    }

   private:
    static constexpr int32_t kMidCenter = 10000;
    static constexpr int32_t kMidBand = 50;

    std::mt19937_64 rng_;
    std::uniform_int_distribution<int> side_dist_{0, 1};
    std::uniform_int_distribution<int32_t> offset_dist_{-3, 3};
    std::uniform_int_distribution<int32_t> mid_walk_dist_{-2, 2};
    std::uniform_int_distribution<uint32_t> qty_dist_{1, 500};
    int32_t mid_ = kMidCenter;
    uint64_t next_id_ = 0;
};

struct WindowStats {
    double mean = 0.0;
    double p50 = 0.0;
    double p99 = 0.0;
};

template <typename T>
WindowStats compute_stats(std::vector<T>& samples) {
    if (samples.empty()) return WindowStats{};
    std::sort(samples.begin(), samples.end());
    const std::size_t n = samples.size();
    double sum = 0.0;
    for (T v : samples) sum += static_cast<double>(v);
    return WindowStats{sum / static_cast<double>(n), static_cast<double>(samples[n / 2]),
                        static_cast<double>(samples[static_cast<std::size_t>(0.99 * static_cast<double>(n - 1))])};
}

// Atomic-enough for this purpose: write to a .tmp path, then rename()
// over the real path - the forwarder never observes a half-written
// file, since rename() on the same filesystem is a single directory-
// entry update, not a byte-by-byte copy.
void write_snapshot(uint64_t window_end_unix_ns, uint64_t sample_count, const WindowStats& row2,
                     double row2_reject_pct, const WindowStats& row3_cycles, const WindowStats& row4_ns,
                     double row34_reject_pct) {
    std::ofstream out(kSnapshotTmpPath, std::ios::trunc);
    if (!out) return;
    out << "{"
        << "\"window_end_unix_ns\":" << window_end_unix_ns << ","
        << "\"sample_count\":" << sample_count << ","
        << "\"row2_mean_ns\":" << row2.mean << ","
        << "\"row2_p50_ns\":" << row2.p50 << ","
        << "\"row2_p99_ns\":" << row2.p99 << ","
        << "\"row2_reject_pct\":" << row2_reject_pct << ","
        << "\"row3_mean_cycles\":" << row3_cycles.mean << ","
        << "\"row3_p50_cycles\":" << row3_cycles.p50 << ","
        << "\"row3_p99_cycles\":" << row3_cycles.p99 << ","
        << "\"row4_mean_ns\":" << row4_ns.mean << ","
        << "\"row4_p50_ns\":" << row4_ns.p50 << ","
        << "\"row4_p99_ns\":" << row4_ns.p99 << ","
        << "\"row34_reject_pct\":" << row34_reject_pct << "}";
    out.close();
    std::rename(kSnapshotTmpPath, kSnapshotPath);
}

} // namespace

int main() {
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    BoundedMatchingEngine<16, 8> row2_engine;
    FpgaMatchingCore fpga_core; // throws on failure to mmap /dev/mem (e.g. not running as root)
    WorkloadStream stream(/*seed=*/42);

    std::vector<double> row2_ns_samples;
    std::vector<uint32_t> row3_cycle_samples;
    std::vector<double> row4_ns_samples;
    uint64_t row2_rejects = 0, row34_rejects = 0, window_count = 0;

    std::printf("fpga_latency_harness: running, writing %s every %dms (Ctrl+C to stop)\n", kSnapshotPath,
                kWindowMs);

    auto window_start = std::chrono::steady_clock::now();
    while (!g_stop) {
        const SyntheticOrder o = stream.next();

        const auto r2_t0 = std::chrono::steady_clock::now();
        const auto r2_result = row2_engine.submit_limit_order(o.order_id, o.ref_side, o.price, o.qty);
        const auto r2_t1 = std::chrono::steady_clock::now();
        row2_ns_samples.push_back(std::chrono::duration<double, std::nano>(r2_t1 - r2_t0).count());
        if (r2_result.rejected) ++row2_rejects;

        const auto r34_t0 = std::chrono::steady_clock::now();
        const auto fpga_result = fpga_core.submit_limit_order(o.order_id, o.fpga_side, o.price, o.qty);
        const auto r34_t1 = std::chrono::steady_clock::now();
        row4_ns_samples.push_back(std::chrono::duration<double, std::nano>(r34_t1 - r34_t0).count());
        row3_cycle_samples.push_back(fpga_result.latency_cycles);
        if (fpga_result.rejected) ++row34_rejects;

        ++window_count;

        const auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - window_start).count() >= kWindowMs) {
            const WindowStats row2_stats = compute_stats(row2_ns_samples);
            const WindowStats row3_stats = compute_stats(row3_cycle_samples);
            const WindowStats row4_stats = compute_stats(row4_ns_samples);
            const double row2_reject_pct =
                100.0 * static_cast<double>(row2_rejects) / static_cast<double>(window_count);
            const double row34_reject_pct =
                100.0 * static_cast<double>(row34_rejects) / static_cast<double>(window_count);
            const uint64_t window_end_unix_ns = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::system_clock::now().time_since_epoch())
                    .count());

            write_snapshot(window_end_unix_ns, window_count, row2_stats, row2_reject_pct, row3_stats, row4_stats,
                            row34_reject_pct);

            std::printf(
                "[window] n=%llu row2 mean=%.0fns p99=%.0fns reject=%.1f%% | row3 mean=%.1fcyc | row4 "
                "mean=%.0fns reject=%.1f%%\n",
                static_cast<unsigned long long>(window_count), row2_stats.mean, row2_stats.p99, row2_reject_pct,
                row3_stats.mean, row4_stats.mean, row34_reject_pct);

            row2_ns_samples.clear();
            row3_cycle_samples.clear();
            row4_ns_samples.clear();
            row2_rejects = 0;
            row34_rejects = 0;
            window_count = 0;
            window_start = now;
        }
    }

    std::printf("fpga_latency_harness: stopping\n");
    return 0;
}
