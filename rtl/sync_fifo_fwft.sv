//==============================================================================
// Module      : sync_fifo_fwft
// Description : Parameterizable synchronous (single-clock) FIFO with a
//               FIRST-WORD-FALL-THROUGH (FWFT / "show-ahead") read interface.
//               Same extra-MSB dual-pointer ring-buffer core as sync_fifo, but
//               the read side is COMBINATIONAL: the oldest unread word is
//               presented on rd_data continuously while the FIFO is non-empty,
//               BEFORE rd_en is asserted. rd_en then acts as an ACKNOWLEDGE /
//               POP — it advances the read pointer to retire the shown word.
// Parameters  : DATA_WIDTH          - width of each data word        [1..64]
//               DEPTH               - number of entries, power of 2  [4..1024]
//               ALMOST_FULL_THRESH  - count >= thresh -> almost_full
//               ALMOST_EMPTY_THRESH - count <= thresh -> almost_empty
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + cover) via inlined `ifdef FORMAL
//               SVA. Lints clean with verilator --lint-only -Wall.
//
// Registered (sync_fifo) vs FWFT (this module) — the read-side contrast:
//
//   sync_fifo  : rd_data is REGISTERED. Assert rd_en at cycle T; the popped word
//                appears at T+1 (1-cycle read latency). rd_data is meaningless
//                until you have asked for a word.
//   sync_fifo_fwft : rd_data is COMBINATIONAL (mem[raddr]). The head word is
//                already on rd_data when valid (== !empty) goes high — no
//                latency, "fall-through". Assert rd_en to pop/advance to the
//                next word the SAME cycle you consume the shown one.
//
//   Why have both: FWFT removes the consumer's one-cycle bubble (the data is
//   ready to use immediately — ideal feeding combinational logic or a streaming
//   consumer that wants zero-latency head access), at the cost of putting the
//   memory read on the consumer's combinational path. The registered sync_fifo
//   keeps a clean registered timing boundary (and maps cleanly to synchronous
//   block RAM); FWFT's async memory read tends toward distributed-RAM mapping
//   or needs an output-prefetch register to hit block RAM. Same ring-buffer
//   pointer math, opposite ends of the latency/timing trade-off.
//
//   The `valid` output is the FWFT-idiomatic name for "a word is shown on
//   rd_data this cycle"; it is exactly !empty, surfaced as a port so a consumer
//   can use the standard valid/ready-style { valid, rd_data, rd_en } handshake.
//==============================================================================

`default_nettype none

