# ADR-007: Bounded price-time-priority order book for the FPGA matching core

> **Note on this copy**: synced from
> [Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)'s
> `docs/adr/ADR-007-fpga-bounded-order-book.md` (source of truth for the
> prose if the two drift). Inline `docs/*.md` and `ADR-00N` references
> below point at that software repo's own docs (e.g. `docs/order-book.md`,
> `docs/architecture.md`); `fpga_docs/bugs.md` references are local to
> **this** repo — see [fpga_docs/bugs.md](../fpga_docs/bugs.md).

## Status
Accepted

## Context
`OrderBook`/`MatchingEngine` (ADR-004) are deliberately unbounded:
`std::map` grows to however many distinct price levels and resting orders
actually show up, and `docs/order-book.md`'s own benchmark is the reason —
an unbounded tree beats a bounded flat array by 5.7x on this project's
realistic order-flow mix specifically because insert/cancel dominates and
`std::map` degrades far more gracefully than a shifted vector as N grows.

None of that reasoning carries over to hardware. There is no heap on an
FPGA fabric — every register, BRAM row, and comparator that might ever be
used has to be instantiated at synthesis time, so "however many levels show
up" isn't an option; some fixed capacity has to be chosen. The upside is
that the operation software has to walk a tree for — "compare every active
price level, find the best" — can instead be done by dedicated comparator
hardware, one per level, all evaluating simultaneously in the same clock
cycle. That parallelism is the entire reason to build this in hardware; a
bounded array is what makes it buildable.

## Decision
`fpga_matching_core` (Phase 22) implements a **bounded** book: fixed
`N_LEVELS = 16` distinct price levels per side, fixed `M_ORDERS = 8`
resting orders per level (FIFO, time priority), single instrument per core
instance (matches `docs/matching-engine.md`'s existing statement that each
instrument's matching engine is independent — hardware scaling to more
instruments means instantiating more cores, not widening one).

- **Price**: 32-bit signed ticks, same `kPriceScale = 10000` fixed-point
  convention as `protocol/market_event.hpp` (narrower than the wire
  protocol's `int64_t` — 32 bits covers ±$214,748.36, comfortably enough
  for this project's synthetic instruments, and keeps every price
  comparator 32 bits wide instead of 64).
- **Quantity**: 32-bit unsigned, matches the wire protocol exactly.
- **Order ID**: 64-bit, matches the wire protocol exactly, passed as two
  32-bit Avalon-MM register writes.
- **Storage layout — not a sorted array.** Each side's N levels are an
  *unordered* set of slots (valid bit + price + FIFO). "Best price" is
  computed combinationally every cycle by an N-wide max/min reduction
  (highest valid price for bids, lowest for asks), not maintained by
  insertion order. Opening a new price level means claiming any invalid
  slot — no shifting, unlike `FlatOrderBook`'s sorted-vector approach.
  This is a real, deliberate departure from both software options
  benchmarked in `docs/order-book.md`: it has neither `std::map`'s
  pointer-chasing nor `FlatOrderBook`'s O(n) insert shift, because
  hardware can afford to compare all N slots at once instead of needing
  either of software's workarounds for comparing them one at a time.
- **Overflow — reject, at one specific point only.** A new order can
  *never* fail to match against existing resting liquidity (matching only
  ever consumes slots, never allocates one). Overflow can only happen at
  the final step, resting an unfilled remainder: if the remainder's price
  doesn't match any open level and all `N_LEVELS` slots are already
  occupied by other prices, or its level's FIFO already holds `M_ORDERS`
  entries, the remainder is rejected outright (a `REJECTED` status bit,
  no partial rest). Whatever quantity already traded before hitting that
  wall stands — rejection only ever affects the passive remainder, never
  a fill that already happened. This is a named, deliberate hardware-only
  limitation the software engine doesn't share.
