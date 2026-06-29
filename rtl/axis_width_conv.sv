//==============================================================================
// Module      : axis_width_conv
// Description : AXI4-Stream DATA-WIDTH CONVERTER (up-sizer or down-sizer) built
//               on sync_fifo_width. Presents a standard AXI4-Stream SLAVE (sink)
//               at S_WIDTH on the input and a standard AXI4-Stream MASTER
//               (source) at M_WIDTH on the output, converting the stream's data
//               width through one sync_fifo_width instance. A 1-deep output skid
//               register absorbs the FIFO's registered read latency so no beat is
//               dropped or duplicated under backpressure.
// Parameters  : S_WIDTH      - slave (input)  TDATA width, bits      [1..64]
//               M_WIDTH      - master (output) TDATA width, bits      [1..64]
//                              (one MUST be an integer multiple of the other,
//                               and S_WIDTH != M_WIDTH)
//               DEPTH_NARROW - buffer depth in NARROW-width beats,
//                              power of two                          [4..4096]
//               SUB_WORD_BIG - sub-word order across the width change (see
//                              sync_fifo_width): 0 = little, 1 = big
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + cover) via inlined `ifdef FORMAL
//               SVA. Lints clean under Verilator -Wall and the Verible gate.
//
// Scope — TDATA only (no TLAST/TKEEP):
//   This converter handles pure data-width conversion (TVALID/TREADY/TDATA),
//   the common case for rate/width matching between IP blocks. TLAST is
//   deliberately NOT carried: across a width change a packet boundary does not
//   map cleanly to a single sub-beat (an up-sizer would have to merge several
//   slave TLASTs into one master beat; a down-sizer would have to decide which
//   emitted sub-beat is "last"), and a half-correct TLAST is worse than none.
//   Packetized width conversion (TLAST/TKEEP-aware, with partial-beat padding)
//   is a documented future extension; the FIFO-buffered axis_fifo wrapper
//   already carries TLAST for the equal-width case.
//
// Composition (this is the systems-integration point):
//
//   s_axis ─►[ sync_fifo_width  S_WIDTH→M_WIDTH ]─(rd, 1-cyc lat)─►[ skid ]─► m_axis
//
//   The width crossing itself (pack/unpack, sub-word ordering, FIFO ordering)
//   is the proven sync_fifo_width core; this wrapper only adds the two AXI
//   handshakes and the master-side skid register (same idiom as axis_fifo).
//==============================================================================

`default_nettype none

