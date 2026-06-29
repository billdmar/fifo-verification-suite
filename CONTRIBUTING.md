# Contributing

This repo is a formally-verified SystemVerilog FIFO suite. Every design ships
with formal proofs, simulation, lint, and CI gates. This guide is how to build,
test, and add to it without breaking that bar.

## Prerequisites

- **[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)** — bundles
  Yosys, SymbiYosys (`sby`), Verilator, nextpnr, `ecppack`/`icepack`, `mcy`,
  cocotb, and SMT solvers (yices/z3/…). Source it before any command:
  ```sh
  source ~/oss-cad-suite/environment
  ```
- **[Verible](https://github.com/chipsalliance/verible)** for the style gate.
  Pass its path locally: `make lint-verible VERIBLE=$HOME/verible/bin/verible-verilog-lint`.

The Makefile sources the suite automatically (via `$(ENV)`); CI pins both.

## Build & test

```sh
make help            # list every target
make all             # the full CI gate set (lint ×N + synth + formal + sim)
make lint            # Verilator -Wall on sync_fifo (one per design: lint-<name>)
make formal          # every formal gate (BMC + cover + k-induction where it closes)
make sim             # Verilator C++ scoreboard + functional coverage
make sim-cocotb      # the Python (cocotb) testbench
make sim-coverage    # line/toggle/branch/expr coverage report
make mutate          # mutation testing (mcy kill-rate)
make perf-report     # cycle-accurate throughput/latency
make bitstream       # real ECP5 .bit + iCE40 .bin for demo_top
make clean           # remove all build artefacts
```

Long `sby`/`mcy` runs can be slow; that's expected. Build artefacts
(`obj_dir*`, `formal/*/`, `mcy/database`, `build/`, `*.vcd`) are gitignored — keep
them out of commits.

## Adding a new verified design (the house pattern)

Mirror an existing design (`rtl/sync_fifo.sv` is the reference) exactly:

1. **RTL** `rtl/<name>.sv`:
   - Header block (`Module / Description / Parameters / Author / Date / Notes`).
   - `` `default_nettype none `` … `` `default_nettype wire ``.
   - `parameter int` with derived `localparam`; one named `gen_chk_*` generate
     block with an elaboration-time `$error` per parameter range.
   - Inline the formal properties under `` `ifdef FORMAL `` (à la `axis_fifo.sv`):
     `f_past_valid`, the `f_init` reset-assumption, `(* anyconst *)` data trackers
     with NARROW counters, and `a_`/`m_`/`c_` label prefixes for assert/assume/cover.
     Guard `$anyconst` data-integrity props under `` `ifdef FORMAL_DATA `` if you
     also want a k-induction `prove` gate (see
     [formal_proof_methodology.md](docs/formal_proof_methodology.md) §4).
2. **Formal** `formal/<name>_bmc.sby` + `_cover.sby` (+ `_prove.sby` if k-induction
   closes): `[options] mode/depth`, `[engines] smtbmc yices`, `[script] read
   -formal -DFORMAL … + chparam -set <param> <small>` for SMT tractability,
   `[files]`. BMC depth ~14–20, cover depth ~30.
3. **Sim** `tb/tb_<name>.cpp`: a `std::queue`/`deque` golden model, `DEPTH_PARAM`/
   `DW_PARAM` defines, drive-point input masking (Verilator does **not** truncate
   narrow inputs), and an `INJECT_FAULT` anti-vacuity path.
4. **Makefile**: add `lint-<name>`, `formal-<name>-{bmc,cover}`, `sim-<name>`,
   `sim-<name>-fault`; wire them into `.PHONY`, the `formal`/`all` aggregates,
   `clean`, and `VERIBLE_RTL`.
5. **CI** `.github/workflows/ci.yml`: add the gate steps using the
   `<Verb> — <module> … (gate)` naming.
6. **Docs**: add rows to `docs/assertions.md`, `docs/traceability.md`,
   `docs/proven_vs_tested.md`, and the README.

## The quality bar (don't regress it)

- **Lint clean**: Verilator `-Wall` *and* Verible, no suppressions without a
  documented reason.
- **Formal green**: BMC + covers must pass; covers must be REACHED (non-vacuity).
- **Sim green**: scoreboard passes; the fault-injection self-test must *catch* its
  injected error.
- **Honest claims**: every doc row maps to a real assertion label + `make` target.
  Distinguish PROVEN (k-induction) from PASS (BMC-bounded) from SIM — never
  overclaim. See [proven_vs_tested.md](docs/proven_vs_tested.md).
- **Surgical diffs**: additive; don't refactor working designs to add a new one.

## Before opening a PR

```sh
make all            # must be green from a clean tree
```
CI runs the same gates on `ubuntu-latest` plus informational FPGA-P&R,
bitstream-build, and mutation jobs. PRs are reviewed; never force-merge a red CI.
