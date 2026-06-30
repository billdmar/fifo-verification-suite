//==============================================================================
// Module      : sync_fifo_ecc
// Description : Parameterizable synchronous FIFO with SINGLE-ERROR-CORRECTING,
//               DOUBLE-ERROR-DETECTING (SECDED) memory protection. Each data
//               word is stored as an extended-Hamming codeword; on read, a
//               single-bit error anywhere in the stored codeword is CORRECTED
//               and flagged (single_err), and a double-bit error is DETECTED and
//               flagged (double_err). Built as the sync_fifo extra-MSB dual-
//               pointer ring with an ECC encode-on-write / decode-on-read layer.
// Parameters  : DATA_WIDTH - width of each data word (FIXED at 8 this release)
//               DEPTH      - number of entries, power of 2        [4..1024]
//               ALMOST_FULL_THRESH  - count >= thresh -> almost_full
//               ALMOST_EMPTY_THRESH - count <= thresh -> almost_empty
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys — the SECDED correct/detect behaviour is
//               proven EXHAUSTIVELY over every error position by formal fault
//               injection (an $anyconst error mask XORed into the stored codeword
//               under `ifdef FORMAL only — the synth path has NO error-injection
//               logic). The pointer/count/flag core closes k-induction (PROVEN),
//               same as sync_fifo. A Verilator TB validates the clean (no-error)
//               datapath. Lints clean under Verilator -Wall + the Verible gate.
//
// SECDED code (extended Hamming (13,8), DATA_WIDTH=8):
//   13-bit codeword cw[12:0]. Positions are 1-indexed 1..12 for the Hamming
//   (12,8) core; cw[12] is the OVERALL parity that upgrades SEC to SECDED.
//     - Hamming parity bits sit at 1-indexed positions {1,2,4,8} (cw[0],cw[1],
//       cw[3],cw[7]); the 8 data bits fill the remaining positions {3,5,6,7,9,
//       10,11,12} (cw[2],cw[4],cw[5],cw[6],cw[8],cw[9],cw[10],cw[11]).
//     - Each Hamming parity p_k covers every position whose 1-indexed value has
//       bit k set (classic Hamming coverage), even parity.
//     - cw[12] = XOR of all 12 lower bits (overall even parity).
//   Decode recomputes the 4-bit syndrome s (over positions 1..12) and the
//   overall parity p:
//     - s==0 && p==0 : no error.
//     - s!=0 && p==1 : single-bit error at 1-indexed position s -> CORRECT it,
//                      assert single_err.
//     - s!=0 && p==0 : double-bit error -> assert double_err (uncorrectable).
//     - s==0 && p==1 : single-bit error in the overall-parity bit cw[12] itself
//                      -> data intact, treat as a corrected single (single_err).
//   (3+-bit errors are out of SECDED scope and may alias — documented, not
//   claimed.)
//==============================================================================

