# Consolidated Verification Matrix

Every row maps to a `make` target that runs locally and in CI. Status legend:
**PROVEN** = k-induction step closes (unbounded) · **PASS** = BMC-bounded ·
**REACHED** = cover witness hit · **info** = informational (not a gate).

Tools: Yosys 0.64, SymbiYosys 0.66, Verilator 5.049, nextpnr 0.10, Verible
v0.0-4071, solver yices. Formal harness DEPTH=8 unless noted.

## Synchronous FIFO (`sync_fifo`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Mutual exclusion `!(full&&empty)` | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Empty-clears-after-write, full-clears-after-read | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Write/read pointer monotonicity | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Count range / empty⇔0 / full⇔DEPTH / shadow-count | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Count step ±1 | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Almost-full / almost-empty track count | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Aux inductive invariants (`a_aux_*`) | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Bounded progress drain/fill, no-deadlock | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Data ordering `$anyconst` (`a_data_integrity`) | bmc | 20 | sby/yices | ✅ PASS (step open) |
| No duplicate read / no read-before-write | bmc | 20 | sby/yices | ✅ PASS (step open) |
| 10 cover witnesses (fill, drain, wrap×2, simul R+W, full→empty→full, sustained drain/fill, round-trip) | cover | 30 | sby/yices | ✅ all REACHED |

## Asynchronous FIFO (`async_fifo`, dual-clock CDC)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Gray pointers change by exactly one bit | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| Gray encodes binary | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| Binary pointer monotone per domain | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| No overflow / no underflow | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| Occupancy 0..DEPTH | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| No missed-full; empty matches read view | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| Cross-domain data integrity (`$anyconst`) | bmc (multiclk) | 16 | sby/yices | ✅ PASS |
| 4 cover witnesses (full, non-empty, Gray wrap, round-trip) | cover | 30 | sby/yices | ✅ all REACHED |
| k-induction | prove | — | sby/yices | ⚠️ info (step open) |

## AXI4-Stream wrapper (`axis_fifo`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Master TVALID stable until accepted | bmc | 20 | sby/yices | ✅ PASS |
| Master TDATA / TLAST stable while stalled | bmc | 20 | sby/yices | ✅ PASS |
| No spurious valid (TVALID iff data held) | bmc | 20 | sby/yices | ✅ PASS |
| Slave handshake / no overflow | bmc | 20 | sby/yices | ✅ PASS |
| Registered-latency skid invariants | bmc | 20 | sby/yices | ✅ PASS |
| No data loss under backpressure | bmc | 20 | sby/yices | ✅ PASS |
| End-to-end data/last integrity (`$anyconst`) | bmc | 20 | sby/yices | ✅ PASS |
| 4 cover witnesses (deliver, stall-resume, round-trip, TLAST out) | cover | 30 | sby/yices | ✅ all REACHED |

## Simulation & coverage (`sync_fifo`)

| Check | Tool | Result |
|-------|------|--------|
| 13 directed/random tests, DEPTH 4/8/16/64/256 | Verilator | ✅ 0 errors |
| Functional coverage bins | Verilator TB | ✅ 10/10 (100%), hard-gated |
| Line / toggle / branch / expr coverage | verilator_coverage | ✅ 100% / 100% / 100% / 100% |
| Fault-injection anti-vacuity | Verilator | ✅ fault caught (exit ≠ 0) |

## FPGA place-and-route (open-source flow)

| Part | Tool | Result |
|------|------|--------|
| ECP5 LFE5U-85F (CABGA381) | yosys + nextpnr-ecp5 | ✅ all depths fit, ~175–294 MHz |
| iCE40 UP5K (SG48) | yosys + nextpnr-ice40 | ✅ all depths fit, ~59–73 MHz |

Full tables: [fpga_results.md](fpga_results.md). See
[proven_vs_tested.md](proven_vs_tested.md) for the integrity framing.
