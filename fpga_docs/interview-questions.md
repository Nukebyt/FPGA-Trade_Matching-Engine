# FPGA Interview Preparation

Same format as the software project's `docs/interview-prep.md`: built
phase by phase alongside the code, every answer traces back to a real
design decision (and usually a real tool run) in this project, with file
citations so you can re-derive the answer from the RTL itself rather than
memorizing prose. Category tags noted per question for cross-topic study.

---

## Setup / Deployment — JTAG vs. SD card

### Q: Why does this project need both JTAG and an SD card — why not just one?

**[FPGA Toolflow, Embedded Systems]**

Because they configure two different, independent things. JTAG
(`quartus_pgm`) reprograms the FPGA **fabric** only — fast, but volatile,
lost on power-cycle. The SD card is what the HPS's ARM Cortex-A9 cores
boot **Linux** from (preloader → U-Boot → device tree → kernel → rootfs) —
on a Cyclone V SoC, fabric configuration and HPS boot are architecturally
independent processes. Once Linux is up off the card, JTAG can keep
reprogramming the fabric across RTL revisions without touching the card
or rebooting Linux at all — that's what makes fast RTL iteration
practical while a persistent Linux userspace host process
(`fpga/host/fpga_bridge.cpp`, Phase 24) stays running in the background.

**Follow-up:** "When would you *have* to use the SD card path for the
fabric bitstream too?" → For a standalone demo with no PC/JTAG attached —
baking the final `.rbf` into the SD boot flow so the board configures
itself at power-on (Phase 29/30, optional polish, not needed for any
correctness milestone).

---

## Phase 20 — Bounded order book design (ADR-007)

### Q: Why does the FPGA book need a fixed capacity when the software book (`std::map`) doesn't?

**[Computer Architecture, Hardware Design]**

Because there's no heap on fabric. `std::map` calls `malloc` on demand and
grows however large the workload needs; every register, comparator, and
BRAM row an FPGA design might ever use has to be instantiated at
synthesis time — "grow as needed" isn't an available strategy. `ADR-007`
fixes `N_LEVELS=16` price levels/side and `M_ORDERS=8` resting orders per
level, and documents overflow as an explicit `REJECTED` status bit rather
than pretending the constraint doesn't exist.

**Follow-up:** "Doesn't that make the hardware book strictly worse than
the software one?" → Along that one axis, yes, by construction — but the
comparison this project runs (Phase 26) holds the *software* side to the
same bound too (`BoundedMatchingEngine`, Phase 21), specifically so the
latency comparison isn't an apples-to-oranges "unbounded tree vs. bounded
array."

---

### Q: Why is the book stored as an *unordered* set of N slots instead of a sorted array (like `FlatOrderBook`)?

**[Computer Architecture, Data Structures]**

`docs/order-book.md` (software project) already measured that a sorted
`std::vector` loses badly to `std::map` in *software*, specifically
because inserting into a sorted array is O(n) — every element past the
insertion point has to be shifted, sequentially, one memory write at a
time. That cost is fundamentally a software cost: it exists because a CPU
core can only touch one (or a few, with SIMD) memory location per cycle.

Hardware doesn't have that constraint. `bounded_order_book.sv` keeps each
side's `N_LEVELS` slots in **no particular order** — inserting a new price
level means claiming any invalid slot (no shift at all), and "what's the
best price" is answered by a **combinational reduction**: all 16 slots'
prices compared *in the same clock cycle*, via dedicated comparator
hardware, not a sequential scan. The thing software has to avoid
(comparing many candidates one-by-one) is exactly the thing this design
leans into, because in hardware it's genuinely parallel, not sequential.

**Where this lives in the code:** `bounded_order_book.sv`'s
`buy_best_valid`/`buy_best_price`/`buy_best_idx` `always_comb` block.

**Follow-up:** "Is that reduction really O(1) in hardware, or O(log N)?"
→ See the next question — it's the right follow-up, and the honest answer
isn't "O(1)."

---

### Q: What's the actual time complexity of that N-wide reduction — is it really O(1)?

**[Computer Architecture, Digital Logic]**

