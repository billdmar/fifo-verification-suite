// =============================================================================
// Module      : sync_fifo_properties
// Description : Formal-verification property module for sync_fifo.
//
// Design note on Yosys open-source `read -formal` and `bind`:
//   The Yosys open-source frontend (as of 0.64) does not reliably resolve
//   `bind` statements that reference non-port internal signals of a separate
//   DUT module — hierarchical references to sub-module internals are not
//   promoted through the hierarchy pass.  This module is therefore instantiated
//   EXPLICITLY in sync_fifo_formal_tb rather than via a `bind` statement.
//   All DUT-internal signals (wptr, rptr, mem, do_write, do_read, waddr, raddr)
//   must be surfaced as ports for this module to consume them.
//
// Usage:
//   sync_fifo_properties #(.DATA_WIDTH(8), .DEPTH(8)) u_props (
//       .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data),
//       .rd_en(rd_en), .rd_data(rd_data), .full(full), .empty(empty),
//       .almost_full(almost_full), .almost_empty(almost_empty),
//       .count(count),
//       .do_write(do_write_w), .do_read(do_read_w),
//       .waddr(sf_waddr), .raddr(sf_raddr),
//       .sf_wptr(sf_wptr), .sf_rptr(sf_rptr)
//   );
//
//   The shadow write/read pointers (sf_wptr, sf_rptr, sf_waddr, sf_raddr) are
//   maintained in sync_fifo_formal_tb and passed in here.
// =============================================================================

