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
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if (f_read_of_tracked_happened) begin
                a_data_integrity: assert (rd_data == $past(tracked_data));
            end
        end
    end

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

`endif // FORMAL

endmodule

`default_nettype wire