No — and claiming O(1) would be exactly the kind of implausible,
unverified number this project's own software half (`docs/performance.md`)
warns against reporting without cross-checking. The reduction is written
as a `for` loop over `N_LEVELS` in `always_comb`, which describes *what*
to compute (the max/min), not literally *how* it's wired — a synthesis
tool restructures a commutative reduction like this into a balanced
comparator tree, `⌈log₂ N⌉` levels deep (4 levels for N=16), not a
16-long sequential chain. That's still asymptotically the same order as
`std::map`'s O(log n) tree walk — the real advantage isn't a better
Big-O, it's that every comparison in the hardware tree is
**combinationally independent and evaluated simultaneously** within one
clock edge, where `std::map`'s tree walk is **sequentially
memory-dependent** (each node's comparison needs that node's memory load
to complete before the *next* comparison can even be issued). Same
asymptotic shape, very different constant factor, for a very different
reason. Whether Quartus actually built a 4-deep tree instead of leaving a
16-deep chain is a real thing to verify in the post-fit netlist viewer,
not assume — noted directly in `bounded_order_book.sv`'s comments as a
Phase 22 resource-report follow-up.

---

## Phase 22 — RTL and Avalon-MM integration

### Q: Why does the matching core run on its own clock domain instead of just using the Avalon bus clock?

**[Digital Logic, Computer Architecture]**

Because the entire point of building this in hardware is to run the
matching loop faster than the bus that talks to it. If `bounded_order_book`
ran on the same clock as the Avalon-MM register file, its cycle count
would be artificially tied to bus timing instead of measuring what the
matching logic itself can actually achieve — and Phase 25's whole
SignalTap/Fmax exercise would have nothing real to report. `core_clk` is
deliberately separate from `avs_clk` in `fpga_matching_core.sv`, crossed
by two `cdc_pulse_sync` instances (one each direction).

---

### Q: Why does only a single-bit pulse get synchronized across clock domains, instead of synchronizing the whole result bus?

**[Digital Logic, CDC]**

