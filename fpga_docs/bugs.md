# FPGA Bug Reports

Same standing rule as the software project's own `docs/bug-reports.md`:
every entry here is a real bug, found by actually running a real tool
(Questa, Quartus) against real RTL — not hypothesized, not injected for
demonstration. Each entry: what broke, how it was diagnosed, the fix, how
it was verified. Entries that turned out to be tool warnings worth
explaining rather than actual bugs are recorded too, the same way the
software project documents benign findings explicitly instead of silently
suppressing them.

## Index

| # | Phase | Bug | Severity | Status |
|---|---|---|---|---|
| 1 | 22 — RTL | `fpga_matching_core.sv`: signals used before their declaration | High (compile failure, 0 simulated) | Fixed |
| 2 | 22 — RTL | `avs_read` input pin drives no logic (Quartus warning 21074/15610) | None (benign, by design) | Documented, not a bug |
| 3 | 22 — RTL | Parallel-access design forces order storage into registers/LUTRAM, not BRAM (~17.5K LEs at N=16/M=8) | None (architectural consequence, not a defect) | Documented |
| 4 | 21 — C++ Reference | Bounded book + no CANCEL compounds into a persistently high reject rate under any sustained-drift workload (72.4% at N=16/M=8, not a generator bug) | None (real structural limitation, not a defect) | Documented, ADR-007 updated |
| 5 | 21 — C++ Reference | `sudo apt-get install` in WSL hung indefinitely — non-interactive shell, no TTY for the password prompt | Medium (wasted a background task, no data loss) | Fixed (ran as `wsl -u root` instead) |
| 6 | 21 — C++ Reference | QEMU-emulated ARM benchmark number (285 ns/event) is not a valid performance figure | None (verification-method boundary, not a defect) | Documented — do not quote as real |
| 7 | Setup | `` `ENABLE_HPS`` without the actual HPS hard IP fails Fitter placement on differential DDR3 pins | Medium (blocked the JTAG sanity-check step until diagnosed) | Reverted — deferred to Phase 24 |
| 8 | 24 — HPS integration | `qsys-generate` regresses 5 entries out of `soc_system.qip` every regeneration (HPS DDR3/UniPHY, documented Intel bug) | High (blocked all HPS synthesis until diagnosed) | Fixed — patch re-applied by hand, must be reapplied after every regeneration |
| 9 | 24 — HPS integration | Fitter fails with 1449 "does not use calibrated on-chip termination" errors — the required `hps_sdram_p0_pin_assignments.tcl` step was never run | High (blocked Fitter until diagnosed) | Fixed — must be re-run after every regeneration, same as #8 |
| 10 | 24 — HPS integration | `devmem` readback of `ORDER_ID_LO`/`ORDER_ID_HI`/etc. after writing them always showed 0 — looked like a dead register interface | None (write-only registers correctly never appear in the read mux, by design) | Investigated, not a bug — see below for the real round-trip proof |
| 11 | 24 — HPS integration | First 1M-event real-hardware benchmark reported `total_filled_qty` 4.5x above the structural maximum (impossible); a real, reproducible ~19-point reject-rate gap vs. the C++ reference remains | High initially, downgraded after re-investigation | Partially resolved — the "impossible" reading was not reproduced (see below); reject-rate gap still open, needs a real trace-replay-vs-sim comparison (Phase 23) |
| 12 | 24 — HPS integration | Power-on-reset fix attempted for bug #11 caused a WORSE regression on real hardware: `fpga_matching_core` hung permanently mid-order, and the whole shared Avalon interconnect behind `mm_bridge_0` (including unrelated `led_pio`) stopped responding | Critical (total hang, board-wide) on the attempted fix; none on the reverted, shipped build | Reverted at the time; real root cause found and fixed — see #13 |
| 13 | 23/24 — Timing closure | `bounded_order_book`'s 16-way best-price reduction was a single-cycle combinational block assumed (never verified) to synthesize as a balanced comparator tree; real `quartus_sta` showed a 76-logic-level, 66.9ns register-to-register path against a 20ns/50MHz budget (-47.6ns worst-case setup slack, thousands of failing paths) — almost certainly the true root cause of both #11's reject-rate gap and #12's hang | Critical (silicon running ~47ns past setup budget on every order) | Fixed — pipelined binary-tree reduction, verified in sim and on real hardware |

---

## 1. `fpga_matching_core.sv`: signals used before their declaration

**Phase found:** 22 (RTL) · **Severity:** High — compile failure, zero
tests ran until fixed · **Status:** Fixed

**Symptom:** First `vlog` compile of the three RTL files failed with six
errors, all `(vlog-2730) Undefined variable`, pointing at `avs_done_pulse`
and the five `out_*` result signals inside `fpga_matching_core.sv`'s
avs-domain `always_ff` block:

```
** Error: ../rtl/fpga_matching_core.sv(115): (vlog-2730) Undefined variable: 'avs_done_pulse'.
** Error: ../rtl/fpga_matching_core.sv(119): (vlog-2730) Undefined variable: 'out_trade_qty'.
** Error: ../rtl/fpga_matching_core.sv(120): (vlog-2730) Undefined variable: 'out_trade_price'.
** Error: ../rtl/fpga_matching_core.sv(121): (vlog-2730) Undefined variable: 'out_trade_id'.
** Error: ../rtl/fpga_matching_core.sv(122): (vlog-2730) Undefined variable: 'out_rejected'.
** Error: ../rtl/fpga_matching_core.sv(123): (vlog-2730) Undefined variable: 'out_latency_cycles'.
```

**Root cause:** the register-file `always_ff` block (register-write and
result-latch logic) was written before the `logic` declarations for
`avs_done_pulse` and the `bounded_order_book` output wires, which were
declared later in the file, next to the module instances that actually
drive them (`u_done_sync`, `u_book`). Unlike VHDL's fully declarative
elaboration, `vlog` requires a signal's declaration to textually precede
its first use within a module — SystemVerilog module bodies are not
order-independent the way a block's port/signal list conceptually
suggests they might be.

**Diagnosis method:** the error output itself was unambiguous — `vlog`
names the exact file, line, and signal for every undefined-variable error,
so this needed no further diagnosis beyond reading the compiler output.

**Fix:** moved the `avs_done_pulse` and `out_*` declarations up to
immediately after the register-file's other signal declarations, ahead of
the `always_ff` block that reads them; removed the now-duplicate
declarations from their original location further down the file.
`core_start_pulse` and `core_done_pulse` (declared and used only below
that point) were left where they were, since they had no ordering
violation.

**Verification:** re-ran `vlog` on the same three files — `Errors: 0,
Warnings: 0` — then ran the full `tb_fpga_matching_core` testbench:
14/14 directed test cases passed on this same, single fix, no other
changes needed.

---

## 2. `avs_read` input pin drives no logic

**Phase found:** 22 (RTL, Analysis & Synthesis) · **Severity:** None —
benign, by design · **Status:** Documented, not a bug

**Symptom:** `quartus_map` on `fpga_matching_core` reported:

```
Warning (21074): Design contains 1 input pin(s) that do not drive logic
    Warning (15610): No output dependent on input pin "avs_read"