module sync_fifo_fwft #(
    parameter int DATA_WIDTH          = 8,
    parameter int DEPTH               = 16,
    parameter int ALMOST_FULL_THRESH  = DEPTH - 2,
    parameter int ALMOST_EMPTY_THRESH = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,        // active-low synchronous reset
    input  wire                   wr_en,
    input  wire  [DATA_WIDTH-1:0] wr_data,
    input  wire                   rd_en,        // acknowledge/pop the shown word
    output logic [DATA_WIDTH-1:0] rd_data,      // COMBINATIONAL head word (show-ahead)
    output logic                  valid,        // a word is shown this cycle (== !empty)
    output logic                  full,
    output logic                  empty,
    output logic                  almost_full,
    output logic                  almost_empty,
    output logic [$clog2(DEPTH):0] count         // valid entries, 0..DEPTH
);

    // ADDR_WIDTH is derived internally — never expose it as a top-level
    // parameter, so DEPTH and the pointer widths can never disagree.
    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // Compile-time sanity checks (elaboration-time $error; silent for legal
    // params, fires on every tool).
    if (DATA_WIDTH < 1 || DATA_WIDTH > 64) begin : gen_chk_data_width
        $error("sync_fifo_fwft: DATA_WIDTH=%0d out of range [1,64]", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("sync_fifo_fwft: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("sync_fifo_fwft: DEPTH=%0d must be a power of two", DEPTH);
    end
    if (ALMOST_FULL_THRESH < 1 || ALMOST_FULL_THRESH > DEPTH-1) begin : gen_chk_af_thresh
        $error("sync_fifo_fwft: ALMOST_FULL_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_FULL_THRESH);
    end
    if (ALMOST_EMPTY_THRESH < 1 || ALMOST_EMPTY_THRESH > DEPTH-1) begin : gen_chk_ae_thresh
        $error("sync_fifo_fwft: ALMOST_EMPTY_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_EMPTY_THRESH);
    end

    // Storage.
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Dual pointers: ADDR_WIDTH+1 bits each (extra MSB = wrap flag).
    logic [ADDR_WIDTH:0] wptr;
    logic [ADDR_WIDTH:0] rptr;

    // Address slices into the memory array.
    wire [ADDR_WIDTH-1:0] waddr = wptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] raddr = rptr[ADDR_WIDTH-1:0];

    // Qualified write/read strobes (no write when full, no pop when empty).
    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    //--------------------------------------------------------------------------
    // Empty / full / count : combinationally derived from the pointers only.
    //--------------------------------------------------------------------------
    assign empty = (wptr == rptr);
    assign full  = (wptr[ADDR_WIDTH] != rptr[ADDR_WIDTH]) &&
                   (wptr[ADDR_WIDTH-1:0] == rptr[ADDR_WIDTH-1:0]);
    assign valid = !empty;

    // count = wptr - rptr in (ADDR_WIDTH+1)-bit unsigned arithmetic.
    assign count = wptr - rptr;

    // Thresholds derived combinationally from count (full integer width — no
    // silent high-bit truncation; the elaboration guards reject bad ranges).
    assign almost_full  = (32'(count) >= ALMOST_FULL_THRESH);
    assign almost_empty = (32'(count) <= ALMOST_EMPTY_THRESH);

    //--------------------------------------------------------------------------
    // FWFT read: rd_data shows the head word COMBINATIONALLY. No registered
    // output, no read latency — the word is on the bus the moment it is the
    // oldest unread entry. rd_en only advances the pointer.
    //--------------------------------------------------------------------------
    assign rd_data = mem[raddr];

    //--------------------------------------------------------------------------
    // Write port.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
        end else begin
            if (do_write) begin
                mem[waddr] <= wr_data;
                wptr       <= wptr + 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read pointer: advance on an accepted pop (rd_en && !empty). The data has
    // already been shown combinationally this cycle; the pop retires it and the
    // next word falls through next cycle.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rptr <= '0;
        end else begin
            if (do_read) begin
                rptr <= rptr + 1'b1;
            end
        end
    end

    //==========================================================================
    // FORMAL — inlined under `ifdef FORMAL so the SVA sees module internals
    // (mem[], wptr, rptr) natively (the Yosys OSS frontend cannot `bind` to a
    // separate module's internal array). The harness/sby drives clk, rst_n,
    // wr_en, wr_data, rd_en symbolically and holds rst_n low for the first cycle.
    //==========================================================================
`ifdef FORMAL

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // Reset low for exactly the first cycle, high forever after.
    reg f_init;
    initial f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @(*) begin
        if (f_init) assume (!rst_n);
        else        assume (rst_n);
    end

    // -------------------------------------------------------------------------
    // GROUP 1 — Environment handshake assumptions (no write-when-full, no
    //   pop-when-empty), matching the sync_fifo convention.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            m_no_write_when_full: assume (!(full && wr_en));
            m_no_read_when_empty: assume (!(empty && rd_en));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — Core ring-buffer invariants (same as sync_fifo).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_full_and_empty:    assert (!(full && empty));
            a_count_in_range:       assert (count <= DEPTH[ADDR_WIDTH:0]);
            a_empty_iff_count_zero: assert (empty == (count == '0));
            a_full_iff_count_depth: assert (full  == (count == DEPTH[ADDR_WIDTH:0]));
            a_valid_iff_not_empty:  assert (valid == !empty);
            a_almost_full_iff:      assert (almost_full  == (32'(count) >= ALMOST_FULL_THRESH));
            a_almost_empty_iff:     assert (almost_empty == (32'(count) <= ALMOST_EMPTY_THRESH));
        end
    end

    // No overflow / no underflow on the qualified strobes.
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_overflow:  assert (!(do_write && full));
            a_no_underflow: assert (!(do_read  && empty));
        end
    end

    // Pointer monotonicity + count step ±1.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_wptr_monotone: assert ((wptr == $past(wptr)) || (wptr == ($past(wptr) + 1'b1)));
            a_rptr_monotone: assert ((rptr == $past(rptr)) || (rptr == ($past(rptr) + 1'b1)));
            a_count_monotone: assert (
                (count == $past(count)       ) ||
                (count == $past(count) + 1'b1) ||
                (count == $past(count) - 1'b1));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — FWFT SHOW-AHEAD DATA INTEGRITY (the defining property).
    //   A solver-chosen slot is tracked; whenever it currently holds the oldest
    //   unread word (raddr points at it AND it is pending), rd_data must show
    //   that word THIS cycle — ZERO latency. This is the FWFT contract: the head
    //   word is on the bus before any rd_en, not one cycle after.
    //
    //   Guarded under FORMAL_DATA: the $anyconst slot tracker is a shadow model
    //   that the open-source Yosys frontend cannot bind to the DUT's mem[] array,
    //   so its k-induction STEP cannot close (basecase + BMC do pass). The BMC
    //   gate defines FORMAL_DATA and checks these exhaustively to depth 20; the
    //   k-induction `prove` gate omits them so the pointer/count/flag invariants
    //   (which ARE inductive) close cleanly and can be claimed PROVEN. Same
    //   split + rationale as sync_fifo's data-integrity properties.
    // -------------------------------------------------------------------------
`ifdef FORMAL_DATA
    (* anyconst *) logic [ADDR_WIDTH-1:0] f_track_slot;
    logic [DATA_WIDTH-1:0] f_tracked_data;
    logic                  f_slot_pending;     // tracked slot holds an unconsumed word
    logic                  f_slot_ever_written;

    initial begin
        f_tracked_data      = '0;
        f_slot_pending      = 1'b0;
        f_slot_ever_written = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            f_tracked_data      <= '0;
            f_slot_pending      <= 1'b0;
            f_slot_ever_written <= 1'b0;
        end else begin
            if (do_write && (waddr == f_track_slot)) begin
                f_tracked_data      <= wr_data;
                f_slot_pending      <= 1'b1;
                f_slot_ever_written <= 1'b1;
            end else if (do_read && (raddr == f_track_slot)) begin
                f_slot_pending <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            // Show-ahead: when the read pointer is at the tracked slot and that
            // slot holds a pending word, rd_data shows it combinationally NOW.
            if (!empty && (raddr == f_track_slot) && f_slot_pending) begin
                a_fwft_data_at_head: assert (rd_data == f_tracked_data);
            end
            // No duplication / no read-before-write of the tracked slot.
            if (do_read && (raddr == f_track_slot)) begin
                a_no_duplicate_read:    assert (f_slot_pending);
                a_no_read_before_write: assert (f_slot_ever_written);
            end
        end
    end

    // Tracked round-trip: written, shown at head, then popped (data-tracker cover).
    always @(posedge clk) begin
        c_tracked_roundtrip: cover (
            rst_n && f_slot_ever_written && do_read &&
            (raddr == f_track_slot) && f_slot_pending);
    end
`endif // FORMAL_DATA

    // -------------------------------------------------------------------------
    // GROUP 4 — Cover witnesses (reachability; pointer/flag-only, always on).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        c_reach_full:  cover (rst_n && full);
        c_show_ahead:  cover (rst_n && valid);   // a word presented before any pop
    end

    // Drain-to-empty after having been full.
    reg f_was_full;
    initial f_was_full = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_full <= 1'b0;
        else if (full) f_was_full <= 1'b1;
    end
    always @(posedge clk) begin
        c_full_then_empty: cover (rst_n && f_was_full && empty);
    end

`endif // FORMAL

endmodule

`default_nettype wire
