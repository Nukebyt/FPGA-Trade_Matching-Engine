# FPGA Matching Engine — Roadmap (Checklist)

> **Note on this copy**: synced from
> [Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)'s
> `docs/fpga-roadmap.md` (source of truth if the two drift). Written
> while this repo (the Quartus/RTL project) and that one were developed
> side by side as sibling folders on one machine — some phrasing below
> still reflects that original local layout (e.g. "lives outside this
> repo," "not git-tracked here") rather than this repo's own
> perspective; read those as historical narration of how the work was
> done, not as claims about this repo's current structure. `docs/*.md`
> mentions below are the software repo's docs; `fpga_docs/*.md`
> mentions are local to this repo — see
> [fpga_docs/bugs.md](../fpga_docs/bugs.md).

Continuation of the 19-phase software project, scoped to: **hardware
matching-engine core only** (protocol decode/sequencing/risk stay in C++ on
the HPS ARM cores), **HPS-mediated ingress** (no fabric-side NIC), **hand
SystemVerilog** RTL. Board + Quartus already set up.

**Two numbers this whole roadmap exists to produce, kept separate on
purpose:** (1) fabric-internal latency (order-accept cycle → result-valid
cycle, timestamped inside the fabric) — the fair comparison against a
same-bounds software engine; (2) HPS-observed round-trip latency (includes
the LWH2F bridge/MMIO hop) — the honest "if you actually deployed this"
number. Never collapse these into one headline number.

**Deployment path — JTAG and SD card, not one or the other:** JTAG
(`quartus_pgm`) reprograms fabric only, fast, volatile — used throughout
Phase 22/23/25 RTL iteration, and mandatory for Phase 25's SignalTap
capture (that's how SignalTap streams data back, no substitute). SD card
is mandatory separately, for the HPS: the ARM Cortex-A9 cores need to boot
embedded Linux from somewhere before Phase 24's `fpga_bridge.cpp` harness
can run — preloader → U-Boot → device tree → kernel → rootfs, the same
flow the `de10_ghrd` reference project's Makefile already builds. Fabric
config and HPS boot are independent on Cyclone V SoC, so once Linux is up
off the card, JTAG can keep reprogramming just the fabric across RTL
revisions without touching the card or rebooting. Only Phase 29/30's
standalone demo is worth baking the final `.rbf` into the SD card itself.

**Bug/interview tracking:** kept outside this repo too, alongside the
Quartus project — `f:/Projects/trading_infra_fpga/fpga_docs/bugs.md` and
`fpga_docs/interview-questions.md`, same standing rules as the software
project's own `docs/bug-reports.md`/`docs/interview-prep.md` (real bugs
found by actually running the tools, built incrementally per phase).

---

## Setup

- [x] Golden-top Quartus project skeleton assembled (`.v`, `.sdc`, `.qpf`,
      `platform_setup.tcl`, `filelist.txt`) in `d10_standard_golden_top/`
- [ ] `` `ENABLE_HPS`` uncommented in `DE10_Standard_golden_top.v` —
      **tried, reverted**: fails Fitter placement (differential DDR3
      `DQS_N`/`DQS_P` pins need the actual HPS hard IP driving them,
      which doesn't exist until Phase 24's Platform Designer work) — see
      `fpga_docs/bugs.md` #7. Stays commented out until Phase 24
- [x] Project opens and compiles clean in Quartus as-is, before any custom
      RTL — real `.qsf` generated from `platform_setup.tcl`, `quartus_map`
      0 errors (HPS disabled)
- [x] Sanity-check JTAG path: golden-top `.sof` programs over USB-Blaster
      via `quartus_pgm` before any custom RTL exists — **done, for real**:
      full compile (`quartus_map`→`quartus_fit`→`quartus_asm`, all 0
      errors) produced a real 6.69MB `.sof`; `quartus_pgm -c "DE-SoC
      [USB-1]" -m JTAG -o "p;...sof@2"` reported "Configuration succeeded
      -- 1 device(s) configured", 0 errors. Bonus: Quartus's own log line
      (`...for device 5CSXFC6D6F31@2`) confirms the exact correct part,
      resolving the earlier `jtagconfig` generic-label concern
- [x] Confirm board's current SD card boots HPS Linux (Terasic
      `DE10-Standard_Linux_Console.img` or equivalent) before Phase 24 needs it
      — confirmed for real: `ssh root@192.168.137.200` succeeded, blank
      password, board is up on the network (bonus: also confirms the
      HPS-Ethernet-reachability item Phase 24/27 needed, ahead of schedule)

