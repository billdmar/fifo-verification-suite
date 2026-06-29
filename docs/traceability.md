# Requirement → Property → Witness Traceability

This matrix traces each **design guarantee** (the requirement) to the **formal
property** (or simulation check) that establishes it and the **witness** that
proves the check is non-vacuous (a passing cover trace, or a fault-injection
self-test). It complements [assertions.md](assertions.md) (the raw per-label
catalogue) by organizing around *what each design promises a user*.

Status legend: **PROVEN** = k-induction (unbounded) · **BMC** = bounded model
check (sound to the depth) · **SIM** = Verilator/cocotb constrained-random ·
witness column names the cover or anti-vacuity check.

Every row maps to a `make` target that runs locally and in CI.

---

## sync_fifo (single-clock, registered read)

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| Never reports full and empty at once | `a_no_full_and_empty` | PROVEN | — |
| Never overflows / underflows | handshake assumes + count bound | PROVEN | — |
| Occupancy & flags always consistent | `a_count_*`, `a_*_iff_*`, `a_shadow_count` | PROVEN | `c_reach_full`, `c_full_then_empty` |
| Always makes progress (no deadlock) | `a_progress_drain/fill`, `a_no_deadlock` | PROVEN | `c_sustained_drain/fill` |
| Data exits in order, uncorrupted | `a_data_integrity` (`$anyconst`) | BMC 20 | `c_tracked_roundtrip` + `sim-fault` |
| No word read twice / before write | `a_no_duplicate_read`, `a_no_read_before_write` | BMC 20 | `c_tracked_roundtrip` |
| Correct across widths/depths | 13 scenarios + 120k random, DEPTH 4–256, DATA_WIDTH 1/8/64 | SIM | `sim-fault` anti-vacuity |

## sync_fifo_fwft (first-word-fall-through / show-ahead)

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| Head word visible with **zero latency** | `a_fwft_data_at_head` | BMC 20 | `c_show_ahead` |
| `valid` ⇔ non-empty | `a_valid_iff_not_empty` | **PROVEN** (k-ind) | — |
| Ring invariants / no over-underflow | `a_count_*`, `a_no_overflow/underflow` | **PROVEN** (k-ind) | `c_reach_full`, `c_full_then_empty` |
| No dup / no read-before-write | `a_no_duplicate_read`, `a_no_read_before_write` | BMC 20 | `c_tracked_roundtrip` |
| Correct across widths | show-ahead TB, DATA_WIDTH 1/8/64 | SIM | `sim-fwft-fault` |

(`formal/sync_fifo_fwft_prove.sby` closes k-induction on the pointer/count/flag
subset — round 3; the `$anyconst` show-ahead data props remain BMC-bounded, same
`mem[]` limitation as `sync_fifo`.)

## async_fifo (dual-clock CDC)

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| Gray pointer changes one bit/step (CDC-safe) | `a_wgray_one_bit`, `a_rgray_one_bit` | BMC 16 (multiclk) | `c_wgray_wrap` |
| No overflow / underflow across domains | `a_no_overflow`, `a_no_underflow`, `a_occupancy_le_depth` | BMC 16 | `c_reach_full`, `c_reach_empty` |
| Flags conservative (never unsafe) | `a_full_when_actually_full`, `a_empty_matches_rdview` | BMC 16 | — |
| Data crosses domains intact | `a_data_integrity` (`$anyconst`) | BMC 16 | `c_tracked_roundtrip` |

## axis_fifo (AXI4-Stream wrapper)

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| TVALID/TDATA/TLAST stable until accepted | `a_m_tvalid_stable`, `a_m_t{data,last}_stable` | BMC 20 | `c_deliver` |
| No spurious valid | `a_no_spurious_valid` | BMC 20 | — |
| No overflow (slave handshake) | `a_tready_iff_room`, `a_no_push_when_full` | BMC 20 | — |
| No loss/dup under backpressure | `a_pop_excl`, `a_landing_slot`, `a_no_pop_when_stalled` | BMC 20 | `c_stall_then_resume` |
| End-to-end data + TLAST integrity | `a_e2e_data`, `a_e2e_last` (`$anyconst`) | BMC 20 | `c_track_roundtrip`, `c_tlast_out` |

