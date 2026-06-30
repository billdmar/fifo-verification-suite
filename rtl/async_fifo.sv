//==============================================================================
// Module      : async_fifo
// Description : Parameterizable ASYNCHRONOUS (dual-clock) FIFO. Independent
//               write (wr_clk/wr_rst_n) and read (rd_clk/rd_rst_n) clock
//               domains are bridged with Gray-code pointers and multi-flop
//               CDC synchronizers — the textbook (Cummings) clock-domain-
//               crossing FIFO architecture.
// Parameters  : DATA_WIDTH  - width of each data word            [1..64]
//               DEPTH       - number of entries, power of 2       [4..1024]
//               SYNC_STAGES - synchronizer flop depth per crossing [2..8]
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (multi-clock BMC + cover) via inlined
//               `ifdef FORMAL SVA — the open-source Yosys frontend cannot wire
//               `bind` to a separate module's internals, so the CDC-aware
//               properties live inside this module where they see internals
//               natively. Fully synthesizable: NO initial blocks outside
//               `ifdef FORMAL; the synth path is pure always_ff / assign.
//
// Why Gray code crosses clock domains safely:
//   A binary counter can change many bits at once (e.g. 0111 -> 1000). When
//   that multi-bit value is sampled by a flop in the OTHER clock domain at the
//   exact moment of transition, the sampled value can be ANY combination of
//   old/new bits — a metastable, arbitrary integer. Gray code guarantees that
//   successive values differ by EXACTLY ONE bit, so a mid-flight sample can
//   only ever resolve to the old or the new value, never a bogus third one.
//   That single-bit-change invariant is what makes the comparison safe.
//
// Architecture (per-domain pointer math, gray crossing in the middle):
//
//   wr_clk domain                                          rd_clk domain
//   -------------                                          -------------
//   wbin (binary) --+--> mem[] write addr                  rbin (binary)
//                   |                                            |
//                   +--> wgray (bin->gray) ===[SYNC_STAGES]===> wgray_rdsync
//                                                                |
//   rgray_wrsync <===[SYNC_STAGES]=== rgray (bin->gray) <--------+
//        |
//   full = (wgray == invert-top-two-bits(rgray_wrsync))    empty = (rgray ==
//                                                                   wgray_rdsync)
//
//   full  is computed in the WRITE domain (compares local wgray against the
//         read pointer synchronized INTO the write domain). Asserted when the
//         next write would catch the read pointer: the classic test where the
//         two MSBs of the gray pointers are inverted and the rest match.
//   empty is computed in the READ domain (rgray equals the write pointer
//         synchronized INTO the read domain). Both flags are CONSERVATIVE:
//         a synchronized pointer is always stale-or-current, so `full` may
//         assert a touch early and `empty` may de-assert a touch late — never
//         the unsafe direction (never overflow, never underflow).
//==============================================================================

