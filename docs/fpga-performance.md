# FPGA vs. Software Matching-Engine Performance (Phase 26)

> **Note on this copy**: synced from
> [Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)'s
> `docs/fpga-performance.md` (source of truth if the two drift).
> `fpga_docs/bugs.md` references below are local to this repo — see
> [fpga_docs/bugs.md](../fpga_docs/bugs.md).

Four rows, deliberately kept separate rather than collapsed into one
headline number (see `fpga-roadmap.md`'s own framing): the unbounded x86
engine is context only, not a fair comparison against the bounded
FPGA/ARM rows (different scope — see ADR-007). Rows 2-4 replay the
*identical* order sequence (`generate_workload(seed=42)`, 1,000,000
ADD_ORDER events, same bounded N_LEVELS=16/M_ORDERS=8 semantics) so they
are directly comparable to each other.

## The four rows

| # | Measures | Platform | Compare against |
|---|---|---|---|
| 1 | x86 dev-machine, unbounded `std::map` | Windows dev machine | context only |
| 2 | ARM (HPS), bounded C++ reference | DE10 Cortex-A9, native | baseline for row 3 |
| 3 | FPGA fabric-internal latency | DE10 Cyclone V fabric | direct vs. row 2 |
| 4 | FPGA HPS-observed round-trip | DE10 Cortex-A9 → LWH2F → fabric → back | the honest deployed-today number |

## Results

| # | Mean | p50 (median) | p99 | Reject rate |
|---|---|---|---|---|
| 1 | ~245 ns/event (`BM_RealisticMixedWorkload`) | not captured — see note | not captured — see note | n/a (unbounded book) |
| 2 | 1863.39 ns/event | 1820.00 ns | 2760.00 ns | 72.359% |
| 3 | 256.31 ns (12.82 cycles @ nominal 50MHz) | 240.00 ns (12 cycles) | 480.00 ns (24 cycles) | 73.555%* |
| 4 | 6341.75 ns/event | 6320.00 ns | 6420.00 ns | 73.555%* |

\* Rows 3/4 come from the same hardware run, so they share one reject
count.

Row 2's reject rate (72.359%) and row 3/4's (73.555%) both replay the
identical seed=42 trace and should, on a perfectly-behaving FPGA, match
exactly and match the 72.4% C++-reference figure from Phase 21. The
~1.2-point residual gap between rows 2/3-4 is real, known, and
deliberately left open — see `fpga_docs/bugs.md` #13's "still open"
section (leading suspect: `reset_reset_n` still tied permanently high,
the power-on-reset fix from bug #11/#12 was reverted and never
revisited). It is *not* run-to-run noise from this benchmark alone:
successive hardware runs this session showed 73.365% and 73.555% on two
back-to-back invocations without a fresh JTAG reconfigure between them —
that ~0.2-point spread is most likely leftover book state from the prior
run (the board wasn't power-cycled/reconfigured between benchmark
invocations, so the second run didn't start from a genuinely empty
book), not additional evidence of nondeterminism on top of the
already-documented gap.

## A real measurement-methodology finding, not hidden

Rows 2 and 4 both instrument *every individual order* with
`std::chrono::steady_clock::now()` immediately before and after the call
being measured, to get real per-event percentiles instead of one
aggregate mean. Doing this changed the reported **aggregate** ns/event
number substantially on this specific ARM target:

| | Aggregate ns/event, no per-call instrumentation (earlier this session) | Aggregate ns/event, with per-call `now()` added |
|---|---|---|
| Row 2 (bounded C++, ARM) | 589.82 | 3134.60 |
| Row 4 (FPGA round-trip, ARM) | 5563.59 | 7209.23 |

The difference (~2545 ns/event for row 2, ~1646 ns/event for row 4) is
the cost of the `chrono::steady_clock::now()` calls themselves. That's
far larger than the ~20-50 ns a vDSO-accelerated `clock_gettime` costs
on a typical x86 Linux box — the working theory is this specific board's
kernel/libc combination doesn't have a fast vDSO path for
`CLOCK_MONOTONIC` on this Cortex-A9, so each call is a real syscall
(context-switch cost). Not independently confirmed (would need
`strace`/`perf` on the board to prove), but consistent with the
magnitude and with both rows showing the same directional effect.
Reported honestly rather than hidden or silently used to inflate the
"real" per-event numbers — matches this project's established practice
(see the QEMU-timing caution in `fpga_docs/bugs.md` #6 for the same
kind of "the measurement method itself has a cost, name it" finding).
The **p50/p99 numbers above include this instrumentation tax** baked
into every sample; the **aggregate mean without per-call instrumentation**
(589.82 ns row 2, 5563.59 ns row 4) is the cleaner throughput figure if
you need one number un-inflated by measurement overhead.

Row 3 (fabric-internal `LATENCY_CYCLES`) is unaffected by any of this —
it's read from the FPGA's own register, not measured by host-side
`chrono` calls, so its mean/p50/p99 are clean.

## Row 1 caveat

Row 1's number is the existing `BM_RealisticMixedWorkload` result from
Phase 17's `matching_engine_bench.cpp` (Google Benchmark, different
workload generator — full ADD/MODIFY/CANCEL mix via `EventGenerator`,
not the ADD-only synthetic generator rows 2-4 share, since the unbounded
engine supports operations the bounded one deliberately doesn't per
ADR-007's scope limit). It was not independently re-run or
re-instrumented this session — no p50/p99 exists for it in this
project's history, since Google Benchmark's macro-based timing loop
doesn't expose per-iteration latencies the way rows 2-4's manual
`chrono` harnesses do. Re-running row 1 with matching per-event
instrumentation (mirroring rows 2-4's methodology) is a reasonable
follow-up if a rigorous row-1 comparison is ever needed, but the
roadmap's own framing ("context only, not head-to-head") means it
wasn't prioritized this session.

## Takeaways

- **Row 3 vs. row 2 (the real hardware-vs-software comparison, same
  bounds, same trace):** FPGA fabric-internal latency (256 ns mean) is
  roughly **7.3x faster** than the ARM software reference (1863 ns
  mean) — and that's *after* the timing-closure fix in bug #13; before
  it, the FPGA wasn't meeting its own 50MHz timing budget at all, so
  this number wouldn't have meant anything.
- **Row 4 (the honest "if you deployed this today" number)** is
  *slower* than row 2, not faster — 6342 ns vs. 1863 ns mean. The LWH2F
  bridge/MMIO round-trip (plus this ARM target's apparent syscall-cost
  `chrono` tax) dominates and erases the fabric's own speed advantage
  at these order-submission rates. This is the real, load-bearing
  reason rows 3 and 4 are kept separate rather than collapsed into one
  "FPGA is N times faster" headline: which one is true depends entirely
  on whether the bottleneck you care about is the matching computation
  itself (row 3) or the whole deployed path (row 4).
- The bounded book's reject rate (~72-73% across rows 2/3/4) is a real,
  structural cost of N_LEVELS=16/M_ORDERS=8 with no CANCEL support
  (ADR-007), not a red flag — expected and already root-caused in
  `fpga_docs/bugs.md` #4.

## Phase 29: resource utilization, timing closure, and throughput ceiling

### Resource utilization — full integrated system vs. standalone core

Two real, distinct fitter runs exist for this design, at two different
integration stages. Reporting both, not just the newer one, because the
delta between them is itself informative (it isolates what the HPS
bridge/Platform Designer plumbing costs, separate from the matching core
itself):

| | Standalone core only (Phase 22) | Full integrated system (current, post bug-#13 timing fix) |
|---|---|---|
| Device | 5CSXFC6D6F31C6 | 5CSXFC6D6F31C6 |
| ALMs | 9,040 / 41,910 (22%) | 10,688 / 41,910 (26%) |
| Total registers | not separately reported | 15,358 |
| RAM blocks | 0 / 553 (0%) | 6 / 553 (1%) |
| Block memory bits | 0 | 2,816 / 5,662,720 (<1%) |
| DSP blocks | 0 / 112 (0%) | 0 / 112 (0%) |
| Total pins | n/a (no board I/O, standalone sub-project) | 338 / 499 (68%) |
| PLLs / DLLs | 0 / 0 | 0 / 15, 1 / 4 DLL |

Both numbers are real `quartus_fit` output, not estimates — the
standalone figure from a dedicated `synth_check/` sub-project (Phase 22,
no pins/SDC), the full-system figure from the actual board project's
`output_files/DE10_Standard_golden_top.fit.summary`, timestamped after
bug #13's pipelined-reduction fix (matches the currently-flashed `.sof`).

**The delta (~1,648 ALMs, ~4 percentage points, 6 RAM blocks) is HPS
bridge/Platform Designer plumbing, not the order book.** The order
book's 0%-BRAM finding from Phase 22 (`fpga_docs/bugs.md` #3 — the
parallel-access pattern structurally can't target embedded RAM, since
every level/slot needs simultaneous access and BRAM only offers 1-2
ports) still holds in the full-system build: `fpga_matching_core` itself
contributes 0 of the 6 RAM blocks now visible in the full-system report.
Those 6 come from the surrounding Qsys system (`soc_system.qsys` — the
HPS SDRAM PHY / bridge-side FIFOs Platform Designer inserts automatically),
confirmed by the fact they weren't present in the standalone report,
where none of that plumbing exists yet.

### Timing closure — confirmed via the current multi-corner `.sta.summary`

Bug #13's fix (`fpga_docs/bugs.md` #13) is verified closed across every
corner Quartus checks, not just the one number originally chased:

| Corner | Setup slack (`CLOCK_50`) | TNS |
|---|---|---|
| Slow 1100mV 85C | +5.157 ns (was -47.6 ns pre-fix) | 0.000 |
| Slow 1100mV 0C | +5.348 ns | 0.000 |
| Fast 1100mV 85C | +11.305 ns | 0.000 |
| Fast 1100mV 0C | +12.136 ns | 0.000 |

TNS (total negative slack) is **0.000 at every corner, for every check
type** — setup, hold, recovery, removal, and minimum pulse width, on
`CLOCK_50`, the HPS SDRAM PLL's `afi_clk`/`pll_write_clk_dq_write_clk`,
and JTAG's `altera_reserved_tck` alike. This is a genuinely fully closed
design, not a single cherry-picked passing number.

### Throughput ceiling — bridge vs. core, using the real Phase 26 sustained-load run

Phase 26's 1,000,000-order hardware benchmark (`fpga_bridge_bench.cpp`)
is itself a real sustained-load test: a tight back-to-back loop with no
artificial pacing between orders (see that file — each iteration is
`submit_limit_order()` immediately followed by the next, timed with
`chrono` around the call). Re-running it wasn't necessary to answer
Phase 29's throughput-ceiling question; converting its existing per-row
means to steady-state throughput does:

| Row | Mean latency | Implied throughput ceiling |
|---|---|---|
| 3 — core (fabric-internal, `LATENCY_CYCLES`) | 256.31 ns/event | **~3.90M events/sec** |
| 4 — bridge (full HPS↔fabric round-trip via LWH2F/MMIO) | 6341.75 ns/event | **~157.7K events/sec** |

**The bridge is the throughput ceiling, not the core — by ~24.75x.**
The matching computation itself could sustain roughly 3.9M orders/sec if
fed directly (no host round-trip per order). The system as actually
deployable today is bottlenecked by the single-order-at-a-time, blocking
`/dev/mem`-mapped MMIO round trip through the HPS — not by the fabric's
own compute speed. This quantifies, rather than just states, the
qualitative finding in this doc's own Takeaways section above ("row 4 is
slower than row 2, the bridge dominates"): the bridge isn't merely
slower than the core, it is specifically *the* system-level ceiling, and
by a wide enough margin that closing it (e.g. a request queue/FIFO in
the register map so the host can pipeline multiple in-flight orders
instead of blocking on `STATUS.BUSY` per order) would be the highest-
leverage next optimization if this project ever pursued higher
deployed-today throughput — named here as a real, identified follow-up,
not attempted this session.

### Optional SD-card `.rbf` bake: not attempted

`fpga-roadmap.md`'s Phase 29 checklist marks this optional
(standalone-demo polish, no PC/JTAG attached). Re-imaging the physical
SD card is the same category of hard-to-reverse physical action as
JTAG-flashing the board, and wasn't requested — left undone rather than
attempted without being asked, consistent with this project's flashing-
safety practice throughout.
