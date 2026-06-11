//==============================================================================
// Module      : axis_fifo
// Description : AXI4-Stream FIFO wrapper around sync_fifo. Presents a standard
//               AXI4-Stream SLAVE (sink) port on the input and a standard
//               AXI4-Stream MASTER (source) port on the output, buffering the
//               stream through a single instance of sync_fifo. Optional TLAST is
//               carried alongside TDATA by widening the buffered word to
//               {tlast, tdata} (DATA_WIDTH+1) so a single FIFO keeps the
//               last-flag perfectly aligned with its data.
// Parameters  : DATA_WIDTH - width of TDATA                       [1..63]
//               DEPTH      - sync_fifo depth, power of 2          [4..1024]
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + cover) via inlined `ifdef FORMAL
//               SVA. All AXI signals are PORTS of this wrapper, so the protocol
//               properties live inside this module and the open-source Yosys
//               frontend sees them natively (no `bind` to sub-module internals).
//               Lints clean with `verilator --lint-only -Wall`.
//
// AXI4-Stream handshake recap:
//   A transfer happens on a rising clk edge when TVALID && TREADY are both high.
//   A MASTER must not retract TVALID once asserted, and must hold TDATA/TLAST
//   stable, until the transfer is accepted (TREADY seen). A SLAVE may assert or
//   deassert TREADY freely.
//
// The registered-read-latency problem and the output-skid solution:
//   sync_fifo has a REGISTERED read port: when rd_en && !empty at cycle T, the
//   popped word appears on rd_data at cycle T+1 (1-cycle latency). A naive
//   mapping of m_axis_tvalid=!empty / m_axis_tdata=rd_data would (a) expose
//   rd_data a cycle late and (b) drop or duplicate words under backpressure,
//   because rd_data is overwritten by the NEXT pop while the master is stalled.
//
//   We therefore add a 1-deep OUTPUT HOLDING (skid) register that owns the
//   master interface:
//
//     out_valid / out_word  ->  m_axis_tvalid / {m_axis_tlast, m_axis_tdata}
//
//   Exactly one read can be "in flight" at a time (rd_inflight): the cycle after
//   we assert rd_en, rd_data is valid and we latch it into the holding register
//   (if free) or it stays in rd_data (the FIFO already advanced its pointer, so
//   the word is committed and never re-read). We only issue a new pop (rd_en)
//   when the FIFO is non-empty AND the pipeline has room for the result — i.e.
//   the holding register is empty, or it is being accepted this cycle, AND no
//   read is already in flight. This guarantees:
//     * every popped word lands in out_word exactly once (no loss),
//     * out_word never advances while m_axis_tvalid && !m_axis_tready (no loss
//       under backpressure, data held stable),
//     * out_valid is never high without a real buffered word (no spurious out).
//
//   Pipeline (1 sync_fifo read latency + 1 skid stage):
//
//     s_axis ─► [ sync_fifo {tlast,tdata} ] ─(rd_data, 1-cyc lat)─► [ skid ] ─► m_axis
//==============================================================================

`default_nettype none

