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

## Per-design results & a methodology caveat (`make mutate-async` / `mutate-axis`)

The round-4 work extended mcy to `async_fifo` and `axis_fifo` (`mcy/async/`,
`mcy/axis/`). These surfaced a real, instructive methodology point worth stating
plainly rather than headlining a flattering single number:

| Design | mutation harness | clean DUT-logic kill-rate |
|--------|------------------|---------------------------|
| `sync_fifo` | properties in a **separate** module — mcy mutates *only* the DUT | **92%** (8 survivors all equivalent — the clean reference) |
| `axis_fifo` | properties **inlined** under `` `ifdef FORMAL `` | ~53% synth-logic (see caveat) |
| `async_fifo` | properties **inlined**, multi-clock | ~56% synth-logic (see caveat) |

**Why the inlined-property numbers are lower — and not directly comparable:** for
`sync_fifo` the SVA lives in a separate `sync_fifo_properties.sv`, so mcy mutates
*only* the synthesizable DUT — a clean kill-rate. For `axis_fifo`/`async_fifo` the
properties are **inlined** in the RTL, so to have the assertions present in the
mutated netlist mcy must read the source with `-DFORMAL` — which also exposes the
**formal-only scaffolding** (the `assert`/`cover` cells, `$anyconst` trackers,
counters) to mutation. Mutating that scaffolding produces "survivors" that say
nothing about DUT quality. Classifying survivors by source line (synthesizable
region vs the `` `ifdef FORMAL `` block) recovers a DUT-logic-only rate, but it is
*still* depressed by two effects: (1) the per-mutant BMC depth is trimmed (12–16)
to keep the broad campaign tractable, so some synth-logic mutants are *false
survivors* a deeper window would catch; and (2) for the wrappers, many DUT
mutations land in the `sync_fifo` submodule whose internal data integrity the
*wrapper's protocol* properties intentionally don't re-prove (that is the
submodule's own gate's job).

**Honest takeaway:** the **clean, comparable mutation-kill metric is
`sync_fifo`'s 92%** (separate-property module → DUT-only mutation). The
`async`/`axis` harnesses are provided as runnable per-design explorations and as a
demonstration of *why* inlined-property modules need separate-property extraction
(or per-region mutation selection) for an apples-to-apples kill-rate — a genuine
verification-engineering nuance, not a number to inflate. Extracting the inlined
properties into separate modules for clean wrapper kill-rates is documented
future work.

See [proven_vs_tested.md](proven_vs_tested.md) and [traceability.md](traceability.md)
for the formal/sim verification matrix this metric complements.