- **Trade reporting is aggregated, not per-fill.** One submitted order can
  still cross multiple resting orders across multiple price levels in one
  submission (the FSM loops up to `N_LEVELS × M_ORDERS` times, same
  price-time-priority walk as `MatchingEngine::match_and_rest()`) — but
  the register map (Phase 22) exposes one `TRADE_QTY` (aggregate filled
  across every fill this order caused) and one `TRADE_PRICE` (the *last*
  fill's price only). A host wanting the full per-fill trade list, the
  way `MatchingEngine::submit_limit_order()` returns a `std::vector<Trade>`
  in software, would need a trade-event FIFO in the register map — not
  built in v1, named here rather than silently dropped.

## Rationale
- The comparison this whole roadmap exists to produce (Phase 26) is only
  meaningful if both sides are solving the *same bounded problem* —
  Phase 21's `BoundedMatchingEngine` reference exists specifically so the
  software side is held to these same N/M bounds, rather than comparing a
  hardware toy against software's genuinely unbounded book.
- Unordered-slot-plus-reduction, not a sorted array, is the direct
  hardware translation of "why not `std::unordered_map`" from
  `docs/order-book.md`: there, the answer was software needs an *ordered*
  structure because scanning for a min/max is O(n) in software. In
  hardware, an O(n) scan across n small fixed comparators *is* the
  parallel primitive — the thing software had to avoid is exactly the
  thing hardware is built to do well, in one clock's worth of logic
  depth (`⌈log₂ N⌉` comparator-tree levels, not `N` sequential steps).

## Consequences
- The FPGA core cannot represent a book deeper than 16 price levels or 8
  orders resting at one price — a real ceiling, unlike software. A
  synthetic workload that regularly exceeds this (e.g. many orders
  piling up at one price during a thin/illiquid instrument) will show up
  as a nonzero reject rate on the FPGA side and nowhere on the software
  side; Phase 26's comparison harness needs to report reject rate
  alongside latency so this isn't hidden.
- **Bounded levels and no CANCEL compound, measured in Phase 21's
  benchmark, not just theorized:** a level can only be freed by being
  fully matched away at its exact price. Under any sustained workload
  with ongoing price movement — even movement confined to a fixed band,
  not unbounded drift — a level opened away from the currently-active
  price neighborhood can go unmatched indefinitely and stays claimed
  forever, since there's no CANCEL to reclaim it. `bounded_matching_engine_bench`
  measured a **72.4% reject rate** at the real N=16/M=8 bounds under a
  realistically-clustered (not adversarial) synthetic workload — see
  `fpga_docs/bugs.md` #4 for the full three-step investigation. Widening
  `N_LEVELS` delays this, it does not fix it; only CANCEL or an expiry
  mechanism (neither in scope) would. This means a high reject rate
  should be *expected*, not treated as a workload-tuning bug, in Phase
  26's comparison — and reported as a first-class number, not a
  footnote.
- Widening `N_LEVELS`/`M_ORDERS` later is a resynthesis, not a config
  change — comparator count and FIFO depth are structural, chosen at
  elaboration time.
- CANCEL and MODIFY are out of scope for the v1 register map (Phase 22
  only wires ADD_ORDER: `ORDER_ID`/`SIDE`/`PRICE`/`QTY`/`START` in). Named
  here as a deliberate v1 scope boundary, not an oversight — matching
  this project's standing practice of naming gaps rather than pretending
  completeness.

## Alternatives considered
- **Sorted array per side (mirror `FlatOrderBook`)**: rejected — would
  need an N-entry shift network on every insert, real complexity for no
  benefit, when an unordered array plus a reduction tree gets the same
  O(1)-cycle best-price answer without ever needing to move an existing
  entry.
- **Content-addressable/hash-indexed price lookup**: rejected as
  unnecessary complexity at N=16 — a linear compare across 16 comparators
  is already what the reduction tree does, and a CAM only pays off at
  scales this bounded core deliberately doesn't target.
- **Match multiple instruments per core (time-multiplexed)**: rejected for
  v1 — keeps the FSM and the Phase 26 comparison simpler; multi-instrument
  scaling by instantiating more cores mirrors the software project's own
  "no cross-instrument coordination" design (`docs/matching-engine.md`,
  trade-ID generation) instead of introducing a new sharing mechanism
  hardware doesn't need.

## Amendment (Phases 22-29): what actually got built, vs. this decision

This ADR was written before any RTL existed. Phases 22-29 built it, and
this section names where reality diverged from the plan above — the same
practice `docs/architecture.md` applies to its own planning document,
rather than silently editing the Decision/Rationale above to look like
it was always exactly right.

- **"One clock's worth of logic depth" was wrong — the best-price
  reduction is pipelined, not combinational.** The Rationale above
  states the N-wide reduction happens "in one clock's worth of logic
  depth (`⌈log₂N⌉` comparator-tree levels, not `N` sequential steps)."
  That was the intent, and the *first* synthesized version did exactly
  that — a single-cycle `for`-loop reduction. Real `quartus_sta` against
  the actual board project (only run for the first time in Phase 24/29,
  well after Phase 22's own synthesis-only checks) found it violated
  timing by **-47.6 ns** of setup slack at 20 ns/cycle: Quartus emitted a
  76-logic-level, 66.9 ns serial priority chain, not the balanced tree
  assumed. This was almost certainly the true root cause of two bugs
  that had already been chased under other theories (`fpga_docs/bugs.md`
  #11's reject-rate gap, #12's board hang) before the timing report was
  ever pulled. Fixed by rewriting the reduction as an explicit
  *registered* binary-tree pipeline — `⌈log₂16⌉ = 4` extra clock cycles
  of latency per order to find a winner, added deliberately per the
  user's explicit call ("we can wait for the shipping but we need a
  proper product... pipeline it") rather than shipping a design that
  didn't meet its own timing budget. Full root cause, the Quartus-vs-
  Questa static-elaboration trap hit along the way, and the fix are in
  `fpga_docs/bugs.md` #13. The parallel-comparison *idea* this ADR is
  built on is unaffected — 16 comparators still evaluate in parallel
  each pipeline stage — but "one clock" in the Rationale should be read
  as "four clocks" in the as-built design.
- **`core_clk` is not yet actually a separate, faster domain.** The
  register-map header comment (`fpga_matching_core.sv`) describes
  `core_clk` as "deliberately a separate, faster domain — the whole
  point of building this in hardware is to run the matching loop faster
  than the bus that talks to it." As actually wired in
  `DE10_Standard_golden_top.v`, `core_clk` and `avs_clk` are both tied to
  the same `CLOCK_50` (50 MHz nominal) — the real CDC boundary
  (`cdc_pulse_sync.sv`) exists and is exercised, but on two clock inputs
  driven by one physical clock, not yet two independently-timed domains.
  Named as a real, deliberate scope limit for this pass (a PLL to give
  `core_clk` its own faster rate is future work), not an oversight —
  same-clock CDC still had to be built correctly (bug #11/#12's
  hard-earned reset lessons apply regardless of clock ratio) but the
  "run matching faster than the bus" upside this ADR anticipates hasn't
  been realized yet.
- **The reject rate matches this ADR's own prediction closely, but not
  exactly, and the residual gap is real and still open.** This ADR's
  Consequences section predicted a real, structural reject rate from
  bounded levels + no CANCEL, and Phase 21's software reference measured
  it at 72.4% — that prediction held up. What wasn't anticipated: the
  real hardware run (Phase 26/27) measures 73.365-73.555% on the
  identical seed=42 trace, a persistent ~1-point gap versus the software
  reference that a bit-for-bit-matching design should not have. Leading
  suspect (not yet confirmed): `reset_reset_n` is still tied permanently
  high in `DE10_Standard_golden_top.v` (the power-on-reset fix attempted
  for bug #11 caused a worse regression — bug #12's board hang — and was
  reverted, never revisited). Left open deliberately per the user's
  explicit call ("leave it for now, move on to the next phases") — see
  `fpga_docs/bugs.md` #13's "still open" section.
- **The register map (Decision section, "Trade reporting is aggregated,
  not per-fill") was built exactly as planned, unchanged.** Confirmed
  against the real RTL (`fpga_matching_core.sv`'s register-map header
  comment and address decode): `STATUS` (bit0 BUSY, bit1 DONE, bit2
  REJECTED), `TRADE_QTY`, `TRADE_PRICE` (last fill only), `TRADE_ID_LO/HI`,
  and `LATENCY_CYCLES` all match this ADR's plan exactly — no trade-event
  FIFO was added, and CANCEL/MODIFY remain out of scope, both exactly as
  named here originally. Full register map and address table in
  `docs/fpga-matching-engine.md`.
- **The throughput consequence of the aggregated/no-queue design turned
  out to dominate the whole system, more than this ADR anticipated.**
  This ADR frames the no-queue, poll-`STATUS.BUSY`-per-order register
  interface as a v1 simplicity choice, without projecting its throughput
  cost. Phase 29 measured it directly: the core alone can sustain
  ~3.90M events/sec, but the deployed system (core + this single-order
  blocking MMIO interface) is ceilinged at ~157.7K events/sec — a
  ~24.75x gap attributable entirely to this interface, not the matching
  logic. See `docs/fpga-performance.md`'s Phase 29 section for the full
  numbers; named there as the highest-leverage follow-up if higher
  deployed throughput is ever pursued.