## Phase 20 — Bounded-book design + ADR

- [x] Fix N price levels/side, M orders/level, price bit-width (reuse
      `kPriceScale = 10000` tick convention) — N_LEVELS=16, M_ORDERS=8,
      32-bit signed price ticks, 32-bit qty, 64-bit order id
- [x] Decide overflow behavior (reject at boundary) and document it as a
      named limitation — reject only on resting the remainder; matching
      itself can never overflow
- [x] Write `docs/adr/ADR-007-fpga-bounded-order-book.md`

## Phase 21 — Bounded software reference (runs on HPS ARM cores)

- [x] New `BoundedMatchingEngine` C++ target, same bounds as Phase 20, same
      price-time-priority semantics as `matching_engine.cpp` —
      `d10_standard_golden_top/host/bounded_matching_engine/`, header-only
      template class. Same 14 directed cases as the RTL testbench,
      **14/14 passing, bit-for-bit identical results to the hardware sim**
- [x] Cross-compile for Cortex-A9 — resolved via WSL
      `apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf`
      (user's choice over downloading Intel's vendor-matched SoC EDS —
      see `fpga_docs/bugs.md` #5 for the tradeoff and the real ABI risk
      it accepts). Both test and benchmark cross-compile clean with
      `-Wall -Wextra -Wpedantic`, real 32-bit ARM EABI5 static ELF
      binaries (`file` confirmed), and — functionally verified under
      QEMU user-mode emulation, not just "compiles" — **14/14 tests
      pass, bit-for-bit identical to both native x86 and the RTL sim**.
      CMake toolchain file at `host/toolchain-arm-cortex-a9.cmake` for
      reuse in Phase 24