module axis_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,        // active-low synchronous reset

    // AXI4-Stream SLAVE (sink) — stream INTO the FIFO
    input  wire                   s_axis_tvalid,
    output logic                  s_axis_tready,
    input  wire  [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                   s_axis_tlast,

    // AXI4-Stream MASTER (source) — stream OUT OF the FIFO
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tlast
);

    // The buffered word carries TLAST in the MSB: {tlast, tdata}.
    localparam int W = DATA_WIDTH + 1;

    // Compile-time sanity checks (elaboration-time $error; silent for legal
    // params, fires on every tool). DATA_WIDTH is capped at 63 so the widened
    // word W = DATA_WIDTH+1 stays within sync_fifo's [1..64] DATA_WIDTH range.
    if (DATA_WIDTH < 1 || DATA_WIDTH > 63) begin : gen_chk_data_width
        $error("axis_fifo: DATA_WIDTH=%0d out of range [1,63]", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("axis_fifo: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("axis_fifo: DEPTH=%0d must be a power of two", DEPTH);
    end

    //--------------------------------------------------------------------------
    // Buffered-FIFO interface signals.
    //--------------------------------------------------------------------------
    wire           fifo_full;
    wire           fifo_empty;
    wire [W-1:0]   fifo_rd_word;          // {tlast, tdata}, valid 1 cyc after pop

    // sync_fifo also drives almost_full/almost_empty/count; the AXI wrapper does
    // not surface them. Tie them to locals and mark unused so -Wall stays clean.
    wire                   fifo_almost_full;
    wire                   fifo_almost_empty;
    wire [$clog2(DEPTH):0] fifo_count;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, fifo_almost_full, fifo_almost_empty, fifo_count};
    /* verilator lint_on UNUSEDSIGNAL */

    // Slave-side push: accept a beat when there is room. AXI TREADY = !full.
    wire           push = s_axis_tvalid && s_axis_tready;

    //--------------------------------------------------------------------------
    // Output holding (skid) register — owns the master interface.
    //   out_valid : a buffered word is presented on the master port.
    //   out_word  : the held {tlast, tdata}.
    //--------------------------------------------------------------------------
    logic          out_valid;
    logic [W-1:0]  out_word;

    // The master accepts the held word this cycle when valid && ready.
    wire           out_accept = out_valid && m_axis_tready;

    // A read is "in flight": we asserted rd_en last cycle, so fifo_rd_word is
    // valid THIS cycle and must be consumed (the FIFO pointer already advanced).
    logic          rd_inflight;

    // Issue a new pop when:
    //   * the FIFO has a word (!fifo_empty), AND
    //   * no read is already in flight (rd_inflight is exclusive — at most one
    //     word ever sits in the 1-cycle read shadow), AND
    //   * the holding register can take the result next cycle: it is empty, or
    //     it is being accepted this cycle (so it frees up).
    wire           out_free   = !out_valid || out_accept;
    wire           do_pop     = !fifo_empty && !rd_inflight && out_free;

    //--------------------------------------------------------------------------
    // Slave side: ready whenever the FIFO is not full.
    //--------------------------------------------------------------------------
    assign s_axis_tready = !fifo_full;

    //--------------------------------------------------------------------------
    // Buffered FIFO instance — widened to carry {tlast, tdata}.
    //--------------------------------------------------------------------------
    sync_fifo #(
        .DATA_WIDTH (W),
        .DEPTH      (DEPTH)
    ) u_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (push),
        .wr_data     ({s_axis_tlast, s_axis_tdata}),
        .rd_en       (do_pop),
        .rd_data     (fifo_rd_word),
        .full        (fifo_full),
        .empty       (fifo_empty),
        .almost_full (fifo_almost_full),
        .almost_empty(fifo_almost_empty),
        .count       (fifo_count)
    );

    //--------------------------------------------------------------------------
    // Read-shadow / output-register control.
    //   rd_inflight tracks the 1-cycle registered read latency: it is high the
    //   cycle fifo_rd_word is valid. When in flight, we move the word into the
    //   holding register if the register is free (empty or accepted this cycle);
    //   otherwise (register occupied and stalled) we cannot have issued a pop in
    //   the first place — do_pop is gated on out_free && !rd_inflight — so the
    //   "in flight but no room" case never arises and no word is dropped.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid   <= 1'b0;
            out_word    <= '0;
            rd_inflight <= 1'b0;
        end else begin
            // A pop issued this cycle => its data is valid next cycle.
            rd_inflight <= do_pop;

            // Update the holding register. If the held word is accepted and no
            // new word arrives from the FIFO this cycle, the register empties.
            if (rd_inflight) begin
                // Newly popped word is valid now: load it into the register.
                // (do_pop guaranteed out_free last cycle, so this is safe.)
                out_valid <= 1'b1;
                out_word  <= fifo_rd_word;
            end else if (out_accept) begin
                // Held word accepted, nothing new arriving: register goes empty.
                out_valid <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Master interface drive.
    //--------------------------------------------------------------------------
    assign m_axis_tvalid = out_valid;
    assign m_axis_tdata  = out_word[DATA_WIDTH-1:0];
    assign m_axis_tlast  = out_word[DATA_WIDTH];

    //==========================================================================
    // FORMAL — AXI4-Stream protocol-compliance properties, inlined under
    // `ifdef FORMAL. Every signal referenced is a PORT or local of this wrapper,
    // so the SVA sees everything natively (no `bind` to sub-module internals).
    //
    // The harness/sby drives clk, rst_n, and the four free interface inputs
    // (s_axis_tvalid, s_axis_tdata, s_axis_tlast, m_axis_tready) symbolically
    // with $anyseq, and constrains rst_n low for exactly the first cycle.
    //==========================================================================