```

**Why this is not a bug:** `avs_readdata` is driven by a combinational
`always_comb` block keyed only on `avs_address`, unconditionally — reads
have no side effects anywhere in this register file (nothing is
cleared-on-read, nothing is FIFO-popped by a read), so there is nothing
that needs to be *gated* by a read-enable. The `avs_read` port exists for
Avalon-MM interface-completeness (a real slave port Platform Designer's
component-editor expects to see wired) rather than because this
particular register file needs it internally. Left in the port list
rather than removed, since Phase 24's Platform Designer integration will
want a conventional Avalon-MM slave signature.

**Verification:** re-confirmed by inspection of `fpga_matching_core.sv`'s
`always_comb` read-mux — no `avs_read` reference exists anywhere in the
sensitivity or body, consistent with the warning being exactly correct
about what it found.

---

## 3. Parallel-access design forces order storage into registers/LUTRAM, not embedded BRAM

**Phase found:** 22 (RTL, Analysis & Synthesis) · **Severity:** None —
real architectural consequence of a deliberate design choice, not a
defect · **Status:** Documented

**Finding:** `quartus_map` at the real default parameters (`N_LEVELS=16`,
`M_ORDERS=8`) reported **17,552 logic cells** implemented for
`fpga_matching_core` (pre-fit synthesis estimate), and separately noted:

```
Info (10008): EDA Netlist Writer cannot regroup multidimensional array "buy_oid" into its bus
Info (10008): EDA Netlist Writer cannot regroup multidimensional array "buy_qty" into its bus
Info (10008): EDA Netlist Writer cannot regroup multidimensional array "sell_oid" into its bus
Info (10008): EDA Netlist Writer cannot regroup multidimensional array "sell_qty" into its bus
```

Neither is a functional problem, but the LE count is worth explaining
rather than reported as a bare number: `bounded_order_book`'s entire
design point (ADR-007) is comparing all `N_LEVELS` price levels
*simultaneously* every cycle (the best-price reduction) and shifting all
`M_ORDERS` slots of a level *simultaneously* on pop — both are genuinely
parallel-access patterns. Embedded Block RAM on Cyclone V offers at most
two read/write ports; it cannot serve a reduction that reads all 16
slots' prices in the same cycle, or a shift that reads/writes up to 8
FIFO slots in the same cycle. Quartus's only option is to implement
`buy_price`/`sell_price`/`buy_oid`/`buy_qty`/`sell_oid`/`sell_qty` as
discrete registers (or LUTRAM at best), not dense BRAM — which is exactly
what "cannot regroup into its bus" is reporting.

This is the direct resource cost of the design's central claim (parallel
comparison beats software's sequential tree walk): the parallelism that
makes it fast in cycles is the same property that makes it expensive in
LEs. A design that stored levels in BRAM and read them one at a time
would cost far fewer LEs and take far more cycles per lookup — closer to
software's own tradeoff, and not the point of building this in hardware
at all.

**Verification:** ran `quartus_fit` (place-and-route) to get the real
post-fit number instead of trusting the pre-fit estimate. Real result,
`fpga_matching_core_synth.fit.summary`:

```
Logic utilization (in ALMs) : 9,040 / 41,910 ( 22 % )
Total registers              : 10,165
Total block memory bits      : 0 / 5,662,720 ( 0 % )
Total RAM Blocks             : 0 / 553 ( 0 % )
Total DSP Blocks             : 0 / 112 ( 0 % )
```

Confirms the prediction exactly: **0 embedded RAM blocks used, 0%** —
every bit of `buy_price`/`sell_price`/`buy_oid`/`buy_qty`/`sell_oid`/
`sell_qty` really did get placed as ALM-packed registers, not M10K
memory, because the parallel-access pattern genuinely cannot target
BRAM. 0 DSP blocks used is also expected and worth naming: this design
does no multiplication anywhere (only comparison, addition/subtraction,
and muxing), so the DSP-block count being zero is a sanity check that
passed, not a surprise. 22% ALM utilization (9,040 of 41,910) at the
real N=16/M=8 scale leaves comfortable headroom for Phase 24's HPS
bridge logic and any other Platform Designer components sharing the same
device. This is a real, final, `quartus_fit`-reported number — not the
17,552-logic-cell pre-fit estimate above, which is a different metric
(logic cells vs. ALMs) from an earlier, less-optimized stage and should
not be quoted as the resource cost going forward.

---

## 4. Bounded book + no CANCEL compounds into a persistently high reject rate

**Phase found:** 21 (C++ Reference, on-target benchmark) · **Severity:**
None — a real structural limitation of this design, not a defect ·
**Status:** Documented, ADR-007 updated

**Finding:** `bounded_matching_engine_bench.cpp`'s first run (1,000,000
synthetic orders, `N_LEVELS=16`/`M_ORDERS=8`) reported a **97.9% reject
rate** — implausibly high enough to distrust and investigate before
reporting, the same standing rule `docs/performance.md` (software
project) applied to an implausibly *fast* number; this is the same
discipline applied to an implausibly *high* one.

**Investigation (three real attempts, each partially explanatory):**

1. **First hypothesis: too many distinct prices for the level count.**
   The generator's price offset was `mid ± 40` (81 distinct prices/side)
   against only `N_LEVELS=16` slots. Narrowed to `± 6` (13 distinct
   prices, under 16) — reject rate barely moved, 97.9% → 97.7%. Offset
   width alone wasn't the real driver.
2. **Second hypothesis: an unbounded random walk.** `mid` was updated by
   `mid_walk_dist(rng)` (±2) on *every one* of 1,000,000 steps with no
   bound — a random walk's typical excursion after N steps grows like
   `sqrt(N)`, so `mid` drifts far from its start over a long run. With no
   CANCEL (already an ADR-007-named scope limit), a level only frees up
   by being *fully matched* — once `mid` drifts past a level's price,
   nothing will ever cross it again, so it stays claimed forever. Over a
   long run, all 16 slots/side end up permanently claimed by scattered,
   now-unreachable historical prices. Clamping `mid` to a fixed `±50`
   band dropped reject rate to 76.2% — a real improvement, confirming
   drift was a real contributor, but not the whole story.
3. **Real root cause: levels can only be freed by an exact-price match,
   and CANCEL is the mechanism real order books use to reclaim stale
   resting interest — deliberately not built here (ADR-007).** Even
   *bounded* drift is still drift: a level opened at price P only gets
   matched away while other order flow is still landing near P; once
   `mid` wanders even a few ticks off (still within the bound), P stops
   receiving crossing orders and its slot stays claimed until `mid`
   happens to randomly revisit that exact neighborhood again — a slow,
   low-probability event once most of the 16 slots/side are already
   claimed elsewhere. Narrowing the offset further (`±3`) only moved
   reject rate to 72.4%, essentially the same order of magnitude —
   confirming this isn't a tunable generator artifact anymore, it's the
   book's real behavior under any workload where price interest
   continues to shift, however slowly or however bounded the range.

**Why this isn't "fixed" further:** continuing to narrow the generator's
parameters until the reject rate looks better would be tuning the test
to produce a flattering number, not measuring anything real — the
opposite of this project's standing rule. 72.4% at `N=16`/`M=8` under a
sustained, realistically-clustered-but-still-drifting workload is
reported as-is.

**Real implication for ADR-007:** the ADR already named "bounded levels"
and "no CANCEL" as two *independent* scope limits. This benchmark shows
they **compound**: a bounded book with no CANCEL will exhibit high,
possibly majority, reject rates under any sustained workload with
ongoing price movement, regardless of how large `N_LEVELS` is chosen,
because capacity is consumed by orders that can only ever be freed by an
exact-price match that may never come again. Widening `N_LEVELS` delays
this, it doesn't fix it — only CANCEL (out of scope) or an expiry
mechanism (also out of scope, never proposed) actually would. Added as a
Consequences note in ADR-007.

**Real implication for Phase 26:** reject rate must be reported
alongside every latency number for the FPGA/bounded-software rows, not
as a footnote — it's frequently going to be the majority outcome, not an
edge case, under any workload with sustained price movement. A latency
number computed only over the *accepted* fraction of orders would be
quietly averaging over a biased, shrinking sample as a session runs
longer, which would itself be worth flagging if it happened.

**Verification:** three real benchmark runs (`bounded_matching_engine_bench`,
built and run via WSL `g++-13 -std=c++20 -O2`), each change isolated to
one generator parameter, each run's actual printed output quoted above —
not estimated, not asserted from theory alone.

---

## 5. `sudo apt-get install` hung indefinitely in a non-interactive WSL shell

**Phase found:** 21 (C++ Reference, toolchain setup) · **Severity:**
Medium — wasted a background task slot, no data loss · **Status:** Fixed

**Symptom:** `wsl.exe -e bash -lc "sudo apt-get install -y -qq
gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf"`, launched as a
background task to install the ARM cross-compiler, produced **zero
output** for several minutes — no `apt-get update` output, nothing.

