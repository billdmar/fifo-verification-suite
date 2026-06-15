# HANDOFF — SystemVerilog FIFO Verification Suite "reference-grade" upgrade

_Last updated: 2026-06-15. Repo: github.com/billdmar/fifo-verification-suite (public)._

## Goal
Take the repo from "strong formally-verified synchronous FIFO" to a reference-grade
digital-design + formal-verification showcase: add liveness/no-loss proofs, an async
(dual-clock CDC) FIFO, functional coverage closure, an AXI4-Stream wrapper, real FPGA
place-and-route numbers, a second linter, and reproducible CI — delivered as **3 reviewed
PRs (one per wave)**, never auto-merged, every claim backed by a real `make` run.

## Execution model (agreed with user)
- FPGA targets: **ECP5 + iCE40 both** (real nextpnr P&R, verified working locally).
- PRs: **one per wave (3 PRs)**.
- Mode: **run waves A→B→C autonomously, pause only on failure / real decision.**

## Current state

### ✅ Wave A — DONE, PR OPEN (#2)
Branch `wave-a-formal-rtl-coverage` → PR #2 (base `main`). All verified by local `make`:
- Formal completeness (`rtl/sync_fifo_properties.sv`, `formal/sync_fifo_live.sby`): bounded
  liveness/progress (`a_progress_drain/fill`, `a_no_deadlock` — close k-induction), no-loss/
  no-dup (`a_no_duplicate_read`, `a_no_read_before_write` — BMC-gated), aux inductive
  invariants, 10 cover witnesses (all REACHED). True `mode live` NOT possible (suprove not
  bundled) — documented honestly as bounded-window safety.
- Async dual-clock FIFO (`rtl/async_fifo.sv`, `formal/async_fifo_*.sby`): Gray pointers +
  multi-flop CDC sync; multiclock BMC d=16 PASS, 4 covers REACHED; k-induction informational.
- Coverage + TB (`tb/tb_sync_fifo.cpp`): 7→13 tests + 120k-cycle biased run; 10/10 functional
  bins (hard gate); 100% Verilator line/toggle/branch/expr via `make sim-coverage`.

### ✅ Wave B — DONE, PR OPEN (#3, stacked on Wave A branch)
Branch `wave-b-axi-fpga-lint` → PR #3 (base `wave-a-formal-rtl-coverage`). Verified locally:
- AXI4-Stream wrapper (`rtl/axis_fifo.sv`, `formal/axis_fifo_*.sby`): skid-reg handles
  registered-read latency; BMC d=20 PASS (tvalid/tdata/tlast stable, no loss under
  backpressure, e2e $anyconst integrity), 4 covers REACHED, lint clean.
- FPGA P&R (`scripts/fpga_report.sh`, `docs/fpga_results.md`): real Yosys+nextpnr on ECP5
  (LFE5U-85F) + iCE40 (UP5K), depths 4/8/16/64/256, all fit, BRAM-vs-logic crossover captured.
  Done by orchestrator directly (the sub-agent hit 2 API errors).
- Verible lint (`.rules.verible_lint`): native arm64 at `~/verible/bin/`, exit 0 on all RTL,
  4 documented rule disables, no logic changed.
- `make all` GREEN end-to-end (Wave A+B). CI updated: Verible install + lint-axis/lint-verible/
  formal-axis gates + informational FPGA job.

### ✅ Wave C — DONE (done directly by orchestrator; sub-agents hit transient API errors)
Branch `wave-c-docs-cicd`. `make all` green. Added:
- `scripts/gen_waveforms.py` (stdlib-only VCD→SVG) + 4 committed SVGs under `docs/waveforms/`
  (fill-to-full, drain-to-empty, simultaneous-R+W, thresholds) — generated from the REAL sim VCD,
  verified against actual values (count 0→8, full asserts at count==8). `make waveforms` regenerates.
- `docs/cdc_architecture.md` (Mermaid CDC diagram + why-Gray/why-sync prose),
  `docs/verification_matrix.md` (consolidated), `docs/proven_vs_tested.md` (integrity centerpiece).
- README: waveforms section, "what's proven vs tested" summary + doc links, layout/quickstart updated.
- CI/claim audit: every README matrix row maps to a CI gate; `*.vcd` correctly gitignored (SVGs
  committed, VCD regenerates); CI already comprehensive from Wave A/B. No ci.yml gap found.
