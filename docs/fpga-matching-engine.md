# FPGA Matching Engine (Phases 20-29)

> **Note on this copy**: this file is a synced copy of the same
> document maintained in the
> [Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)
> repo's `docs/fpga-matching-engine.md` — that project's software stack
> is what this hardware core is compared against and wired into. Links
> below are adjusted for this repo's layout; if they drift out of sync,
> the software repo's copy is the source of truth for the prose.

## What this is

A hardware matching-engine core for one instrument, built on an Intel
DE10-Standard board (Cyclone V SoC, `5CSXFC6D6F31C6`), extending the
[Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)
project's software-only 19-phase build with a real hardware comparison
point. RTL, simulation, and this Quartus project (hand-written
SystemVerilog, not HLS) live in **this repository**; this document
covers how the FPGA core is scoped
([ADR-007](ADR-007-fpga-bounded-order-book.md)), its register interface,
how it's wired into the software project's Kafka/Postgres/Redis/API
stack (Phase 27), the frontend panel that visualizes it live (Phase 28),
and the real measured numbers (Phase 26/29, full detail in
[fpga-performance.md](fpga-performance.md)).

See the software project's
[foundations.md](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/blob/master/docs/foundations.md#18-fpga--rtl--hardware-description-synthesis-and-why-parallelism-changes-the-algorithm)
for an FPGA/RTL primer if you're new to hardware design — this document
assumes that background.

## Scope: matching only, HPS-mediated

Only the matching-engine core moved to fabric. Protocol decode,
sequencing, and risk checks stay in C++ on the DE10's HPS (hard ARM
Cortex-A9 cores) — the same split of responsibilities this project's
software stack already uses, just with one stage now running in
dedicated hardware instead of a CPU. Packets still arrive over HPS
Ethernet under Linux; there is no fabric-side NIC. This keeps the
comparison isolated to the one component parallel hardware genuinely
changes the complexity class of (see ADR-007's Rationale) rather than
re-implementing an entire feed-handling pipeline in RTL.

## The bounded book: why hardware needs a different data structure

This project's software `OrderBook` (`docs/order-book.md`) is
deliberately unbounded — `std::map` grows to however many price levels
and resting orders actually show up. There is no equivalent to "grows as
needed" on an FPGA: every register, comparator, and storage element that
might ever be used has to be instantiated at synthesis time. `ADR-007`
covers the full reasoning; the summary:

- **N_LEVELS = 16** distinct price levels per side, **M_ORDERS = 8**
  resting orders per level (time-priority FIFO), one instrument per core
  instance.
- Levels are **unordered slots**, not a sorted array — "best price" is
  recomputed every operation by comparing all N slots in parallel
  (a reduction tree), rather than maintained by insertion order. This is
  the actual hardware win: what forces software toward `std::map` (an
  O(n) scan to find a min/max is expensive one-at-a-time) is exactly the
  operation N parallel comparators do well.
- **Reject, at exactly one point**: a new order can never fail to match
  existing liquidity — overflow can only happen resting an unfilled
  remainder, if its price needs a new level and all N are taken, or its
  level's FIFO already holds M orders. Whatever already traded before
  hitting that wall stands.
- No CANCEL/MODIFY in v1 — named as a deliberate scope boundary in
  ADR-007, not an oversight.

## Register map

Word-addressed Avalon-MM slave, base address `0x7000` on the HPS
lightweight (LWH2F) bridge — `0xFF207000` as the ARM-side physical
address (`d10_standard_golden_top`'s `soc_system.qsys`; host-side mapped
in `fpga_bridge.hpp` via a single page-aligned 4KB `/dev/mem` mmap).

| Addr | Name | R/W | Meaning |
|---|---|---|---|
| 0x0 | `ORDER_ID_LO` | W | Low 32 bits of the 64-bit order id |
| 0x1 | `ORDER_ID_HI` | W | High 32 bits |
| 0x2 | `SIDE` | W | bit0: 0 = BUY, 1 = SELL |
| 0x3 | `PRICE` | W | Signed, ticks (`kPriceScale = 10000`, matches the wire protocol's fixed-point convention, narrowed to 32 bits) |
| 0x4 | `QTY` | W | Unsigned |
| 0x5 | `CONTROL` | W | bit0 = START (write 1 to pulse; self-clears) |
| 0x6 | `STATUS` | R | bit0 = BUSY, bit1 = DONE (sticky until next START), bit2 = REJECTED |
| 0x7 | `TRADE_QTY` | R | Aggregate filled quantity for the last order (can span multiple fills) |
| 0x8 | `TRADE_PRICE` | R | The *last* fill's price only — no per-fill list (ADR-007 names this as a v1 limit) |
| 0x9 | `TRADE_ID_LO` | R | Low 32 bits of the last fill's trade id |
| 0xA | `TRADE_ID_HI` | R | High 32 bits |
| 0xB | `LATENCY_CYCLES` | R | `core_clk` cycles, START accept → DONE |

Protocol: write the five input registers, pulse `CONTROL.START`, poll
`STATUS.BUSY` (or `.DONE`) low, then read results. The core does not
queue requests — one order in flight at a time. This single-order
protocol is what Phase 29 found to be the system's real throughput
ceiling (see below), separate from the matching logic's own speed.

## Matching algorithm in hardware: a pipelined reduction, not a single-cycle one

The core walks the same price-time-priority loop as software's
`MatchingEngine::match_and_rest()` (`docs/matching-engine.md`) — consume
crossing levels best-price-first, FIFO order within a level, rest any
unfilled remainder — but "find the best price across N unordered slots"
is where hardware and software genuinely diverge, and where this design
went through a real correction.

The original design (and this project's original assumption) was that
comparing 16 slots to find a winner would synthesize as a balanced
comparator tree, evaluated in a single clock — `⌈log₂16⌉ = 4` logic
levels, well inside a 20ns (50MHz) budget. Real `quartus_sta`, run for
the first time only after the board-level project existed (Phase
24/29), found otherwise: Quartus had synthesized it as a 76-logic-level
serial priority chain, **-47.6ns of setup slack** — almost certainly the
true root cause of two bugs (a reject-rate mismatch, a board hang) that
had already been chased under other theories before this was found. See
[fpga_docs/bugs.md](../fpga_docs/bugs.md) #13 for the full trail,
including a real Quartus-vs-Questa static-elaboration divergence hit
along the way (Quartus statically checks SV `for`-loop array-index
bounds on the structural expression regardless of a runtime-only guard;
Questa only checks values actually computed — two rounds of "passes
sim, fails synthesis" before landing on a fix needing *both* a
full-width outer loop and a separate compile-time-constant guard).

**As actually built** (`bounded_order_book.sv`, `ST_REDUCE_BEST`/
`ST_REDUCE_REST` states): the reduction is a real *registered*
binary-tree pipeline — one pairwise compare-and-select per cycle,
`RB_STAGES = $clog2(16) = 4` cycles to resolve a winner, ping-ponging
between two halves of an array sized for the full structural width at
each stage. This costs 4 extra clock cycles of latency per level-search
versus the original (broken) single-cycle assumption — an accepted
trade-off, made explicitly per the project owner's call ("we can wait
for the shipping but we need a proper product... pipeline it") rather
than shipping a design that didn't meet its own timing budget. The
parallel-comparison idea ADR-007 is built on is unaffected — 16
comparators still evaluate simultaneously each stage — but it now takes
4 clocks to get an answer, not 1.

## Clock domains

`avs_clk` (register-bus side, standing in for the real LWH2F bridge
clock) and `core_clk` (the matching FSM) are wired as genuinely separate
clock *inputs* with a real CDC boundary (`cdc_pulse_sync.sv`, a
two-flop synchronizer for the START pulse). As currently deployed, both
inputs are driven by the same physical `CLOCK_50` — the CDC
infrastructure is real and exercised, but `core_clk` doesn't yet run
faster than the bus, which was the original motivation for splitting the
domains in the first place (see ADR-007's Amendment section). Giving
`core_clk` its own faster PLL is named future work, not built.

## Real measured results

Full tables, methodology, and honest gaps in
[fpga-performance.md](fpga-performance.md) — summarized:

| | Value | Source |
|---|---|---|
| Fabric-internal latency (mean) | 256.31 ns (12.82 cycles) | Phase 26, real hardware, 1M orders |
| ARM software reference (mean) | 1863.39 ns | Phase 26, same trace, native Cortex-A9 |
| HPS round-trip, whole deployed path (mean) | 6341.75 ns | Phase 26, real hardware |
| Reject rate (hardware) | 73.365-73.555% | vs. 72.4% C++ reference — ~1pt gap, open |
| Full-system ALMs | 10,688 / 41,910 (26%) | Phase 29, real `quartus_fit` |
| Full-system RAM blocks | 6 / 553 (1%) — none from the order book itself | Phase 29 |
| Worst-case setup slack | +5.157ns (was -47.6ns pre-fix) | Phase 29, real multi-corner `quartus_sta`, TNS=0.000 everywhere |
| Core throughput ceiling | ~3.90M events/sec | Phase 29, derived from row-3 mean |
| Deployed (bridge) throughput ceiling | ~157.7K events/sec | Phase 29, derived from row-4 mean — the real system bottleneck |

The headline finding: fabric-internal matching is ~7.3x faster than the
ARM software reference on identical bounded inputs, but the honest
"if you deployed this today" number (row 4, including the LWH2F/MMIO
round-trip) is *slower* than pure software — the single-order blocking
register interface, not the matching computation, dominates and erases
the fabric's speed advantage at the whole-deployed-path level. This is
why the comparison is reported as separate rows rather than one
"FPGA is Nx faster" headline.

## Backend and frontend integration (Phases 27-28)

The FPGA core's live numbers reach the software project's existing
Kafka/Postgres/Redis/API stack through a small forwarder chain, chosen
over cross-compiling `librdkafka` for the DE10's ARM target (no prior
toolchain precedent for that project) or simulating FPGA rows on x86
(defeats the point of a real-hardware comparison):

```
fpga_latency_harness (runs on the DE10's ARM cores)
  -> drives rows 2/3/4 continuously, writes a 500ms JSON snapshot
     to /tmp/fpga_latency_snapshot.json (atomic write-then-rename)
  -> [SSH ControlMaster pull]
fpga_latency_forwarder (x86, this project's stack)
  -> republishes verbatim to Kafka topic "fpga-latency"
     and Redis key "fpga_latency:latest"
persistence_consumer
  -> batched idempotent insert into Postgres fpga_latency_windows
     (window_end_unix_ns as the uniqueness key - the DE10's clock is
     not NTP-synced, confirmed by direct observation, so it's never
     used for query ordering; received_at, Postgres's own clock, is)
api_gateway
  -> GET /api/fpga-latency/history (REST)
  -> "FPGA_LATENCY" reserved pseudo-symbol on the existing WebSocket
     subscribe protocol (no new message shape needed)
frontend: FpgaLatencyComparison.tsx
  -> three small-multiple charts (rows 2/3/4 - deliberately not one
     dual-axis chart, since row 3 is raw cycles and rows 2/4 are ns),
     p50/p99 per row, live via the WebSocket channel above
```

The FPGA host binaries (`fpga_latency_harness`, `fpga_bridge`,
`bounded_matching_engine`) live in this repo, alongside the RTL they
drive (`host/`). The forwarder (`fpga_latency_forwarder`), the
persistence/API wiring, and the dashboard panel are genuinely part of
the software project's existing service stack, so they're built and
live there —
[`fpga-latency/`](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/tree/master/fpga-latency),
[`frontend/src/components/FpgaLatencyComparison.tsx`](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/blob/master/frontend/src/components/FpgaLatencyComparison.tsx).
Read-only reference copies of both are kept in this repo's
[`software-integration/`](../software-integration/) for anyone browsing
this repo alone — the software repo is the buildable, live source of
truth for that half of the chain.

## Known open gaps

- **~1-point reject-rate gap** (73.365-73.555% real hardware vs. 72.4%
  software reference) — leading suspect is `reset_reset_n` still tied
  permanently high (the power-on-reset fix attempted for this was
  reverted after causing a worse hang — see
  [fpga_docs/bugs.md](../fpga_docs/bugs.md) #11/#12). Left open
  deliberately.
- **SignalTap logic-analyzer capture** (would have confirmed/ruled out
  the CDC/no-`waitrequest` hang theory) — skipped; normally GUI-authored
  in Quartus and would need another rebuild+reflash cycle.
- **HPS Ethernet reaching the Kafka broker** — not independently
  confirmed this session (the forwarder chain above was built and
  unit-tested; the full path has not been run live end-to-end against
  the real board plus the real Docker stack simultaneously).
- **Single-order blocking register interface as the real throughput
  ceiling** (Phase 29) — a request queue/FIFO in the register map is the
  named, not-yet-attempted follow-up if higher deployed throughput is
  ever pursued.
- **`core_clk` not yet a genuinely faster domain** than `avs_clk` — see
  Clock domains above.

## References

- [ADR-007](ADR-007-fpga-bounded-order-book.md) — the bounded-book
  design decision, with a Phase 22-29 amendment covering what changed
  from the original plan.
- [fpga-performance.md](fpga-performance.md) — full Phase 26/29 tables
  and methodology notes (including a real ARM `chrono`-overhead finding).
- [fpga-roadmap.md](fpga-roadmap.md) — the phase-by-phase checklist this
  work was tracked against.
- [fpga_docs/bugs.md](../fpga_docs/bugs.md) — every real bug found during
  the hardware build, numbered #1-13, including the timing-closure bug
  (#13) that turned out to be the root cause of two others.