## sync_fifo_width (asymmetric-width FIFO) — round 2

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| Data crosses the width change in FIFO order, correct sub-word position | `a_width_data_integrity` (`$anyconst` narrow-beat tracker) | BMC 14, **both directions** (down-sizer + up-sizer gates) | `c_track_roundtrip` + `sim-width-fifo-fault` |
| Pointers advance at correct per-side beat rates | `a_wptr_step`, `a_rptr_step` | BMC 14 | — |
| No over/underflow (multi-beat) | `a_no_overflow`, `a_no_underflow`, `a_count_in_range` | BMC 14 | `c_reach_full` |
| Flags consistent in narrow-beat units | `a_wr_full_iff`, `a_rd_empty_iff`, `a_almost_*_iff` | BMC 14 | — |
| Higher ratios (4:1/8:1) + big sub-word order | narrow-granularity golden model sweep | SIM | `sim-width-fifo-fault` |

## axis_width_conv (AXI4-Stream width converter) — round 2

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| Width crossing itself correct | (delegated to `sync_fifo_width` gate) | BMC 14 | `c_track_roundtrip` |
| TVALID/TDATA stable until accepted | `a_m_tvalid_stable`, `a_m_tdata_stable` | BMC 14 | `c_deliver` |
| No spurious valid | `a_no_spurious_valid` | BMC 14 | — |
| No overflow (slave handshake) | `a_tready_iff_room`, `a_no_push_when_full` | BMC 14 | — |
| No loss/dup under backpressure | `a_pop_excl`, `a_landing_slot`, `a_no_pop_when_stalled` | BMC 14 | `c_stall_then_resume` |

## axis_pkt_fifo (store-and-forward packet FIFO) — round 3

| Requirement | Property / check | Method | Witness |
|-------------|------------------|--------|---------|
| **Store-and-forward**: a beat is never delivered before its packet's TLAST is committed | `a_read_committed`, commit-pointer bounds (`a_commit_le_write`, `a_commit_monotone`) | BMC 14 | `c_partial_held` |
| Packet-count conservation | `a_pkts_conserved`, `a_pktcount_le_occ` | BMC 14 | `c_two_pkts` |
| End-to-end {tdata,tlast} integrity, in order | `a_e2e_data`, `a_e2e_last` (`$anyconst`) | BMC 14 | `c_track_roundtrip`, `c_tlast_out` |
| AXI master protocol (stable-until-accepted, no spurious) | `a_m_t{valid,data,last}_stable`, `a_no_spurious_valid` | BMC 14 | `c_deliver` |
| No overflow / no loss under backpressure | `a_no_push_when_full`, `a_no_pop_when_stalled` | BMC 14 | `c_stall_then_resume` |
| Random packets + backpressure correct | packet-aware deque golden model | SIM | `sim-pktfifo-fault` |

---

## Coverage evidence

- **Functional coverage:** 10/10 bins on `sync_fifo`, hard-gated (`make sim`).
- **Structural coverage:** 100% line/toggle/branch/expr via `verilator_coverage`
  (`make sim-coverage`); the annotated report is uploaded as the CI artifact
  **`verilator-coverage-report`** (`logs_annotated/`).
- **Anti-vacuity:** every scoreboard has a fault-injection self-test that must
  fail on a corrupted golden model — `sim-fault`, `sim-cocotb-fault`,
  `sim-fwft-fault`, `sim-width-fifo-fault`, `sim-pktfifo-fault`.
- **Mutation testing:** `make mutate` (mcy) — **92% kill-rate** on `sync_fifo`,
  all 8 survivors proven equivalent mutants ([mutation_testing.md](mutation_testing.md)).
- **Bitstream:** `make bitstream` emits real ECP5 `.bit` + iCE40 `.bin` (CI
  artifact **`demo-top-bitstreams`**), proving the RTL→chip flow.
- **Performance:** `make perf-report` — cycle-accurate throughput/latency
  ([perf_results.md](perf_results.md)).

See [proven_vs_tested.md](proven_vs_tested.md) for the formal-vs-simulation
boundary and [assertions.md](assertions.md) for the full assertion catalogue +
density metric.