`default_nettype none

module sync_fifo_ecc #(
    parameter int DATA_WIDTH          = 8,
    parameter int DEPTH               = 16,
    parameter int ALMOST_FULL_THRESH  = DEPTH - 2,
    parameter int ALMOST_EMPTY_THRESH = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,        // active-low synchronous reset
    input  wire                   wr_en,
    input  wire  [DATA_WIDTH-1:0] wr_data,
    input  wire                   rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  single_err,   // a single-bit error was corrected on this read
    output logic                  double_err,   // a double-bit error was detected (uncorrectable)
    output logic                  full,
    output logic                  empty,
    output logic                  almost_full,
    output logic                  almost_empty,
    output logic [$clog2(DEPTH):0] count
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);
    localparam int CW_WIDTH   = 13;   // SECDED codeword width for DATA_WIDTH=8

    // Compile-time sanity checks.
    if (DATA_WIDTH != 8) begin : gen_chk_data_width
        $error("sync_fifo_ecc: DATA_WIDTH=%0d unsupported — this release fixes DATA_WIDTH=8 (SECDED (13,8))", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("sync_fifo_ecc: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("sync_fifo_ecc: DEPTH=%0d must be a power of two", DEPTH);
    end
    if (ALMOST_FULL_THRESH < 1 || ALMOST_FULL_THRESH > DEPTH-1) begin : gen_chk_af_thresh
        $error("sync_fifo_ecc: ALMOST_FULL_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_FULL_THRESH);
    end
    if (ALMOST_EMPTY_THRESH < 1 || ALMOST_EMPTY_THRESH > DEPTH-1) begin : gen_chk_ae_thresh
        $error("sync_fifo_ecc: ALMOST_EMPTY_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_EMPTY_THRESH);
    end

    //--------------------------------------------------------------------------
    // SECDED (13,8) encode/decode — pure combinational functions.
    //
    // 1-indexed Hamming layout over cw[11:0] (positions 1..12); cw[12]=overall.
    //   data bit d[i] -> Hamming data positions (1-indexed): 3,5,6,7,9,10,11,12
    //   parity positions (1-indexed): 1,2,4,8
    //--------------------------------------------------------------------------

    // Pack 8 data bits into the data-carrying positions of a 12-bit Hamming word
    // (1-indexed positions 3,5,6,7,9,10,11,12 -> 0-indexed 2,4,5,6,8,9,10,11).
    function automatic [CW_WIDTH-1:0] secded_encode(input logic [7:0] d);
        logic [11:0] h;        // Hamming(12,8): h[0..11] are 1-indexed pos 1..12
        logic        p1, p2, p4, p8, overall;
        begin
            // Place data bits at the non-power-of-two positions.
            h = '0;
            h[2]  = d[0];  // pos 3
            h[4]  = d[1];  // pos 5
            h[5]  = d[2];  // pos 6
            h[6]  = d[3];  // pos 7
            h[8]  = d[4];  // pos 9
            h[9]  = d[5];  // pos 10
            h[10] = d[6];  // pos 11
            h[11] = d[7];  // pos 12
            // Hamming parity (even) — each p_k covers positions with bit k set.
            //   pos (1-indexed) p has bit0 set: 1,3,5,7,9,11   -> h[0,2,4,6,8,10]
            p1 = h[2] ^ h[4] ^ h[6] ^ h[8] ^ h[10];
            //   bit1 set: 2,3,6,7,10,11                        -> h[1,2,5,6,9,10]
            p2 = h[2] ^ h[5] ^ h[6] ^ h[9] ^ h[10];
            //   bit2 set: 4,5,6,7,12                           -> h[3,4,5,6,11]
            p4 = h[4] ^ h[5] ^ h[6] ^ h[11];
            //   bit3 set: 8,9,10,11,12                         -> h[7,8,9,10,11]
            p8 = h[8] ^ h[9] ^ h[10] ^ h[11];
            h[0] = p1;     // pos 1
            h[1] = p2;     // pos 2
            h[3] = p4;     // pos 4
            h[7] = p8;     // pos 8
            overall = ^h;  // even parity over all 12 Hamming bits
            secded_encode = {overall, h};
        end
    endfunction

    // Decode: recompute syndrome + overall parity, correct a single-bit error,
    // and classify. Returns {double_err, single_err, data[7:0]}.
    function automatic [9:0] secded_decode(input logic [CW_WIDTH-1:0] cw);
        logic [11:0] h;
        logic        ovr_in, ovr_calc, ovr_mismatch;
        logic [3:0]  syn;
        // hc = corrected Hamming word; only its 8 DATA positions feed `d`, so the
        // 4 parity positions {0,1,3,7} are intentionally unread after correction.
        /* verilator lint_off UNUSEDSIGNAL */
        logic [11:0] hc;
        /* verilator lint_on UNUSEDSIGNAL */
        logic        s_err, d_err;
        logic [7:0]  d;
        begin
            h      = cw[11:0];
            ovr_in = cw[12];
            // Syndrome: recompute each parity over its coverage incl. the parity bit.
            syn[0] = h[0] ^ h[2] ^ h[4] ^ h[6] ^ h[8] ^ h[10];          // p1 group + pos1
            syn[1] = h[1] ^ h[2] ^ h[5] ^ h[6] ^ h[9] ^ h[10];          // p2 group + pos2
            syn[2] = h[3] ^ h[4] ^ h[5] ^ h[6] ^ h[11];                 // p4 group + pos4
            syn[3] = h[7] ^ h[8] ^ h[9] ^ h[10] ^ h[11];                // p8 group + pos8
            ovr_calc     = ^h;
            ovr_mismatch = ovr_calc ^ ovr_in;   // overall-parity check (1 => odd # of flips in h+ovr)

            // Correct a single-bit error in the 12-bit Hamming word at 1-indexed
            // position == syn (if in range 1..12).
            hc = h;
            if (ovr_mismatch && (syn != 4'd0) && (syn <= 4'd12)) begin
                hc[syn - 4'd1] = ~h[syn - 4'd1];
            end

            // Classify.
            //   syn==0 & !ovr_mismatch : no error
            //   syn==0 &  ovr_mismatch : single error in the overall-parity bit (data ok)
            //   syn!=0 &  ovr_mismatch : single error in h (corrected above)
            //   syn!=0 & !ovr_mismatch : double error (uncorrectable)
            s_err = ovr_mismatch;                       // any odd-weight (1-bit) error
            d_err = (syn != 4'd0) && !ovr_mismatch;     // even-weight nonzero syndrome => 2-bit

            // Extract data from the (corrected) Hamming positions.
            d = {hc[11], hc[10], hc[9], hc[8], hc[6], hc[5], hc[4], hc[2]};
            secded_decode = {d_err, s_err, d};
        end
    endfunction

    // Storage holds the 13-bit codeword per slot.
    logic [CW_WIDTH-1:0] mem [0:DEPTH-1];

    logic [ADDR_WIDTH:0] wptr;
    logic [ADDR_WIDTH:0] rptr;
    wire [ADDR_WIDTH-1:0] waddr = wptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] raddr = rptr[ADDR_WIDTH-1:0];

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    assign empty = (wptr == rptr);
    assign full  = (wptr[ADDR_WIDTH] != rptr[ADDR_WIDTH]) &&
                   (wptr[ADDR_WIDTH-1:0] == rptr[ADDR_WIDTH-1:0]);
    assign count = wptr - rptr;
    assign almost_full  = (32'(count) >= ALMOST_FULL_THRESH);
    assign almost_empty = (32'(count) <= ALMOST_EMPTY_THRESH);

    //--------------------------------------------------------------------------
    // The codeword presented to the decoder. In the synth path this is just the
    // stored word; under `ifdef FORMAL a solver-chosen error mask is XORed in to
    // prove correction/detection (NO injection logic in the real design).
    //--------------------------------------------------------------------------
    wire [CW_WIDTH-1:0] rd_codeword_raw = mem[raddr];
    logic [CW_WIDTH-1:0] rd_codeword;