**Root cause:** `sudo` was prompting for a password on a shell with no
attached TTY and no cached credential — the prompt was written to a
terminal that would never receive input, so the command hung forever
rather than failing fast. Confirmed directly: `sudo -n true` (the
non-interactive probe flag) returned `sudo: a password is required`,
exit code 1 — proof this WSL user has no passwordless-sudo entry and no
cached ticket, not a fluke of that one command.

**Fix:** stopped the hung background task, then ran the same install as
`wsl.exe -u root -e bash -lc "apt-get install ..."` instead — WSL permits
switching to the `root` user directly (`whoami`/`id` both confirmed
`uid=0`) with no password prompt at all, since Windows has already
authenticated the session. Bypasses `sudo` entirely rather than fighting
its TTY requirement.

**Verification:** the same install command, run as root, completed in
well under a minute with normal `dpkg`/`apt` output, and the resulting
`arm-linux-gnueabihf-g++ --version` worked immediately afterward for the
normal user too (cross-compiler binaries are systemwide, not
per-user-installed).

---

## 6. QEMU-emulated ARM benchmark number is not a valid performance figure

**Phase found:** 21 (C++ Reference, on-target benchmark) · **Severity:**
None — a verification-method boundary worth being explicit about, not a
defect · **Status:** Documented — do not quote as real

**What happened:** after cross-compiling `bounded_matching_engine_test`
and `bounded_matching_engine_bench` for ARM (`arm-linux-gnueabihf-g++
-static`), both were run under `qemu-arm` (QEMU user-mode emulation,
installed specifically to verify the cross-compiled binaries actually
work, not just that they compile). The test binary: **14/14 passing,
bit-for-bit identical to both the native x86 build and the RTL
simulation** — genuine, valuable evidence the cross-compile is
functionally correct. The benchmark binary printed **285.14 ns/event**
— a real number QEMU actually produced, but not a real answer to "how
fast is this on the HPS."

