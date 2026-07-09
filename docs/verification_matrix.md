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

## FWFT (show-ahead) FIFO (`sync_fifo_fwft`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Show-ahead: head word on `rd_data` with zero latency | bmc | 20 | sby/yices | ✅ PASS |
| `valid` ⇔ non-empty | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Pointer / count / flag invariants | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| No overflow / no underflow | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| Count monotone (step ±1) | bmc + k-ind | 20 / 15 | sby/yices | ✅ PROVEN |
| No duplicate read / no read-before-write | bmc | 20 | sby/yices | ✅ PASS |
| 4 cover witnesses (full, show-ahead, full→empty, round-trip) | cover | 30 | sby/yices | ✅ all REACHED |

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

## Asymmetric-width FIFO (`sync_fifo_width`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Data crosses width change in FIFO order, correct sub-word position | bmc | 14 | sby/yices | ✅ PASS (both directions) |
| Pointer advance at correct per-side beat rates | bmc | 14 | sby/yices | ✅ PASS |
| No overflow / no underflow | bmc | 14 | sby/yices | ✅ PASS |
| Count consistency | bmc | 14 | sby/yices | ✅ PASS |
| Cover witnesses (tracked round-trip, fill, ratio transitions) | cover | 30 | sby/yices | ✅ all REACHED (both dirs) |

## AXI4-Stream width converter (`axis_width_conv`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| TVALID/TDATA stable until accepted | bmc | 14 | sby/yices | ✅ PASS |
| No spurious valid | bmc | 14 | sby/yices | ✅ PASS |
| Slave handshake / no overflow | bmc | 14 | sby/yices | ✅ PASS |
| No loss/dup under backpressure | bmc | 14 | sby/yices | ✅ PASS |
| Width-crossing integrity (delegated to `sync_fifo_width`) | bmc | 14 | sby/yices | ✅ PASS |
| Cover witnesses (deliver, stall-resume) | cover | 30 | sby/yices | ✅ all REACHED |

## Store-and-forward packet FIFO (`axis_pkt_fifo`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Store-and-forward: no beat delivered before TLAST committed | bmc | 14 | sby/yices | ✅ PASS |
| Commit-pointer bounds (monotone, ≤ write) | bmc | 14 | sby/yices | ✅ PASS |
| Packet-count conservation | bmc | 14 | sby/yices | ✅ PASS |
| End-to-end TLAST integrity | bmc | 14 | sby/yices | ✅ PASS |
| Max-packet contract (`m_pkt_fits`, ≤ DEPTH-1 beats) | bmc | 14 | sby/yices | ✅ PASS |
| Cover witnesses (partial-held, two-packets) | cover | 30 | sby/yices | ✅ all REACHED |

## SECDED ECC FIFO (`sync_fifo_ecc`)

| Property | Method | Depth | Tool | Status |
|----------|--------|-------|------|--------|
| Single-bit stored error → CORRECTED + flagged, **every** position | bmc (`$anyconst` error mask) | 16 | sby/yices | ✅ PASS (exhaustive) |
| Double-bit stored error → DETECTED, every position pair | bmc (`$anyconst`) | 16 | sby/yices | ✅ PASS (exhaustive) |
| Clean (no-error) datapath transparent + flags quiescent | bmc + sim | 16 | sby + verilator | ✅ PASS |
| Pointer / count / flag core invariants | bmc + k-ind | 16 / 15 | sby/yices | ✅ PROVEN |
| Cover witnesses (single corrected, double detected, reach full, full→empty) | cover | 30 | sby/yices | ✅ all REACHED |

## Simulation & coverage

| Check | Scope | Tool | Result |
|-------|-------|------|--------|
| 13 directed/random tests + 120k-cycle biased random | `sync_fifo` (DEPTH 4/8/16/64/256) | Verilator C++ | ✅ 0 errors |
| FWFT show-ahead scoreboard | `sync_fifo_fwft` (widths 1/8/64) | Verilator C++ | ✅ 0 errors |
| Width-crossing golden pack/unpack | `sync_fifo_width` (2:1, 4:1, 8:1, both dirs) | Verilator C++ | ✅ 0 errors |
| Packet-FIFO atomicity scoreboard | `axis_pkt_fifo` | Verilator C++ | ✅ 0 errors |
| ECC clean-path round-trip | `sync_fifo_ecc` | Verilator C++ | ✅ 0 errors |
| cocotb deque golden model (6 tests) | `sync_fifo` | cocotb/Verilator | ✅ all pass |
| Functional coverage bins | `sync_fifo` | Verilator TB | ✅ 10/10 (100%), hard-gated |
| Structural coverage (line/toggle/branch/expr) | `sync_fifo` | verilator_coverage | ✅ 100% / 100% / 100% / 100% |
| Fault-injection anti-vacuity | all 5 designs with TBs | Verilator | ✅ fault caught (exit ≠ 0) |

## Mutation testing

| Design | Tool | Kill-rate | Notes |
|--------|------|-----------|-------|
| `sync_fifo` | mcy/Yosys | **92%** | 8 survivors = proven equivalent mutants (0 real gaps) |
| `async_fifo` | mcy/Yosys | exploratory | Inlined props reduce resolution (methodology caveat) |
| `axis_fifo` | mcy/Yosys | exploratory | Same inlined-props caveat |

## FPGA place-and-route (open-source flow)

| Part | Tool | Result |
|------|------|--------|
| ECP5 LFE5U-85F (CABGA381) | yosys + nextpnr-ecp5 | ✅ all depths fit, ~175–294 MHz |
| iCE40 UP5K (SG48) | yosys + nextpnr-ice40 | ✅ all depths fit, ~59–73 MHz |

Full tables: [fpga_results.md](fpga_results.md). See
[proven_vs_tested.md](proven_vs_tested.md) for the integrity framing.