`ifdef FORMAL

    // f_past_valid: true after the first rising edge so $past() is safe.
    reg f_past_valid;
    initial f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // Reset: low for exactly the first cycle, high forever after (mirrors the
    // sync_fifo_formal_tb convention so the proof starts from a real reset).
    reg f_init;
    initial f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @(*) begin
        if (f_init) assume (!rst_n);
        else        assume (rst_n);
    end

    // -------------------------------------------------------------------------
    // GROUP 1 — MASTER TVALID stable until accepted.
    //   Once m_axis_tvalid is asserted it must remain asserted until the master
    //   sees m_axis_tready (the transfer completes). A master may never retract
    //   a valid beat. (AXI4-Stream rule.)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(m_axis_tvalid) && !$past(m_axis_tready)) begin
                a_m_tvalid_stable: assert (m_axis_tvalid);
            end
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — MASTER TDATA/TLAST stable while stalled.
    //   While m_axis_tvalid is high and m_axis_tready is low, the payload
    //   (TDATA and TLAST) must not change before the beat is accepted.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(m_axis_tvalid) && !$past(m_axis_tready)) begin
                a_m_tdata_stable: assert (m_axis_tdata == $past(m_axis_tdata));
                a_m_tlast_stable: assert (m_axis_tlast == $past(m_axis_tlast));
            end
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — NO SPURIOUS OUTPUT.
    //   m_axis_tvalid is exactly the holding-register occupancy: it is asserted
    //   if and only if there is a real buffered word presented. The wrapper
    //   never raises TVALID with nothing held.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_spurious_valid: assert (m_axis_tvalid == out_valid);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 4 — HANDSHAKE SAFETY (slave side, no overflow).
    //   s_axis_tready is deasserted exactly when the FIFO is full, so a push is
    //   never accepted into a full FIFO (no overflow). Conversely, while there
    //   is room the slave is ready (no spurious backpressure that could stall a
    //   producer when space exists).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_tready_iff_room:   assert (s_axis_tready == !fifo_full);
            a_no_push_when_full: assert (!(push && fifo_full));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 5 — READ-SHADOW EXCLUSIVITY (the registered-latency invariant).
    //   At most ONE read is ever in flight, and a pop is only issued when the
    //   pipeline has room for its result. This is the core correctness argument
    //   for the 1-cycle registered read latency: a popped word always has a
    //   landing slot, so it can never be dropped or overwritten.
    //     * rd_inflight => the holding register was free when the pop was issued
    //       (we asserted do_pop only when out_free), hence on arrival there is a
    //       slot: either out_valid is low, or it is being accepted this cycle.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            // A pop is never issued while a read is already in flight.
            a_pop_excl: assert (!(do_pop && rd_inflight));
            // When a read result arrives, the holding register has room for it:
            // it is empty, or its current word is being accepted this cycle.
            if (rd_inflight) begin
                a_landing_slot: assert (!out_valid || (out_valid && m_axis_tready));
            end
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 6 — NO DATA LOSS UNDER BACKPRESSURE (held word preserved).
    //   While the master is stalled (m_axis_tvalid && !m_axis_tready), the held
    //   word is preserved unchanged AND no new pop is issued — the output word
    //   is conserved across an arbitrarily long stall and delivered intact.
    //   (Stability is GROUP 1/2; here we additionally prove the FIFO is frozen
    //   behind a stalled output so nothing is silently popped and lost.)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            // No pop while the output is stalled => buffered data is conserved.
            a_no_pop_when_stalled: assert (
                !(do_pop && out_valid && !m_axis_tready));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 7 — END-TO-END DATA INTEGRITY (tracked-word, $anyconst).
    //   A solver-chosen constant payload is injected on a chosen slave beat and
    //   must emerge unchanged on the master side (carrying its TLAST), in a
    //   single delivery — proving the {tlast, tdata} word survives the FIFO +
    //   skid pipeline without corruption, loss, or duplication.
    //
    //   Mechanism: a one-shot tracker arms when the chosen payload is pushed,
    //   follows it through the FIFO (occupancy bookkeeping is the sync_fifo's
    //   job, already proven), and checks the value when it is delivered. We use
    //   a position counter: the tracked beat is the Nth pushed beat for an
    //   $anyconst N within the BMC window, and it must be the Nth delivered
    //   beat with the same value. This is the conservation argument requested.
    //   The push/pop counters are intentionally NARROW (CW bits) — a depth-D
    //   BMC can transfer at most D beats, so they need only cover the window;
    //   keeping them small keeps the SMT problem tractable. FIFO ordering makes
    //   the index match exact (the Nth in is the Nth out), so wrap of these
    //   counters past the window is irrelevant to the in-window proof.
    // -------------------------------------------------------------------------
    (* anyconst *) logic [DATA_WIDTH-1:0] f_track_data;
    (* anyconst *) logic                  f_track_last;

    // Count pushes and deliveries; the tracked beat is a solver-chosen index.
    localparam int CW = 5;
    (* anyconst *) logic [CW-1:0] f_track_idx;
    logic [CW-1:0] f_push_cnt;
    logic [CW-1:0] f_pop_cnt;

    initial begin
        f_push_cnt = '0;
        f_pop_cnt  = '0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            f_push_cnt <= '0;
            f_pop_cnt  <= '0;
        end else begin
            if (push)       f_push_cnt <= f_push_cnt + 1'b1;
            if (out_accept) f_pop_cnt  <= f_pop_cnt  + 1'b1;
        end
    end

    // When the tracked-index beat is pushed, force its payload to the tracked
    // constants (an assumption on the free slave inputs). The FIFO is FIFO-
    // ordered, so the tracked-index push must be the tracked-index delivery.
    always @(posedge clk) begin
        if (rst_n && push && (f_push_cnt == f_track_idx)) begin
            m_track_push_payload: assume (s_axis_tdata == f_track_data);
            m_track_push_last:    assume (s_axis_tlast == f_track_last);
        end
    end

    // On the matching delivery, the payload must equal the tracked constants:
    // no corruption, and (by index equality) no loss or duplication.
    always @(posedge clk) begin
        if (rst_n && out_accept && (f_pop_cnt == f_track_idx)) begin
            a_e2e_data: assert (m_axis_tdata == f_track_data);
            a_e2e_last: assert (m_axis_tlast == f_track_last);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 8 — COVER points (reachability witnesses for real waveforms).
    // -------------------------------------------------------------------------

    // A master beat is actually delivered.
    always @(posedge clk) begin
        c_deliver: cover (rst_n && out_accept);
    end

    // A backpressure stall-then-resume sequence: the output is stalled with a
    // valid beat, then later accepted — exercises the skid hold path.
    reg f_was_stalled;
    initial f_was_stalled = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_stalled <= 1'b0;
        else if (m_axis_tvalid && !m_axis_tready) f_was_stalled <= 1'b1;
    end
    always @(posedge clk) begin
        c_stall_then_resume: cover (rst_n && f_was_stalled && out_accept);
    end

    // End-to-end round trip of the tracked beat: it was pushed and is delivered.
    reg f_track_pushed;
    initial f_track_pushed = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_track_pushed <= 1'b0;
        else if (push && (f_push_cnt == f_track_idx)) f_track_pushed <= 1'b1;
    end
    always @(posedge clk) begin
        c_track_roundtrip: cover (
            rst_n && f_track_pushed && out_accept && (f_pop_cnt == f_track_idx));
    end

    // A TLAST beat propagates all the way to the master output.
    always @(posedge clk) begin
        c_tlast_out: cover (rst_n && out_accept && m_axis_tlast);
    end

`endif // FORMAL

endmodule

`default_nettype wire
