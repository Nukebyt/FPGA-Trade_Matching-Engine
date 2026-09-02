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

Real, measured, on real hardware — not simulated or projected. The
table below compares three things running the **same** 1,000,000-order
trace (`seed=42`), the **same** `N_LEVELS=16`/`M_ORDERS=8` bounds, so
they're directly comparable to each other. (A fourth number — plain C++
on a desktop PC — is deliberately *not* in this table; see
[below](#the-245-ns-desktop-pc-number-and-why-its-not-in-the-table-above)
for why, and why comparing it directly to the FPGA row is misleading.)

### Plain-English summary

- **The FPGA chip itself is genuinely fast at the one thing it does**:
  finding the best price among 16 candidates. It checks all 16 at once,
  in parallel circuits, instead of one CPU checking them one at a time.
  That's row 3 below (**256 ns**) vs. row 2 (**1863 ns**) — the FPGA
  wins by ~7.3x on the actual computation.
- **But "talking to the FPGA" costs more than the FPGA saves.** Every
  order has to travel from the ARM processor, across a communication
  bus, into the chip, and the answer has to travel back — and the
  software has to sit there polling "are you done yet?" the whole time.
  That round trip (row 4, **6342 ns**) costs more than the entire
  software computation it was trying to speed up. It's like winning a
  100m sprint but losing so much time walking to the starting line and
  back that you'd have been better off not racing at all.
- **The lesson isn't "FPGAs are slow."** It's that *how* you talk to
  custom hardware matters as much as how fast the hardware itself is —
  and this project measured that gap instead of assuming it away. The
  named fix (letting the software hand the FPGA several orders at once
  instead of one-at-a-time-and-wait) is real, identified, and just not
  built yet — see the Throughput ceiling section below.

### Per-event latency

| # | Engine | Platform | Mean | p50 | p99 | Reject rate |
|---|---|---|---|---|---|---|
| 2 | C++, bounded (same N/M as FPGA) | DE10 ARM Cortex-A9, native | 1863.39 ns | 1820.00 ns | 2760.00 ns | 72.359% |
| 3 | SystemVerilog, fabric-internal | DE10 Cyclone V fabric | **256.31 ns** (12.82 cycles) | 240.00 ns | 480.00 ns | 73.555%¹ |
| 4 | Same core, full HPS round-trip | ARM → LWH2F → fabric → ARM | 6341.75 ns | 6320.00 ns | 6420.00 ns | 73.555%¹ |

¹ Rows 3/4 are the same hardware run, so they share one reject count.

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

### The 245 ns desktop-PC number, and why it's not in the table above

Earlier drafts of this README listed a fourth row: plain C++, unbounded
`std::map`, running on an ordinary x86 desktop/laptop — **~245 ns per
event**. It's a real, previously-measured number (Phase 17 of the
[software project](https://github.com/Nukebyt/Low-Latency-Trading-Exchange),
`BM_RealisticMixedWorkload`), but it doesn't belong in a head-to-head
table with the FPGA rows, for three separate, honest reasons:

1. **It's not the same test.** That benchmark replays a full
   ADD/MODIFY/CANCEL order mix on an *unbounded* book. Rows 2-4 above
   replay an ADD-only trace against a *bounded* 16-level book. Different
   code paths, different operation mix — not the same question.
2. **It's not the same class of CPU.** A desktop/laptop x86 chip runs at
   several GHz with deep pipelines, branch prediction, and large caches.
   The DE10 board's ARM Cortex-A9 is a small embedded core built for
   low power, not peak speed — it's simply a much slower chip *before*
   any FPGA is even involved. Comparing "FPGA round-trip on a phone-class
   ARM chip" against "plain C++ on a gaming desktop" mixes up two
   different questions: "is the algorithm/hardware faster?" and "is this
   specific embedded board's CPU faster than my desktop?" (it isn't,
   and was never expected to be).
3. **The 245 ns number never leaves the CPU core it runs on.** A C++
   function call reads and writes ordinary RAM/registers inside one
   chip. Row 4's 6342 ns, by contrast, is a real trip *off* the ARM
   chip's own compute path — through Linux, across a physical on-chip
   bus (the "LWH2F bridge"), into a completely separate piece of silicon
   (the FPGA fabric), and back. That crossing has a real, physical cost
   no in-process function call ever has to pay, no matter how fast
   either chip is individually.

