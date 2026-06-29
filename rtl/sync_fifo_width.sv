//==============================================================================
// Module      : sync_fifo_width
// Description : Parameterizable synchronous ASYMMETRIC-WIDTH FIFO — the write
//               and read data widths differ (one must be an integer multiple of
//               the other). Acts as a width down-sizer (WR_WIDTH > RD_WIDTH,
//               e.g. write 32 / read 8) or up-sizer (WR_WIDTH < RD_WIDTH, e.g.
//               write 8 / read 32) over a single shared ring buffer. Storage is
//               at the NARROW granularity; the wide side packs/unpacks across
//               RATIO consecutive narrow entries in one transaction, so the
//               write and read pointers advance at different rates.
// Parameters  : WR_WIDTH       - write data width, bits             [1..64]
//               RD_WIDTH       - read  data width, bits             [1..64]
//                                (one MUST be an integer multiple of the other,
//                                 and WR_WIDTH != RD_WIDTH)
//               DEPTH_NARROW   - ring depth in NARROW-width beats,
//                                power of two                       [4..4096]
//               SUB_WORD_BIG   - 0 = little (chunk i <-> bits [i*N +: N], the
//                                least-significant chunk first), 1 = big
//               ALMOST_FULL_THRESH  - count(narrow beats) >= thresh -> almost_full
//               ALMOST_EMPTY_THRESH - count(narrow beats) <= thresh -> almost_empty
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + cover) via inlined `ifdef FORMAL
//               SVA and a Verilator constrained-random testbench with a narrow-
//               granularity golden model. Fully synthesizable: no initial blocks
//               or $display outside `ifdef FORMAL. Lints clean under Verilator
//               -Wall and the Verible style gate.
//
// Width-change model (the whole point of this module):
//   NARROW = min(WR_WIDTH, RD_WIDTH); WIDE = max(WR_WIDTH, RD_WIDTH).
//   RATIO  = WIDE / NARROW. Exactly one of {WR_BEATS, RD_BEATS} is 1, the other
//   is RATIO:
//     WR_BEATS = WR_WIDTH / NARROW   (narrow words consumed per write xfer)
//     RD_BEATS = RD_WIDTH / NARROW   (narrow words produced per read  xfer)
//   The memory holds NARROW-bit words. A write deposits WR_BEATS narrow words
//   and advances wptr by WR_BEATS; a read pops RD_BEATS narrow words and
//   advances rptr by RD_BEATS. Occupancy `count` is in NARROW beats.
//     wr_full   : fewer than WR_BEATS free narrow slots  (no room for a write)
//     rd_empty  : fewer than RD_BEATS available beats     (no full read yet)
//   so a wide write is never partially accepted and a wide read never returns
//   fewer than RD_WIDTH valid bits.
//
// Sub-word ordering (SUB_WORD_BIG):
//   A wide word's chunk index maps to FIFO sub-order. SUB_WORD_BIG=0 (little):
//   narrow chunk i (= wide_word[i*NARROW +: NARROW]) is enqueued/dequeued at
//   sub-position i (i=0 is the OLDEST / first out) — least-significant chunk
//   leads. SUB_WORD_BIG=1 (big): chunk i maps to sub-position (RATIO-1-i) —
//   most-significant chunk leads. The narrow side (BEATS==1) is order-agnostic;
//   the rule only bites on the wide side's pack/unpack.
//
// Registered read: rd_data is latched on the read-accept edge, valid the NEXT
// cycle (1-cycle read latency, same convention as sync_fifo — NOT fall-through).
//==============================================================================