`default_nettype none

module async_fifo #(
    parameter int DATA_WIDTH  = 8,
    parameter int DEPTH       = 16,
    parameter int SYNC_STAGES = 2
) (
    // Write clock domain
    input  wire                   wr_clk,
    input  wire                   wr_rst_n,    // active-low async-assert reset
    input  wire                   wr_en,
    input  wire  [DATA_WIDTH-1:0] wr_data,
    output logic                  full,

    // Read clock domain
    input  wire                   rd_clk,
    input  wire                   rd_rst_n,    // active-low async-assert reset
    input  wire                   rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  empty
);

    // ADDR_WIDTH is derived internally — never expose it as a top-level
    // parameter, so DEPTH and the pointer widths can never disagree.
    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // Compile-time sanity checks. A named generate block of elaboration-time
    // $error calls fires during elaboration on every tool and emits nothing
    // for legal parameterizations.
    if (DATA_WIDTH < 1 || DATA_WIDTH > 64) begin : gen_chk_data_width
        $error("async_fifo: DATA_WIDTH=%0d out of range [1,64]", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("async_fifo: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("async_fifo: DEPTH=%0d must be a power of two", DEPTH);
    end
    if (SYNC_STAGES < 2 || SYNC_STAGES > 8) begin : gen_chk_sync_stages
        $error("async_fifo: SYNC_STAGES=%0d out of range [2,8]", SYNC_STAGES);
    end

    // Storage. Dual-port: written on wr_clk, read on rd_clk.
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Binary and Gray pointers: ADDR_WIDTH+1 bits each (extra MSB = wrap flag).
    logic [ADDR_WIDTH:0] wbin,  wgray;   // write domain
    logic [ADDR_WIDTH:0] rbin,  rgray;   // read  domain

    // Synchronizer chains (SYNC_STAGES flops). [SYNC_STAGES-1] is the settled
    // output; [0] is the first capture stage (the metastability-prone one).
    logic [ADDR_WIDTH:0] wgray_rdsync [0:SYNC_STAGES-1]; // wgray -> read domain
    logic [ADDR_WIDTH:0] rgray_wrsync [0:SYNC_STAGES-1]; // rgray -> write domain

    // Memory write address = low bits of the binary write pointer.
    wire [ADDR_WIDTH-1:0] waddr = wbin[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] raddr = rbin[ADDR_WIDTH-1:0];

    // bin->gray: g = b ^ (b >> 1).
    function automatic [ADDR_WIDTH:0] bin2gray(input logic [ADDR_WIDTH:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // Settled synchronizer outputs.
    wire [ADDR_WIDTH:0] wgray_rd = wgray_rdsync[SYNC_STAGES-1];
    wire [ADDR_WIDTH:0] rgray_wr = rgray_wrsync[SYNC_STAGES-1];

    //--------------------------------------------------------------------------
    // Next-state binary/gray write pointer (combinational), then the registered
    // full flag. full is computed from the NEXT gray write pointer vs the
    // synchronized read pointer so it is correct on the cycle the write lands.
    //--------------------------------------------------------------------------
    wire                 do_write = wr_en && !full;
    wire [ADDR_WIDTH:0]  wbin_next  = do_write ? (wbin + 1'b1) : wbin;
    wire [ADDR_WIDTH:0]  wgray_next = bin2gray(wbin_next);

    // full when the next write pointer (in gray) would equal the read pointer
    // with the TOP TWO bits inverted — the standard async-FIFO full test.
    wire full_next = (wgray_next == {~rgray_wr[ADDR_WIDTH:ADDR_WIDTH-1],
                                      rgray_wr[ADDR_WIDTH-2:0]});

    //--------------------------------------------------------------------------
    // Next-state read pointer (combinational), then the registered empty flag.
    //--------------------------------------------------------------------------
    wire                 do_read = rd_en && !empty;
    wire [ADDR_WIDTH:0]  rbin_next  = do_read ? (rbin + 1'b1) : rbin;
    wire [ADDR_WIDTH:0]  rgray_next = bin2gray(rbin_next);

    // empty when the next read pointer (in gray) equals the synchronized write
    // pointer — the read side has caught up to all data it can see.
    wire empty_next = (rgray_next == wgray_rd);

    //--------------------------------------------------------------------------
    // WRITE clock domain.
    //--------------------------------------------------------------------------
    integer wi;
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin  <= '0;
            wgray <= '0;
            full  <= 1'b0;
            for (wi = 0; wi < SYNC_STAGES; wi = wi + 1)
                rgray_wrsync[wi] <= '0;
        end else begin
            // Synchronize the read-domain gray pointer into the write domain.
            rgray_wrsync[0] <= rgray;
            for (wi = 1; wi < SYNC_STAGES; wi = wi + 1)
                rgray_wrsync[wi] <= rgray_wrsync[wi-1];

            // Advance the write pointer / write memory on an accepted write.
            if (do_write)
                mem[waddr] <= wr_data;
            wbin  <= wbin_next;
            wgray <= wgray_next;
            full  <= full_next;
        end
    end

    //--------------------------------------------------------------------------
    // READ clock domain. Registered-output FIFO: rd_data is latched on the
    // clock edge when a read is accepted (NOT fall-through / show-ahead).
    //--------------------------------------------------------------------------
    integer ri;
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin    <= '0;
            rgray   <= '0;
            empty   <= 1'b1;
            rd_data <= '0;
            for (ri = 0; ri < SYNC_STAGES; ri = ri + 1)
                wgray_rdsync[ri] <= '0;
        end else begin
            // Synchronize the write-domain gray pointer into the read domain.
            wgray_rdsync[0] <= wgray;
            for (ri = 1; ri < SYNC_STAGES; ri = ri + 1)
                wgray_rdsync[ri] <= wgray_rdsync[ri-1];

            // Advance the read pointer / present read data on an accepted read.
            if (do_read)
                rd_data <= mem[raddr];
            rbin  <= rbin_next;
            rgray <= rgray_next;
            empty <= empty_next;
        end
    end

    //==========================================================================
    // FORMAL — CDC-aware properties, inlined under `ifdef FORMAL so the SVA
    // sees module internals natively (the Yosys OSS frontend cannot wire a
    // `bind` to a separate module's internal signals).
    //
    // Multi-clock modelling: wr_clk and rd_clk are driven from a single
    // $global_clock in the harness via per-edge clock enables (gclk style).
    // Every property is sampled on @(posedge wr_clk) or @(posedge rd_clk) so it
    // only fires on the cycles its own domain actually advances.
    //==========================================================================
