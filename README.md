# sync-fifo-formal

> Formally-verified, parameterizable **synchronous and asynchronous (dual-clock CDC)** FIFOs in SystemVerilog — proven correct with SymbiYosys, not just simulated.

[![CI](https://github.com/billdmar/sync-fifo-formal/actions/workflows/ci.yml/badge.svg)](https://github.com/billdmar/sync-fifo-formal/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-IEEE_1800-orange?style=for-the-badge)]()
[![Formal](https://img.shields.io/badge/Formal-SymbiYosys-blue?style=for-the-badge)]()
[![Sim](https://img.shields.io/badge/Sim-Verilator-green?style=for-the-badge)]()
[![BMC](https://img.shields.io/badge/BMC-all_assertions_PASS-brightgreen?style=for-the-badge)]()
[![CDC](https://img.shields.io/badge/CDC-async_FIFO_proven-blueviolet?style=for-the-badge)]()
[![Coverage](https://img.shields.io/badge/Functional_coverage-10%2F10_bins-brightgreen?style=for-the-badge)]()
[![AXI4-Stream](https://img.shields.io/badge/AXI4--Stream-protocol_proven-red?style=for-the-badge)]()
[![FPGA](https://img.shields.io/badge/FPGA-ECP5_%2B_iCE40_real_P%26R-informational?style=for-the-badge)]()

---

## ✨ Highlights

- **Two verified designs** — a single-clock `sync_fifo` (extra-MSB dual-pointer) **and** a dual-clock `async_fifo` (Gray-code pointers + multi-flop CDC synchronizers, Cummings-style)
- **Formally verified** — all sync SVA assertions pass BMC at depth 20 (the required gate); the async CDC properties pass multi-clock BMC at depth 16; bounded-liveness/progress proofs gate that the FIFO always drains/fills and never deadlocks
- **Pointer/count/flag invariants are k-induction PROVEN** (unbounded), strengthened with auxiliary inductive invariants — not merely BMC-bounded
- **Cover witnesses** — fill-to-full, drain-to-empty, pointer wrap, simultaneous R+W, and full→empty→full round-trip all generate real waveform traces
- **Verilator scoreboard** — 13 directed scenarios + a 120,000-cycle biased constrained-random run validated against a `std::queue` golden model
- **Coverage closure** — 10/10 functional-coverage bins hit (enforced as a hard gate) plus 100% Verilator line/toggle/branch/expr coverage
- **Fault-injection self-test** — `make sim-fault` proves the checker is not vacuous (scoreboard must catch an intentionally injected error)
- **AXI4-Stream wrapper** — drop-in `axis_fifo` (tvalid/tready/tdata/tlast) with formal proof of protocol compliance: tvalid/tdata stable-until-accepted, no data loss under backpressure
- **Real FPGA numbers** — actual Yosys + nextpnr place-and-route on **ECP5 (LFE5U-85F)** and **iCE40 (UP5K)** across the depth sweep, each labeled with the tool + part it came from ([docs/fpga_results.md](docs/fpga_results.md))
- **Two linters as hard gates** — Verilator `-Wall` *and* Verible style lint, both clean
- **Parameterizable DEPTH 4–1024** — depth sweep (4, 8, 16, 64, 256) all green in CI
- **100% open-source toolchain** — OSS CAD Suite (Yosys 0.64, SymbiYosys 0.66, Verilator 5.049) + Verible + nextpnr
- **Green GitHub Actions CI** — lint (Verilator ×3 + Verible), synth, formal (sync BMC + liveness + CDC + AXI + cover), simulation, sweep, coverage, and an informational FPGA P&R sweep on every push

---

## Architecture

### Dual-Pointer + Extra-MSB Ring Buffer

```
                         ┌─────────────────────────────────────┐
  wr_en ──────────────►  │          sync_fifo (DUT)            │
  wr_data ────────────►  │                                     │
                         │   ADDR_WIDTH+1-bit write pointer    │
                         │   wptr[ADDR_WIDTH:0]                │
                         │        │                            │
                         │        ▼                            │
                         │   ┌─────────────────────┐          │
                         │   │  mem[0..DEPTH-1]    │          │  ◄── DATA_WIDTH bits each
                         │   │  (ring buffer)      │          │
                         │   └─────────────────────┘          │
                         │        ▲                            │
                         │        │                            │
                         │   ADDR_WIDTH+1-bit read pointer     │
                         │   rptr[ADDR_WIDTH:0]                │
                         │                                     │
  rd_en ───────────────► │  ┌─────────────────────────────┐   │
  full  ◄──────────────  │  │  Empty/Full Comparators     │   │
  empty ◄──────────────  │  │                             │   │
                         │  │  empty = (wptr == rptr)     │   │
                         │  │  full  = (wptr[AW] !=       │   │
                         │  │           rptr[AW])    AND  │   │
                         │  │         (wptr[AW-1:0] ==    │   │
                         │  │           rptr[AW-1:0])     │   │
                         │  └─────────────────────────────┘   │
  count ◄──────────────  │                                     │
  almost_full ◄────────  │  count = wptr - rptr (unsigned)    │
  almost_empty ◄───────  │                                     │
  rd_data ◄───────────   │  rd_data: registered (1-cycle lat) │
                         └─────────────────────────────────────┘

  Pointer width: ADDR_WIDTH+1 bits
  Extra MSB (bit [ADDR_WIDTH]) flips once per full wrap of the address space.
  Low bits [ADDR_WIDTH-1:0] index into mem[].
```

### Why the Extra MSB?

With only `ADDR_WIDTH`-bit pointers there are two indistinguishable states
where `wptr == rptr`: the FIFO is completely empty *and* the FIFO is
completely full (after wrapping). The standard resolution is to extend each
pointer to `ADDR_WIDTH+1` bits.

**Invariants:**

- **Empty**: `wptr == rptr` (all `ADDR_WIDTH+1` bits match).
- **Full**: `wptr[ADDR_WIDTH] != rptr[ADDR_WIDTH]` AND
  `wptr[ADDR_WIDTH-1:0] == rptr[ADDR_WIDTH-1:0]`
  (the MSBs differ, meaning one extra wrap has occurred, while the low address
  bits align).

**DEPTH=4 walk-through** (ADDR_WIDTH=2, pointer width=3 bits):

| Operation | wptr (bin) | rptr (bin) | wptr==rptr? | MSBs differ? | State    |
|-----------|-----------|-----------|------------|-------------|----------|
| Reset     | 000       | 000       | yes        | no          | Empty    |
| Write ×1  | 001       | 000       | no         | no          | 1 entry  |
| Write ×2  | 010       | 000       | no         | no          | 2 entries|
| Write ×3  | 011       | 000       | no         | no          | 3 entries|
| Write ×4  | 100       | 000       | no         | **yes**, low=00 | **Full** |
| Read ×1   | 100       | 001       | no         | yes         | 3 entries|
| Read ×4   | 100       | 100       | yes        | no          | Empty    |

The MSB flip after the pointer crosses `DEPTH-1 → 0` is the unique signal
that exactly one more write than read cycle has occurred, unambiguously
flagging full.

---

## Overview

`sync_fifo` is a single-clock FIFO implemented in SystemVerilog. It uses
`ADDR_WIDTH+1`-bit read and write pointers (the "extra MSB" technique) to
eliminate the classic pointer-aliasing ambiguity between the empty and full
conditions without requiring any additional state bits or comparators.

Correctness properties are expressed as SVA assertions in a companion
properties module and discharged via Bounded Model Checking (BMC, depth 20,
the required gate) with a k-induction proof (basecase depth 15) as an
informational supplement. A Verilator C++ testbench with a
`std::queue` golden-model scoreboard provides constrained-random coverage at
multiple depths, and a built-in fault-injection path proves the checker is not
vacuous.

---

## Parameters & Ports

### Parameters

| Parameter      | Range          | Default | Description                              |
|----------------|----------------|---------|------------------------------------------|
| `DATA_WIDTH`   | 1 – 64         | 8       | Width of each data word                  |
| `DEPTH`        | 4 – 1024 (2^n) | 16      | Number of entries; must be a power of 2  |
| `ALMOST_FULL_THRESH`  | 1 – DEPTH-1 | DEPTH-2 | `almost_full` asserts when count >= this |
| `ALMOST_EMPTY_THRESH` | 1 – DEPTH-1 | 2       | `almost_empty` asserts when count <= this|

### Ports

| Port         | Dir | Width       | Description                              |
|--------------|-----|-------------|------------------------------------------|
| `clk`        | in  | 1           | System clock (rising-edge)               |
| `rst_n`      | in  | 1           | Synchronous active-low reset             |
| `wr_en`      | in  | 1           | Write enable                             |
| `rd_en`      | in  | 1           | Read enable                              |
| `wr_data`    | in  | DATA_WIDTH  | Data to write                            |
| `rd_data`    | out | DATA_WIDTH  | Data read out                            |
| `full`       | out | 1           | FIFO is full (write inhibited)           |
| `empty`      | out | 1           | FIFO is empty (read inhibited)           |
| `almost_full` | out | 1          | Entry count >= ALMOST_FULL_THRESHOLD     |
| `almost_empty`| out | 1          | Entry count <= ALMOST_EMPTY_THRESHOLD    |
| `count`      | out | ADDR_WIDTH+1| Number of valid entries currently stored |

**Note:** `rd_data` is registered (clocked output). Reading requires one cycle
of latency — assert `rd_en` on cycle N and sample `rd_data` on cycle N+1.
Reset is **synchronous**: `rst_n` is sampled on the rising clock edge.

---

## Toolchain

| Tool           | Version      | Notes                       |
|----------------|--------------|-----------------------------|
| Verilator      | 5.049        | Lint + simulation + coverage |
| Yosys          | 0.64         | Synthesis / elaboration / FPGA mapping |
| SymbiYosys     | 0.66         | Formal verification front-end|
| nextpnr        | 0.10         | FPGA place-and-route (ecp5, ice40) |
| Verible        | v0.0-4071    | SystemVerilog style/lint gate (`make lint-verible`); config in `.rules.verible_lint` |
| OSS CAD Suite  | 2026-06-04   | Bundles Verilator/Yosys/SymbiYosys/nextpnr/solvers |
| Solvers        | yices-smt2, boolector, z3, bitwuzla | Included in suite |

Tested on **macOS (darwin-arm64)** locally; CI runs on **ubuntu-latest (linux-x64)**.

---

## Quickstart

### 1. Install OSS CAD Suite

Download the appropriate release from
[github.com/YosysHQ/oss-cad-suite-build/releases](https://github.com/YosysHQ/oss-cad-suite-build/releases),
extract it, and source the environment:

```sh
tar -xzf oss-cad-suite-<platform>-<date>.tgz
source oss-cad-suite/environment
```

### 2. Clone and run

```sh
git clone https://github.com/billdmar/sync-fifo-formal.git
cd sync-fifo-formal

make lint          # sync RTL lint with Verilator
make formal-bmc    # Bounded model check (depth 20) — CI gate
make sim           # Verilator simulation at DEPTH=8 + functional coverage
make all           # Full CI gate (sync+async lint, synth, formal, sim)
```

Additional targets:

```sh
make synth              # Yosys synthesis + area stats
make lint-async         # async (dual-clock) FIFO lint
make lint-axis          # AXI4-Stream wrapper lint
make lint-verible       # Verible style gate (local: VERIBLE=$HOME/verible/bin/verible-verilog-lint)
make formal-live        # bounded liveness / progress (depth 20) — CI gate
make formal-cover       # sync cover witnesses (depth 30) — CI gate
make formal-prove       # sync k-induction proof (depth 15, informational)
make formal-async-bmc   # async CDC BMC (depth 16, multiclock) — CI gate
make formal-async-cover # async reachability covers — CI gate
make formal-async-prove # async k-induction (informational, step open)
make formal-axis-bmc    # AXI4-Stream protocol BMC (depth 20) — CI gate
make formal-axis-cover  # AXI4-Stream cover witnesses — CI gate
make formal             # all sync + async + AXI formal gates
make sim DEPTH=64       # Simulation at a specific depth
make sim-sweep          # Sweep DEPTHS="4 8 16 64 256"
make sim-coverage       # Verilator line/toggle/branch/expr coverage report
make sim-fault          # Fault-injection self-test (exits 0 only if checker fires)
make fpga-report        # Real Yosys+nextpnr P&R sweep (ECP5 + iCE40)
make clean              # Remove all build artefacts
make help               # Show all targets
```

---

## Verification Approach

### Formal (SymbiYosys)

SVA properties live in `rtl/sync_fifo_properties.sv` and are connected to the
DUT by explicit instantiation inside the formal harness
`formal/sync_fifo_formal_tb.sv`. (The Yosys open-source frontend does not
resolve `bind` statements that reference a separate module's internal signals,
so the harness reconstructs the write/read pointers from port-observable events
— `wr_en`/`rd_en`/`full`/`empty` — and ties them to the DUT's real `count`
output via the `a_shadow_count` assertion.) Two SymbiYosys scripts run:

| Script                          | Mode          | Depth | Role                            |
|---------------------------------|---------------|-------|---------------------------------|
| `formal/sync_fifo_bmc.sby`      | bmc           | 20    | CI gate — required              |
| `formal/sync_fifo_live.sby`     | bmc           | 20    | CI gate — bounded liveness/progress |
| `formal/sync_fifo_cover.sby`    | cover         | 30    | CI gate — reachability witnesses |
| `formal/sync_fifo.sby`          | prove (k-ind) | 15    | Inductive proof (informational) |
| `formal/async_fifo_bmc.sby`     | bmc (multiclk)| 16    | CI gate — async CDC properties  |
| `formal/async_fifo_cover.sby`   | cover         | 30    | CI gate — async reachability    |
| `formal/async_fifo_prove.sby`   | prove (k-ind) | —     | Async induction (informational, step open) |
| `formal/axis_fifo_bmc.sby`      | bmc           | 20    | CI gate — AXI4-Stream protocol compliance |
| `formal/axis_fifo_cover.sby`    | cover         | 30    | CI gate — AXI handshake reachability |

**On liveness:** true unbounded liveness (`mode live` / `s_eventually`) is not
runnable on this OSS CAD Suite — SymbiYosys only accepts the `aiger suprove`
engine for live mode, and `suprove` is not bundled. Progress is therefore
encoded as **bounded-window safety**: under sustained read/write pressure
occupancy strictly de/increases each cycle, which bounds drain-to-empty and
fill-to-full to ≤ DEPTH cycles. These progress properties pass BMC at depth 20
**and** close k-induction, and the cover traces exhibit real multi-cycle
drain/fill episodes — a sound, decidable progress guarantee.

### Simulation (Verilator)

`tb/tb_sync_fifo.cpp` drives `sync_fifo` through **13 directed/random
scenarios** — reset; sequential fill; sequential drain; 10k-cycle randomized
R/W; almost-full/empty thresholds; depth/pointer-wrap behavior; back-to-back
fill/drain ×100; single-entry oscillation; full-boundary write-while-full
stress; empty-boundary read-while-empty stress; alternating random bursts; a
**120,000-cycle biased constrained-random** run (write-heavy → read-heavy →
balanced phases); and many-wrap churn that laps both pointers dozens of times —
validating every read against a `std::queue` golden model and checking `count`,
`empty`, `full` against the model each cycle. A VCD waveform is written to
`docs/waveforms/sim_waves.vcd`.

**Functional coverage** (C++ event bins, portable across all depths) and
**Verilator structural coverage** (`make sim-coverage`, line/toggle/branch/expr)
report closure; an unhit functional bin fails the run, so 10/10 is a hard gate.

`make sim-fault` rebuilds the TB with `-DINJECT_FAULT`, which intentionally
corrupts data values. The target **succeeds** only when the binary exits
non-zero (i.e., the scoreboard detected the mismatch), proving the checker is
not vacuous.

---

## SVA Property Status

Results below are from local OSS CAD Suite runs (DEPTH=8 formal harness) that
also gate CI. **BMC is the authoritative gate**; the pointer/count/flag and
progress invariants additionally **close k-induction** (unbounded). "PROVEN"
means the k-induction step closed; "PASS" means BMC-bounded only.

#### Synchronous FIFO (`sync_fifo`)

| Property (assertion label)                      | Type   | BMC | k-induction |
|-------------------------------------------------|--------|-----|-------------|
| Mutual exclusion `!(full && empty)` (`a_no_full_and_empty`) | assert | ✅ PASS | ✅ PROVEN |
| Write handshake `!(full && wr_en)` (`m_no_write_when_full`) | assume | enforced | enforced |
| Read handshake `!(empty && rd_en)` (`m_no_read_when_empty`) | assume | enforced | enforced |
| Empty clears after write (`a_empty_clears_after_write`)     | assert | ✅ PASS | ✅ PROVEN |
| Full clears after read (`a_full_clears_after_read`)         | assert | ✅ PASS | ✅ PROVEN |
| Write/read pointer monotone (`a_wptr_monotone`, `a_rptr_monotone`) | assert | ✅ PASS | ✅ PROVEN |
| Count in range / empty-iff-0 / full-iff-DEPTH / shadow-count (`a_count_*`, `a_*_iff_*`, `a_shadow_count`) | assert | ✅ PASS | ✅ PROVEN |
| Count step ±1 (`a_count_monotone`)                          | assert | ✅ PASS | ✅ PROVEN |
| Almost-full/empty flags track count (`a_almost_full_iff`, `a_almost_empty_iff`) | assert | ✅ PASS | ✅ PROVEN |
| **Aux inductive invariants** (`a_aux_count_le_depth`, `a_aux_full_excl_empty`, `a_aux_shadow_empty`, `a_aux_shadow_full`) | assert | ✅ PASS | ✅ PROVEN |
| **Bounded progress: drain / fill** (`a_progress_drain`, `a_progress_fill`) | assert | ✅ PASS | ✅ PROVEN |
| **No-deadlock** `!full \|\| !empty` (`a_no_deadlock`)        | assert | ✅ PASS | ✅ PROVEN |
| Data ordering, `$anyconst` slot tracker (`a_data_integrity`) | assert | ✅ PASS | ⚠️ basecase PASS, step open (see note) |
| **No duplicate read / no read-before-write** (`a_no_duplicate_read`, `a_no_read_before_write`) | assert | ✅ PASS | ⚠️ basecase PASS, step open (see note) |
| Cover witnesses — fill-to-full, drain-to-empty, wptr/rptr wrap, simultaneous R+W, full→empty→full, sustained drain/fill, tracked round-trip (10 covers) | cover | ✅ all 10 REACHED | — |

**Note on the `$anyconst`-tracker k-induction step** (`a_data_integrity`,
`a_no_duplicate_read`, `a_no_read_before_write`): these are proven by BMC at
depth 20 (which fully covers fill-and-drain windows for the DEPTH=8 harness) and
their k-induction *basecase* passes. The induction *step* is not closed because
the `$anyconst` slot tracker cannot be tied to the DUT's internal `mem[]` array
— the open-source Yosys frontend does not expose another module's internal
arrays by hierarchical reference, so the inductive hypothesis admits states
where the shadow tracker and `mem[]` disagree. This is a known limitation of
shadow-model formal proofs on this toolchain, not a DUT defect; BMC remains the
authoritative gate and the Verilator scoreboard independently validates ordering
across all depths and 120k randomized cycles.

#### Asynchronous FIFO (`async_fifo`, dual-clock CDC)

Properties are inlined under `` `ifdef FORMAL `` inside `async_fifo.sv` (so they
see CDC internals natively) and discharged by a multi-clock harness
(`$global_clock` + per-domain clock-enable gating). Gate: `async_fifo_bmc.sby`,
**mode bmc, depth 16, `multiclock on`, yices**.

| Property (assertion label)                      | Type   | BMC (multiclk, d=16) |
|-------------------------------------------------|--------|----------------------|
| Gray pointers change by exactly one bit (`a_wgray_one_bit`, `a_rgray_one_bit`) | assert | ✅ PASS |
| Gray encodes binary (`a_wgray_encodes_wbin`, `a_rgray_encodes_rbin`) | assert | ✅ PASS |
| Binary pointer monotone per domain (`a_wbin_monotone`, `a_rbin_monotone`) | assert | ✅ PASS |
| No overflow / no underflow (`a_no_overflow`, `a_no_underflow`) | assert | ✅ PASS |
| Occupancy 0..DEPTH (`a_occupancy_le_depth`)     | assert | ✅ PASS |
| No missed-full (`a_full_when_actually_full`)    | assert | ✅ PASS |
| Empty matches read-domain view (`a_empty_matches_rdview`) | assert | ✅ PASS |
| Cross-domain data integrity, `$anyconst` (`a_data_integrity`) | assert | ✅ PASS |
| Handshake assumes (`m_no_write_when_full`, `m_no_read_when_empty`) | assume | enforced |
| Cover — reach full, non-trivially non-empty, Gray wrap, tracked round-trip (4 covers) | cover | ✅ all REACHED |

Async k-induction (`async_fifo_prove.sby`) is **informational**: basecase
passes, the step does not close (the synchronizer chain needs explicit inductive
strengthening from arbitrary start states). All async claims above are
BMC-bounded to depth 16 — sufficient to cover a full fill + sync latency + drain
window for DEPTH=8 — plus cover reachability. Open-source formal models relative
clock phase/rate (the functional CDC risk); it does not model analog
metastability resolution — the `SYNC_STAGES` flops are that mitigation.

#### AXI4-Stream wrapper (`axis_fifo`)

`axis_fifo` wraps `sync_fifo` in a standard AXI4-Stream interface (slave sink →
FIFO → master source). The 1-cycle registered read latency is absorbed by a
1-deep output skid register so data is never dropped or duplicated under
backpressure; `{tlast, tdata}` is buffered together so TLAST stays aligned.
Properties are inlined under `` `ifdef FORMAL ``. Gate: `axis_fifo_bmc.sby`,
**mode bmc, depth 20, yices**.

| Property (assertion label)                      | Type   | BMC (d=20) |
|-------------------------------------------------|--------|------------|
| Master TVALID stable until accepted (`a_m_tvalid_stable`) | assert | ✅ PASS |
| Master TDATA / TLAST stable while stalled (`a_m_tdata_stable`, `a_m_tlast_stable`) | assert | ✅ PASS |
| No spurious valid — TVALID iff real data held (`a_no_spurious_valid`) | assert | ✅ PASS |
| Slave handshake / no overflow (`a_tready_iff_room`, `a_no_push_when_full`) | assert | ✅ PASS |
| Registered-latency skid invariants (`a_pop_excl`, `a_landing_slot`) | assert | ✅ PASS |
| No data loss under backpressure (`a_no_pop_when_stalled`) | assert | ✅ PASS |
| End-to-end `$anyconst` data/last integrity, no loss/dup (`a_e2e_data`, `a_e2e_last`) | assert | ✅ PASS |
| Cover — deliver, stall-then-resume, tracked round-trip, TLAST out (4 covers) | cover | ✅ all REACHED |

AXI properties are BMC-bounded at depth 20 on a DEPTH=8 harness (the repo's
BMC-as-gate convention); no k-induction script for the wrapper.

**AXI4-Stream ports** (`DATA_WIDTH` 1–63, `DEPTH` 4–1024 pow2):

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axis_tvalid` | in  | 1 | Slave: input beat valid |
| `s_axis_tready` | out | 1 | Slave: ready (= space available) |
| `s_axis_tdata`  | in  | DATA_WIDTH | Slave: input payload |
| `s_axis_tlast`  | in  | 1 | Slave: last-of-packet (buffered) |
| `m_axis_tvalid` | out | 1 | Master: output beat valid |
| `m_axis_tready` | in  | 1 | Master: downstream ready |
| `m_axis_tdata`  | out | DATA_WIDTH | Master: output payload |
| `m_axis_tlast`  | out | 1 | Master: last-of-packet |

### FPGA synthesis & timing (real Yosys + nextpnr P&R)

Actual place-and-route on two concrete Lattice parts across the depth sweep —
full tables, tool versions, and caveats in **[docs/fpga_results.md](docs/fpga_results.md)**
(`make fpga-report` to reproduce). Highlights (`DATA_WIDTH=8`, seed 1):

| Part | DEPTH=8 Fmax | DEPTH=256 Fmax | mem→BRAM from | Tool |
|------|--------------|----------------|---------------|------|
| ECP5 LFE5U-85F (CABGA381) | 266.8 MHz | 221.3 MHz | DEPTH=256 | yosys 0.64 + nextpnr-ecp5 0.10 |
| iCE40 UP5K (SG48)         | 59.2 MHz  | 72.7 MHz  | DEPTH=16  | yosys 0.64 + nextpnr-ice40 0.10 |

All swept depths (4/8/16/64/256) fit on both parts; the design maps to
distributed LUT RAM when shallow and to dedicated block RAM when deep with no
source changes. These are **open-source-flow numbers, not vendor (Diamond/
Radiant/Vivado) numbers** — see the doc for the full methodology.

### Simulation results (local, all gating CI)

| DEPTH | Sim result | Functional coverage |
|-------|------------|---------------------|
| 4   | ✅ PASS (0 errors) | ✅ 10/10 bins (100%) |
| 8   | ✅ PASS (0 errors) | ✅ 10/10 bins (100%) |
| 16  | ✅ PASS (0 errors) | ✅ 10/10 bins (100%) |
| 64  | ✅ PASS (0 errors) | ✅ 10/10 bins (100%) |
| 256 | ✅ PASS (0 errors) | ✅ 10/10 bins (100%) |

| Check | Result |
|-------|--------|
| `make sim-fault` (fault injection) | ✅ caught — 16,255 mismatches flagged, exit ≠ 0 |
| `make sim-coverage` (Verilator line/toggle/branch/expr) | ✅ 100% / 100% / 100% / 100% |
| Sync formal covers | ✅ all 10 REACHED |
| Async formal covers | ✅ all 4 REACHED |
| AXI formal covers | ✅ all 4 REACHED |
| `make lint` / `lint-async` / `lint-axis` (Verilator) | ✅ all clean |
| `make lint-verible` (Verible style gate) | ✅ exit 0 on all RTL |

---

## Repository Layout

```
sync-fifo-formal/
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions CI
├── docs/
│   ├── fpga_results.md        # Real ECP5 + iCE40 P&R area/timing tables
│   └── waveforms/
│       └── .gitkeep            # Placeholder; sim VCD written here
├── formal/
│   ├── sync_fifo_bmc.sby       # sync BMC (depth 20, CI gate)
│   ├── sync_fifo_live.sby      # sync bounded liveness/progress (depth 20, CI gate)
│   ├── sync_fifo_cover.sby     # sync cover witnesses (depth 30, CI gate)
│   ├── sync_fifo.sby           # sync prove script (k-induction, informational)
│   ├── sync_fifo_formal_tb.sv  # sync formal harness (DUT + properties)
│   ├── async_fifo_bmc.sby      # async CDC BMC (depth 16, multiclock, CI gate)
│   ├── async_fifo_cover.sby    # async reachability covers (CI gate)
│   ├── async_fifo_prove.sby    # async k-induction (informational, step open)
│   ├── async_fifo_formal_tb.sv # async multi-clock formal harness
│   ├── axis_fifo_bmc.sby       # AXI4-Stream protocol BMC (depth 20, CI gate)
│   └── axis_fifo_cover.sby     # AXI4-Stream cover witnesses (CI gate)
├── rtl/
│   ├── sync_fifo.sv            # DUT — parameterizable synchronous FIFO
│   ├── sync_fifo_properties.sv # sync SVA properties (explicit-instantiation module)
│   ├── async_fifo.sv           # DUT — dual-clock CDC FIFO (Gray + synchronizers, inlined SVA)
│   └── axis_fifo.sv            # AXI4-Stream wrapper around sync_fifo (inlined SVA)
├── scripts/
│   └── fpga_report.sh         # Yosys + nextpnr P&R sweep (ECP5 + iCE40)
├── tb/
│   └── tb_sync_fifo.cpp        # Verilator C++ TB + std::queue scoreboard (13 tests + coverage)
├── .rules.verible_lint         # Verible style-lint config
├── LICENSE                     # MIT
├── Makefile                    # Build, lint, formal, sim, fpga targets
└── README.md                   # This file
```

---

## License

MIT — see [LICENSE](LICENSE).  
Copyright (c) 2026 William Mar.