`default_nettype none

module sync_fifo_width #(
    parameter int    WR_WIDTH            = 32,
    parameter int    RD_WIDTH            = 8,
    parameter int    DEPTH_NARROW        = 16,
    parameter bit    SUB_WORD_BIG        = 1'b0,   // 0 = little-, 1 = big-sub-word order
    parameter int    ALMOST_FULL_THRESH  = DEPTH_NARROW - 2,
    parameter int    ALMOST_EMPTY_THRESH = 2
) (
    input  wire                       clk,
    input  wire                       rst_n,        // active-low synchronous reset

    // Write port (WR_WIDTH bits per transaction)
    input  wire                       wr_en,
    input  wire  [WR_WIDTH-1:0]       wr_data,
    output logic                      wr_full,
    output logic                      wr_almost_full,

    // Read port (RD_WIDTH bits per transaction, registered output)
    input  wire                       rd_en,
    output logic [RD_WIDTH-1:0]       rd_data,
    output logic                      rd_empty,
    output logic                      rd_almost_empty,

    // Occupancy in NARROW-width beats, 0..DEPTH_NARROW
    output logic [$clog2(DEPTH_NARROW):0] count
);

    // Width-change geometry, all derived (never exposed as ports).
    localparam int NARROW   = (WR_WIDTH < RD_WIDTH) ? WR_WIDTH : RD_WIDTH;
    localparam int WIDE     = (WR_WIDTH > RD_WIDTH) ? WR_WIDTH : RD_WIDTH;
    localparam int RATIO    = WIDE / NARROW;
    localparam int WR_BEATS = WR_WIDTH / NARROW;   // 1 (upsizer) or RATIO (downsizer)
    localparam int RD_BEATS = RD_WIDTH / NARROW;   // RATIO (upsizer) or 1 (downsizer)
    localparam int AW       = $clog2(DEPTH_NARROW);

    // Compile-time sanity checks. Named generate blocks of elaboration-time
    // $error calls — silent for legal params, fires on every tool.
    if (WR_WIDTH < 1 || WR_WIDTH > 64) begin : gen_chk_wr_width
        $error("sync_fifo_width: WR_WIDTH=%0d out of range [1,64]", WR_WIDTH);
    end
    if (RD_WIDTH < 1 || RD_WIDTH > 64) begin : gen_chk_rd_width
        $error("sync_fifo_width: RD_WIDTH=%0d out of range [1,64]", RD_WIDTH);
    end
    if (WR_WIDTH == RD_WIDTH) begin : gen_chk_widths_differ
        $error("sync_fifo_width: WR_WIDTH==RD_WIDTH=%0d — use sync_fifo for equal widths", WR_WIDTH);
    end
    if ((WIDE % NARROW) != 0) begin : gen_chk_integer_ratio
        $error("sync_fifo_width: WR_WIDTH=%0d / RD_WIDTH=%0d not an integer ratio", WR_WIDTH, RD_WIDTH);
    end
    if (DEPTH_NARROW < 4 || DEPTH_NARROW > 4096) begin : gen_chk_depth_range
        $error("sync_fifo_width: DEPTH_NARROW=%0d out of range [4,4096]", DEPTH_NARROW);
    end
    if ((DEPTH_NARROW & (DEPTH_NARROW - 1)) != 0) begin : gen_chk_depth_pow2
        $error("sync_fifo_width: DEPTH_NARROW=%0d must be a power of two", DEPTH_NARROW);
    end
    if (DEPTH_NARROW < RATIO) begin : gen_chk_depth_ge_ratio
        $error("sync_fifo_width: DEPTH_NARROW=%0d must be >= RATIO=%0d", DEPTH_NARROW, RATIO);
    end
    if (ALMOST_FULL_THRESH < 1 || ALMOST_FULL_THRESH > DEPTH_NARROW-1) begin : gen_chk_af_thresh
        $error("sync_fifo_width: ALMOST_FULL_THRESH=%0d out of range [1,DEPTH_NARROW-1]", ALMOST_FULL_THRESH);
    end
    if (ALMOST_EMPTY_THRESH < 1 || ALMOST_EMPTY_THRESH > DEPTH_NARROW-1) begin : gen_chk_ae_thresh
        $error("sync_fifo_width: ALMOST_EMPTY_THRESH=%0d out of range [1,DEPTH_NARROW-1]", ALMOST_EMPTY_THRESH);
    end

    // Storage at the narrow granularity.
    logic [NARROW-1:0] mem [0:DEPTH_NARROW-1];

    // Extra-MSB binary pointers (AW+1 bits): low AW bits index mem, the top bit
    // disambiguates full from empty across a full wrap (same scheme as sync_fifo,
    // generalized to multi-beat increments).
    logic [AW:0] wptr;
    logic [AW:0] rptr;

    wire [AW-1:0] waddr = wptr[AW-1:0];
    wire [AW-1:0] raddr = rptr[AW-1:0];

    // Occupancy in narrow beats = wptr - rptr (unsigned, wraps correctly).
    assign count = wptr - rptr;

    // Free narrow slots.
    wire [AW:0] free_beats = DEPTH_NARROW[AW:0] - count;

    // A write needs WR_BEATS free slots; a read needs RD_BEATS available beats.
    assign wr_full         = (free_beats < WR_BEATS[AW:0]);
    assign rd_empty        = (count      < RD_BEATS[AW:0]);
    assign wr_almost_full  = (32'(count) >= ALMOST_FULL_THRESH);
    assign rd_almost_empty = (32'(count) <= ALMOST_EMPTY_THRESH);

    // Qualified strobes.
    wire do_write = wr_en && !wr_full;
    wire do_read  = rd_en && !rd_empty;

    // sub_index(i, beats) maps beat i of a transaction to its bit-slice position
    // within that side's data word, under the selected sub-word ordering. The
    // reversal is over THAT SIDE's beat count: the wide side has `beats`=RATIO
    // (sub-words really are ordered), the narrow side has `beats`=1 (a single
    // word, always offset 0 — so a narrow port is never mis-sliced regardless of
    // SUB_WORD_BIG). little: identity. big: reversed within the word.
    function automatic int sub_index(input int i, input int beats);
        sub_index = SUB_WORD_BIG ? (beats - 1 - i) : i;
    endfunction

    //--------------------------------------------------------------------------
    // Write port. Deposit WR_BEATS narrow chunks of wr_data into consecutive
    // narrow slots and advance wptr by WR_BEATS. For the up-sizer (WR_BEATS==1)
    // this is a plain single-word write; for the down-sizer it unpacks wr_data.
    //--------------------------------------------------------------------------
    integer wi;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
        end else if (do_write) begin
            for (wi = 0; wi < WR_BEATS; wi = wi + 1) begin
                // Chunk that lands at sub-position wi of this write. With the
                // narrow side WR_BEATS==1 the loop body runs once (chunk 0).
                mem[(waddr + wi[AW-1:0])] <=
                    wr_data[(sub_index(wi, WR_BEATS))*NARROW +: NARROW];
            end
            wptr <= wptr + WR_BEATS[AW:0];
        end
    end

    //--------------------------------------------------------------------------
    // Read port (registered). Pack RD_BEATS narrow slots starting at raddr into
    // rd_data on the read-accept edge; valid next cycle. Advance rptr by
    // RD_BEATS. Up-sizer packs RATIO narrow words; down-sizer reads one word.
    //--------------------------------------------------------------------------
    integer ri;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rptr    <= '0;
            rd_data <= '0;
        end else if (do_read) begin
            for (ri = 0; ri < RD_BEATS; ri = ri + 1) begin
                rd_data[(sub_index(ri, RD_BEATS))*NARROW +: NARROW] <=
                    mem[(raddr + ri[AW-1:0])];
            end
            rptr <= rptr + RD_BEATS[AW:0];
        end
    end

    //==========================================================================
    // FORMAL — inlined under `ifdef FORMAL so the SVA sees mem[]/wptr/rptr
    // natively. The harness/sby drives clk, rst_n, wr_en, wr_data, rd_en
    // symbolically and holds rst_n low for the first cycle. Run on a SMALL
    // instance (chparam) for SMT tractability.
    //==========================================================================
