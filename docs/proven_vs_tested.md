# What's Proven vs. What's Tested

This project is deliberate about the difference between *formally proven*,
*formally checked within a bound*, *simulation-validated*, and *out of scope*.
Every row below corresponds to a `make` target that actually runs (locally and
in CI). Nothing here is aspirational.

## ✅ Formally PROVEN (unbounded — k-induction step closes)

These hold for **all reachable states**, not just a bounded window. Discharged
by SymbiYosys `prove` mode and re-checked by BMC.

- Mutual exclusion: `!(full && empty)`
- Empty clears after a write; full clears after a read
- Write/read pointer monotonicity (stay or +1 per cycle)
- Count in range `0..DEPTH`; `empty ⇔ count==0`; `full ⇔ count==DEPTH`
- Count steps by at most ±1; shadow-count equals `wptr − rptr`
- Almost-full / almost-empty flags exactly track `count`
- Auxiliary inductive invariants (occupancy bound, full⊕empty exclusion,
  shadow-empty/full equivalence) that strengthen the induction
- **Bounded progress / no-deadlock**: under sustained read (resp. write)
  pressure occupancy strictly decreases (resp. increases), and `!full || !empty`
  always holds — so the FIFO always makes progress and can never wedge

## ✅ Formally CHECKED — BMC-bounded (sound within the depth)

Proven by Bounded Model Checking to the stated depth. The depth is chosen to
cover a complete fill-and-drain episode for the DEPTH=8 formal harness, so these
are exhaustive over every reachable scenario within that window.

| Property | Module | Depth |
|----------|--------|-------|
| Data ordering / per-slot integrity (`$anyconst` slot tracker) | sync | 20 |
| No duplicate read / no read-before-write | sync | 20 |
| All CDC properties — Gray-one-bit, encode, monotonic, no over/underflow, occupancy, no-missed-full, cross-domain data integrity | async (multiclock) | 16 |
| AXI4-Stream protocol — tvalid/tdata/tlast stable-until-accepted, no loss under backpressure, no spurious valid, end-to-end data/last integrity | axis | 20 |
| Show-ahead data-at-head + ring invariants + no-dup/no-read-before-write | fwft | 20 |
| Width-crossing data integrity (`$anyconst` narrow-beat tracker) + pointer/count/flag invariants, no over/underflow | sync_fifo_width | 14 |

**On the asymmetric-width FIFO (`sync_fifo_width`).** The width-crossing data
integrity is formally proven by BMC (depth 14) on a representative **2:1
down-sizer** instance (`WR_WIDTH=8`, `RD_WIDTH=4`, `NARROW=4`, `DEPTH_NARROW=8`,
little sub-word order). A companion cover (`c_track_roundtrip`) exhibits a
concrete write→read round-trip of a solver-chosen tracked narrow beat, proving
the `$anyconst` integrity assertion is **non-vacuous** (it is genuinely checked on
a reachable index, not trivially satisfied). The `$anyconst` tracker proves every
reachable narrow beat is delivered in FIFO order at the correct sub-word position.
**Higher ratios (4:1, 8:1), the up-sizer direction (`WR_WIDTH<RD_WIDTH`), and big
sub-word order are validated by the Verilator constrained-random testbench**
against a narrow-granularity golden model (`make sim-width-fifo-sweep` covers
2:1/4:1/8:1, little+big, both directions), with anti-vacuity proven by fault
injection (`make sim-width-fifo-fault`). In short: the formal instance proves the
pack/unpack data-flow on one geometry; simulation covers the geometric sweep.

**Why the `$anyconst` data-integrity properties are BMC-bounded, not proven:**
the slot tracker is a shadow model that cannot be tied to the DUT's internal
`mem[]` array — the open-source Yosys frontend does not expose another module's
internal arrays by hierarchical reference, so the inductive hypothesis admits
states where the shadow and `mem[]` disagree (the *basecase* passes; the
induction *step* does not). This is a tooling limitation, not a design defect.
BMC is the authoritative gate, and simulation independently validates ordering.

## ✅ Simulation-VALIDATED (not formal, but exhaustively exercised)

Verilator C++ testbench with a `std::queue` golden-model scoreboard:

- Data ordering and `count`/`empty`/`full` correctness checked **every cycle**
  across DEPTH ∈ {4, 8, 16, 64, 256}
- 13 directed/random scenarios incl. boundary stress and a **120,000-cycle**
  biased constrained-random run
- **Coverage closure**: 10/10 functional bins (hard-gated) + 100% Verilator
  line / toggle / branch / expr coverage
- **Anti-vacuity**: `make sim-fault` injects a fault and the run *fails*
  unless the scoreboard catches it — proving the checker isn't vacuous

## ⚠️ NOT claimed / out of scope

- **True unbounded liveness** (`s_eventually` / `mode live`): not runnable on
  this OSS CAD Suite — SymbiYosys only accepts the `aiger suprove` engine for
  live mode and it isn't bundled. We provide *bounded* progress instead (proven,
  above) and say so plainly.
- **Async k-induction**: informational only — basecase passes, the step does not
  close (the synchronizer chain needs explicit inductive strengthening). Async
  guarantees are BMC depth-16 + cover.
- **Analog metastability resolution**: an electrical/STA concern; mitigated by
  the `SYNC_STAGES` flop chain, not provable by functional formal.
- **Vendor-FPGA timing**: the committed FPGA numbers are open-source-flow
  (Yosys + nextpnr); Lattice Diamond/Radiant or Xilinx Vivado will differ.