`default_nettype none

module sync_fifo_properties #(
    parameter int DATA_WIDTH          = 8,
    parameter int DEPTH               = 16,
    parameter int ALMOST_FULL_THRESH  = DEPTH - 2,
    parameter int ALMOST_EMPTY_THRESH = 2
) (
    input wire                    clk,
    input wire                    rst_n,
    input wire                    wr_en,
    input wire  [DATA_WIDTH-1:0]  wr_data,
    input wire                    rd_en,
    input wire  [DATA_WIDTH-1:0]  rd_data,
    input wire                    full,
    input wire                    empty,
    input wire                    almost_full,
    input wire                    almost_empty,
    input wire  [$clog2(DEPTH):0] count,
    // Shadow-pointer wires from the TB (mirrors DUT's wptr/rptr/waddr/raddr)
    input wire                    do_write,
    input wire                    do_read,
    input wire  [$clog2(DEPTH)-1:0] waddr,
    input wire  [$clog2(DEPTH)-1:0] raddr,
    input wire  [$clog2(DEPTH):0]  sf_wptr,
    input wire  [$clog2(DEPTH):0]  sf_rptr
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // -------------------------------------------------------------------------
    // f_past_valid: true after the first rising edge so $past() is safe.
    // -------------------------------------------------------------------------
    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // =========================================================================
    // GROUP 1 — Mutual exclusion: full and empty cannot both be set.
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_full_and_empty: assert (!(full && empty));
        end
    end

    // =========================================================================
    // GROUP 2 — ENVIRONMENT ASSUMPTIONS.
    //   Do not write when full; do not read when empty.
    // =========================================================================
    always @(posedge clk) begin
        // ENVIRONMENT ASSUMPTION: no write when full
        m_no_write_when_full: assume (!(full && wr_en));
        // ENVIRONMENT ASSUMPTION: no read when empty
        m_no_read_when_empty: assume (!(empty && rd_en));
    end

    // =========================================================================
    // GROUP 3 — Empty clears after a write into an empty FIFO.
    // =========================================================================
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(empty) && $past(wr_en)) begin
                a_empty_clears_after_write: assert (!empty);
            end
        end
    end

    // =========================================================================
    // GROUP 4 — Full clears after a read from a full FIFO.
    // =========================================================================
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(full) && $past(rd_en)) begin
                a_full_clears_after_read: assert (!full);
            end
        end
    end

    // =========================================================================
    // GROUP 5 — Pointer monotonicity (shadow pointers reflect DUT behavior).
    //   Each shadow pointer either stays or increments by 1 per cycle.
    // =========================================================================
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_wptr_monotone: assert (
                (sf_wptr == $past(sf_wptr)) ||
                (sf_wptr == ($past(sf_wptr) + 1'b1))
            );
            a_rptr_monotone: assert (
                (sf_rptr == $past(sf_rptr)) ||
                (sf_rptr == ($past(sf_rptr) + 1'b1))
            );
        end
    end

    // =========================================================================
    // GROUP 6 — Count / flag consistency.
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            a_count_in_range:       assert (count <= DEPTH[ADDR_WIDTH:0]);
            a_empty_iff_count_zero: assert (empty == (count == '0));
            a_full_iff_count_depth: assert (full  == (count == DEPTH[ADDR_WIDTH:0]));
            a_shadow_count:         assert ((sf_wptr - sf_rptr) == count);
        end
    end

    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_count_monotone: assert (
                (count == $past(count)      ) ||
                (count == $past(count) + 1'b1) ||
                (count == $past(count) - 1'b1)
            );
        end
    end

    // =========================================================================
    // GROUP 6b — Almost-full / almost-empty threshold flags track count.
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            a_almost_full_iff:  assert (almost_full  == (count >= ALMOST_FULL_THRESH[ADDR_WIDTH:0]));
            a_almost_empty_iff: assert (almost_empty == (count <= ALMOST_EMPTY_THRESH[ADDR_WIDTH:0]));
        end
    end

    // =========================================================================
    // GROUP 6c — AUXILIARY INDUCTIVE INVARIANTS (k-induction strengthening).
    //
    //   The shadow pointers sf_wptr/sf_rptr are (ADDR_WIDTH+1)-bit free-running
    //   counters with the extra-MSB wrap encoding (identical scheme to the DUT).
    //   For k-induction these assertions pin the reachable state space so the
    //   inductive hypothesis is strong enough; without them an unrolled induction
    //   start state could place the pointers in a combination that is unreachable
    //   in practice (e.g. count > DEPTH).  Each one is itself an inductive
    //   invariant (true in every reachable state and preserved by one step), so
    //   adding them does not weaken the proof — it only excludes garbage start
    //   states that the bare hypothesis would otherwise admit.
    //
    //   a_aux_count_le_depth : the shadow occupancy (sf_wptr - sf_rptr) can never
    //                          exceed DEPTH.  This is the core ring-buffer bound;
    //                          it makes a_full_iff_count_depth / a_count_in_range
    //                          inductive rather than only basecase-true.
    //   a_aux_full_excl_empty: the shadow pointers can never simultaneously encode
    //                          both full (MSB differ, low equal) and empty (equal),
    //                          mirroring a_no_full_and_empty at the pointer level.
    //   a_aux_shadow_empty   : shadow "equal pointers" iff DUT empty — ties the
    //                          shadow model to the port-observable empty flag so
    //                          the two cannot drift in an inductive start state.
    //   a_aux_shadow_full    : shadow "MSB differ, low equal" iff DUT full — same
    //                          tie for the full flag.
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            a_aux_count_le_depth: assert (
                ((sf_wptr - sf_rptr) <= DEPTH[ADDR_WIDTH:0])
            );
            a_aux_full_excl_empty: assert (
                !( (sf_wptr == sf_rptr) &&
                   (sf_wptr[ADDR_WIDTH] != sf_rptr[ADDR_WIDTH]) &&
                   (sf_wptr[ADDR_WIDTH-1:0] == sf_rptr[ADDR_WIDTH-1:0]) )
            );
            a_aux_shadow_empty: assert (
                (sf_wptr == sf_rptr) == empty
            );
            a_aux_shadow_full: assert (
                ( (sf_wptr[ADDR_WIDTH] != sf_rptr[ADDR_WIDTH]) &&
                  (sf_wptr[ADDR_WIDTH-1:0] == sf_rptr[ADDR_WIDTH-1:0]) ) == full
            );
        end
    end

    // =========================================================================
    // GROUP 7 — DATA ORDERING (per-slot integrity).
    //
    // Timing reasoning:
    //   Registered-output FIFO: rd_data at cycle T+1 equals mem[raddr] latched
    //   at cycle T when do_read was asserted.  We record a read of the tracked
    //   slot at cycle T via f_read_of_tracked_happened, then check rd_data at
    //   cycle T+1.
    //
    // Strategy:
    //   track_slot is a solver-chosen constant (anyconst).
    //   tracked_data holds the last wr_data written to that slot.
    //   When the FIFO reads from that slot, rd_data (one cycle later) must
    //   equal tracked_data.
    // =========================================================================
`ifdef FORMAL

    (* anyconst *) logic [ADDR_WIDTH-1:0] track_slot;

    logic [DATA_WIDTH-1:0] tracked_data;
    logic                  tracked_valid;
    logic                  f_read_of_tracked_happened;

    initial begin
        tracked_data               = '0;
        tracked_valid              = 1'b0;
        f_read_of_tracked_happened = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            tracked_data               <= '0;
            tracked_valid              <= 1'b0;
            f_read_of_tracked_happened <= 1'b0;
        end else begin
            if (do_write && (waddr == track_slot)) begin
                tracked_data  <= wr_data;
                tracked_valid <= 1'b1;
            end
            f_read_of_tracked_happened <=
                do_read && (raddr == track_slot) && tracked_valid;
        end
    end

    // Check rd_data one cycle after the read of the tracked slot.
    //
    // NB: the $anyconst-tracker data/no-loss properties (a_data_integrity,
    // a_no_duplicate_read, a_no_read_before_write) pass BMC but their
    // k-induction STEP does not close — the tracker cannot be tied to the DUT's
    // internal mem[] by hierarchical reference on the open-source Yosys frontend,
    // so the inductive hypothesis admits states where tracker and mem[] disagree
    // (see docs/proven_vs_tested.md). They are therefore excluded from the
    // `mode prove` k-induction gate via `PROVE_KIND` (defined only by the prove
    // script), which k-inducts exactly the pointer/count/flag invariants the
    // docs report as PROVEN. BMC (formal-bmc) still checks all of them.
