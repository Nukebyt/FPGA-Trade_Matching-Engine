// Hand-rolled test runner (no GoogleTest dependency - deliberate: this
// sits outside low_latency_trading_infra's CMake/GTest setup, and a
// dependency-free program can be built and run with a single g++
// invocation in any environment, x86 dev machine or ARM target alike, a
// real requirement given this class is also headed for on-target
// benchmarking under a cross-compiler whose available package set isn't
// guaranteed yet). Same pass/fail-counter style as
// d10_standard_golden_top/sim/tb_fpga_matching_core.sv's testbench, and
// deliberately the SAME 14 scenarios in the SAME order, so this file and
// that one are a direct hardware/software cross-check on today's most
// important open question - does the C++ reference actually agree with
// the RTL - well before Phase 23's full trace-replay testbench exists.
#include <cstdio>
#include <cstdlib>

#include "bounded_matching_engine/bounded_matching_engine.hpp"

using fpga_ref::BoundedMatchingEngine;
using fpga_ref::Side;
using fpga_ref::SubmitResult;

namespace {

int g_passes = 0;
int g_errors = 0;

void check(const char* name, const SubmitResult& got, uint32_t exp_qty, int32_t exp_price, bool exp_rejected) {
    if (got.total_filled_qty != exp_qty || got.last_trade_price != exp_price || got.rejected != exp_rejected) {
        std::printf("[FAIL] %-28s got qty=%u price=%d rejected=%d | expected qty=%u price=%d rejected=%d\n",
                     name, got.total_filled_qty, got.last_trade_price, got.rejected, exp_qty, exp_price,
                     exp_rejected);
        ++g_errors;
    } else {
        std::printf("[PASS] %-28s qty=%u price=%d rejected=%d\n", name, got.total_filled_qty, got.last_trade_price,
                     got.rejected);
        ++g_passes;
    }
}

} // namespace

int main() {
    // Same N_LEVELS=4, M_ORDERS=2 override as tb_fpga_matching_core.sv,
    // for the same reason: makes the two overflow paths reachable with
    // a handful of directed orders.
    {
        BoundedMatchingEngine<4, 2> eng;

        // ---- Group A: resting add, price improvement, full consume+pop
        check("RestingAddNoCross", eng.submit_limit_order(1, Side::kBuy, 100, 10), 0, 0, false);
        check("PartialMatchPriceImprove", eng.submit_limit_order(2, Side::kSell, 95, 5), 5, 100, false);
        check("FullConsumeAndPop", eng.submit_limit_order(3, Side::kSell, 100, 5), 5, 100, false);
    }
    {
        BoundedMatchingEngine<4, 2> eng;

        // ---- Group B: multi-level walk in a single incoming order
        check("RestingAddOtherSide", eng.submit_limit_order(4, Side::kSell, 120, 5), 0, 0, false);
        check("RestingAddSecondLevel", eng.submit_limit_order(5, Side::kSell, 125, 5), 0, 0, false);
        check("CrossesTwoLevelsAggregate", eng.submit_limit_order(6, Side::kBuy, 130, 8), 8, 125, false);
    }
    {
        BoundedMatchingEngine<4, 2> eng;

        // ---- Group C: level-full (M_ORDERS) rejection, clean opposite side
        check("FillLevelSlot0", eng.submit_limit_order(7, Side::kBuy, 200, 1), 0, 0, false);
        check("FillLevelSlot1", eng.submit_limit_order(8, Side::kBuy, 200, 1), 0, 0, false);
        check("LevelFullReject", eng.submit_limit_order(9, Side::kBuy, 200, 1), 0, 0, true);
    }
    {
        BoundedMatchingEngine<4, 2> eng;

        // ---- Group D: book-full (N_LEVELS) rejection, clean opposite side
        check("OpenLevel0", eng.submit_limit_order(10, Side::kBuy, 100, 1), 0, 0, false);
        check("OpenLevel1", eng.submit_limit_order(11, Side::kBuy, 101, 1), 0, 0, false);
        check("OpenLevel2", eng.submit_limit_order(12, Side::kBuy, 102, 1), 0, 0, false);
        check("OpenLevel3", eng.submit_limit_order(13, Side::kBuy, 103, 1), 0, 0, false);
        check("BookFullReject", eng.submit_limit_order(14, Side::kBuy, 104, 1), 0, 0, true);
    }

    std::printf("=== SUMMARY: %d passed, %d failed ===\n", g_passes, g_errors);
    std::printf(g_errors == 0 ? "TEST PASSED\n" : "TEST FAILED\n");
    return g_errors == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