**So "why is the FPGA slower than a PC?"** — it isn't a fair fight to
begin with: different test, a much weaker CPU on the board side, and a
real hardware boundary being crossed that the PC number never has to
cross. The numbers worth trusting for "is hardware actually faster
here?" are rows 2, 3, and 4 above — same board, same trace, same
bounds — and *that* comparison is the real, interesting result: the
FPGA fabric itself is decisively faster (row 3), but the price of
reaching it from software (row 4) currently costs more than it saves.

### Throughput ceiling

| | Derived from | Events/sec |
|---|---|---|
| Core alone (fabric compute) | Row 3 mean | **~3.90M** |
| Deployed system (core + register interface) | Row 4 mean | **~157.7K** |

**In plain terms**: the FPGA circuit itself could process about 3.9
million orders a second if you could feed it directly. The actual
deployed system manages about 158 thousand a second, because it has to
stop and wait for one full round trip (send order, poll "done yet?",
read the answer) before it's allowed to send the next one — it's not
allowed to have several orders "in flight" at once. The interface, not
the fabric, is the system's real bottleneck — by ~24.75x. See
`docs/fpga-performance.md`'s Phase 29 section for the named follow-up (a
request queue in the register map, so multiple orders could be in
flight at once) this points to — not built yet, but exactly the kind of
fix this measurement makes obvious.

### Resource utilization (Cyclone V `5CSXFC6D6F31C6`, 41,910 ALM budget)

| | Standalone core only | Full integrated system (HPS + Platform Designer) |
|---|---|---|
| ALMs | 9,040 (22%) | 10,688 (26%) |
| Registers | not separately reported | 15,358 |
| RAM blocks | 0 / 553 (0%) | 6 / 553 (1%)² |
| DSP blocks | 0 / 112 (0%) | 0 / 112 (0%) |

² Still **zero** from the order book itself, confirmed not assumed —
its parallel-access pattern structurally can't target block RAM's 1-2
ports. The 6 blocks come from the surrounding HPS/DDR3 plumbing.

**In plain terms**: an FPGA has two very different kinds of storage —
ordinary logic registers (fast, but there's a limited supply) and
dedicated memory blocks (bigger, but only 1-2 things can read/write them
at once). This design needs to compare *all 16* price levels
*simultaneously* every cycle — which the dedicated memory blocks
physically cannot do (they only offer 1-2 access ports). So the tool
was forced to build the order book entirely out of ordinary registers
instead, using about a quarter of the chip's total logic capacity and
none of its dedicated memory — not a failed optimization, a direct,
structural consequence of "compare everything at once" being the whole
point of building this in hardware.

### Timing closure

| | Worst-case setup slack (`CLOCK_50`) | TNS (all corners) |
|---|---|---|
| Before fix (single-cycle reduction) | **-47.6 ns** | tens of thousands of ns |
| After fix (pipelined reduction) | **+5.157 ns** | **0.000** |

**In plain terms**: every digital chip has a clock ticking at a fixed
rate, and every calculation between one tick and the next has to
*finish* before the next tick arrives — like a relay race where every
runner has to reach the next handoff point before the starting gun for
the next leg fires. The original design tried to compare all 16 price
levels and pick a winner in a single tick, but that turned out to take
almost 3.5x longer than one tick actually allows — some ticks were
firing before the answer was ready, which corrupts results in ways that
don't show up in a slower, idealized simulation, only on the real chip
running at real speed. "Negative slack" is exactly this: a promise the
circuit can't keep. The fix spreads the same comparison across 4 ticks
instead of 1 (see the Plain-English summary above) — slower per
comparison, but a promise the real chip can actually keep every time.
This was a real synthesizability bug, not a rounding error — full root
cause in `fpga_docs/bugs.md` #13 and the "what actually broke" writeup
in
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

**In plain terms, the 72-73% reject rate isn't a bug — it's what
"16 shelves, no way to clear one early" always leads to.** Imagine 16
labeled shelf slots for prices, each holding up to 8 waiting orders.
A slot only empties when someone buys *everything* sitting on it, at
*exactly* that price. There's deliberately no CANCEL in this design (see
the register map in
[`docs/fpga-matching-engine.md`](docs/fpga-matching-engine.md)) — so if
the market's price wanders off and never comes back to a slot, whatever
is parked there stays parked *forever*, occupying that slot for the
rest of the run. Run enough orders through 16 fixed slots with no way
to reclaim a stale one, and most of them end up permanently stuck long
before the run ends — so most *new* resting orders arrive to find every
slot already full, and get rejected. Widening it to 32 or 64 slots would
only delay this, not fix it — the fix would be adding CANCEL, which is a
deliberate, named scope boundary of this design (v1), not an oversight.

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