`ifndef PROVE_KIND
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if (f_read_of_tracked_happened) begin
                a_data_integrity: assert (rd_data == $past(tracked_data));
            end
        end
    end
`endif

    // =========================================================================
    // GROUP 7b — NO-LOSS / NO-DUPLICATION (read-once, in order).
    //
    //   End-to-end "no duplication" story for the tracked slot: the value a
    //   tracked write deposited must be consumed by EXACTLY ONE matching read
    //   before that slot can be legitimately re-read.  In a single-pointer ring
    //   buffer a slot can only be re-read after the read pointer wraps all the
    //   way around (DEPTH reads) AND the slot has been rewritten in between —
    //   you can never read the same deposited word twice without an intervening
    //   write to that slot.  We model this with a small per-slot ownership flag:
    //
    //     slot_pending : set when the tracked slot is written, cleared when it
    //                    is read.  A read of the tracked slot is only legal
    //                    while pending; reading it while NOT pending would mean
    //                    the previously-deposited word is being delivered a
    //                    second time (duplication) or before any write
    //                    (read-before-write), both of which the handshake +
    //                    pointer discipline must forbid.
    //
    //   a_no_duplicate_read: a read of the tracked slot only occurs while its
    //                        deposited word is still pending (not yet consumed).
    //   a_no_read_before_write: the very first read of the tracked slot is never
    //                        accepted before that slot has ever been written.
    // =========================================================================
    logic slot_pending;       // tracked slot holds an un-consumed word
    logic slot_ever_written;  // tracked slot has been written at least once

    initial begin
        slot_pending      = 1'b0;
        slot_ever_written = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            slot_pending      <= 1'b0;
            slot_ever_written <= 1'b0;
        end else begin
            // A write to the tracked slot deposits a (new) word -> pending.
            if (do_write && (waddr == track_slot)) begin
                slot_pending      <= 1'b1;
                slot_ever_written <= 1'b1;
            // A read of the tracked slot consumes the pending word.
            end else if (do_read && (raddr == track_slot)) begin
                slot_pending <= 1'b0;
            end
        end
    end