- [x] Benchmark on-target (ns/event, on the DE10 itself) — **done, for
      real**: `scp`'d the cross-compiled binary to `root@192.168.137.200`
      and ran it directly on the board's Cortex-A9 cores. Real result:
      **589.82 ns/event, ~1.70M events/sec**, same 14/14 test pass and
      same 72.359% reject rate as every other platform (deterministic,
      bit-identical logic across x86/QEMU/real-ARM). Context, all real
      measurements, none guessed: x86 native ~69 ns/event; QEMU-emulated
      ARM 285 ns/event (not a valid perf number, see `fpga_docs/bugs.md`
      #6); real ARM 589.82 ns/event is ~2.1x *slower* than the QEMU
      number — concrete proof QEMU's speed has no reliable relationship
      to real hardware, confirming #6's caution rather than just
      asserting it

## Phase 22 — RTL: hardware matching core

- [x] `fpga_matching_core.sv`: N-level parallel price array + priority
      compare (no tree, no pointer chasing) — `rtl/bounded_order_book.sv`
      + `rtl/fpga_matching_core.sv` (Avalon-MM wrapper)
- [x] Per-level order FIFO — **not BRAM**: the FSM's parallel compare/shift
      access pattern (all N levels read simultaneously for best-price;
      all M slots shifted simultaneously on pop) can't be served by
      BRAM's 1-2 ports, so Quartus implements it as registers/LUTRAM
      instead. Real deviation from this plan's original wording — see
      `fpga_docs/bugs.md` #3
- [x] Matching FSM: compare → consume → emit trade(s) → rest remainder —
      `ST_IDLE → ST_DECODE → ST_MATCH → ST_POP_LEVEL → ST_REST → ST_DONE`
- [x] Free-running fabric-clock cycle counter, latched at accept/result-valid
- [x] LWH2F Avalon-MM register map (`ORDER_ID`/`SIDE`/`PRICE`/`QTY`/`START`
      in; `DONE`/`TRADE_QTY`/`TRADE_PRICE`/`LATENCY_CYCLES` out) —
      word-addressed, no `waitrequest` (fixed 0/1-cycle latency slave)
- [x] 2-flop synchronizer on every clock-domain-crossing control pulse —
      `rtl/cdc_pulse_sync.sv`, handshake-protected data bus (not per-bit
      sync — see `fpga_docs/interview-questions.md`)
- [x] Quartus resource report (LE/BRAM/DSP) — measured, not guessed —
      real `quartus_fit` (place-and-route) on device `5CSXFC6D6F31C6`:
      **9,040 / 41,910 ALMs (22%)**, **0 block RAM (0%)**, **0 DSP (0%)**
      at N_LEVELS=16/M_ORDERS=8. 0 errors, 5 fitter warnings (all
      expected — no SDC yet, no pin assignments; see `fpga_docs/bugs.md`
      #2/#3). Zero BRAM usage confirms the design's parallel-access
      pattern genuinely can't target embedded RAM, exactly as predicted

## Phase 23 — Simulation and verification

- [x] ModelSim/Questa testbench covering the same cases as `MatchingEngineTest`
      — `sim/tb_fpga_matching_core.sv`, 14 directed cases (resting add,
      price-improvement trade convention, full-consume-and-pop,
      multi-level walk with aggregate accounting, level-full reject,
      book-full reject) — **14/14 passing** on real Questa 2024.1
- [x] Trace-replay testbench: `host/fpga_bridge/tools/gen_trace.cpp`
      generates the workload + C++ reference expected results,
      `sim/tb_trace_replay.sv` and `sim/tb_trace_replay_wrapper.sv`
      replay it against RTL (bare core, and the full real wrapper+CDC)
      and compare order-by-order. **All 1,000,000 orders matched
      exactly, both ways.** This is what root-caused
      `fpga_docs/bugs.md` #11's reject-rate gap — not an RTL defect, a
      missing power-on-reset generator (see above)
- [x] TimeQuest timing closure at the chosen fabric clock (no negative slack)
      — run for real for the first time this session, and it caught a real
      bug: `bounded_order_book`'s 16-way best-price reduction synthesized
      as a 76-logic-level serial chain, -47.6ns worst-case setup slack on
      CLOCK_50 (thousands of failing paths, TNS in the tens of thousands
      of ns) — see `fpga_docs/bugs.md` #13. Fixed via a pipelined
      binary-tree reduction; re-ran `quartus_sta`: worst-case slack now
      **+5.16ns** (slow/hot corner), TNS = 0.000 everywhere, every clock
      domain, every check type. This is very likely the true root cause of
      both #11 and #12, not just #11's missing-reset theory

## Phase 24 — HPS ⟷ FPGA integration

- [x] Platform Designer system: HPS + `fpga_matching_core` on LWH2F bridge
      — real `soc_system.qsys` built by copying `de10_ghrd`'s proven
      HPS/DDR3 config and swapping `cfar_bridge_0` for `fpga_matching_core_0`
      on the same `mm_bridge_0` (confirmed lightweight-bridge) connection,
      base `0x7000`. Full HPS-integrated system (DDR3 + all board
      peripherals + our core) synthesizes clean: **0 errors, 24,769
      device resources, 23,701 logic cells, 72 RAM segments**. Hit and
      fixed a real, documented Intel toolchain bug along the way
      (`qsys-generate` regressing 5 `.qip` entries) — see
      `fpga_docs/bugs.md` #8. `core_clk`/`core_reset` tied to the same
      clock as `avs_clk` for this pass, deliberately — a real PLL for a
      genuinely faster core clock is follow-up work, not done yet
- [x] `quartus_fit` (place-and-route) on the full HPS-integrated system,
      device `5CSXFC6D6F31C6` — hit and fixed a second real toolchain
      issue first (Fitter failed with 1449 "does not use calibrated
      on-chip termination" errors because `qsys-generate`'s own
      auto-generated `hps_sdram_p0_pin_assignments.tcl` post-synthesis
      step had never been run — see `fpga_docs/bugs.md` #9). Re-ran
      `quartus_fit` clean: **0 errors, 272 warnings, 11,664/41,910 ALMs
      (28%), 14,812 registers, 6/553 RAM blocks, 0 DSP blocks**. This is
      a real, fitted, placed-and-routed design — not an estimate
- [x] `quartus_asm` — generate the real `.sof` for this HPS-integrated
      system. **0 errors, 2 warnings**, real `.sof` written
      (`output_files/DE10_Standard_golden_top.sof`, 7.42MB). One warning
      is a genuine pointer to the next item, not noise — Warning (11713):
      "The configuration of the Hard Processor Subsystem (HPS) within
      this design has changed. The Preloader software that initializes
      the HPS requires an update. Using
      `hps_isw_handoff/soc_system_hps_0/`, run the Preloader Support
      Package Generator to update your Preloader software"
- [x] Device tree fragment / preloader / U-Boot / kernel rebuild — **not
      needed**. Diffed `hps_isw_handoff/soc_system_hps_0/{hps,emif}.xml`
      (the files that actually drive HPS pin mux + DDR3 timing) against
      the reference project's copy: byte-for-byte identical, since
      `hps_0`'s config was deliberately reused unchanged. The Assembler's
      Warning (11713) about HPS config changing is generic boilerplate
      from a fresh `hps_isw_handoff/` generation, not a real electrical
      change. `fpga_matching_core_0` is accessed via raw `/dev/mem` from
      userspace, not a kernel driver, so no device tree node is required
      either. Confirmed empirically, not just by inspection — see below.
- [x] SD card: original Weibull_CFAR card was unavailable; flashed
      Terasic's stock `de10_standard_linux_console.img` (already present
      at `F:\DE10 FPGA\DE10-Standard_Linux_Console\`) onto a new card via
      Win32DiskImager. Board boots, reachable at
      `root@192.168.137.200`, same as before
- [x] JTAG-programmed the real, fitted `.sof` (bugs #8/#9's fixes) onto
      the live board — "Configuration succeeded", 0 errors/0 warnings.
      Confirmed board stayed reachable afterward (fabric-only JTAG
      reprogram doesn't disturb the already-booted HPS/Linux)
- [x] `fpga/host` bridge harness — done via raw `devmem` over SSH first
      (proves the mechanism before writing `fpga_bridge.cpp`); a real
      C++ `/dev/mem` mmap harness is still the cleaner permanent form,
      not yet written
- [x] **Real order round-trips ARM → fabric → ARM — verified on physical
      hardware.** Two directed orders (matching the RTL testbench/C++
      reference's own test cases): order 1 (BUY, empty book) rests, no
      trade, not rejected; order 2 (matching SELL) trades — `TRADE_QTY=5`,
      `TRADE_PRICE` = resting order's price, `TRADE_ID_LO` = resting
      order's ID, bit-for-bit consistent with simulation and the C++
      reference. Real measured `LATENCY_CYCLES=4` per order. Full
      diagnosis trail (a real dead-end investigation before finding the
      register interface was correct all along) in `fpga_docs/bugs.md`
      #10. Correction: Phase 23's own "trace-replay testbench" item below
      is still unchecked — there is no RTL-sim-vs-C++-reference trace
      run to reuse yet, so "same trace Phase 23 validated" was inaccurate
      when first written here. What's next is a real workload through
      real hardware, not a replay of a simulation result that doesn't
      exist yet
- [x] `fpga/host/fpga_bridge.hpp` + `fpga_bridge_bench.cpp` — real
      `/dev/mem` mmap C++ harness, cross-compiled ARM, run on hardware
      with the exact same 1M-event workload as Phase 21's C++ reference
      benchmark. Found and investigated a real anomaly along the way —
      see `fpga_docs/bugs.md` #11: an "impossible" first-run total
      turned out to be a non-reproduced isolated glitch (multi-level
      walk logic and per-order bounds both confirmed correct via a
      targeted testbench and a per-order debug scan), but a genuine,
      reproducible 53.275% vs. 72.4% reject-rate gap against the C++
      reference remains open and unexplained
- [x] Root-caused bug #11's reject-rate gap via Phase 23's trace-replay
      testbench (see below) — **not an RTL bug**. Both
      `bounded_order_book` alone and the full `fpga_matching_core`
      wrapper (Avalon + CDC, same-clock topology matching real hardware)
      matched the C++ reference **exactly across all 1,000,000 orders**
      in simulation, given a genuine reset pulse. Real root cause:
      `DE10_Standard_golden_top.v` tied `soc_system`'s `reset_reset_n` to
      a permanent constant (`1'b1`, never reset) — relying on Quartus's
      bitstream configuration to initialize the book's large register
      arrays correctly, an assumption no simulation ever tested since
      every testbench pulses a real reset.
- [x] Attempted fix (real power-on-reset generator) — **reverted after
      testing on hardware caused a worse regression**: `fpga_matching_core`
      hung permanently mid-order and took the whole shared Avalon
      interconnect down with it (`led_pio`, unrelated, also stopped
      responding). Leading hypothesis at the time: the core's
      fixed-latency, no-`waitrequest` Avalon interface is a promise real
      silicon's CDC apparently broke once. Reverted to the known-stable
      permanently-tied reset to ship that day. Full trail in
      `fpga_docs/bugs.md` #12 — **superseded by the real root cause found
      below**
- [x] Real root cause of #11/#12 found and fixed: `quartus_sta` (run for
      the first time — see Phase 23 above) showed `bounded_order_book`'s
      best-price search was -47.6ns past its setup budget on real
      silicon on every single order. Fixed via a pipelined binary-tree
      reduction, verified in simulation (all prior sim results
      reproduced exactly) and on real hardware: timing now closes with
      **+5.16ns margin**, board stays responsive after flashing
      (`led_pio` + `fpga_matching_core` both alive, unlike #12's hang),
      single-order round-trip matches simulation's `LATENCY_CYCLES`
      exactly, and the real 1,000,000-order benchmark reject rate is now
      **73.365%** vs. the 72.4% C++ reference — down from #11's original
      53.275%. Full trail in `fpga_docs/bugs.md` #13
- [ ] Residual ~1-point reject-rate gap (73.365% vs. 72.4%) — small,
      real, non-blocking. Leading suspect: `reset_reset_n` is still tied
      permanently high (the power-on-reset fix above was reverted for
      #12 and never revisited). Left as a documented, known limitation
      for now at the user's call ("leave it for now, move on to the next
      phases") — not chased further this session
- [ ] Confirm HPS Ethernet can reach the x86-hosted Kafka broker (needed by
      Phase 27) while Linux boots off the SD card

## Phase 25 — Latency instrumentation cross-check

- [ ] JTAG connected (mandatory — SignalTap has no other capture path)
- [ ] SignalTap capture of `START`/`DONE`/latency register, independent of
      the HPS-read path
- [ ] SignalTap vs. HPS-read values agree over several hundred transactions
- [ ] Document real achieved Fmax and the resulting ns/cycle conversion

## Phase 26 — Four-way comparison harness

- [x] Rows 2-4 replay one identical trace (`generate_workload(seed=42)`,
      1M ADD_ORDER events, real N_LEVELS=16/M_ORDERS=8 bounds) through:

  | # | Measures | Compare against |
  |---|---|---|
  | 1 | x86 dev-machine, unbounded `std::map` (existing, reused not re-run — different workload generator, unbounded scope, genuinely context only) | context only, not head-to-head |
  | 2 | ARM (HPS), bounded C++ reference — real hardware | baseline for row 3 |
  | 3 | FPGA fabric-internal latency — real hardware | direct vs. row 2 |
  | 4 | FPGA HPS-observed round-trip — real hardware | the honest deployed-today number |

  Not one literal cross-machine binary (row 1 is x86-only, rows 2-4 run
  on the DE10's ARM cores — can't be a single running executable) — "one
  trace" means the same generator/seed used consistently, not one binary
- [x] Report mean/median **and p50/p99** for rows 2-4 (real per-event
      `chrono` instrumentation, not just an aggregate mean) — row 1 has
      no p50/p99 (Google Benchmark's macro timing doesn't expose
      per-iteration latency the way rows 2-4's manual harnesses do; noted
      as a real, explained gap, not silently omitted)
- [x] Reported **reject rate** for rows 2/3/4 as a first-class number:
      72.359% (row 2) / 73.555% (rows 3+4) vs. Phase 21's 72.4%
      reference — close but not exact, a small real residual gap tied to
      bug #13's "still open" note (missing POR), documented rather than
      hidden
- [x] `docs/fpga-performance.md` written with all four numbers, labeled
      — also surfaced a real, unhidden measurement-methodology finding:
      per-call `chrono::steady_clock::now()` costs ~1.3-2.5µs on this ARM
      target (likely a non-vDSO syscall path), inflating rows 2/4's
      instrumented numbers relative to the aggregate-timer-only figures
      measured earlier this session — both numbers reported, not just
      one

## Phase 27 — Backend plumbing

Architecture decision made explicitly with the user before implementing
(three options presented, this one chosen): the DE10 board's
`fpga_latency_harness` (new,
`d10_standard_golden_top/host/fpga_latency_harness/`, sibling/non-git
per this project's established convention) runs on the ARM cores
(needs `/dev/mem` for the real FPGA), continuously drives rows 2/3/4
through the SAME workload generator as Phase 26, and every 500ms writes
a local JSON snapshot (`/tmp/fpga_latency_snapshot.json`, atomic
write-then-rename). It does NOT link Kafka directly - no ARM
cross-compile of librdkafka exists in this project (only the plain C++
stdlib has been cross-compiled so far). A new git-tracked module,
`fpga-latency/`, SSH-pulls that snapshot (SSH ControlMaster/
ControlPersist to avoid a fresh handshake every 500ms poll) and
republishes it verbatim through the real, already-working
`KafkaProducer`/`RedisClient` - one schema-defining place
(`fpga_latency_harness.cpp`'s hand-written JSON), no re-serialization
step in the forwarder.

- [x] New Kafka topic `fpga-latency` (+ `fpga-latency-dlq`), published by
      `fpga-latency/`'s forwarder (`fpga_latency_forwarder`) - the "long-
      running comparison harness" is really two cooperating processes
      (ARM harness + x86 forwarder), not one binary - see above
- [x] Consumer → new `fpga_latency_windows` Postgres table -
      `persistence_consumer` now subscribes to `fpga-latency` alongside
      orders/executions/risk-events, same batch/commit-ordering
      discipline. Real finding along the way: the DE10 board's clock is
      NOT NTP-synced (observed directly - its `window_end_unix_ns`
      corresponds to a date roughly 8-9 months in the past relative to
      the PC's clock) - the schema uses it only as the idempotency key
      (`UNIQUE`, protects against Kafka redelivery), never for query
      ordering; `received_at` (this server's own clock) is what
      `/fpga-latency/history` actually orders by
- [x] `fpga_latency:latest` Redis key (same 500ms cadence as top-of-book)
      - `FpgaLatencyCache`, a single-global-key analog of
      `TopOfBookCache` (no per-instrument family needed, exactly one
      live stream)
- [x] `api_gateway`: REST `/api/fpga-latency/history` (roadmap said
      "/fpga-latency/history" in plain-text description - served under
      `/api/...` here to match every other route's convention, not a
      deviation) + WebSocket channel (reserved pseudo-symbol
      `"FPGA_LATENCY"` on the existing subscribe protocol - simpler
      than top-of-book's per-instrument channel since there's exactly
      one global stream)

**Verification status, reported honestly rather than claimed
uniformly:** `fpga_latency_forwarder` (the real new binary - actual
KafkaProducer/RedisClient/JsonReader, no stubs) builds and links clean
in a from-scratch WSL validation environment; `fpga_latency_core_tests`
(5 tests) all pass. `rest_server.cpp`'s new route syntax-checks with
zero errors. The `persistence`/`postgres_reader.cpp` additions follow
the exact pre-existing pattern byte-for-byte and fail to compile in
that same scratch environment for a confirmed pre-existing reason
unrelated to this work: the environment's apt-installed libpqxx (7.8.1)
genuinely lacks the `exec(query, params)` overload this project's
*existing, untouched* code already uses everywhere (`ensure_instrument`,
`write_orders`, etc. all fail identically) - a version gap in the
validation environment, not a defect introduced here. Similarly,
`websocket_server.cpp` hits a websocketpp-vs-C++20/GCC13
injected-class-name incompatibility entirely inside websocketpp's own
headers, unrelated to this session's two-line diff there (a
constructor parameter, one new conditional branch). Both gaps are named
here rather than silently claimed as "fully verified" - the real
target environment (this project's actual Docker-based build, not this
scratch WSL setup) may well have matching library versions already;
this just wasn't independently confirmed this session.

## Phase 28 — Frontend comparison panel

- [x] `FpgaLatencyComparison.tsx`, subscribed to the new WebSocket channel
      (`useFpgaLatency.ts`, `FPGA_LATENCY` pseudo-symbol on the existing
      subscribe protocol)
- [x] Rolling p50/p99 tiles + live chart, rows 2/3/4 side by side, each
      labeled with what it measures (dataviz skill followed: form choice,
      3-color categorical palette validated via `validate_palette.js` for
      both light/dark modes, 2px lines, mandatory crosshair+tooltip hover
      layer built with `createElement`/`textContent` not `innerHTML`,
      three single-axis small multiples instead of one dual-axis chart
      since row 3 is raw cycles and rows 2/4 are ns)
- [x] `tsc -b` and `npm run build` (`vite build`) both pass cleanly with
      no errors
- [ ] Verified live end-to-end against the real running stack (needs the
      Docker backend stack + `fpga_latency_harness` running on the board +
      `fpga_latency_forwarder` running, pointed at both — not yet attempted)

## Phase 29 — Resource/throughput report

- [x] Final fitter report as % of the 5CSXFC6D6F31C6's real LE/BRAM/DSP
      budget for the *full integrated system* — **10,688/41,910 ALMs
      (26%), 15,358 registers, 6/553 RAM blocks (1%), 0 DSP** — compared
      against Phase 22's standalone-core-only number (22% ALMs, 0%
      BRAM/DSP); the ~1,648-ALM/6-RAM-block delta is attributed to HPS
      bridge/Platform Designer plumbing, not the order book itself (still
      confirmed 0% BRAM). Multi-corner timing closure also re-confirmed
      post bug-#13-fix: TNS=0.000 at every corner/check type. Full
      numbers and reasoning in `docs/fpga-performance.md`'s Phase 29
      section.
- [x] Sustained-load test; report whichever of {bridge, core} becomes the
      throughput ceiling — reused Phase 26's real 1M-order back-to-back
      hardware run (already a genuine sustained-load test, no artificial
      pacing) rather than re-running: core ceiling ~3.90M events/sec
      (256.31 ns/event), bridge ceiling ~157.7K events/sec (6341.75
      ns/event). **The bridge is the ceiling, by ~24.75x** — the
      single-order-at-a-time blocking MMIO round-trip, not the fabric's
      compute speed. Named the request-queue/FIFO register-map extension
      as the highest-leverage follow-up if higher deployed throughput is
      ever pursued (not attempted).
- [ ] (Optional, standalone-demo polish) final `.rbf` baked into the SD
      card boot flow so the board runs the comparison with no PC/JTAG
      attached — deliberately not attempted (physical SD re-imaging,
      same hard-to-reverse category as flashing; not requested)

## Phase 30 — Docs

- [x] ADR-007 finalized with what actually got built vs. planned — new
      "Amendment (Phases 22-29)" section: the reduction is pipelined
      (4 cycles), not single-cycle as originally written; `core_clk`
      isn't yet a genuinely faster domain than `avs_clk`; the ~1-point
      reject-rate gap; confirmation the register map was built exactly
      as planned; the throughput-ceiling finding from Phase 29
- [x] `docs/fpga-matching-engine.md` deep-dive — register map, matching
      algorithm (with the pipelined-reduction correction explained),
      clock domains, real measured-results table, Phase 27/28
      integration diagram, known open gaps, references
- [x] `docs/foundations.md` gets an FPGA/RTL primer entry — new §18:
      FPGA/RTL/synthesis/timing-closure/pipelining/Avalon-MM/CDC/HPS/
      Questa, tied back to this project's own real bug (#13) as the
      worked example
- [x] `docs/architecture.md` status section updated — new "Status: FPGA
      extension (Phases 20-29 of 30)" section, plus the repository-
      structure tree updated to list `fpga-latency/` and the new docs