Synchronizing a multi-bit bus by putting an independent 2-flop
synchronizer on every bit is a real, well-known bug pattern — different
bits can resolve out of metastability on different clock edges ("bus
skew"), so the receiving domain can briefly sample a value that was never
actually valid in the source domain (some old bits, some new). The
correct pattern — used here — is **handshake-protected data**: the wide
result bus (`out_trade_qty`/`out_trade_price`/`out_trade_id`/
`out_rejected`/`out_latency_cycles`) is held stable in `core_clk` from the
moment `ST_DONE` writes it until the *next* transaction starts (many
cycles later, gated by the avs domain not issuing a new `START` until it
has observed `BUSY` clear). Only the single-bit `done` event crosses
through a synchronizer (`cdc_pulse_sync`); by the time the avs domain
observes that synchronized pulse, the data it's about to sample has
already been stable for at least the synchronizer's own multi-cycle
latency — eliminating the metastability window for that sample entirely,
without needing to synchronize 200+ bits individually.

**Where this lives in the code:** `cdc_pulse_sync.sv`'s header comment
spells this out explicitly; `fpga_matching_core.sv`'s avs-domain
`always_ff` samples `out_trade_qty` etc. directly, gated by
`avs_done_pulse`.

**Follow-up:** "What's the one place this reasoning doesn't protect you?"
→ The same pattern runs in reverse for order *inputs*
(`order_id`/`side`/`price`/`qty`), and it depends on a software usage
contract — the host must finish writing all four input registers *before*
writing `CONTROL.START`, and must not write new input fields again until
`BUSY` clears. The RTL doesn't and can't enforce that ordering itself; a
host that violated it (e.g. wrote `START` concurrently with a field write)
would create a real race the hardware has no way to detect. Documented
here rather than silently assumed.

---

### Q: Why doesn't the register file need an `avs_waitrequest` signal?

**[Computer Architecture, Bus Protocols]**

`avs_waitrequest` exists in Avalon-MM to let a slave stall a transaction
when it isn't ready — needed for anything with variable or nonzero read
latency (a memory controller, a pipelined ALU). This register file's
reads are purely combinational (`avs_readdata` is driven directly off
`avs_address` with no registered stage) and writes always complete in the
cycle they're issued, so the slave is always ready — a fixed 0-cycle-read
/ 1-cycle-write-latency slave, a legitimate and simpler Avalon-MM slave
class that Platform Designer supports without a `waitrequest` port at
all. This is a real, deliberate v1 simplification; a future revision
that pipelines reads or adds a request queue would need to add it back.

---

### Q: Why does this design use zero embedded Block RAM — isn't RAM the obvious place to put an order book?

**[Computer Architecture, Hardware Resource Estimation]**

Because both of this design's parallel-access properties — comparing all
`N_LEVELS` prices simultaneously, and shifting all `M_ORDERS` FIFO slots
of a level simultaneously on pop — are access patterns embedded Block RAM
literally cannot serve (BRAM offers at most two read/write ports; a
16-wide simultaneous compare needs 16). Quartus's synthesis log says this
explicitly ("EDA Netlist Writer cannot regroup multidimensional array
... into its bus") and the real, `quartus_fit`-reported post-fit number
confirms it directly: **0 / 5,662,720 block memory bits used (0%)** —
every level's price/count/order-FIFO storage really did get placed as
ALM-packed registers, not M10K memory. That's the direct resource price
of the parallelism the whole design exists to demonstrate: 9,040 of the
device's 41,910 ALMs (22%) at the real N=16/M=8 scale, all of it in
registers, none in RAM. A BRAM-backed design (one entry read per cycle,
sequential lookup) would cost far fewer ALMs and take far more cycles per
operation — closer to software's own sequential tradeoff, and not the
point of building this in hardware. 0 DSP blocks used is the other real,
confirmatory number here: this design does no multiplication anywhere
(only comparison, add/subtract, muxing), so a nonzero DSP count would
have been the surprise, not a zero one.

**Where this lives in the code:** `fpga_docs/bugs.md` #3 has the full
`fit.summary` output this answer quotes.

---

## Phase 23 — Verification methodology

### Q: Why test with `N_LEVELS=4`/`M_ORDERS=2` in the testbench instead of the real `16`/`8`?

**[Verification, Testing]**

To make the two overflow paths (level-full, book-full) reachable with a
handful of directed orders instead of dozens. `tb_fpga_matching_core.sv`
overrides the module's parameters down for exactly this reason — the FSM
logic being tested is identical regardless of N/M (the reduction and shift
loops are generated from the same `for` loops either way), so a small N/M
exercises the same control paths with far less testbench code, the same
principle as choosing small, sharp unit-test inputs over "realistic-sized"
ones when the logic under test doesn't actually depend on scale.

**Follow-up:** "What would you still want to test at the real N=16/M=8
that you can't learn from N=4/M=2?" → The actual post-fit resource cost
and Fmax (Phase 22's resource report, Phase 23's timing closure) — those
genuinely do depend on the real size, unlike functional correctness.

---

### Q: How do you know the hardware core's matching semantics actually match the software engine's, not just that the RTL "runs without errors"?

**[Verification, Testing]**

Two separate kinds of evidence, deliberately not conflated: (1)
`tb_fpga_matching_core.sv`'s directed cases check specific documented
behaviors against known-correct expected values — e.g.
`PartialMatchPriceImprove` asserts a trade executes at the *resting*
order's price (100), not the incoming aggressor's better price (95),
directly mirroring the software project's own
`MatchingEngineTest.TradeExecutesAtRestingOrdersPriceNotAggressorsPrice`.
(2) Phase 23's still-pending trace-replay testbench goes further: the
same `simulator::EventGenerator`-produced trace fed through both the RTL
simulation and the Phase 21 C++ reference, asserting identical trade
sequences — that's the test that would actually catch a subtle semantic
divergence a handful of directed cases might miss.

---

## Phase 21 — Bounded C++ reference and a real benchmark finding

### Q: Your first benchmark run showed a 97.9% reject rate. Was the matching engine broken?

**[Debugging Methodology, Benchmarking Honesty]**

No — and confirming that *first*, before chasing the engine, mattered:
the same 14 directed test cases that pass against the RTL testbench also
pass bit-for-bit against this C++ reference (same qty/price/rejected
values on every case), so the engine's logic was already known-correct
before the benchmark ever ran. That made it clear the benchmark's
*workload generator* was the thing to investigate, not the engine — a
useful general lesson: when a component with independent passing tests
produces a surprising number under load, suspect the harness generating
the load before suspecting the component again.

---

### Q: What actually caused the high reject rate, if not a bug?

**[Systems Design, Order Book Design]**

A real, structural interaction between two scope decisions that were
each named independently in ADR-007 but turned out to compound: bounded
`N_LEVELS` and no CANCEL. A resting level can only be freed by being
*fully matched* at its exact price — there's no other mechanism to
reclaim it. Under any workload where the price of interest keeps moving,
even within a fixed band (not unbounded drift), a level opened away from
wherever the price currently is can go unmatched indefinitely, because
nothing will land at its exact price again until — if ever — the price
happens to wander back there. Once most of `N_LEVELS` slots are claimed
this way, most new orders arrive at prices with no free slot. Confirmed
by three isolated benchmark attempts, not asserted from theory alone —
see `fpga_docs/bugs.md` #4 for the full progression (97.9% → 97.7% →
76.2% → 72.4%, each change targeting a different, real hypothesis).

**Follow-up:** "What would actually fix this?" → CANCEL, or an expiry
mechanism — both explicitly out of scope for this project (ADR-007).
Widening `N_LEVELS` only delays the effect, since it's driven by "levels
never get reclaimed," not by "not enough levels."

---

### Q: Why not just keep tuning the benchmark's parameters until the reject rate looks better?

**[Benchmarking Honesty, Engineering Judgment]**

Because at that point it stops being measurement and becomes shaping the
test to produce a flattering answer — exactly what `docs/performance.md`
(software project) warns against from the other direction ("only publish
measurements you actually obtain, never fabricate results"). The first
two tuning passes (offset width, then drift bound) each had a real,
independently-justifiable rationale (matching realistic order clustering,
not simulating unbounded multi-day drift) and each produced a real,
substantial change — legitimate debugging. Once a third change (further
narrowing offset) produced only a marginal further improvement, that was
the signal the *underlying property itself* was being measured
correctly, not an artifact of the test — the point to stop tuning and
report the number.

---

### Q: You cross-compiled for ARM and ran it under QEMU — doesn't that give you the on-target benchmark number?

**[Verification Methodology, Embedded Systems]**

No, and conflating the two would be a real mistake worth catching before
it ever reached a report. QEMU user-mode emulation proves something
narrow and real: the cross-compiled binary is *functionally correct* —
`bounded_matching_engine_test` under `qemu-arm` passed all 14 cases,
bit-for-bit identical to the native x86 build and the RTL simulation,
which is genuine evidence the cross-compile toolchain and the code are
both sound. What it does *not* prove is speed: QEMU works by
binary-translating ARM instructions into host x86 instructions at
runtime, so its execution time is a function of QEMU's translation cache
and the host CPU, with no principled relationship to real Cortex-A9
silicon — it could be many times slower or faster than the real thing
depending on instruction mix. The 285 ns/event QEMU produced is a real
number QEMU actually printed, but reporting it as "the on-target
latency" would be exactly the kind of measurement `docs/performance.md`
(software project) warns against — technically true output, wrong
question answered.

**Follow-up:** "So what was the point of running it under QEMU at all,
then?" → Catching a cross-compile-specific bug *before* ever touching
real hardware is valuable on its own — a wrong `-mfpu`/`-mfloat-abi`
flag, a miscompiled comparison, or an ABI issue could easily pass on x86
and fail only once cross-compiled. QEMU is the fast, free way to catch
that class of bug early; it just isn't a substitute for the real board
when the question is latency.

---

## Phase 26 (preview) — What the four-way comparison will and won't prove

### Q: If the FPGA core turns out faster, what would that *not* prove?

**[System Design, Benchmarking Honesty]**

That FPGAs are "faster than software" in general — it would prove that
*this specific bounded matching operation*, compared fairly against a
*same-bounds* software reference (Phase 21's `BoundedMatchingEngine`, not
the unbounded `std::map` one), is faster in hardware. Collapsing the two
fabric-vs-bus latency numbers (fabric-internal vs. HPS-observed
round-trip, see `fpga-roadmap.md`) into one headline number would also
overstate the result — the round-trip number, which includes the LWH2F
bridge/MMIO hop, is the honest "if you deployed this" answer, and it's
expected to be meaningfully worse than the fabric-internal one. Reporting
both, and reporting reject rate (real for the FPGA, structurally absent
for unbounded software) alongside latency, is what keeps the comparison
honest rather than a headline that oversells a bounded microbenchmark.

---

## Phase 24 — Debugging a live HPS↔FPGA register interface

### Q: You write a value to a memory-mapped register from Linux
userspace and read back 0 instead of what you wrote. Walk through how
you'd diagnose that — is it a bug?

**[Hardware Debugging, Avalon-MM, Cyclone V SoC]**

Not necessarily — this happened for real in `fpga_matching_core`'s
`ORDER_ID_LO`/`ORDER_ID_HI`/etc. registers (`fpga_docs/bugs.md` #10),
and it turned out to be correct, documented behavior, not a bug. The
diagnostic order matters — cheapest, most likely explanations first:

1. **Check the design's own contract before assuming a defect.** The
   register map comment in `fpga_matching_core.sv` marks those registers
   `W` (write-only) — the read-data mux only covers `STATUS` through
   `LATENCY_CYCLES`; input registers fall through to
   `default: avs_readdata = 0`. A write-then-readback echo test was
   simply testing a guarantee the interface never made. The real test of
   a command-style register interface (write parameters, pulse a START
   bit, poll STATUS, read results) is a full round trip, not an echo.
2. **If it is genuinely dead, isolate the layer.** Before suspecting the
   specific peripheral, test something else on the *same* bridge with an
   observable physical effect — writing `0xFF` to a PIO driving LEDs and
   visually confirming they light up proves the whole
   HPS→LWH2F-bridge→interconnect→peripheral path is alive, independent
   of any one peripheral's own RTL correctness.
3. **Address math** — re-derive the HPS-side physical address from the
   actual generated `.qsys`/`.sopcinfo`, not from memory: LWH2F bridge
   base (`0xFF200000`, fixed on Cyclone V HPS) + the peripheral's base
   *within* the bridge's downstream Qsys address map (here `0x7000`).
4. **HPS-side state that gates the bridge**, checked via `devmem` on
   read-only diagnostic registers: the FPGA Manager's `stat` register
   (`0xFF706000`) reports whether HPS sees the fabric as fully configured
   (MODE field = 4/USER); the Reset Manager's `brgmodrst`
   (`0xFFD0501C`) reports whether the H2F/LWH2F/F2H bridges are held in
   reset. Both are real, fast, non-destructive reads worth doing before
   touching RTL.
5. **Clock-domain assumptions**, checked against the actual `.qsys`
   connections rather than assumed from memory of the interface's
   design intent.

**Follow-up:** "Why does JTAG-reconfiguring the fabric after Linux has
already booted not require a preloader/U-Boot rebuild?" → Because the
preloader only cares about `hps_isw_handoff/soc_system_hps_0/{hps,
emif}.xml` — HPS pin muxing and DDR3 timing — which are independent of
whatever Avalon peripheral map is wired into the FPGA fabric side of the
LWH2F bridge. If that HPS/DDR3 config is unchanged (diff it against a
known-good prior build to confirm, don't assume), the existing preloader
on the SD card is still valid for the new fabric image.

---

### Q: A design passes every directed simulation test, but real hardware
shows a different result on a large, realistic workload. Simulation
always seemed to prove correctness before — what's the gap, and how do
you find it without just staring at RTL and guessing?

**[Hardware Debugging, Reset Design, Verification Methodology]**

This happened for real (`fpga_docs/bugs.md` #11): 14/14 directed tests
passed, but a real 1,000,000-order hardware run showed a reject rate
19 points off from the golden C++ reference on the *identical* input.
The gap wasn't in the matching logic at all — it was in something every
simulation testbench does that real hardware never did: **explicitly
assert and release a reset pulse before driving any input.**
`DE10_Standard_golden_top.v` wired the core's reset to a permanently-tied
constant (`reset_reset_n(1'b1)`, never actually toggling), relying on
Quartus's bitstream configuration to initialize several KB of
book-storage registers to their synchronous-reset value. That assumption
is never exercised by a testbench that always pulses `rst_n` for real.

The methodology that found it, in order:
1. **Build the strongest possible correctness check simulation can give
   you before assuming the RTL is wrong**: a trace-replay testbench
   (`gen_trace.cpp` + `tb_trace_replay.sv`/`tb_trace_replay_wrapper.sv`)
   that runs the *exact same* large, realistic workload through both the
   golden C++ reference and the RTL, comparing every single order's
   result, not aggregate statistics. Both the bare matching core and the
   full real wrapper (Avalon interface + CDC, same-clock topology
   matching what's actually deployed) matched the reference **exactly**
   across all 1,000,000 orders.
2. That result reframes the question: if the RTL is provably correct
   under the one condition simulation actually tests (a genuine reset),
   the bug must be in the *difference* between what simulation always
   does and what hardware actually does. Reset assertion was the
   obvious, glaring candidate once framed that way — a tied-off reset
   is a well-known FPGA correctness pitfall precisely because it "works"
   in every testbench (which always resets explicitly) and silently
   depends on an unverified assumption on real silicon.
3. Fix: add a real power-on-reset generator (a small counter holding
   reset low for a handful of real clock cycles after configuration,
   then releasing it) instead of tying reset off permanently.

**Follow-up:** "Why didn't the 14 directed tests catch this?" → They ran
in a testbench that explicitly pulses `rst_n` before every test group
(`reset_dut()` in `tb_fpga_matching_core.sv`) — a correct, standard
simulation practice that happens to be exactly the condition real
hardware wasn't actually receiving. Passing simulation proves the design
is correct *given the precondition simulation assumes*; it doesn't prove
that precondition holds on real silicon. That's exactly why this
project's hardware testing (not just simulation) discipline mattered
here — the gap was invisible from the RTL and testbenches alone.