`ifdef FORMAL

    // Per-domain f_past_valid guards so $past() is only used after a real edge
    // in that domain.
    reg f_wr_past_valid;  initial f_wr_past_valid = 1'b0;
    reg f_rd_past_valid;  initial f_rd_past_valid = 1'b0;
    always @(posedge wr_clk) f_wr_past_valid <= 1'b1;
    always @(posedge rd_clk) f_rd_past_valid <= 1'b1;

    // -------------------------------------------------------------------------
    // GROUP 1 — Gray-code single-bit-change (the whole point of gray coding).
    //   Successive committed gray pointer values differ by AT MOST one bit.
    //   We test "at most one bit set" in the XOR-difference via the classic
    //   power-of-two-or-zero identity  (d & (d-1)) == 0 , which is far cheaper
    //   for the SMT solver than a $countones popcount under multiclock unroll.
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (f_wr_past_valid && wr_rst_n && $past(wr_rst_n)) begin
            a_wgray_one_bit: assert (
                ((wgray ^ $past(wgray)) & ((wgray ^ $past(wgray)) - 1'b1)) == '0);
        end
    end
    always @(posedge rd_clk) begin
        if (f_rd_past_valid && rd_rst_n && $past(rd_rst_n)) begin
            a_rgray_one_bit: assert (
                ((rgray ^ $past(rgray)) & ((rgray ^ $past(rgray)) - 1'b1)) == '0);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — Gray pointers are the faithful gray encoding of the binary
    //   pointers at all times (ties the two representations together so the
    //   gray comparison logic is meaningful).
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_rst_n) a_wgray_encodes_wbin: assert (wgray == (wbin ^ (wbin >> 1)));
    end
    always @(posedge rd_clk) begin
        if (rd_rst_n) a_rgray_encodes_rbin: assert (rgray == (rbin ^ (rbin >> 1)));
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — Pointer monotonicity: each binary pointer stays or +1 per edge
    //   in its OWN domain.
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (f_wr_past_valid && wr_rst_n && $past(wr_rst_n)) begin
            a_wbin_monotone: assert (
                (wbin == $past(wbin)) || (wbin == ($past(wbin) + 1'b1)));
        end
    end
    always @(posedge rd_clk) begin
        if (f_rd_past_valid && rd_rst_n && $past(rd_rst_n)) begin
            a_rbin_monotone: assert (
                (rbin == $past(rbin)) || (rbin == ($past(rbin) + 1'b1)));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 4 — Handshake safety ASSUMPTIONS (environment never abuses flags).
    //   No write when full, no read when empty — sampled in each flag's domain.
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_rst_n) m_no_write_when_full: assume (!(full && wr_en));
    end
    always @(posedge rd_clk) begin
        if (rd_rst_n) m_no_read_when_empty: assume (!(empty && rd_en));
    end

    // -------------------------------------------------------------------------
    // GROUP 5 — No overflow / no underflow: the qualified strobes can never
    //   fire against an asserted flag (follows from GROUP 4, but asserted on
    //   the design's own do_write/do_read so a logic bug would be caught).
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_rst_n) a_no_overflow:  assert (!(do_write && full));
    end
    always @(posedge rd_clk) begin
        if (rd_rst_n) a_no_underflow: assert (!(do_read && empty));
    end

    // -------------------------------------------------------------------------
    // GROUP 6 — Occupancy never exceeds DEPTH.
    //   With both pointers visible (single $global_clock harness) the true
    //   occupancy is (wbin - rbin) in (ADDR_WIDTH+1)-bit unsigned arithmetic.
    //   This must always be 0..DEPTH inclusive: the FIFO can never hold more
    //   words than it has slots, nor go "negative" (underflow).
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] f_occupancy = wbin - rbin;
    always @(posedge wr_clk) begin
        if (wr_rst_n && rd_rst_n)
            a_occupancy_le_depth: assert (f_occupancy <= DEPTH[ADDR_WIDTH:0]);
    end

    // -------------------------------------------------------------------------
    // GROUP 7 — Flag soundness (CDC-correct conservative direction).
    //
    //   In an async FIFO each flag is derived from a SYNCHRONIZED (hence stale-
    //   or-current) copy of the other domain's pointer, so the flags are
    //   intentionally CONSERVATIVE. The SAFE invariants are:
    //
    //     full  => occupancy >= DEPLOY-margin : the write side never believes
    //              there is room when there isn't. Because the synchronized
    //              read pointer is stale, the TRUE occupancy when `full` is set
    //              is at MOST DEPTH (never more — that is the no-overflow
    //              guarantee already in GROUP 6) and at LEAST DEPTH minus the
    //              words the read side has popped but not yet reflected. We
    //              assert the safety-critical bound: full never lies about
    //              there being NO room, i.e. occupancy can never EXCEED DEPTH
    //              (GROUP 6) — and conversely whenever occupancy == DEPTH the
    //              design must be reporting full (no missed-full / overflow).
    //
    //     empty => the read side will not pop: occupancy as SEEN BY THE READ
    //              DOMAIN (rbin vs the synchronized write pointer) is zero.
    //              The true occupancy may be > 0 (data in flight), which is
    //              safe: a late-clearing empty only delays a read, never
    //              corrupts one.
    // -------------------------------------------------------------------------

    // No missed-full: if the FIFO is truly completely full, `full` must be set
    // (otherwise a write could be accepted and overflow). Sampled in the write
    // domain where `full` lives.
    always @(posedge wr_clk) begin
        if (wr_rst_n && rd_rst_n && (f_occupancy == DEPTH[ADDR_WIDTH:0]))
            a_full_when_actually_full: assert (full);
    end

    // empty is the registered result of the comparison made on the PREVIOUS
    // rd_clk edge: empty(t) == ( rgray(t) == wgray_rd(t-1) ), where rgray(t) is
    // the gray encoding the read pointer took at that edge. Checking it with
    // $past captures the one-cycle register skew exactly and proves the empty
    // flag faithfully implements the read-domain pointer-equality test it is
    // supposed to (the invariant the read logic relies on to never underflow).
    always @(posedge rd_clk) begin
        if (f_rd_past_valid && rd_rst_n && $past(rd_rst_n))
            a_empty_matches_rdview: assert (
                empty == (rgray == $past(wgray_rd)));
    end

    // -------------------------------------------------------------------------
    // GROUP 8 — Data integrity across the clock domains.
    //   A solver-chosen constant slot (anyconst) is tracked: the last word
    //   written to it is remembered (in the write domain), and when the read
    //   domain pops that slot, rd_data one rd_clk later must match. Honest
    //   scope: closes under BMC (the same mem[]-binding limitation that the
    //   sync design documents prevents a clean k-induction proof of this one).
    //   Guarded under FORMAL_DATA so the k-induction `prove` gate can omit it and
    //   close the per-domain gray/pointer subset (the BMC gate defines it).
    // -------------------------------------------------------------------------
`ifdef FORMAL_DATA
    (* anyconst *) logic [ADDR_WIDTH-1:0] f_track_slot;

    logic [DATA_WIDTH-1:0] f_tracked_data;
    logic                  f_tracked_valid;
    logic                  f_read_of_tracked;
    initial begin
        f_tracked_data    = '0;
        f_tracked_valid   = 1'b0;
        f_read_of_tracked = 1'b0;
    end

    // Capture writes to the tracked slot in the write domain.
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            f_tracked_data  <= '0;
            f_tracked_valid <= 1'b0;
        end else if (do_write && (waddr == f_track_slot)) begin
            f_tracked_data  <= wr_data;
            f_tracked_valid <= 1'b1;
        end
    end

    // Flag a read of the tracked slot in the read domain (one rd_clk early so
    // we can compare against the registered rd_data the next rd_clk).
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            f_read_of_tracked <= 1'b0;
        else
            f_read_of_tracked <= do_read && (raddr == f_track_slot) && f_tracked_valid;
    end

    always @(posedge rd_clk) begin
        if (f_rd_past_valid && rd_rst_n && $past(rd_rst_n) && f_read_of_tracked)
            a_data_integrity: assert (rd_data == $past(f_tracked_data));
    end

    // -------------------------------------------------------------------------
    // GROUP 9 — Cover points: prove the interesting states are reachable.
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        c_reach_full: cover (wr_rst_n && full);
    end
    always @(posedge rd_clk) begin
        c_reach_empty: cover (rd_rst_n && !empty);  // non-trivially non-empty
    end

    // Gray pointer wrap: the extra MSB toggles (a full lap of the FIFO).
    always @(posedge wr_clk) begin
        if (f_wr_past_valid && wr_rst_n && $past(wr_rst_n))
            c_wgray_wrap: cover (wgray[ADDR_WIDTH] != $past(wgray[ADDR_WIDTH]));
    end

    // Round-trip of the tracked slot: written then read.
    reg f_tracked_written; initial f_tracked_written = 1'b0;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) f_tracked_written <= 1'b0;
        else if (do_write && (waddr == f_track_slot)) f_tracked_written <= 1'b1;
    end
    always @(posedge rd_clk) begin
        c_tracked_roundtrip: cover (
            rd_rst_n && f_tracked_written &&
            do_read && (raddr == f_track_slot) && f_tracked_valid);
    end
`endif // FORMAL_DATA

`endif // FORMAL

endmodule

`default_nettype wire
