# sync-fifo-formal

> A formally-verified, parameterizable synchronous FIFO in SystemVerilog — proven correct with SymbiYosys, not just simulated.

[![CI](https://github.com/billdmar/sync-fifo-formal/actions/workflows/ci.yml/badge.svg)](https://github.com/billdmar/sync-fifo-formal/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-IEEE_1800-orange?style=for-the-badge)]()
[![Formal](https://img.shields.io/badge/Formal-SymbiYosys-blue?style=for-the-badge)]()
[![Sim](https://img.shields.io/badge/Sim-Verilator-green?style=for-the-badge)]()
[![BMC](https://img.shields.io/badge/BMC-all_assertions_PASS-brightgreen?style=for-the-badge)]()

---

## ✨ Highlights

- **Formally verified** — all SVA assertions pass BMC at depth 20 (the required CI gate); k-induction supplements structural completeness
- **8 SVA property groups** — covering mutual exclusion, pointer monotonicity, count invariants, and data-ordering via a `$anyconst` slot tracker
- **Verilator scoreboard** — 7 directed scenarios + 10,000-cycle randomized reads/writes validated against a `std::queue` golden model
- **Fault-injection self-test** — `make sim-fault` proves the checker is not vacuous (scoreboard must catch an intentionally injected error)
- **Parameterizable DEPTH 4–1024** — depth sweep (4, 8, 16, 64, 256) all green in CI
- **100% open-source toolchain** — OSS CAD Suite (Yosys 0.64, SymbiYosys 0.66, Verilator 5.049)
- **Green GitHub Actions CI** — lint + synth + formal BMC + simulation on every push

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
| Verilator      | 5.049        | Lint + simulation           |
| Yosys          | 0.64         | Synthesis / elaboration     |
| SymbiYosys     | 0.66         | Formal verification front-end|
| OSS CAD Suite  | 2026-06-04   | Bundles all of the above    |
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

make lint          # RTL lint with Verilator
make formal-bmc    # Bounded model check (depth 20) — CI gate
make sim           # Verilator simulation at DEPTH=8
make all           # Full CI gate: lint + synth + formal-bmc + sim
```

Additional targets:

```sh
make synth         # Yosys synthesis + area stats
make formal-prove  # k-induction proof (depth 15, informational)
make sim DEPTH=64  # Simulation at a specific depth
make sim-sweep     # Sweep DEPTHS="4 8 16 64 256"
make sim-fault     # Fault-injection self-test (exits 0 only if checker fires)
make clean         # Remove all build artefacts
make help          # Show all targets
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

| Script                        | Mode          | Depth | Role                      |
|-------------------------------|---------------|-------|---------------------------|
| `formal/sync_fifo_bmc.sby`    | bmc           | 20    | CI gate — required        |
| `formal/sync_fifo.sby`        | prove (k-ind) | 15    | Inductive proof (informational) |
| `formal/sync_fifo_cover.sby`  | cover         | —     | Reachability of key states |

### Simulation (Verilator)

`tb/tb_sync_fifo.cpp` drives `sync_fifo` through seven directed scenarios
(1: reset; 2: sequential fill; 3: sequential drain; 4: 10,000-cycle randomized
simultaneous read/write; 5: almost-full/empty thresholds; 6: depth behavior /
pointer wrap; 7: back-to-back fill/drain ×100) and validates every read against
a `std::queue` golden model, also checking `count`, `empty`, and `full` against
the model each cycle. A VCD waveform is written to
`docs/waveforms/sim_waves.vcd`.

`make sim-fault` rebuilds the TB with `-DINJECT_FAULT`, which intentionally
corrupts one data value. The target **succeeds** only when the binary exits
non-zero (i.e., the scoreboard detected the mismatch), proving the checker is
not vacuous.

---

## SVA Property Status

Results below are from the local OSS CAD Suite 2026-06-04 run (DEPTH=8 formal
harness). **BMC at depth 20 is the authoritative gate**; k-induction is run as
a supplementary check.

| Property (assertion label)                      | Type   | BMC (d=20) | k-induction |
|-------------------------------------------------|--------|------------|-------------|
| Mutual exclusion `!(full && empty)` (`a_no_full_and_empty`) | assert | ✅ PASS | ✅ PROVEN |
| Write handshake `!(full && wr_en)` (`m_no_write_when_full`) | assume | enforced | enforced |
| Read handshake `!(empty && rd_en)` (`m_no_read_when_empty`) | assume | enforced | enforced |
| Empty clears after write (`a_empty_clears_after_write`)     | assert | ✅ PASS | ✅ PROVEN |
| Full clears after read (`a_full_clears_after_read`)         | assert | ✅ PASS | ✅ PROVEN |
| Write pointer monotone (`a_wptr_monotone`)                  | assert | ✅ PASS | ✅ PROVEN |
| Read pointer monotone (`a_rptr_monotone`)                   | assert | ✅ PASS | ✅ PROVEN |
| Count in range / empty-iff-0 / full-iff-DEPTH / shadow-count (`a_count_*`, `a_*_iff_*`, `a_shadow_count`) | assert | ✅ PASS | ✅ PROVEN |
| Count step ±1 (`a_count_monotone`)                          | assert | ✅ PASS | ✅ PROVEN |
| Data ordering preservation, `$anyconst` slot tracker (`a_data_integrity`) | assert | ✅ PASS | ⚠️ basecase PASS, induction not closed (see note) |
| `c_reach_full`, `c_full_then_empty`, `c_tracked_roundtrip`  | cover  | ✅ all REACHED | — |

**Note on `a_data_integrity` k-induction:** the data-ordering property is
proven by BMC at depth 20 (which fully covers fill-and-drain windows for the
DEPTH=8 harness) and its k-induction *basecase* passes. The induction step is
not closed because the `$anyconst` slot tracker cannot be tied to the DUT's
internal `mem[]` array — the open-source Yosys frontend does not expose another
module's internal arrays by hierarchical reference, so the inductive hypothesis
admits states where the shadow tracker and `mem[]` disagree. This is a known
limitation of shadow-model formal proofs on this toolchain, not a DUT defect;
BMC remains the authoritative gate and the Verilator scoreboard independently
validates ordering across all depths and 10k randomized cycles.

### Simulation results (local)

| DEPTH | Result | | Self-test | Result |
|-------|--------|-|-----------|--------|
| 4   | ✅ PASS (0 errors) | | `make sim-fault` | ✅ fault caught (exit ≠ 0) |
| 8   | ✅ PASS (0 errors) | | covers | ✅ all 3 REACHED |
| 16  | ✅ PASS (0 errors) | | | |
| 64  | ✅ PASS (0 errors) | | | |
| 256 | ✅ PASS (0 errors) | | | |

---

## Repository Layout

```
sync-fifo-formal/
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions CI
├── docs/
│   └── waveforms/
│       └── .gitkeep            # Placeholder; sim VCD written here
├── formal/
│   ├── sync_fifo_bmc.sby       # SymbiYosys BMC script (depth 20, CI gate)
│   ├── sync_fifo.sby           # SymbiYosys prove script (k-induction)
│   ├── sync_fifo_cover.sby     # SymbiYosys cover script (reachability)
│   └── sync_fifo_formal_tb.sv  # formal harness (instantiates DUT + properties)
├── rtl/
│   ├── sync_fifo.sv            # DUT — parameterizable synchronous FIFO
│   └── sync_fifo_properties.sv # SVA properties (explicit-instantiation module)
├── tb/
│   └── tb_sync_fifo.cpp        # Verilator C++ TB + std::queue scoreboard
├── LICENSE                     # MIT
├── Makefile                    # Build, lint, formal, sim targets
└── README.md                   # This file
```

---

## License

MIT — see [LICENSE](LICENSE).  
Copyright (c) 2026 William Mar.
