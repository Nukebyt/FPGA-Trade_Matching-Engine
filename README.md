# FPGA Trade Matching Engine

A hardware limit-order matching engine for one instrument, built in
hand-written SystemVerilog (no HLS) for an Intel DE10-Standard board
(Cyclone V SoC, `5CSXFC6D6F31C6`), running real trading-engine logic on
real fabric — not a toy demo.

This is a hardware extension of
**[Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)**,
a 19-phase C++ software trading-infrastructure project (market
simulator, feed handler, order book, matching engine, risk engine,
Kafka/Postgres/Redis, REST/gRPC/WebSocket API, React dashboard). That
project's matching engine is deliberately unbounded (`std::map`-backed);
this repo asks what changes when the same problem is solved in
dedicated parallel hardware instead, and measures the answer on real
silicon rather than assuming it.

## C++ vs. FPGA: the real numbers

Real, measured, on real hardware — not simulated or projected. Every
number below is from the same 1,000,000-order trace (`seed=42`), same
`N_LEVELS=16`/`M_ORDERS=8` bounds, so rows are directly comparable to
each other (full methodology, including a real ARM measurement-overhead
finding, in [`docs/fpga-performance.md`](docs/fpga-performance.md)).

### Per-event latency

| # | Engine | Platform | Mean | p50 | p99 | Reject rate |
|---|---|---|---|---|---|---|
| 1 | C++, unbounded `std::map` | x86 dev machine | ~245 ns | n/a¹ | n/a¹ | n/a¹ |
| 2 | C++, bounded (same N/M as FPGA) | DE10 ARM Cortex-A9, native | 1863.39 ns | 1820.00 ns | 2760.00 ns | 72.359% |
| 3 | SystemVerilog, fabric-internal | DE10 Cyclone V fabric | **256.31 ns** (12.82 cycles) | 240.00 ns | 480.00 ns | 73.555%² |
| 4 | Same core, full HPS round-trip | ARM → LWH2F → fabric → ARM | 6341.75 ns | 6320.00 ns | 6420.00 ns | 73.555%² |

¹ Different workload generator (full ADD/MODIFY/CANCEL mix, not the
ADD-only synthetic trace rows 2-4 share) and an unbounded book — context
only, not head-to-head; see `docs/fpga-performance.md`'s Row 1 caveat.
² Rows 3/4 are the same hardware run, so they share one reject count.

**Reading this table correctly is the whole point**: row 3 vs. row 2 is
the fair, apples-to-apples hardware-vs-software result — the FPGA's
matching computation is **~7.3x faster**. But row 4, the honest "if you
deployed this today" number including the register-interface round
trip, is **~3.4x *slower* than row 2** — the single-order-at-a-time
`STATUS.BUSY`-polling interface between the ARM cores and the fabric
dominates and erases the fabric's own speed advantage. Hardware wins the
computation decisively and loses the deployed system, for a completely
identified, non-mysterious reason (the interface, not the matching
logic — see [`docs/fpga-matching-engine.md`](docs/fpga-matching-engine.md)).

### Throughput ceiling

| | Derived from | Events/sec |
|---|---|---|
| Core alone (fabric compute) | Row 3 mean | **~3.90M** |
| Deployed system (core + register interface) | Row 4 mean | **~157.7K** |

The interface, not the fabric, is the system's real bottleneck — by
~24.75x. See `docs/fpga-performance.md`'s Phase 29 section for the named
follow-up (a request queue in the register map) this points to.

### Resource utilization (Cyclone V `5CSXFC6D6F31C6`, 41,910 ALM budget)

| | Standalone core only | Full integrated system (HPS + Platform Designer) |
|---|---|---|
| ALMs | 9,040 (22%) | 10,688 (26%) |
| Registers | not separately reported | 15,358 |
| RAM blocks | 0 / 553 (0%) | 6 / 553 (1%)³ |
| DSP blocks | 0 / 112 (0%) | 0 / 112 (0%) |

³ Still **zero** from the order book itself, confirmed not assumed —
its parallel-access pattern structurally can't target block RAM's 1-2
ports. The 6 blocks come from the surrounding HPS/DDR3 plumbing.

### Timing closure

