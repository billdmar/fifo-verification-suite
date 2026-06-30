# What's Proven vs. What's Tested

This project is deliberate about the difference between *formally proven*,
*formally checked within a bound*, *simulation-validated*, and *out of scope*.
Every row below corresponds to a `make` target that actually runs (locally and
in CI). Nothing here is aspirational.

## ✅ Formally PROVEN (unbounded — k-induction step closes)

These hold for **all reachable states**, not just a bounded window. Discharged
by SymbiYosys `prove` mode and re-checked by BMC.

**`sync_fifo`:**
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

**`sync_fifo_fwft`** (k-induction `formal/sync_fifo_fwft_prove.sby`): the
pointer/count/flag subset — `!(full&&empty)`, count-in-range, `empty⇔count==0`,
`full⇔count==DEPTH`, `valid⇔!empty`, almost-flags track count, pointer/count
monotonicity, no over/underflow — closes k-induction (PROVEN), same extra-MSB
scheme as `sync_fifo`. The `$anyconst` show-ahead data-integrity properties stay
BMC-bounded (below) — they are guarded under `FORMAL_DATA` and omitted from the
prove gate, since the shadow tracker cannot bind to the DUT `mem[]` on the
open-source Yosys frontend (same documented limitation as `sync_fifo`).

**`sync_fifo_ecc`** (k-induction `formal/sync_fifo_ecc_prove.sby`): the
pointer/count/flag core closes k-induction (PROVEN) — the SECDED encode/decode is
purely combinational and doesn't touch the pointers, so the inductive core is
identical to `sync_fifo`'s. (The SECDED correct/detect behaviour is proven
*exhaustively over every error position* by BMC — see below.)

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
| Show-ahead data-at-head + no-dup/no-read-before-write (`$anyconst`; ring invariants are k-induction PROVEN above) | fwft | 20 |
| Width-crossing data integrity (`$anyconst` narrow-beat tracker) + pointer/count/flag invariants, no over/underflow | sync_fifo_width | 14 |
| Store-and-forward + packet atomicity + end-to-end {tdata,tlast} integrity (`$anyconst`) | axis_pkt_fifo | 14 |
| **SECDED correct/detect — EXHAUSTIVE over every error position** (`$anyconst` error mask): single-bit corrected + `single_err`; double-bit detected + `double_err` | sync_fifo_ecc | 16 |

**On the SECDED ECC FIFO (`sync_fifo_ecc`).** Each 8-bit word is stored as a
13-bit extended-Hamming (13,8) codeword. The correct/detect behaviour is proven
**exhaustively over every error position** by formal fault injection: under
`FORMAL_DATA`, an `$anyconst` error mask (exactly two solver-chosen bit positions)
is XORed into the stored codeword on read, so BMC discharges the correction
(weight-1 → data restored + `single_err`) and detection (weight-2 → `double_err`)
assertions for *all* positions — not a sampled subset. The synth path carries NO
error-injection logic (it is `` `ifdef FORMAL ``-only). Covers `c_single_corrected`
+ `c_double_detected` witness a real corrected single / detected double
(non-vacuity). Out of scope: 3+-bit errors (SECDED does not claim them — see
below); errors in the pointer/control logic (only the data word is ECC-protected).

**On the asymmetric-width FIFO (`sync_fifo_width`).** The width-crossing data
integrity is formally proven by BMC (depth 14) on **two** instances covering
**both directions** of the width change: a **2:1 down-sizer**
(`WR_WIDTH=8`,`RD_WIDTH=4`; `formal/sync_fifo_width_bmc.sby`) and a **2:1
up-sizer** (`WR_WIDTH=4`,`RD_WIDTH=8`; `formal/sync_fifo_width_up_bmc.sby`), both
`NARROW=4`,`DEPTH_NARROW=8`, little sub-word order. The two exercise the opposite
pack/unpack datapaths (multi-beat write + single-beat read vs. the reverse). Each
has a companion cover (`c_track_roundtrip`) exhibiting a concrete write→read
round-trip of a solver-chosen tracked narrow beat, proving the `$anyconst`
integrity assertion is **non-vacuous** — it witnesses that *at least one* tracked
index is reachable and genuinely checked, not that every one of the 32 possible
`f_track_idx` values fires (indices unreachable in the depth-14 window pass
inertly and cannot mask a counterexample). BMC discharges the assertion for *all*
index values, so within the window every reachable narrow beat is proven delivered
in FIFO order at the correct sub-word position.
**Higher ratios (4:1, 8:1) and big sub-word order are validated by the Verilator
constrained-random testbench** against a narrow-granularity golden model
(`make sim-width-fifo-sweep` covers 2:1/4:1/8:1, little+big, both directions),
with anti-vacuity proven by fault injection (`make sim-width-fifo-fault`). In
short: both width *directions* at 2:1 are formally proven; the larger ratios and
big-endian order are covered by the geometric simulation sweep.

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
- **`axis_pkt_fifo` with an oversized packet**: store-and-forward *inherently*
  needs the whole packet to fit before its TLAST commits, so a packet of
  `DEPTH`-or-more beats wedges the buffer (it can never commit). This is a
  **producer contract** (packets ≤ `DEPTH-1` beats), documented in the module
  header and made explicit as the formal assumption `m_pkt_fits` ((`wptr -
  commit_ptr`) < DEPTH); the cover `c_near_full` shows the bound is exercised to
  the limit. The suite-wide no-deadlock guarantee is about the single-clock
  plain/FWFT FIFOs' `!full || !empty` progress and does **not** extend to a
  store-and-forward buffer fed a non-conformant (oversized) packet.
- **`sync_fifo_ecc` triple-bit (3+) errors**: a SECDED (13,8) code corrects 1-bit
  and detects 2-bit errors by construction; 3-or-more-bit errors in one codeword
  are **out of scope** (may miscorrect or alias) — this is the definition of
  SECDED, stated plainly, not a gap. Only the stored *data word* is protected
  (the pointer/control logic is not ECC-covered — a separate concern). DATA_WIDTH
  is fixed at 8 this release; generalization to other widths is documented future
  work.
- **Async `async_fifo` k-induction**: still informational (basecase passes, step
  open). A round-4 time-boxed attempt (per-domain gray/monotonicity aux invariants
  + `FORMAL_DATA`-guarded data tracker) did NOT close the step — the gated-
  multiclock model admits inductive start states where `$past(wgray)` isn't a
  valid encoding of `$past(wbin)`, and pinning that across the synchronizer chain
  + relative clock phase is research-hard. Async guarantees remain BMC depth-16 +
  cover (unchanged, honest).