`ifdef FORMAL

    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    reg f_init;
    initial f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @(*) begin
        if (f_init) assume (!rst_n);
        else        assume (rst_n);
    end

    // -------------------------------------------------------------------------
    // GROUP 1 — Environment handshake assumptions.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            m_no_write_when_full: assume (!(wr_full && wr_en));
            m_no_read_when_empty: assume (!(rd_empty && rd_en));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — Occupancy / flag invariants (narrow-beat granularity).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_count_in_range:   assert (count <= DEPTH_NARROW[AW:0]);
            a_wr_full_iff:      assert (wr_full  == (free_beats < WR_BEATS[AW:0]));
            a_rd_empty_iff:     assert (rd_empty == (count      < RD_BEATS[AW:0]));
            a_no_overflow:      assert (!(do_write && (free_beats < WR_BEATS[AW:0])));
            a_no_underflow:     assert (!(do_read  && (count      < RD_BEATS[AW:0])));
            a_almost_full_iff:  assert (wr_almost_full  == (32'(count) >= ALMOST_FULL_THRESH));
            a_almost_empty_iff: assert (rd_almost_empty == (32'(count) <= ALMOST_EMPTY_THRESH));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — Pointer / count step invariants. Each pointer either holds or
    //   advances by exactly its beat count; count changes by the net of the two.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_wptr_step: assert (
                (wptr == $past(wptr)) ||
                (wptr == ($past(wptr) + WR_BEATS[AW:0])));
            a_rptr_step: assert (
                (rptr == $past(rptr)) ||
                (rptr == ($past(rptr) + RD_BEATS[AW:0])));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 4 — WIDTH-CROSSING DATA INTEGRITY (the defining proof).
    //   A solver-chosen narrow word value is forced onto a solver-chosen narrow
    //   beat index (counted on the narrow side: every chunk that crosses the
    //   write port, in FIFO order, gets an index). FIFO ordering means the Nth
    //   narrow word IN is the Nth narrow word OUT, so when that index is
    //   dequeued the corresponding narrow slice of rd_data must equal the forced
    //   value — proving the pack (write) + unpack (read) across the width change
    //   preserves every narrow word, in order, with the correct sub-word
    //   position. Counters are NARROW (CW bits) — a depth-bounded BMC transfers
    //   few beats, so they need only span the window.
    // -------------------------------------------------------------------------
    localparam int CW = 5;
    (* anyconst *) logic [CW-1:0]     f_track_idx;     // which narrow beat to track
    (* anyconst *) logic [NARROW-1:0] f_track_val;     // value forced on that beat
    logic [CW-1:0] f_wbeat_cnt;   // narrow words pushed (across the write port)
    logic [CW-1:0] f_rbeat_cnt;   // narrow words popped (across the read port)

    initial begin
        f_wbeat_cnt = '0;
        f_rbeat_cnt = '0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            f_wbeat_cnt <= '0;
            f_rbeat_cnt <= '0;
        end else begin
            if (do_write) f_wbeat_cnt <= f_wbeat_cnt + WR_BEATS[CW-1:0];
            if (do_read)  f_rbeat_cnt <= f_rbeat_cnt + RD_BEATS[CW-1:0];
        end
    end

    // NOTE on soundness/vacuity: f_track_idx is an unbounded $anyconst, so BMC
    // proves a_width_data_integrity for EVERY index value. Out-of-window indices
    // are inert (their write-force never fires and their read-check never
    // triggers) — they cannot mask a bug. The companion cover c_track_roundtrip
    // independently exhibits a concrete write->read round-trip of the tracked
    // beat, proving the assertion is genuinely exercised on a reachable index
    // (non-vacuous). An explicit `assume (f_track_idx < ...)` bound was tried as
    // an SMT-runtime trim but measured SLOWER on yices here, so it is omitted.

    // Force the tracked value onto the chunk of wr_data whose global narrow
    // index equals f_track_idx. Within a write, sub-position s carries global
    // index (f_wbeat_cnt + s); its bit slice is the one mapped by sub_index.
    // (Unlabeled assume: the loop unrolls to WR_BEATS distinct statements, so a
    // static label would collide across iterations — Yosys auto-names them.)
    integer fk;
    always @(posedge clk) begin
        if (rst_n && do_write) begin
            for (fk = 0; fk < WR_BEATS; fk = fk + 1) begin
                if ((f_wbeat_cnt + fk[CW-1:0]) == f_track_idx) begin
                    assume (wr_data[(sub_index(fk, WR_BEATS))*NARROW +: NARROW] == f_track_val);
                end
            end
        end
    end

    // On the read that dequeues the tracked global narrow index, the matching
    // sub-slice of rd_data (registered, so checked the NEXT cycle) must equal
    // the forced value. We capture "this read delivers the tracked index at
    // sub-position s" and verify rd_data one cycle later.
    logic            f_track_read;
    logic [$clog2(RD_BEATS>1?RD_BEATS:2)-1:0] f_track_sub;
    initial begin
        f_track_read = 1'b0;
        f_track_sub  = '0;
    end
    integer fr;
    always @(posedge clk) begin
        if (!rst_n) begin
            f_track_read <= 1'b0;
            f_track_sub  <= '0;
        end else begin
            f_track_read <= 1'b0;
            if (do_read) begin
                for (fr = 0; fr < RD_BEATS; fr = fr + 1) begin
                    if ((f_rbeat_cnt + fr[CW-1:0]) == f_track_idx) begin
                        f_track_read <= 1'b1;
                        f_track_sub  <= fr[$clog2(RD_BEATS>1?RD_BEATS:2)-1:0];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && f_track_read) begin
            a_width_data_integrity: assert (
                rd_data[(sub_index(f_track_sub, RD_BEATS))*NARROW +: NARROW] == f_track_val);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 5 — Cover witnesses.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        c_reach_full:  cover (rst_n && wr_full);
        c_do_write:    cover (rst_n && do_write);
        c_do_read:     cover (rst_n && do_read);
    end

    // Tracked beat round-trip: the chosen narrow word is written then delivered.
    reg f_track_written;
    initial f_track_written = 1'b0;
    integer fw;
    always @(posedge clk) begin
        if (!rst_n) f_track_written <= 1'b0;
        else if (do_write) begin
            for (fw = 0; fw < WR_BEATS; fw = fw + 1)
                if ((f_wbeat_cnt + fw[CW-1:0]) == f_track_idx) f_track_written <= 1'b1;
        end
    end
    always @(posedge clk) begin
        c_track_roundtrip: cover (rst_n && f_track_written && f_track_read);
    end

`endif // FORMAL

endmodule

`default_nettype wire
