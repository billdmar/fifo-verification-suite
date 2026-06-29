# Assertion Catalogue & Verification Density

A consolidated, per-property view of every SVA assertion, assumption, and cover
witness in the suite, with its verification method and status. Every label below
exists verbatim in the RTL (`grep` the labels) and every status maps to a `make`
target that runs locally and in CI.

Status legend: **PROVEN** = k-induction step closes (unbounded) · **PASS** =
BMC-bounded (sound within the depth) · **REACHED** = cover witness hit ·
**enforced** = environment assumption (`assume`). Formal harness DEPTH=8.

---

## Verification density

| Metric | Value |
|--------|-------|
| Designs formally verified | 4 (`sync_fifo`, `async_fifo`, `axis_fifo`, `sync_fifo_fwft`) |
| Distinct `assert` properties | 44 |
| Environment `assume` constraints | 4 |
| `cover` witnesses (all REACHED) | 22 (10 sync + 4 async + 4 AXI + 4 FWFT) |
| Synthesizable RTL | ~311 SLOC across the 4 designs |
| **Assertion density** | **~0.14 asserts / synth-LOC** (~0.21 incl. covers) |

Context: published guidance on assertion-based verification typically cites
~0.02–0.05 assertions per RTL line as a healthy ratio for control-dominated
logic. This suite runs roughly 3–7× that, because the properties are the primary
correctness argument (formal-first), not an afterthought layered on simulation.
The number is a *rough* density signal, not a quality guarantee — what matters is
that the properties below cover the real failure modes (overflow/underflow,
ordering, CDC sampling, protocol compliance, show-ahead timing), which the
proven-vs-tested split documents honestly.

---

## Synchronous FIFO — `sync_fifo` (properties in `sync_fifo_properties.sv`)

| Assertion label | Concern | Method | Status |
|-----------------|---------|--------|--------|
| `a_no_full_and_empty` | safety | bmc + k-ind | PROVEN |
| `m_no_write_when_full` / `m_no_read_when_empty` | env assume | — | enforced |
| `a_empty_clears_after_write` / `a_full_clears_after_read` | safety | bmc + k-ind | PROVEN |
| `a_wptr_monotone` / `a_rptr_monotone` | pointer | bmc + k-ind | PROVEN |
| `a_count_in_range` / `a_empty_iff_count_zero` / `a_full_iff_count_depth` / `a_shadow_count` | count/flag | bmc + k-ind | PROVEN |
| `a_count_monotone` | count step ±1 | bmc + k-ind | PROVEN |
| `a_almost_full_iff` / `a_almost_empty_iff` | threshold | bmc + k-ind | PROVEN |
| `a_aux_count_le_depth` / `a_aux_full_excl_empty` / `a_aux_shadow_empty` / `a_aux_shadow_full` | inductive strengthening | bmc + k-ind | PROVEN |
| `a_progress_drain` / `a_progress_fill` | bounded liveness | bmc + k-ind | PROVEN |
| `a_no_deadlock` | bounded liveness | bmc + k-ind | PROVEN |
| `a_data_integrity` | data ordering (`$anyconst`) | bmc | PASS (step open) |
| `a_no_duplicate_read` / `a_no_read_before_write` | no-loss/dup | bmc | PASS (step open) |
| 10 `c_*` covers (fill, drain, wptr/rptr wrap, simul R+W, full→empty→full, sustained drain/fill, round-trip) | reachability | cover (d=30) | all REACHED |

## Asynchronous FIFO — `async_fifo` (inlined `ifdef FORMAL`, multiclock)

| Assertion label | Concern | Method | Status |
|-----------------|---------|--------|--------|
| `a_wgray_one_bit` / `a_rgray_one_bit` | Gray single-bit-change (CDC safety) | bmc (multiclk, d=16) | PASS |
| `a_wgray_encodes_wbin` / `a_rgray_encodes_rbin` | Gray encodes binary | bmc | PASS |
| `a_wbin_monotone` / `a_rbin_monotone` | per-domain monotonicity | bmc | PASS |
| `a_no_overflow` / `a_no_underflow` | safety | bmc | PASS |
| `a_occupancy_le_depth` | occupancy bound | bmc | PASS |
| `a_full_when_actually_full` | no missed-full | bmc | PASS |
| `a_empty_matches_rdview` | read-domain flag soundness | bmc | PASS |
| `a_data_integrity` | cross-domain data (`$anyconst`) | bmc | PASS |
| `m_no_write_when_full` / `m_no_read_when_empty` | env assume | — | enforced |
| 4 `c_*` covers (full, non-empty, Gray wrap, round-trip) | reachability | cover (d=30) | all REACHED |

## AXI4-Stream wrapper — `axis_fifo` (inlined `ifdef FORMAL`)

| Assertion label | Concern | Method | Status |
|-----------------|---------|--------|--------|
| `a_m_tvalid_stable` | TVALID stable until accepted | bmc (d=20) | PASS |
| `a_m_tdata_stable` / `a_m_tlast_stable` | payload stable while stalled | bmc | PASS |
| `a_no_spurious_valid` | TVALID iff data held | bmc | PASS |
| `a_tready_iff_room` / `a_no_push_when_full` | slave handshake / no overflow | bmc | PASS |
| `a_pop_excl` / `a_landing_slot` | registered-latency skid invariants | bmc | PASS |
| `a_no_pop_when_stalled` | no data loss under backpressure | bmc | PASS |
| `a_e2e_data` / `a_e2e_last` | end-to-end integrity (`$anyconst`) | bmc | PASS |
| 4 `c_*` covers (deliver, stall-then-resume, round-trip, TLAST out) | reachability | cover (d=30) | all REACHED |

## FWFT (show-ahead) FIFO — `sync_fifo_fwft` (inlined `ifdef FORMAL`)

| Assertion label | Concern | Method | Status |
|-----------------|---------|--------|--------|
| `a_fwft_data_at_head` | **show-ahead: head word on rd_data with zero latency** | bmc (d=20) | PASS |
| `a_no_full_and_empty` / `a_valid_iff_not_empty` | flag safety | bmc | PASS |
| `a_count_in_range` / `a_empty_iff_count_zero` / `a_full_iff_count_depth` | count/flag | bmc | PASS |
| `a_almost_full_iff` / `a_almost_empty_iff` | threshold | bmc | PASS |
| `a_no_overflow` / `a_no_underflow` | safety | bmc | PASS |
| `a_wptr_monotone` / `a_rptr_monotone` / `a_count_monotone` | pointer/count | bmc | PASS |
| `a_no_duplicate_read` / `a_no_read_before_write` | no-loss/dup | bmc | PASS |
| `m_no_write_when_full` / `m_no_read_when_empty` | env assume | — | enforced |
| 4 `c_*` covers (full, show-ahead, full→empty, round-trip) | reachability | cover (d=30) | all REACHED |

---

See [proven_vs_tested.md](proven_vs_tested.md) for why the `$anyconst` data
properties are BMC-bounded (the shadow tracker cannot bind to internal `mem[]`
on the open-source Yosys frontend) and [verification_matrix.md](verification_matrix.md)
for the consolidated method/depth/tool matrix.