| | Worst-case setup slack (`CLOCK_50`) | TNS (all corners) |
|---|---|---|
| Before fix (single-cycle reduction) | **-47.6 ns** | tens of thousands of ns |
| After fix (pipelined reduction) | **+5.157 ns** | **0.000** |

A real synthesizability bug, not a rounding error — full root cause in
`fpga_docs/bugs.md` #13 and the "what actually broke" writeup in
[`docs/ADR-007-fpga-bounded-order-book.md`](docs/ADR-007-fpga-bounded-order-book.md)'s
Amendment section.

## Why a bounded book, and why that's the right hardware answer

Software's `std::map`-backed book grows to whatever the workload needs;
an FPGA has no heap — every comparator and storage slot must be sized at
synthesis time. Rather than treat that as a limitation to work around,
this design leans into it: **N=16 price levels, M=8 resting orders per
level, evaluated in parallel** by dedicated comparator hardware instead
of walked one at a time by a single ALU. The full reasoning, the
bounded-book's real consequences (a structural ~72-73% reject rate under
sustained load — not a bug, a named, measured tradeoff), and what
changed between the original plan and what actually got built are all
in [`docs/ADR-007-fpga-bounded-order-book.md`](docs/ADR-007-fpga-bounded-order-book.md).

## Repository layout

```
rtl/                          Hand-written SystemVerilog source (source of truth)
  bounded_order_book.sv         The core: N-level parallel book + pipelined
                                 best-price reduction (registered binary tree)
  fpga_matching_core.sv         Avalon-MM register-map wrapper, avs_clk/core_clk CDC
  cdc_pulse_sync.sv             Two-flop clock-domain-crossing synchronizer

sim/                           Questa testbenches (real source, not generated)
  tb_fpga_matching_core.sv        14 directed test cases
  tb_bounded_order_book_multilevel.sv   Multi-level-walk sweep
  tb_trace_replay*.sv             1,000,000-order trace replay vs. a C++ reference
  sim.do                           Questa driver script

host/                          C++ host software (cross-compiles for the DE10's ARM cores)
  bounded_matching_engine/        Software reference impl, same N/M bounds
  fpga_bridge/                    /dev/mem mmap driver + benchmark harness
  fpga_latency_harness/           Continuous 4-way latency sampler -> JSON snapshot

ip/fpga_matching_core/         Platform Designer (Qsys) component definition
soc_system.qsys                Full HPS + DDR3 + fpga_matching_core system
soc_system/                    qsys-generate output (committed - see note below)
hps_isw_handoff/                HPS preloader/BSP handoff files (committed - see note below)

DE10_Standard_golden_top.{v,qsf,sdc,qpf}   Top-level board project
platform_setup.tcl             Pin/IO assignments (Terasic-provided)
*.tcl                          Build-flow driver scripts (see Building below)

output_files/                  Real quartus_fit/quartus_sta/quartus_asm output —
                                the actual verified .sof and every timing/resource
                                report referenced in docs/, committed rather than
                                left to regeneration (see Building below)
synth_check/                   Standalone core-only synthesis check (Phase 22's
                                pre-integration resource baseline) — its own small
                                Quartus sub-project, reports committed

docs/                          FPGA-side documentation (synced from the software
                                repo where noted; each file says which way)
fpga_docs/                     bugs.md (every real bug found, #1-13) and
                                interview-questions.md

software-integration/          Reference copies of the code that connects this
                                core to the software project's live stack —
                                see software-integration/README.md
```

**Why `soc_system/` and `hps_isw_handoff/` are committed even though
they're tool-generated**: regenerating them (`qsys-generate` +
Quartus's HPS SDRAM pin-assignment step) hit real, documented Intel
toolchain bugs during this project's own development —
`fpga_docs/bugs.md` #8 (5 `.qip` entries silently regress on every
regeneration) and #9 (1449 termination errors from a post-generation
step that's easy to miss). Committing the known-good output avoids
requiring every clone to rediscover and re-fix both. The one hand-edited
file inside `soc_system/`'s generated tree
(`soc_system/synthesis/submodules/rtl/*.sv`) is a byte-for-byte synced
copy of `rtl/*.sv` — Quartus compiles the RTL from that path, not the
top-level one, a real quirk of how this project's `.qsf` references it;
**both copies must be kept in sync by hand** if you edit `rtl/`.