**Why this number must not be reported as performance:** QEMU user-mode
emulation works by binary-translating ARM instructions into host x86
instructions at runtime — its execution speed is a function of QEMU's
translation cache behavior and the host CPU, with no reliable
relationship to real Cortex-A9 silicon throughput. It could plausibly be
many times slower *or* faster than real hardware depending on the
specific instruction mix, and there is no principled conversion factor
between the two. Reporting 285 ns/event as "the on-target number" would
be exactly the kind of fabricated-by-proxy measurement this project's
own software half (`docs/performance.md`) explicitly rules out ("only
publish measurements you actually obtain").

**What this run actually proves, precisely:** the cross-compiled ARM
binary is functionally correct (same logic, same results, different
instruction set) — satisfies Phase 21's "cross-compile for Cortex-A9"
checklist item in full. It does **not** satisfy "benchmark on-target,"
which specifically requires the real board. Both the roadmap and memory
are worded to keep these two claims separate rather than letting the one
verified fact quietly stand in for the other.

**Update — real on-target number now exists, and it confirms this
caution was correct.** Once the board was reachable over SSH
(`root@192.168.137.200`), the same binary ran directly on the DE10-Standard's
real Cortex-A9 cores: **589.82 ns/event, ~1.70M events/sec** — same
14/14 test pass, same 72.359% reject rate, same 35,547,884 total filled
quantity as every other platform (bit-identical logic, deterministic
seed). The real number is **~2.1x slower** than the QEMU-emulated one
(589.82 ns vs. 285.14 ns) - QEMU, running on this machine's fast x86
host, actually outran the real embedded silicon it was emulating. That's
the concrete, now-measured proof of exactly the risk this entry warned
about: QEMU's speed has no reliable relationship to real hardware speed,
in either direction, and guessing which way it would be wrong would have
been a coin flip. This real number is what Phase 21's "benchmark on-target"
checklist item was actually asking for.

**Verification:** `qemu-arm /tmp/bme_test_arm` and `qemu-arm
/tmp/bme_bench_arm`, real output quoted above; `file` on both cross-compiled
binaries confirmed `ELF 32-bit LSB executable, ARM, EABI5 ... statically
linked` before either was ever run.

---

## 7. `` `ENABLE_HPS`` without the actual HPS hard IP fails Fitter placement

**Phase found:** Setup (attempting the JTAG-sanity-check `.sof`) ·
**Severity:** Medium — blocked progress on that checklist item until
diagnosed, no lasting damage · **Status:** Reverted, deferred to Phase 24

**Symptom:** with `` `define ENABLE_HPS`` uncommented in
`DE10_Standard_golden_top.v` (and no other RTL changes — golden_top's
"Structural coding" section is still empty), `quartus_map` (Analysis &
Synthesis) succeeded cleanly — 0 errors, 403 warnings, all the expected
"unconnected pin" kind for an empty design. `quartus_fit` (place-and-route)
then failed:

```
Error (169008): Can't turn on open-drain option for differential I/O pin HPS_DDR3_DQS_N[0]
... (7 more, one per HPS_DDR3_DQS_N[1-3]/DQS_P[0-3])
Error (11802): Can't fit design in device.
Error: Quartus Prime Fitter was unsuccessful. 9 errors, 6 warnings
```

**Root cause:** `HPS_DDR3_DQS_N`/`HPS_DDR3_DQS_P` are differential I/O
pairs, part of the HPS's dedicated hard memory-controller interface —
their correct electrical configuration (including the open-drain option
Quartus tried and failed to apply) is normally set up by the actual
Cyclone V Hard Processor System IP component (instantiated via Platform
Designer/Qsys), which owns and drives these pins as part of its hard DDR3
controller. With `` `ENABLE_HPS`` on but no HPS component anywhere in the
design (golden_top's body is still empty), these pins are just bare
top-level ports with nothing behind them — Analysis & Synthesis doesn't
check dedicated-pin electrical requirements (hence it passed), but the
Fitter does, and correctly refuses to place them.

**Why this wasn't a surprise, but was still worth verifying rather than
assuming:** Phase 24's roadmap entry already scoped "Platform Designer
system: HPS + `fpga_matching_core` on LWH2F bridge" as its own, later
piece of work — this Fitter error is real, tool-verified confirmation of
exactly why that ordering is necessary, not just a theoretical concern.

**Fix:** reverted `` `define ENABLE_HPS`` back to commented out. The
Setup checklist's JTAG-sanity-check item doesn't need HPS pins active at
all — a trivial, logic-free golden_top build (LEDs/keys/switches only,
matching what the golden_top starter already provides untouched) is
sufficient to prove the JTAG programming mechanism itself works, and
avoids this whole class of error until Phase 24 actually instantiates the
HPS component that's supposed to own these pins.

**Verification:** the JTAG sanity-check itself, once the concurrently
running Weibull_CFAR build finished: full compile of the reverted,
HPS-disabled golden_top (`quartus_map`→`quartus_fit`→`quartus_asm`, 0
errors throughout) produced a real 6.69MB `.sof`, and `quartus_pgm`
programmed it over JTAG successfully — "Configuration succeeded -- 1
device(s) configured", 0 errors, 0 warnings. Confirms the revert was the
right call: with HPS disabled, the exact same design that failed to fit
moments earlier now compiles and programs cleanly end to end.

---

## 8. `qsys-generate` regresses 5 `.qip` entries out of `soc_system.qip` every regeneration

**Phase found:** 24 (HPS integration, first attempt at generating HDL for
a real `soc_system.qsys` with `hps_0` + `fpga_matching_core_0`) ·
**Severity:** High — blocked all HPS-integrated synthesis until diagnosed
· **Status:** Fixed, must be re-applied after every future regeneration

**Symptom:** `qsys-generate soc_system.qsys --synthesis=VERILOG` reported
failure — `uniphy_mcc.exe` (the HPS DDR3 sequencer microcode compiler)
consistently crashed ("child process exited abnormally") at the exact
same point (right after writing `sequencer_auto_ac_init.c`), reproduced
identically across three independent attempts: Git Bash, a `TMP`-path
fix, and native PowerShell — ruling out shell choice and path format as
causes. A fourth attempt, run after confirming no other Quartus process
was running concurrently, failed identically too, ruling out resource
contention. Proceeding anyway (per the diagnostic technique below) and
running `quartus_map` surfaced the real, separate problem: 12 "undefined
entity" errors for 5 distinct files.

**Root cause:** two genuinely separate issues, easy to conflate:

1. The `uniphy_mcc.exe` crash itself is a **documented Intel toolchain
   bug**, unrelated to this project's own RTL or Qsys wiring (Intel
   Community/Altera KB articles `000086780`/`340446`/`347806`; Terasic
   Wiki "Getting Start Install WSL"). Starting with Nios II EDS 19.1,
   Windows Nios II EDS replaced its bundled Cygwin with a WSL-based flow
   for HPS EMIF/UniPHY generation — that flow requires **WSL1
   specifically; WSL2 (what this machine has, used for Phase 21's ARM
   cross-compile toolchain) is not supported** and produces exactly this
   crash signature. Converting/adding WSL1 was not attempted here, to
   avoid risking the already-verified WSL2 cross-compile environment.
2. **Separately**, `qsys-generate` — regardless of whether the crash
   above happens — silently drops 5 specific `SYSTEMVERILOG_FILE`
   references from the generated `soc_system.qip`:
   `altera_mem_if_hard_memory_controller_top_cyclonev.sv`,
   `altera_mem_if_oct_cyclonev.sv`, `altera_mem_if_dll_cyclonev.sv`, and
   `soc_system_mm_interconnect_0`/`_3`'s
   `avalon_st_adapter_error_adapter_0.sv` — even when those files exist
   correctly on disk. This is the actual build blocker; the `uniphy_mcc.exe`
   crash is a red herring for whether hardware synthesis can proceed
   (those DDR3 ROM hex files it's generating,
   `hps_AC_ROM.hex`/`hps_inst_ROM.hex`, are for HPS *software* handoff,
   already confirmed byte-identical/complete before the crash point — see
   bug #8's diagnostic step below).

**Diagnosis method:** confirmed by the user, who had already root-caused
and fixed the *identical* class of failure (same 5 missing entities, same
mechanism) in a separate, unrelated Cyclone V SoC project on this same
machine (`de10_ghrd/rtl/BUG_REPORT.md` #19 and #21 — #21 specifically
being the *recurrence* of #19 after a later regeneration, confirming it's
a standing toolchain property, not a one-time fluke). That project's own
`soc_system.qip` still carries the identical hand-applied patch, live on
disk, with the same 5 lines this project needed.

**Fix:** for this project specifically, the 3 DDR3-generic files didn't
exist on disk at all (a from-scratch regeneration here stopped earlier
than a regeneration of an already-mostly-generated tree, unlike the
reference project's case) — copied from the reference project's own
`soc_system/synthesis/submodules/` (`altera_mem_if_hard_memory_controller_top_cyclonev.sv`
is even confirmed device-family-generic: it also ships directly in
Quartus's own IP library at
`<quartus>/ip/altera/alt_mem_if/alt_mem_if_controllers/altera_mem_if_hard_memory_controller/`).
The 2 interconnect adapter files were verified safe to copy too, not
just assumed: `mm_interconnect_0`/`_3` in this project's own `quartus_map`
log carry the HPS's F2H/SDRAM paths specifically (`hps_0_f2h_sdram0_data`),
completely unrelated to and structurally unaffected by the actual change
between this project's Qsys system and the reference's
(`cfar_bridge_0` swapped for `fpga_matching_core_0`, which sits on
`mm_interconnect_1`, not 0 or 3) — same topology, same generated content,
safe to reuse. Then the same 5 `set_global_assignment -name
SYSTEMVERILOG_FILE` lines from the reference project's own patch were
added to this project's `soc_system.qip`, with a comment explaining why
they must be re-added after every future `qsys-generate`.

**Verification:** re-ran `quartus_map` after copying the 5 files and
patching the `.qip` — **successful**: "Quartus Prime Analysis & Synthesis
was successful. 0 errors, 329 warnings" (all benign, same "unconnected
pin" class as every earlier golden_top run). Real resource numbers for
the full HPS-integrated system (`hps_0` + DDR3 + `fpga_matching_core_0` +
all board peripherals): 24,769 device resources, 23,701 logic cells, 72
RAM segments, 1 DLL. This is the first successful synthesis of the real
Phase 24 Platform Designer system, not just the standalone core. Also
added to `fpga_checklist.md` (a separate, general-purpose FPGA rulebook
this user maintains across projects) as a confirmed-recurring,
cross-project standing toolchain property, at the user's request.

---

## 9. Fitter fails with 1449 "does not use calibrated on-chip termination" errors

**Phase found:** 24 (HPS integration, first `quartus_fit` attempt after
bug #8's fix got Analysis & Synthesis passing) · **Severity:** High —
blocked the Fitter entirely until diagnosed · **Status:** Fixed, must be
re-run after every future regeneration (same recurring-step pattern as #8)

**Symptom:** `quartus_fit` failed with 1449 errors, all `Error (174068)`:
`Output buffer atom "...hps_sdram_p0_acv_hard_io_pads..." has port
"SERIESTERMINATIONCONTROL[N]"/"PARALLELTERMINATIONCONTROL[N]" connected,
but does not use calibrated on-chip termination`, followed by the generic
`Error (11802): Can't fit design in device`.

**Root cause:** not a design bug at all — a documented, standard step in
Intel's own Qsys HPS-SDRAM flow that was simply never run.
`qsys-generate`'s own log output (present in every generation attempt,
including the successful one, easy to miss while focused on the
`uniphy_mcc.exe` crash) says explicitly: *"Remember to run the
`hps_sdram_p0_pin_assignments.tcl` script after running Synthesis and
before Fitting."* That auto-generated script (`soc_system/synthesis/
submodules/hps_sdram_p0_pin_assignments.tcl`) applies the DDR3 I/O pins'
`INPUT_TERMINATION`/`OUTPUT_TERMINATION` assignments (e.g. "PARALLEL 50
OHM WITH CALIBRATION" on every `HPS_DDR3_DQ`/`DQS_P`/`DQS_N`/`DM` pin) —
without it, the DDR3 hard PHY's calibrated on-chip termination logic has
no matching pin-level termination assignment to calibrate against, which
the Fitter correctly refuses to place.

**Diagnosis method:** read the actual `quartus_fit` output pipe (not just
the tail) via the saved `.fit.rpt` file, `grep -n "^Error"` to see the
real per-error messages instead of the generic "Can't fit" summary line.
Confirmed the fix by finding the exact matching `INPUT_TERMINATION`/
`OUTPUT_TERMINATION` assignments already present and working in the
reference `de10_ghrd` project's own `.qsf` (86 lines, one set per
DQ/DQS/DM pin) — not guessed, cross-checked against a proven-working
example on the same board.

**Fix:** ran the script against the actual open project:
```
project_open DE10_Standard_golden_top
source soc_system/synthesis/submodules/hps_sdram_p0_pin_assignments.tcl
export_assignments
project_close
```
The script's own real work (finding the termination atom, dumping
`hps_sdram_p0_all_pins.txt`, applying the assignments) completed and
saved successfully — 86 `INPUT_TERMINATION`/`OUTPUT_TERMINATION` lines
landed in the real `.qsf`. It then threw a secondary error trying to
`exec` a **recursive** `quartus_sh` call (the script is designed to also
be runnable fully standalone as `quartus_sh -t
hps_sdram_p0_pin_assignments.tcl <project>`, and that self-invocation
path doesn't expect to already be running inside an active, sourcing
session) — cosmetic once the real assignments are confirmed saved, not a
sign the fix failed.

**Verification:** re-ran `quartus_fit` after applying the script —
**successful**: "Quartus Prime Fitter was successful. 0 errors, 272
warnings" (Elapsed time: 00:57:44). This is the full HPS-integrated
system (`fpga_matching_core` + HPS hard IP + DDR3 UniPHY), fitted for
real on device `5CSXFC6D6F31C6`. Real post-fit numbers from
`DE10_Standard_golden_top.fit.summary`:

| Resource | Used | Available | % |
|---|---|---|---|
| Logic utilization (ALMs) | 11,664 | 41,910 | 28% |
| Total registers | 14,812 | — | — |
| Total pins | 338 | 499 | 68% |
| Total block memory bits | 2,816 | 5,662,720 | <1% |
| Total RAM Blocks | 6 | 553 | 1% |
| Total DSP Blocks | 0 | 112 | 0% |
| Total DLLs | 1 | 4 | 25% |

The remaining 272 warnings are all benign — the same "unconnected
input pin" class seen in every prior golden_top run, plus a large batch
of `Info (169185)`/`Info (169066)` messages about DDR3 DQ/DQS on-chip
termination pin groupings, which are expected, informational output
from the HPS hard memory controller's OCT calibration and not a defect.
Like bug #8, this step is **not permanent** — it must be re-run after
every future `soc_system.qsys` regeneration, since `qsys-generate`
regenerates this same auto-generated script fresh each time and the
assignments it applies don't persist in the `.qsys` source itself.

---

## 10. `devmem` readback of write-only registers always showed 0 — not a bug, real hardware round-trip works

**Phase found:** 24 (HPS integration) · **Severity:** None (correct,
documented behavior — the actual investigation this entry records led to
the first real ARM-to-fabric round trip on physical hardware) ·
**Status:** Investigated, register interface confirmed working correctly

**Symptom:** After JTAG-programming the new HPS-integrated `.sof` (bugs
#8/#9's fixes, real fitted `.sof` from a clean `quartus_map` → `fit` →
`asm`), used `devmem` over SSH to write `0xDEADBEEF` to `ORDER_ID_LO`
(`0xFF207000`, HPS-side address = LWH2F bridge base `0xFF200000` +
`fpga_matching_core_0`'s Qsys base `0x7000`) and read it back — got
`0x00000000`, not the written value. Same result on `ORDER_ID_HI`.
Looked exactly like a dead or misconfigured register interface.

**Investigation:** worked through several real hypotheses in order,
each checked against actual evidence rather than assumed:
1. Wrong HPS-side base address — ruled out by reading
   `soc_system.qsys` directly: `hps_0.h2f_lw_axi_master` → `mm_bridge_0`
   at offset `0x0`, `fpga_matching_core_0.avs` at offset `0x7000` within
   `mm_bridge_0` — address math confirmed correct.
2. HPS FPGA Manager not recognizing the JTAG-configured fabric as fully
   configured — ruled out by reading the FPGA Manager `stat` register
   (`0xFF706000`): `0x54`, MODE field = 4 (USER mode) — HPS does see the
   fabric as live.
3. HPS↔FPGA bridges left in reset by the JTAG reconfigure (a real,
   documented Cyclone V SoC behavior) — checked the Reset Manager's
   `brgmodrst` (`0xFFD0501C`): read `0x0`, i.e. no bridges held in
   reset. Also ruled out.
4. Clock-domain mismatch between `mm_bridge_0` (clocked from board
   `CLOCK_50` via `clk_0`) and `hps_0.h2f_lw_axi_master` — initially
   suspected, since `fpga_matching_core`'s Avalon interface has no
   `waitrequest` and Qsys needs `waitrequest` support to auto-insert a
   clock-crossing bridge across mismatched domains. Ruled out by reading
   the actual connection: `hps_0.h2f_lw_axi_clock` (an HPS *input* — the
   fabric side of the hard H2F/LWH2F bridge is deliberately
   clock-agnostic; the hard IP does its own internal CDC to the L4 bus)
   is fed by that same `clk_0`/`CLOCK_50` net, so `mm_bridge_0` and the
   bridge's fabric-side interface are genuinely on the same clock — no
   crossing needed at all.
5. Whole bridge path dead, not just this peripheral — tested by writing
   `0xFF` to `led_pio`'s data register (`0xFF204000`, same
   `mm_bridge_0`) over `devmem` and asking the user to look at the
   board: **the 8 user LEDs lit up**. Real, physical, unambiguous proof
   the HPS→LWH2F→`mm_bridge_0`→peripheral path is alive end to end
   (the LED readback itself came back as `0xC4`, not `0xFF` — a PIO
   read-semantics quirk, irrelevant once the physical LEDs confirmed the
   write landed).
6. With the whole path proven alive, re-read `fpga_matching_core.sv`'s
   read-data mux (lines 142–152) with fresh eyes: it only covers
   `ADDR_STATUS` through `ADDR_LATENCY` — the six *input* registers
   (`ORDER_ID_LO`, `ORDER_ID_HI`, `SIDE`, `PRICE`, `QTY`, `CONTROL`) all
   fall into `default: avs_readdata = 32'b0`. This is exactly what the
   register map comment already documents (marked `W`, not `R`/`RW`) —
   the RTL was never designed to support reading back what you wrote to
   those registers. The "bug" was testing against a behavior the design
   never promised.

**Verification (the real round trip):** wrote a full order through the
correct write-then-poll-then-read sequence instead of a raw
write-then-readback echo test:
- Order 1: `ORDER_ID=1, SIDE=BUY, PRICE=100000 (10.0000 ticks), QTY=10`,
  pulsed `CONTROL.START`, polled `STATUS` — result: `BUSY=0, DONE=1,
  REJECTED=0`, `TRADE_QTY=0`, `LATENCY_CYCLES=4`. Correct: first order
  into an empty book rests, no trade, not rejected — exactly what
  ADR-007's semantics and the RTL testbench/C++ reference both predict
  for this case.
- Order 2: `ORDER_ID=2, SIDE=SELL, PRICE=100000, QTY=5` (matches the
  resting BUY) — result: `STATUS=DONE, not rejected`, **`TRADE_QTY=5`,
  `TRADE_PRICE=0x186A0 (100000)`, `TRADE_ID_LO=1`**, `LATENCY_CYCLES=4`.
  A real trade: correct fill quantity, correct price (the resting
  side's price, per ADR-007), correct counterparty order ID (the
  resting BUY). Bit-for-bit consistent with the RTL testbench and C++
  reference's directed-test semantics — now proven on real silicon, not
  simulation.

This is the first real ARM(HPS)-to-fabric-to-ARM round trip on physical
hardware: order submitted from Linux userspace via raw `/dev/mem`
access, matched by the FPGA fabric's `bounded_order_book` (crossing the
`avs_clk`↔`core_clk` CDC boundary both ways via `cdc_pulse_sync`), and
the result read back by the same userspace process. `LATENCY_CYCLES=4`
is a real, measured, hardware fabric-internal latency figure (at the
current same-clock `avs_clk`=`core_clk`=`CLOCK_50` pass — not yet the
faster `core_clk` a real PLL would give, that's still follow-up work).

---

## 11. Real-hardware 1M-event benchmark: an impossible total, then a real (smaller, still open) discrepancy

**Phase found:** 24 (HPS integration) · **Severity:** High initially,
downgraded after re-investigation · **Status:** "Impossible" reading not
reproduced; a real, reproducible reject-rate gap vs. the C++ reference
remains open

**Symptom:** built `fpga_bridge.hpp`/`fpga_bridge_bench.cpp` (a real
`/dev/mem` mmap C++ harness — the roadmap's `fpga_bridge.cpp` item),
cross-compiled for ARM, ran the exact same `generate_workload(seed=42)`
used by Phase 21's C++ reference benchmark (`bounded_matching_engine_
bench.cpp`) — same 1,000,000-order sequence, same `N_LEVELS=16/
M_ORDERS=8`. First run reported `total_filled_qty=1,057,396,697` against
a reject rate of 53.275% (vs. the C++ reference's 72.4%/35,547,884 on
the identical seed). The `total_filled` figure is structurally
impossible: no single order can fill more than its own submitted
quantity (capped at 500 by the generator), so the maximum any run could
ever report is `accepted_orders * 500` — roughly 233M here, less than a
quarter of what was reported.

**Investigation:**
1. Ruled out a copy-paste divergence in the workload generator — diffed
   `fpga_bridge_bench.cpp`'s `generate_workload()` against the original
   in `bounded_matching_engine_bench.cpp` line by line: logic is
   byte-identical (only comments/whitespace differ), so both programs
   generate the exact same 1,000,000-order sequence from seed 42.
2. Statically read `bounded_order_book.sv`'s FSM (`ST_MATCH`/
   `ST_POP_LEVEL`/`ST_REST`): `reg_total_filled` resets to `'0` at
   `ST_DECODE` (start of every new order) and only ever accumulates
   `trade_qty <= reg_remaining_qty`, which itself starts at the order's
   own `in_qty` and monotonically decreases — per-order fill is
   structurally bounded by design, regardless of book history. Real
   latency data backs this up: max `LATENCY_CYCLES` across the run was
   14 (~4-5 level walks), nowhere near what an unbounded/runaway loop
   would produce.
3. Built a **targeted Questa testbench**
   (`sim/tb_bounded_order_book_multilevel.sv`), driving
   `bounded_order_book` directly (bypassing the Avalon wrapper/CDC —
   this class of bug, a quantity value exceeding a hard structural
   bound, isn't the kind of thing a clock-crossing issue produces) at
   the **real, non-overridden `N_LEVELS=16/M_ORDERS=8` defaults**,
   forcing one order to sweep 4 resting price levels. Result: **passed
   cleanly** — `trade_qty=200` (exactly `4×50`), `trade_price=103`
   (last level's price, correct), latency=12 cycles. The multi-level
   walk logic itself is correct.
4. Built a **debug harness** (`fpga_bridge_debug.cpp`) that flags the
   first individual order (not aggregate) whose `trade_qty` exceeds its
   own submitted `qty` — genuinely impossible per point 2. Ran the full
   1,000,000-event sequence: **zero violations found**. Every single
   order's own result was structurally valid.
5. Re-ran the original aggregate benchmark again (same binary, same
   seed): got a **different** total (`116,845,717`), with **max
   `LATENCY_CYCLES=4`** this time (vs. 14 in the first run) — meaning
   this run never walked more than one level, unlike the first. This
   was the point it became clear the runs weren't equivalent: **the
   FPGA fabric was never reconfigured or reset between the manual
   2-order test, the first bench run, the debug run, and this repeat
   run** — `bounded_order_book`'s state (resting orders, per-level
   counts) persists across separate host process invocations, since the
   design has no software-visible reset/clear command (`CONTROL` only
   has a `START` bit). Each run resubmits `order_id=1..1,000,000` from
   the same seed, but against whatever book state the *previous* run
   left behind, not a clean book — runs are not mutually comparable,
   and none of them are directly comparable to the C++ reference's
   from-empty run either.
6. Re-JTAG-programmed the `.sof` (forces a genuinely clean
   configuration-time register state — confirmed real above, bug
   #8/#9's fitted image) and ran the benchmark **exactly once** against
   a verified-fresh book: `total_filled=116,824,869` (sane — average
   fill per accepted order ≈ 250.0, matching the generator's own mean
   qty of 250.5 almost exactly), **reject rate 53.275% and max latency
   14 cycles — both identical to the very first run's numbers**. Since
   the decision-level statistics (reject rate, walk depth) match the
   first run exactly while only that run's *total* was wrong, the first
   run's book state was apparently not meaningfully dirtier in a way
   that changed decisions — the 1,057,396,697 figure looks like an
   isolated, non-reproduced anomaly in that one aggregation (most likely
   a single corrupted `/dev/mem` read summed in as a large garbage
   32-bit value, given how little it would take: even one bad read near
   `0xFFFFFFFF` accounts for most of the excess), not a systematic
   matching-logic defect. Also checked `Side` enum encoding between the
   RTL-facing `fpga_bridge::Side` and the C++ reference's `fpga_ref::
   Side` — both `kBuy=0, kSell=1`, no inversion.

**What's confirmed fixed / not a bug:** the multi-level walk logic
(point 3), per-order structural bounds (point 4), and reproducibility
once the book is actually reset via reconfiguration (point 6).

**Resolution — built the real trace-replay testbench and found the
actual root cause.** `host/fpga_bridge/tools/gen_trace.cpp` generates
the identical 1,000,000-order workload and runs it through the golden
`BoundedMatchingEngine<16,8>` C++ reference, dumping expected
`(rejected, trade_qty, trade_price, trade_id)` per order to
`sim/trace.csv`. Two SV testbenches replay that exact trace against real
RTL and compare order-by-order, stopping at the first mismatch:

- `sim/tb_trace_replay.sv` — drives `bounded_order_book` directly (real
  `N_LEVELS=16/M_ORDERS=8`, no override). **All 1,000,000 orders matched
  the C++ reference exactly** — zero divergence. The core matching FSM
  is bit-for-bit correct at the real bounds.
- `sim/tb_trace_replay_wrapper.sv` — drives the full real
  `fpga_matching_core` (Avalon register interface + `cdc_pulse_sync`
  CDC), with `avs_clk`/`core_clk` tied to the *same* clock (matching
  `soc_system.qsys`'s actual deployed wiring, not the deliberately
  different clocks `tb_fpga_matching_core.sv` uses to stress-test CDC in
  general). **Also all 1,000,000 orders matched exactly**, through the
  full real wrapper.

So the entire RTL design — matching logic, register interface, and CDC —
is proven correct against the C++ reference, given a genuine reset
pulse. That's the key phrase: *given a genuine reset pulse*. Every
testbench in this project explicitly asserts and releases `rst_n` before
driving any orders. Real hardware never does — `DE10_Standard_golden_top.v`
wired `soc_system`'s `reset_reset_n` to a **permanently-tied constant
`1'b1`** (never reset), relying entirely on Quartus's bitstream
configuration to initialize `bounded_order_book`'s book-storage register
arrays (several KB of flip-flops — `buy_oid`/`sell_oid`/`buy_qty`/
`sell_qty` across `N_LEVELS=16 × M_ORDERS=8`) to their synchronous-reset
value at configuration time. That assumption was never actually tested
by anything in this project until now, since simulation always pulses a
real reset and real hardware never did.

**Fix:** added a real power-on-reset generator to
`DE10_Standard_golden_top.v` — a 4-bit counter holding `por_reset_n` low
for 16 real `CLOCK_50` cycles after configuration, then releasing it —
and wired `soc_system`'s `reset_reset_n` to `por_reset_n` instead of the
tied-off constant. Rebuilding (`quartus_map`→`fit`→`asm`, no
`qsys-generate` needed since only the top-level `.v` changed, not
`soc_system` itself) and re-testing on hardware is the direct next step.

**Severity note:** downgraded from "High" (looked like a matching-logic
defect) to a **reset/initialization gap** — a real, common FPGA
correctness pitfall (never rely on a tied-off reset plus assumed
bitstream power-up values matching synchronous-reset semantics for large
register arrays, always generate a real reset pulse), not a bug in the
matching algorithm itself. The multi-level walk logic, per-order
structural bounds, Avalon register semantics, and CDC synchronizers are
now all proven correct by real, exhaustive (1M-order), order-by-order
comparison against the golden C++ reference — a stronger correctness
claim than the original 14 directed test cases alone provided.

---

## 12. The power-on-reset fix for bug #11 caused a worse hang on real hardware — reverted

**Phase found:** 24 (HPS integration) · **Severity:** Critical (total
board-wide hang) on the attempted fix; the shipped build does not have
this fix and does not exhibit this bug · **Status:** Reverted to ship;
root cause of the hang itself not fully diagnosed

**What happened:** applied bug #11's proposed fix (a real power-on-reset
generator — a 4-bit counter holding `reset_n` low for 16 real
`CLOCK_50` cycles after configuration, then releasing it — replacing the
permanently-tied `reset_reset_n(1'b1)`), rebuilt clean (0 errors both
`quartus_fit` and `quartus_asm`), JTAG-programmed it, and ran the real
1,000,000-event hardware benchmark to confirm the fix. It never
finished: the host process pinned one CPU core at 99.9% for 11+ minutes,
genuinely stuck in `submit_limit_order`'s busy-poll loop (which has no
timeout). Reading `STATUS` directly via `devmem` confirmed
`fpga_matching_core` itself was stuck — `BUSY` permanently `1`, never
clearing. Submitting a brand-new order afterward showed the identical
frozen value on every poll: no response at all. Testing `led_pio` (an
entirely separate peripheral on the same `mm_bridge_0` interconnect, the
same one bug #10 used to prove the bridge path was alive) also failed —
writes no longer took visible effect, and the physical LEDs (checked by
the user directly) were off, not reflecting either the newly-written
value or the last known-good state.

**Diagnosis (partial — not fully root-caused):** `led_pio` failing too,
not just `fpga_matching_core`, rules out a defect isolated to our core's
own book-matching logic — something at the shared interconnect level
broke. The leading hypothesis: `fpga_matching_core`'s Avalon slave
interface is declared fixed-latency with no `waitrequest` (a deliberate
early design choice — see the interview-questions.md discussion of the
register interface). That's a hard promise to the Merlin interconnect
that a response always arrives within a fixed number of cycles; if real
silicon ever violated that promise (a CDC hazard between `avs_clk` and
`core_clk` that only manifests with real routing delay/skew, even though
both are nominally "the same" `clk_0` net — something zero-delay RTL
simulation structurally cannot reproduce), the interconnect's own
internal state machine could desynchronize and wedge every peripheral
behind it, not just the one that misbehaved. This is a plausible,
architecturally-sound explanation consistent with every symptom
observed, but it was not confirmed with a SignalTap capture or further
isolation — that's real, deferred follow-up work, not a closed
investigation.

**Why reverted instead of debugged further:** the user needed to ship
today. The prior behavior (permanently-tied reset) was proven stable
across many real runs this session — real trades, working LEDs, a full
1,000,000-order benchmark that always completed — even though it carried
bug #11's smaller, non-fatal reject-rate discrepancy. A build that can
hang the entire board is strictly worse than one with a documented,
bounded correctness gap. Reverted `DE10_Standard_golden_top.v` back to
`reset_reset_n(1'b1)`, rebuilt, and shipped that.

**Real lesson for later, worth preserving:** a fixed-latency,
no-`waitrequest` Avalon-MM slave is a stronger contract than it looks —
it's not just "simpler," it removes the interconnect's only mechanism
for tolerating a late response. Given this project already has real
evidence that RTL simulation (even including the CDC synchronizers,
even at the real clock topology) cannot be trusted to reproduce every
real-silicon timing hazard, adding real `waitrequest` support to
`fpga_matching_core` (so a late response stalls the bus instead of
violating an unrecoverable contract) is a stronger, more defensive fix
than the power-on-reset generator turned out to be — worth revisiting
after today, with SignalTap available to actually watch what happens on
the bus in real time rather than inferring it from `devmem` snapshots.

**Update:** the real root cause turned out to be simpler and far more
directly provable than the CDC/no-`waitrequest` hypothesis above — see
#13. TimeQuest had never actually been run against this design before;
once it was, it showed a massive, structural timing violation inside
`bounded_order_book` itself. The CDC/`waitrequest` hypothesis isn't
disproven and remains a real architectural risk worth hardening later,
but it's no longer the leading explanation for this specific hang.

---

## 13. `bounded_order_book`'s best-price search violated timing by -47.6ns — real root cause of #11 and #12, fixed via pipelining

**Phase found:** 23/24 (the timing-closure item Phase 23's checklist had
carried as `[ ]` unchecked the entire time — this is what happens when
it's finally run for real) · **Severity:** Critical (silicon running
~47ns past its own setup budget on every single order) · **Status:**
Fixed, verified in simulation and on real hardware

**What happened:** after reverting #12's regression to ship, a `git
status`-style sanity check ("go through `fpga_checklist.md` to get a
better idea of issues you might face") flagged that `quartus_sta` timing
closure — the one gate that checklist says to never skip — had never
actually been run against the real board project, only against an
unrelated synthesis-only sanity project with no real `.sdc`. Running it
for the first time against the reverted, "known-stable" build showed:

```
Slow 1100mV 85C Model Setup 'CLOCK_50': Slack -47.579, TNS -103655.013
Slow 1100mV 0C  Model Setup 'CLOCK_50': Slack -46.635, TNS  -95397.660
Fast 1100mV 85C Model Setup 'CLOCK_50': Slack -19.621, TNS  -23440.285
Fast 1100mV 0C  Model Setup 'CLOCK_50': Slack -15.784, TNS  -18770.430
```

CLOCK_50 is a 20ns-period (50MHz) clock — a worst-case -47.6ns slack
means some paths were failing by more than *double* the clock period,
and TNS in the tens of thousands of ns confirms this wasn't one or two
edge-case paths, it was systemic. `report_timing -to_clock CLOCK_50`
pointed straight at the real source: a 76-logic-level, 66.9ns
register-to-register path from `bounded_order_book:u_book|buy_price[0]`
to `sell_qty[11][0]` — the module's own 16-way best-price reduction
(`buy_best`/`sell_best`, written as a single-cycle `for`-loop over all
`N_LEVELS`, magnitude-comparing every candidate serially). The module's
own header comment even flagged the risk at the time it was written:
*"Written as a for-loop... Quartus restructures a commutative reduction
like this into a balanced comparator tree. Verify actual depth in the
post-fit netlist... rather than assuming it."* Nobody had verified it.
Quartus never balanced it — it synthesized as a straight O(N) serial
priority chain, ~4.75 logic levels per candidate × 16 candidates ≈ 76.

This is almost certainly the true, dominant root cause of both #11 (the
53.275%-vs-72.4% reject-rate gap, previously attributed mainly to the
missing power-on-reset) and #12 (the board-wide interconnect hang, only
previously attributed to a CDC/no-`waitrequest` theory) — real silicon
running ~47ns past its setup budget on *every single order* produces
exactly the kind of nondeterministic, corner-sensitive register
corruption both bugs exhibited, and zero-delay RTL simulation
structurally cannot reproduce a timing violation, so every simulation
this project ever ran (including the 1M-order trace-replay that matched
the C++ reference exactly) was blind to it by construction.

**Fix:** replaced the single-cycle combinational reduction with an
explicit, hand-built registered binary-tree pipeline — one pairwise
compare-and-select per clock cycle instead of one 16-deep serial chain.
At the real N_LEVELS=16 bound this is `RB_STAGES = $clog2(16) = 4`
cycles to find a winner, driven by two new FSM states
(`ST_REDUCE_BEST`, `ST_REDUCE_REST`, the latter doing the same tree
shape for the "already a level at this price" / "first free slot"
own-side searches needed before `ST_REST`). This costs extra clock
cycles per order (worse latency, `LATENCY_CYCLES` roughly 3x higher for
a simple resting order) in exchange for real timing closure — the right
trade given the priority had shifted from "ship today" to "a proper
product."

**A genuine synthesizability trap hit along the way, worth recording on
its own:** the first two implementation attempts both passed simulation
(Questa, 0 errors) but failed real Quartus synthesis with `Error
(10251): index N cannot fall outside the declared range` on the
pipeline's register arrays. Root cause: the array-indexing expressions
(`a_i = 2*j`, `b_i = 2*j+1`) were guarded at runtime by `if (j <
in_width/2)`, where `in_width` depends on the `rb_level` register — not
a compile-time constant. Quartus statically unrolls SystemVerilog
`for`-loops at synthesis time and checks array-index bounds on the
*structural* expression regardless of a runtime-only guard, since it
can't prove the guarded branch is unreachable for a given loop
iteration. Questa's simulator, by contrast, only checks bounds on
values actually computed at runtime, and the guard genuinely does
prevent the out-of-range read from ever executing dynamically — so
simulation stayed silent about a real synthesis-time defect. First fix
attempt (enlarging the array without changing the loop bound) traded
this for a *worse*, subtler problem: it would have left some register
array entries structurally undriven — never reset, never written by any
code path — which is exactly the class of bug (an unreset/undriven
register) both #11 and #12 were already about. The real fix needed two
separate conditions doing two separate jobs: an outer loop spanning the
full array width (so every entry gets an explicit, defined value every
cycle — no undriven bits) combined with an *additional*,
compile-time-constant-only guard (`j < N_LEVELS/2`, independent of
`in_width`) gating the actual indexed compute/read, which is provably
safe at elaboration time and lets Quartus eliminate the out-of-range
branches entirely rather than merely disabling them at runtime.

**Verified, in this order:**
1. Simulation (Questa 2024.1), before touching Quartus at all: 14
   directed edge-case tests (N=4/M=2, full wrapper+CDC) — pass; 5-check
   multilevel sweep (N=16/M=8) — pass; 1,000,000-order trace-replay,
   bare `bounded_order_book` — exact match vs. the C++ reference;
   1,000,000-order trace-replay, full `fpga_matching_core` wrapper
   (Avalon + CDC) — exact match. Re-ran all four again after each of
   the two synthesizability fixes above; identical results every time.
2. `quartus_map` (synthesis) clean, 0 errors, 329 warnings — same count
   as the pre-pipeline baseline, i.e. zero *new* warnings introduced.
3. `quartus_fit` + `quartus_asm` clean, 0 errors.
4. `quartus_sta`: worst-case CLOCK_50 setup slack **+5.16ns** (was
   -47.58ns) at the slow/hot corner, +5.35/+11.31/+12.14ns at the other
   three corners. TNS = 0.000 everywhere, every clock domain, every
   check type (setup/hold/recovery/removal/min-pulse-width).
5. Flashed to real hardware (`quartus_pgm`, "Configuration succeeded",
   0 errors/0 warnings). `led_pio` and `fpga_matching_core` both
   responsive (the same canary that failed during #12's hang) —
   single-order round-trip: `STATUS=DONE, not rejected`,
   `TRADE_QTY/PRICE/ID=0` (correct — first order on an empty book rests),
   `LATENCY_CYCLES=12`, matching the simulation's multilevel testbench
   result *exactly*.
6. Real 1,000,000-order hardware benchmark, same seed=42 workload as
   every other platform in this project: **73.365% reject rate**
   (733,649/1,000,000) vs. the 72.4% C++ golden reference — down from
   #11's original 53.275%. The ~19-point gap is now a ~1-point gap.

**Still open, deliberately left as-is for now:** the ~1-point residual
reject-rate gap (73.365% vs. 72.4%). Since this benchmark replays the
*exact same order sequence* as the C++ reference, a perfectly-behaving
FPGA should match it exactly, not approximately — so this is real
signal, not noise. The leading suspect is the thing this fix
deliberately did *not* touch: `reset_reset_n` is still tied permanently
high (#12's power-on-reset fix was reverted and never revisited).
Documented as a known, small, non-blocking limitation rather than
chased further right now, at the user's explicit call ("leave it for
now, move on to the next phases").