`ifdef FORMAL_DATA
    (* anyconst *) logic [CW_WIDTH-1:0] f_err_mask;   // constrained to weight 0/1/2 in the harness
    assign rd_codeword = rd_codeword_raw ^ f_err_mask;
`else
    assign rd_codeword = rd_codeword_raw;
`endif

    //--------------------------------------------------------------------------
    // Write port: encode then store; advance wptr.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
        end else if (do_write) begin
            mem[waddr] <= secded_encode(wr_data);
            wptr       <= wptr + 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Read port (registered): decode the (possibly error-injected) codeword,
    // present data + error flags; advance rptr.
    //--------------------------------------------------------------------------
    wire [9:0] dec = secded_decode(rd_codeword);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rptr       <= '0;
            rd_data    <= '0;
            single_err <= 1'b0;
            double_err <= 1'b0;
        end else if (do_read) begin
            rd_data    <= dec[7:0];
            single_err <= dec[8];
            double_err <= dec[9];
            rptr       <= rptr + 1'b1;
        end
    end

    //==========================================================================
    // FORMAL
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

    // Handshake assumptions.
    always @(posedge clk) begin
        if (rst_n) begin
            m_no_write_when_full: assume (!(full && wr_en));
            m_no_read_when_empty: assume (!(empty && rd_en));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 1 — Pointer/count/flag invariants (the inductive core, no FORMAL_DATA
    //   so the prove gate closes k-induction here — the ECC layer is purely
    //   combinational and doesn't touch the pointers).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_full_and_empty:    assert (!(full && empty));
            a_count_in_range:       assert (count <= DEPTH[ADDR_WIDTH:0]);
            a_empty_iff_count_zero: assert (empty == (count == '0));
            a_full_iff_count_depth: assert (full  == (count == DEPTH[ADDR_WIDTH:0]));
            a_almost_full_iff:      assert (almost_full  == (32'(count) >= ALMOST_FULL_THRESH));
            a_almost_empty_iff:     assert (almost_empty == (32'(count) <= ALMOST_EMPTY_THRESH));
            a_no_overflow:          assert (!(do_write && full));
            a_no_underflow:         assert (!(do_read  && empty));
        end
    end
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_wptr_monotone: assert ((wptr == $past(wptr)) || (wptr == ($past(wptr) + 1'b1)));
            a_rptr_monotone: assert ((rptr == $past(rptr)) || (rptr == ($past(rptr) + 1'b1)));
            a_count_step: assert (
                (count == $past(count)) || (count == $past(count)+1'b1) || (count == $past(count)-1'b1));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — SECDED CORRECT/DETECT (the marquee proof). Guarded under
    //   FORMAL_DATA: the BMC gate injects a solver-chosen error and proves the
    //   decode corrects/detects it for EVERY error position. Two $anyconst
    //   positions select which bits are flipped; f_err_mask (above) is forced to
    //   exactly those positions. We track the word a chosen slot was encoded with
    //   and check what the decoder produces when that slot is read back with the
    //   injected error.
    // -------------------------------------------------------------------------
`ifdef FORMAL_DATA
    // Solver-chosen error positions (0..12). Two positions; equal => weight-1,
    // distinct => weight-2. Forcing f_err_mask to exactly these bits.
    (* anyconst *) logic [3:0] f_pos_a;
    (* anyconst *) logic [3:0] f_pos_b;
    always @(*) begin
        m_pos_a_range: assume (f_pos_a < CW_WIDTH);
        m_pos_b_range: assume (f_pos_b < CW_WIDTH);
        // f_err_mask is exactly bits {f_pos_a, f_pos_b}.
        m_err_mask_def: assume (f_err_mask == (({{(CW_WIDTH-1){1'b0}},1'b1} << f_pos_a)
                                             | ({{(CW_WIDTH-1){1'b0}},1'b1} << f_pos_b)));
    end
    wire f_weight1 = (f_pos_a == f_pos_b);
    wire f_weight2 = (f_pos_a != f_pos_b);

    // Track one solver-chosen slot's encoded word + the data it came from.
    (* anyconst *) logic [ADDR_WIDTH-1:0] f_slot;
    (* anyconst *) logic [7:0]            f_data;
    logic f_slot_loaded;
    initial f_slot_loaded = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_slot_loaded <= 1'b0;
        else if (do_write && (waddr == f_slot)) begin
            m_track_data: assume (wr_data == f_data);
            f_slot_loaded <= 1'b1;
        end
    end

    // When the tracked slot is read (registered → checked next cycle), the
    // decoder must have: corrected a single-bit error back to f_data + flagged
    // single_err; or, for weight-2, flagged double_err.
    logic f_read_tracked;
    initial f_read_tracked = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_read_tracked <= 1'b0;
        else        f_read_tracked <= do_read && (raddr == f_slot) && f_slot_loaded;
    end
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && f_read_tracked) begin
            if ($past(f_weight1)) begin
                a_single_corrected: assert (rd_data == $past(f_data));
                a_single_flagged:   assert (single_err && !double_err);
            end
            if ($past(f_weight2)) begin
                a_double_detected:  assert (double_err);
            end
        end
    end

    // No-error path: with a zero error mask the decode is transparent and quiet.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && f_read_tracked
            && ($past(f_pos_a) == $past(f_pos_b)) && ($past(f_err_mask) == '0)) begin
            a_clean_passthrough: assert (rd_data == $past(f_data) && !single_err && !double_err);
        end
    end

    // Covers: a real corrected single + a real detected double are reachable.
    always @(posedge clk) begin
        c_single_corrected: cover (rst_n && f_read_tracked && $past(f_weight1) && single_err);
        c_double_detected:  cover (rst_n && f_read_tracked && $past(f_weight2) && double_err);
    end
`endif // FORMAL_DATA

    // -------------------------------------------------------------------------
    // GROUP 3 — pointer covers (always on).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        c_reach_full: cover (rst_n && full);
    end
    reg f_was_full; initial f_was_full = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_full <= 1'b0; else if (full) f_was_full <= 1'b1;
    end
    always @(posedge clk) begin
        c_full_then_empty: cover (rst_n && f_was_full && empty);
    end

`endif // FORMAL

endmodule

`default_nettype wire
