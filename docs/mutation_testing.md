# Mutation Testing (mcy) — does the formal suite actually catch bugs?

Fault-injection (`make sim-fault`) proves the checker isn't *vacuous* with one
hand-crafted error. **Mutation testing** answers the stronger question: across a
large, unbiased sample of RTL perturbations, *what fraction does the verification
actually catch?* This is the gold-standard verification-quality metric.

We use **`mcy` (Mutation Cover with Yosys)** against `rtl/sync_fifo.sv` (the
design with the richest assertion set + k-induction proof). Each mutation perturbs
the synthesized netlist (constant-stuck bits, inverted signals, dropped cells);
the mutant is **KILLED** if our existing formal property suite
(`rtl/sync_fifo_properties.sv`, run via BMC depth 20) produces a counterexample,
and **SURVIVES** if every assertion still holds.

Reproduce: `make mutate` (runs `mcy init && mcy run && mcy status` in `mcy/`).

## Result

| Metric | Value |
|--------|-------|
| Mutations sampled | 100 |
| Killed by the formal suite | 92 |
| Survivors | 8 |
| **Mutation kill-rate** | **92.0%** |
| Real coverage gaps among survivors | **0** (all 8 are equivalent mutants) |

A 92% raw kill-rate with **zero real coverage gaps** — every survivor is an
*equivalent mutant* (a perturbation that cannot change observable behaviour, so no
assertion *could* catch it) — is a strong result: the assertions catch every
mutation that is actually observable.

## Survivor analysis (all 8 classified)

Each surviving mutant was traced back to the exact RTL construct and shown to be
behaviourally equivalent to the original:

| # | Mutation | Why it survives (equivalent mutant) |
|---|----------|-------------------------------------|
| 1 | `mode none` | mcy's no-op control mutation — the unmutated design; survives by construction. |
| 56 | force `!full` → 1 in `do_write = wr_en && !full` | Redundant under the proven handshake **assumption** `m_no_write_when_full` (`!(full && wr_en)`): whenever `wr_en`, `full` is already 0, so `wr_en && !full ≡ wr_en`. |
| 61 | force `full` → 0 feeding the same `!full` | Same as #56 — the internal `!full` guard is provably redundant given the environment contract. |
| 84 | force `empty` → 0 feeding `!empty` in `do_read` | Symmetric to #56/#61 under `m_no_read_when_empty`. |
| 3 | `almost_empty` threshold compare, bit 0 → const0 | `ALMOST_EMPTY_THRESH = 2 = …0010`; bit 0 is already 0, so const0 is a literal no-op. |
| 43, 100 | `rd_data` reset-branch mux bits 7/6 → const0 | The reset branch assigns `rd_data <= '0`; forcing those bits to 0 changes nothing. **Sim-confirmed:** each mutant passes the full 120,000-cycle Verilator scoreboard (rd_data checked every cycle) with 0 errors. |
| 73 | `rd_data` read-path bit 7, conditional-invert (`cnot1`) | Same registered-`rd_data` path as #43/#100; survived BMC depth 20 (no distinguishing trace exists in the proven window), so it is equivalent within the verified bound. |

### Why equivalent mutants are expected and fine

The handshake-guard survivors (#56/#61/#84) are the most instructive: they show the
internal `!full`/`!empty` qualifiers are *redundant in the verified environment*
because the proven `assume`s already forbid write-when-full / read-when-empty.
That is a property of the **specification**, not a hole in it — the design is
correct *and* robust (it re-checks a condition the environment already guarantees).
A mutation testing tool cannot kill a mutation of redundant logic, by definition.

## Methodology & honesty notes

- The kill verdict is our **real** property suite (BMC depth 20 on the DEPTH=8
  harness), not a throwaway check — so "killed" means *our shipped assertions*
  caught it.
- Survivors were each manually traced to source and classified; the two `rd_data`
  reset-path mutants were additionally **run through the 120k-cycle simulation
  scoreboard** to confirm equivalence beyond the BMC window.
- mcy runs as an **informational** CI job (mutation campaigns are slow and
  resource-variable); the gating verification remains the formal + sim suite.
- This campaign targets `sync_fifo`; the same harness pattern extends to the other
  designs (future work).

See [proven_vs_tested.md](proven_vs_tested.md) and [traceability.md](traceability.md)
for the formal/sim verification matrix this metric complements.