`ifndef PROVE_KIND
    always @(posedge clk) begin
        if (rst_n) begin
            // No duplication: never read the tracked slot unless it currently
            // holds an un-consumed deposited word.
            if (do_read && (raddr == track_slot)) begin
                a_no_duplicate_read:    assert (slot_pending);
                a_no_read_before_write: assert (slot_ever_written);
            end
        end
    end
`endif

    // =========================================================================
    // GROUP 8 — Cover points.
    // =========================================================================

    // c_reach_full: the FIFO actually becomes full.
    always @(posedge clk) begin
        c_reach_full: cover (rst_n && full);
    end

    // c_full_then_empty: FIFO goes from full back to empty.
    reg f_was_full;
    initial f_was_full = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_full <= 1'b0;
        else if (full) f_was_full <= 1'b1;
    end
    always @(posedge clk) begin
        c_full_then_empty: cover (rst_n && f_was_full && empty);
    end

    // c_tracked_roundtrip: write to track_slot followed by read from it.
    reg f_tracked_written;
    initial f_tracked_written = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_tracked_written <= 1'b0;
        else if (do_write && (waddr == track_slot)) f_tracked_written <= 1'b1;
    end
    always @(posedge clk) begin
        c_tracked_roundtrip: cover (
            rst_n && f_tracked_written &&
            do_read && (raddr == track_slot) && tracked_valid
        );
    end

    // -------------------------------------------------------------------------
    // GROUP 8b — Additional waveform witnesses for richer traces.
    // -------------------------------------------------------------------------

    // c_reach_empty_after_full: explicit "drain to empty" — empty reached while
    //   the FIFO had previously been full (companion to c_full_then_empty, but
    //   asserts the empty edge precisely on the cycle it is first reached).
    reg f_seen_nonempty;
    initial f_seen_nonempty = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_seen_nonempty <= 1'b0;
        else if (!empty) f_seen_nonempty <= 1'b1;
    end
    always @(posedge clk) begin
        c_drain_to_empty: cover (rst_n && f_seen_nonempty && empty);
    end

    // c_ptr_wrap: pointer wrap — a write is accepted while the write address is
    //   the top slot AND the wrap (MSB) bit is about to toggle, i.e. the low
    //   address is about to roll from DEPTH-1 back to 0.  Demonstrates the
    //   extra-MSB ring-buffer wrap that disambiguates empty from full.
    always @(posedge clk) begin
        c_wptr_wrap: cover (
            rst_n && do_write && (waddr == (DEPTH-1)) && (sf_wptr[ADDR_WIDTH-1:0] == (DEPTH-1))
        );
        c_rptr_wrap: cover (
            rst_n && do_read && (raddr == (DEPTH-1)) && (sf_rptr[ADDR_WIDTH-1:0] == (DEPTH-1))
        );
    end

    // c_simul_rw_partial: simultaneous read+write while partially full (neither
    //   empty nor full) — count holds steady at a mid value, exercising the
    //   concurrent-handshake path.
    always @(posedge clk) begin
        c_simul_rw_partial: cover (
            rst_n && do_write && do_read && !empty && !full &&
            (count > 1) && (count < DEPTH[ADDR_WIDTH:0])
        );
    end

    // c_full_empty_full: full -> empty -> full round trip in a single trace.
    //   Two-stage flag: arm on full, advance through empty, complete on full
    //   again — proves the FIFO can be filled, fully drained, and refilled.
    reg [1:0] f_cycle_stage;   // 0=init, 1=was full, 2=full->empty, 3=full again
    initial f_cycle_stage = 2'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            f_cycle_stage <= 2'd0;
        end else begin
            case (f_cycle_stage)
                2'd0: if (full)  f_cycle_stage <= 2'd1;
                2'd1: if (empty) f_cycle_stage <= 2'd2;
                2'd2: if (full)  f_cycle_stage <= 2'd3;
                default: ; // stay
            endcase
        end
    end
    always @(posedge clk) begin
        c_full_empty_full: cover (rst_n && (f_cycle_stage == 2'd3));
    end

    // =========================================================================
    // GROUP 9 — LIVENESS / PROGRESS (fairness-conditioned, bounded formulation).
    //
    //   WHY BOUNDED-SAFETY INSTEAD OF `mode live` / s_eventually:
    //     True unbounded liveness (assert property (s_eventually ...)) needs an
    //     omega-regular / fair-cycle engine.  The only engine SymbiYosys 0.66
    //     accepts for `mode live` is `aiger suprove`, and suprove is NOT present
    //     in this OSS CAD Suite install (verified: `which suprove` -> not found;
    //     `mode live` with smtbmc/pono is rejected as "Invalid engine for live
    //     mode").  Rather than claim a liveness mode we cannot run, we encode
    //     progress as a BOUNDED-WINDOW SAFETY property that smtbmc proves at the
    //     BMC gate: under a fairness assumption (read pressure with no writes),
    //     occupancy strictly decreases every cycle, which bounds drain-to-empty
    //     to <= DEPTH cycles.  Strict monotone decrease under sustained pressure
    //     is a sound, decidable witness of progress / no-deadlock.
    //
    //   a_progress_drain : while rd_en is asserted, the FIFO is non-empty, and no
    //                      write is accepted this cycle, occupancy strictly
    //                      decreases next cycle.  No read-side stall: a readable
    //                      FIFO under read pressure always drains by one.
    //   a_progress_fill  : while wr_en is asserted, the FIFO is non-full, and no
    //                      read is accepted this cycle, occupancy strictly
    //                      increases next cycle.  No write-side stall.
    //   a_no_deadlock    : the FIFO can ALWAYS make progress — it is never
    //                      simultaneously unable to accept a write (full) and
    //                      unable to deliver a read (empty).  (Equivalent to
    //                      a_no_full_and_empty but framed as the no-deadlock
    //                      liveness precondition: at least one direction is
    //                      always enabled, so a fair environment cannot wedge.)
    // =========================================================================
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            // Bounded drain: read pressure + non-empty + no accepted write
            //   => occupancy went down by exactly one.
            if ($past(rd_en) && !$past(empty) && !$past(do_write)) begin
                a_progress_drain: assert (count == ($past(count) - 1'b1));
            end
            // Bounded fill: write pressure + non-full + no accepted read
            //   => occupancy went up by exactly one.
            if ($past(wr_en) && !$past(full) && !$past(do_read)) begin
                a_progress_fill: assert (count == ($past(count) + 1'b1));
            end
        end
    end

    // No-deadlock: at least one direction (enqueue or dequeue) is always enabled.
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_deadlock: assert (!full || !empty);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 9b — progress witnesses (cover): show drain and fill actually run to
    //   completion under sustained pressure, producing readable waveforms.
    //
    //   f_drain_run counts consecutive cycles of "read pressure, no write".  The
    //   cover fires when such a run ends at empty, i.e. a real drain-to-empty
    //   episode happened (not a vacuous single-cycle hit).
    // -------------------------------------------------------------------------
    localparam int CW = ADDR_WIDTH + 2;   // wide enough to count past DEPTH
    reg [CW-1:0] f_drain_run;
    reg [CW-1:0] f_fill_run;
    initial begin
        f_drain_run = '0;
        f_fill_run  = '0;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            f_drain_run <= '0;
            f_fill_run  <= '0;
        end else begin
            // sustained read pressure with no writes accepted
            if (rd_en && !do_write && !empty) f_drain_run <= f_drain_run + 1'b1;
            else                              f_drain_run <= '0;
            // sustained write pressure with no reads accepted
            if (wr_en && !do_read && !full)   f_fill_run <= f_fill_run + 1'b1;
            else                              f_fill_run <= '0;
        end
    end
    always @(posedge clk) begin
        // A multi-cycle drain run that has emptied the FIFO.
        c_sustained_drain_empties: cover (rst_n && empty && (f_drain_run >= DEPTH[CW-1:0]));
        // A multi-cycle fill run that has filled the FIFO.
        c_sustained_fill_fills:    cover (rst_n && full  && (f_fill_run  >= DEPTH[CW-1:0]));
    end

`endif // FORMAL

endmodule

`default_nettype wire
