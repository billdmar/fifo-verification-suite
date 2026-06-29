# How the Formal Proofs Work

A tour of the verification *techniques* behind this suite — not just *what* is
proven (see [proven_vs_tested.md](proven_vs_tested.md)) but *why each proof is
sound* and where its limits are. Written so a reviewer can judge the rigor, and
so a contributor can extend it.

---

## 1. The extra-MSB dual-pointer ring buffer — why it's sound

A FIFO over a power-of-two ring of `DEPTH` slots needs to tell **empty** from
**full**, but both are "the pointers are aligned." The classic fix:
`ADDR_WIDTH+1`-bit pointers (one extra MSB beyond the `$clog2(DEPTH)` address
bits). The low bits index memory; the extra MSB is a *wrap parity*.

- **empty** ⇔ `wptr == rptr` (same address **and** same wrap parity)
- **full**  ⇔ low bits equal **but** wrap parity differs (writer lapped reader once)
- **occupancy** = `wptr − rptr` in `(ADDR_WIDTH+1)`-bit unsigned arithmetic, which
  wraps to exactly `0..DEPTH`.

This is the reusable core of `sync_fifo`, `sync_fifo_fwft`, and (generalized to
multi-beat increments) `sync_fifo_width` and `axis_pkt_fifo`.

## 2. BMC vs. k-induction — bounded check vs. unbounded proof

- **BMC (bounded model checking)** unrolls the design `depth` cycles from a real
  reset and asks the SMT solver "can any assertion fail within `depth` steps?"
  Sound *within the window*. We size `depth` to cover a full fill+drain of the
  formal harness (DEPTH=8 → depth 14–20), so BMC is exhaustive over every
  reachable scenario in that window.
- **k-induction** proves a property for **all** reachable states (unbounded): a
  *basecase* (holds for the first k steps from reset) plus an *induction step*
  (if it held for k consecutive arbitrary states, it holds in the next). When the
  step closes, the property is **PROVEN**, not merely bounded.

`sync_fifo` and `sync_fifo_fwft` close k-induction on their pointer/count/flag
invariants; the rest are BMC-bounded (see §4 for why).

## 3. Auxiliary inductive invariants — making k-induction close

A naive k-induction *step* starts from an **arbitrary** k-state, which may be
*unreachable* in practice (e.g. pointers encoding `count > DEPTH`). The solver
then finds a bogus "counterexample" from that garbage start state and the step
fails. The fix is to *strengthen the inductive hypothesis* with **auxiliary
invariants** — facts that are themselves inductive and exclude the garbage:

- `a_aux_count_le_depth`: occupancy `≤ DEPTH` (the ring-buffer bound)
- `a_aux_full_excl_empty`: pointers can't encode full and empty at once
- `a_aux_shadow_{empty,full}`: the shadow pointer model matches the DUT flags

(See `rtl/sync_fifo_properties.sv` GROUP 6c.) Each is true in every reachable
state and preserved by one step, so adding them never weakens the proof — it only
fences off start states that can't actually occur. With them, the step closes.

`sync_fifo_fwft` reuses the same idea: its pointer/count/flag invariants are
identical in form to `sync_fifo`'s, so the same aux invariants close its
k-induction (`formal/sync_fifo_fwft_prove.sby`).

## 4. The `$anyconst` data-integrity tracker — and why its step stays open

To prove *data* integrity (a written word emerges uncorrupted, in order) without
modelling all of memory, we use a **solver-chosen-constant tracker**: an
`(* anyconst *)` value/index is forced onto one chosen beat at write time, and the
matching delivery is asserted to carry that value. Because the FIFO is
FIFO-ordered, the Nth-in is the Nth-out, so this single tracked beat proves
ordering + integrity for *all* beats within the BMC window.

This **passes BMC** (the authoritative gate) but its **k-induction step does not
close**: the tracker is a *shadow model* that the open-source Yosys frontend can't
bind to the DUT's internal `mem[]` array by hierarchical reference, so an
arbitrary inductive start state can place the shadow and `mem[]` in disagreement.
This is a **tooling limitation, not a design defect** — and we say so plainly in
the docs. BMC depth 16–20 fully covers the data path for the DEPTH=8 harness, and
simulation independently validates ordering across 120k+ cycles.

The data-integrity properties are guarded under `` `ifdef FORMAL_DATA `` so the
`prove` gate can omit them (and cleanly claim PROVEN on the inductive subset)
while the BMC gate still checks them exhaustively.

## 5. CDC: Gray pointers + multi-clock BMC

For the dual-clock `async_fifo`, a binary pointer crossing clock domains could be
sampled mid-transition and resolve to a bogus value. **Gray code** guarantees only
one bit changes per step, so a mid-flight sample resolves to either the old or new
value — never garbage. The proof runs under **`multiclock on`** with the two
clocks driven from a single `$global_clock` via per-edge enables, and verifies
the one-bit-change invariant, conservative full/empty, and cross-domain data
integrity. Open-source functional formal models *relative clock phase/rate* (the
functional CDC risk); it does **not** model analog metastability resolution —
that's what the `SYNC_STAGES` flop chain mitigates, and we don't claim otherwise.

## 6. Liveness: bounded progress, honestly

True unbounded liveness (`s_eventually`) needs the `aiger suprove` engine, which
isn't bundled in this OSS CAD Suite. Rather than claim a mode we can't run, we
encode **bounded progress** as safety: under sustained read (resp. write)
pressure, occupancy strictly decreases (increases) each cycle, bounding
drain-to-empty (fill-to-full) to `≤ DEPTH` cycles, plus `!full || !empty`
(no-deadlock). These close k-induction and have cover witnesses showing real
multi-cycle drain/fill episodes — a sound, decidable progress guarantee.

## 7. Non-vacuity: cover witnesses + fault injection + mutation testing

Three independent layers guard against "the proof passes because nothing
happens":

1. **Cover witnesses** (`c_*`): the solver must *exhibit a trace* reaching each
   interesting state (full, drain-to-empty, tracked round-trip, store-and-forward
   hold-back, …). If a cover can't be reached, the corresponding assertion might be
   vacuous — so all covers must be REACHED.
2. **Fault injection** (`make sim-*-fault`): each simulation scoreboard is rebuilt
   with a deliberately corrupted golden model; the run must *fail*, proving the
   checker isn't asleep.
3. **Mutation testing** (`make mutate`, [mutation_testing.md](mutation_testing.md)):
   the strongest layer — across 100 unbiased RTL mutations, 92% are killed by the
   formal suite and the 8 survivors are all proven equivalent mutants.

Together: the assertions are reachable (covers), the checkers are awake (fault
injection), and the suite catches real bugs at scale (mutation testing).

---

See [assertions.md](assertions.md) for the per-property catalogue,
[traceability.md](traceability.md) for requirement→property→witness mapping, and
[CONTRIBUTING.md](../CONTRIBUTING.md) to add a new verified design.