module axis_width_conv #(
    parameter int S_WIDTH      = 32,
    parameter int M_WIDTH      = 8,
    parameter int DEPTH_NARROW = 16,
    parameter bit SUB_WORD_BIG = 1'b0
) (
    input  wire                 clk,
    input  wire                 rst_n,        // active-low synchronous reset

    // AXI4-Stream SLAVE (sink) — stream INTO the converter
    input  wire                 s_axis_tvalid,
    output logic                s_axis_tready,
    input  wire  [S_WIDTH-1:0]  s_axis_tdata,

    // AXI4-Stream MASTER (source) — stream OUT of the converter
    output logic                m_axis_tvalid,
    input  wire                 m_axis_tready,
    output logic [M_WIDTH-1:0]  m_axis_tdata
);

    // Compile-time sanity checks (elaboration-time $error; silent for legal
    // params). The deeper geometry checks (integer ratio, etc.) are enforced
    // inside sync_fifo_width; these guard this wrapper's own contract.
    if (S_WIDTH < 1 || S_WIDTH > 64) begin : gen_chk_s_width
        $error("axis_width_conv: S_WIDTH=%0d out of range [1,64]", S_WIDTH);
    end
    if (M_WIDTH < 1 || M_WIDTH > 64) begin : gen_chk_m_width
        $error("axis_width_conv: M_WIDTH=%0d out of range [1,64]", M_WIDTH);
    end
    if (S_WIDTH == M_WIDTH) begin : gen_chk_widths_differ
        $error("axis_width_conv: S_WIDTH==M_WIDTH=%0d — use axis_fifo for equal widths", S_WIDTH);
    end

    //--------------------------------------------------------------------------
    // Buffered width-FIFO interface signals.
    //--------------------------------------------------------------------------
    wire                fifo_wr_full;
    wire                fifo_rd_empty;
    wire [M_WIDTH-1:0]  fifo_rd_data;        // valid 1 cyc after pop

    // sync_fifo_width also drives almost-flags + count; this wrapper does not
    // surface them. Tie off and mark unused so -Wall stays clean.
    wire                                fifo_wr_almost_full;
    wire                                fifo_rd_almost_empty;
    wire [$clog2(DEPTH_NARROW):0]       fifo_count;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, fifo_wr_almost_full, fifo_rd_almost_empty, fifo_count};
    /* verilator lint_on UNUSEDSIGNAL */

    // Slave-side push: accept a beat when the FIFO has room.
    wire push = s_axis_tvalid && s_axis_tready;

    //--------------------------------------------------------------------------
    // Output holding (skid) register — owns the master interface (M_WIDTH).
    //--------------------------------------------------------------------------
    logic                out_valid;
    logic [M_WIDTH-1:0]  out_word;

    wire out_accept = out_valid && m_axis_tready;

    // Registered-read shadow: a pop issued last cycle has its data valid now.
    logic rd_inflight;

    wire out_free = !out_valid || out_accept;
    wire do_pop   = !fifo_rd_empty && !rd_inflight && out_free;

    // Slave ready whenever the FIFO can accept a write transaction.
    assign s_axis_tready = !fifo_wr_full;

    //--------------------------------------------------------------------------
    // The proven width-crossing core. S_WIDTH writes in, M_WIDTH reads out.
    //--------------------------------------------------------------------------
    sync_fifo_width #(
        .WR_WIDTH     (S_WIDTH),
        .RD_WIDTH     (M_WIDTH),
        .DEPTH_NARROW (DEPTH_NARROW),
        .SUB_WORD_BIG (SUB_WORD_BIG)
    ) u_fifo (
        .clk             (clk),
        .rst_n           (rst_n),
        .wr_en           (push),
        .wr_data         (s_axis_tdata),
        .wr_full         (fifo_wr_full),
        .wr_almost_full  (fifo_wr_almost_full),
        .rd_en           (do_pop),
        .rd_data         (fifo_rd_data),
        .rd_empty        (fifo_rd_empty),
        .rd_almost_empty (fifo_rd_almost_empty),
        .count           (fifo_count)
    );

    //--------------------------------------------------------------------------
    // Read-shadow / output-register control (same idiom as axis_fifo): a pop is
    // only issued when the skid register has room next cycle, so an in-flight
    // read always has a landing slot — no word is dropped or overwritten.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid   <= 1'b0;
            out_word    <= '0;
            rd_inflight <= 1'b0;
        end else begin
            rd_inflight <= do_pop;
            if (rd_inflight) begin
                out_valid <= 1'b1;
                out_word  <= fifo_rd_data;
            end else if (out_accept) begin
                out_valid <= 1'b0;
            end
        end
    end

    assign m_axis_tvalid = out_valid;
    assign m_axis_tdata  = out_word;

    //==========================================================================
    // FORMAL — AXI4-Stream protocol compliance, inlined under `ifdef FORMAL.
    // Every signal is a PORT or local of this wrapper. Run on a small instance
    // (chparam) for tractability.
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
    // GROUP 1 — MASTER TVALID stable until accepted (AXI4-Stream rule).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(m_axis_tvalid) && !$past(m_axis_tready)) begin
                a_m_tvalid_stable: assert (m_axis_tvalid);
                a_m_tdata_stable:  assert (m_axis_tdata == $past(m_axis_tdata));
            end
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — No spurious valid: TVALID iff a real word is held.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) a_no_spurious_valid: assert (m_axis_tvalid == out_valid);
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — Slave handshake / no overflow.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_tready_iff_room:   assert (s_axis_tready == !fifo_wr_full);
            a_no_push_when_full: assert (!(push && fifo_wr_full));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 4 — Read-shadow exclusivity + landing slot (no drop/dup across the
    //   registered read latency).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_pop_excl: assert (!(do_pop && rd_inflight));
            if (rd_inflight) begin
                a_landing_slot: assert (!out_valid || (out_valid && m_axis_tready));
            end
        end
    end

    // No pop while the output is stalled => buffered data is conserved.
    always @(posedge clk) begin
        if (rst_n) a_no_pop_when_stalled: assert (!(do_pop && out_valid && !m_axis_tready));
    end

    // -------------------------------------------------------------------------
    // GROUP 5 — Cover witnesses.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        c_push:    cover (rst_n && push);
        c_deliver: cover (rst_n && out_accept);
    end

    // Backpressure stall-then-resume on the master side.
    reg f_was_stalled;
    initial f_was_stalled = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_stalled <= 1'b0;
        else if (m_axis_tvalid && !m_axis_tready) f_was_stalled <= 1'b1;
    end
    always @(posedge clk) begin
        c_stall_then_resume: cover (rst_n && f_was_stalled && out_accept);
    end

`endif // FORMAL

endmodule

`default_nettype wire