## Building

Requires Quartus Prime **21.1.0** (Lite, build 842) targeting Cyclone V,
and Siemens Questa (developed against **2024.1**) for simulation.

**Simulate first** (no board or Quartus build needed). `sim/sim.do` runs
the 14 directed test cases:
```
cd sim
vsim -c -do sim.do
```
The multi-level (`tb_bounded_order_book_multilevel.sv`) and trace-replay
(`tb_trace_replay.sv`, `tb_trace_replay_wrapper.sv`) testbenches don't
have their own committed `.do` scripts yet (they were run ad hoc during
development) — compile/run them the same way, e.g.:
```
vlib work
vlog -sv ../rtl/cdc_pulse_sync.sv ../rtl/bounded_order_book.sv ../rtl/fpga_matching_core.sv tb_trace_replay_wrapper.sv
vsim -c work.tb_trace_replay_wrapper
run -all
```
The trace-replay testbenches read `sim/trace.csv` (the 1,000,000-order
test vector, ~27MB), which is not committed — it's deterministic
(seed=42, hardcoded in `gen_trace.cpp`, not a CLI argument) and
regenerates via:
```
g++ -O2 -std=c++17 -I host/bounded_matching_engine/include \
    host/fpga_bridge/tools/gen_trace.cpp -o gen_trace
./gen_trace 1000000 sim/trace.csv
```

**Synthesize the full board project**:
```
quartus_map DE10_Standard_golden_top
quartus_fit DE10_Standard_golden_top
quartus_asm DE10_Standard_golden_top
quartus_sta DE10_Standard_golden_top
```
Regenerating `soc_system.qsys` (`qsys-generate`) is only needed if you
change the Platform Designer system itself — see the toolchain-bug note
above before doing so, and re-run
`apply_hps_sdram_pin_assignments.tcl` afterward (Quartus's own
`qsys-generate` log names this step explicitly; skipping it is what
caused bug #9).

**Programming the board** (`quartus_pgm`) is not something this README
walks through as a one-liner — treat it with real care. This project's
own development hit two board-hang incidents from an under-verified RTL
change reaching hardware (`fpga_docs/bugs.md` #11/#12) before the actual
root cause was found; simulate and check `quartus_sta` slack first,
every time.

## Documentation

- [`docs/fpga-matching-engine.md`](docs/fpga-matching-engine.md) — start
  here: scope, register map, the matching algorithm and the real
  synthesizability bug that changed it, clock domains, full measured
  results, the backend/frontend integration chain, and every known open
  gap named explicitly.
- [`docs/ADR-007-fpga-bounded-order-book.md`](docs/ADR-007-fpga-bounded-order-book.md) —
  the bounded-book design decision, with an amendment covering
  everything that changed between the plan and what was actually built.
- [`docs/fpga-performance.md`](docs/fpga-performance.md) — full
  hardware-vs-software results tables and resource/timing/throughput
  numbers (Phases 26 and 29).
- [`docs/fpga-roadmap.md`](docs/fpga-roadmap.md) — the phase-by-phase
  checklist (20-30) this work was tracked against, including every
  detour and dead end, not just the parts that worked.
- [`fpga_docs/bugs.md`](fpga_docs/bugs.md) — every real bug found during
  the build, numbered #1-13, each with root cause and fix, not just a
  changelog entry.

## Status

Phases 20-24 and 26-29 (of a 20-30 checklist) are done, verified in
simulation and on real hardware. Two items remain open by choice, not
oversight: Phase 25 (SignalTap capture) was skipped — it needs another
GUI-driven rebuild+reflash cycle and the bug it would have investigated
turned out to have a different, already-found root cause; and a small
(~1 percentage point) reject-rate gap between hardware and the software
reference remains unexplained, with a named leading suspect. Both are
detailed in [`docs/fpga-matching-engine.md`](docs/fpga-matching-engine.md#known-open-gaps).

## License

No license file is present in the upstream
[Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)
project either; this repo follows the same as-is stance until that
changes. Both projects are educational, not production trading systems.