NEXT: commit Wave C + open PR (base `wave-b-axi-fpga-lint`). Then all 3 PRs (#2/#3/#C) await review.

## What's left
- Commit + push Wave C, open PR #C (base wave-b-axi-fpga-lint). Then: user reviews/merges the
  3 stacked PRs in order (#2 → #3 → #C), or rebases onto main as each lands.

## Key decisions (don't re-litigate)
- **Build on `harness-audit-fixes`, not `main`** — it's the true green tip (2 commits ahead of
  main: almost-full/empty asserts + k-ind label fix). Wave A branched from it.
- **Orchestrator owns ALL hotspot edits** (Makefile / README / ci.yml) centrally; sub-agents only
  create their own new files + return snippets. This eliminated all merge conflicts.
- **Orchestrator re-runs every gate itself** — never trusts sub-agent self-reports for pass/fail.
- **BMC is the authoritative gate**; k-induction is informational where the `$anyconst` tracker
  can't bind to internal `mem[]` (open-source Yosys limitation — real, documented, not a defect).
- **PR stacking**: #3 bases on Wave A branch so its diff shows only Wave B. Land #2 first (or
  rebase #3 onto main once #2 merges).

## Gotchas / do-not-touch
- **OSS CAD Suite is at `~/oss-cad-suite`, NOT on PATH.** Every tool command MUST
  `source ~/oss-cad-suite/environment` in the SAME bash invocation. The Makefile does this via
  `$(ENV)`. Tools: yosys 0.64, sby 0.66, verilator 5.049, nextpnr-ice40/ecp5 0.10, yices.
- **Verible** is at `~/verible/bin/verible-verilog-lint` (not on PATH). Locally:
  `make lint-verible VERIBLE=$HOME/verible/bin/verible-verilog-lint`. Needs `--rules_config_search`
  flag (Makefile passes it) or it ignores `.rules.verible_lint`.
- `fpga_report.sh`: filenames must use a no-space slug (target string has spaces/parens) — already
  fixed; don't reintroduce `$target` into a `-json` path.
- sby cover *summary* only prints a subset of reached covers; the authoritative count is the
  engine "Reached cover statement" lines in `logfile.txt` (all 10 sync / 4 async / 4 AXI do reach).
- Push to origin works (gh auth as billdmar). `git push --dry-run` was permission-denied in-harness
  but real `git push` succeeded. Never auto-merge.
- macOS: no `timeout`, no python `yaml`; use `ruby -ryaml` to validate CI YAML.

## Key files
- `rtl/sync_fifo.sv` (DUT, registered rd_data 1-cyc latency), `sync_fifo_properties.sv` (SVA),
  `async_fifo.sv` (CDC), `axis_fifo.sv` (AXI wrapper).
- `formal/*.sby` (bmc/live/cover/prove for sync, async, axis) + `*_formal_tb.sv` harnesses.
- `tb/tb_sync_fifo.cpp` (13 tests + functional coverage + fault injection).
- `Makefile` (all targets), `.github/workflows/ci.yml` (gates + informational FPGA job).
- `scripts/fpga_report.sh`, `docs/fpga_results.md`, `.rules.verible_lint`.

## How to build/test/run
```sh
source ~/oss-cad-suite/environment       # REQUIRED first (or rely on Makefile $(ENV))
make all                                  # full gate: lint x3 + synth + formal(sync/async/axis) + sim
make formal-live formal-async-bmc formal-axis-bmc   # individual formal gates
make sim-coverage                         # Verilator line/toggle/branch/expr
make fpga-report                          # real ECP5 + iCE40 P&R sweep
make lint-verible VERIBLE=$HOME/verible/bin/verible-verilog-lint
```

## Next action
On `wave-c-docs-cicd`: dispatch (or do directly) the **CI/CD reproducibility + claim audit** —
verify every README badge/claim maps to a real CI step or committed artifact, confirm clean-clone
repro, then generate committed waveform SVGs under `docs/waveforms/` and the async CDC diagram.
Integrate centrally, `make all`, open Wave C PR (base `wave-b-axi-fpga-lint`).
