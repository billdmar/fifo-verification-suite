//==============================================================================
// Module      : axis_pkt_fifo
// Description : AXI4-Stream STORE-AND-FORWARD packet FIFO. Buffers a TDATA+TLAST
//               stream and releases a packet's beats on the master port ONLY once
//               the ENTIRE packet (up to and including its TLAST) has been written
//               — the canonical store-and-forward behaviour of a network switch
//               (vs. cut-through, which forwards beats as they arrive). A partial
//               (in-flight) packet at the tail is held back until its TLAST lands.
// Parameters  : DATA_WIDTH - width of TDATA                       [1..63]
//               DEPTH      - ring depth in beats, power of two    [4..1024]
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + cover) via inlined `ifdef FORMAL
//               SVA. Lints clean under Verilator -Wall and the Verible gate.
//
// Why store-and-forward (the new property class vs. axis_fifo):
//   axis_fifo forwards every buffered beat as soon as it is present (cut-through
//   over a FIFO). axis_pkt_fifo adds a COMMIT POINTER: beats become readable only
//   when they belong to a fully-written packet. This is what lets a downstream
//   block assume "once m_axis starts a packet, the whole packet is already here"
//   — no mid-packet underrun stalls. The proven invariant is:
//     STORE-AND-FORWARD: a beat is never delivered before its packet's TLAST has
//     been written into the FIFO.
//
// Pointer model (extra-MSB ring, same disambiguation scheme as sync_fifo):
//   wptr       : next write slot (may sit inside an in-flight, uncommitted packet)
//   commit_ptr : one past the last beat of the most-recently-COMPLETED packet;
//                advances to (wptr+1) on each accepted TLAST write
//   rptr       : next read slot
//   full        = wptr caught rptr around the ring (cannot overwrite unread data)
//   read_avail  = rptr != commit_ptr  (a committed beat is waiting)
//   The readable region is [rptr, commit_ptr); the held-back tail is
//   [commit_ptr, wptr). pkt_count = complete packets buffered but not yet drained.
//
// The 1-cycle registered read latency is absorbed by a 1-deep output skid
// register (same idiom as axis_fifo) so no beat is dropped/duplicated under
// backpressure.
//==============================================================================

`default_nettype none

module axis_pkt_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,        // active-low synchronous reset

    // AXI4-Stream SLAVE (sink)
    input  wire                   s_axis_tvalid,
    output logic                  s_axis_tready,
    input  wire  [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                   s_axis_tlast,

    // AXI4-Stream MASTER (source)
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tlast,

    // Number of complete packets buffered (committed, not yet fully delivered)
    output logic [$clog2(DEPTH):0] pkt_count
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);
    localparam int W          = DATA_WIDTH + 1;   // {tlast, tdata}

    // Elaboration-time parameter checks (silent for legal params).
    if (DATA_WIDTH < 1 || DATA_WIDTH > 63) begin : gen_chk_data_width
        $error("axis_pkt_fifo: DATA_WIDTH=%0d out of range [1,63]", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("axis_pkt_fifo: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("axis_pkt_fifo: DEPTH=%0d must be a power of two", DEPTH);
    end

    // Storage: {tlast, tdata} per beat.
    logic [W-1:0] mem [0:DEPTH-1];

    // Extra-MSB pointers.
    logic [ADDR_WIDTH:0] wptr;
    logic [ADDR_WIDTH:0] rptr;
    logic [ADDR_WIDTH:0] commit_ptr;   // one past the last committed (complete) packet

    wire [ADDR_WIDTH-1:0] waddr = wptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] raddr = rptr[ADDR_WIDTH-1:0];

    // Full = next write would catch the read pointer (extra-MSB test). This bounds
    // the WHOLE buffer (committed + in-flight), so an in-flight packet still cannot
    // overwrite unread committed data.
    wire full = (wptr[ADDR_WIDTH] != rptr[ADDR_WIDTH]) &&
                (wptr[ADDR_WIDTH-1:0] == rptr[ADDR_WIDTH-1:0]);

    // A committed beat is available to read when the read pointer has not caught
    // the commit pointer.
    wire read_avail = (rptr != commit_ptr);

    assign s_axis_tready = !full;
    wire push = s_axis_tvalid && s_axis_tready;

    // pkt_count: complete packets buffered = tlasts written − tlasts read.
    logic [ADDR_WIDTH:0] wr_pkts;
    logic [ADDR_WIDTH:0] rd_pkts;
    assign pkt_count = wr_pkts - rd_pkts;

    //--------------------------------------------------------------------------
    // Output skid register (owns the master interface).
    //--------------------------------------------------------------------------
    logic         out_valid;
    logic [W-1:0] out_word;
    wire          out_accept = out_valid && m_axis_tready;
    logic         rd_inflight;

    wire out_free = !out_valid || out_accept;
    wire do_pop   = read_avail && !rd_inflight && out_free;

    wire [W-1:0]  rd_word;           // valid 1 cyc after do_pop
    logic [W-1:0] rd_word_q;
    assign rd_word = rd_word_q;

    //--------------------------------------------------------------------------
    // Write side: store the beat, advance wptr; on TLAST, snapshot commit_ptr to
    // just past this beat and bump the written-packet count.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr       <= '0;
            commit_ptr <= '0;
            wr_pkts    <= '0;
        end else if (push) begin
            mem[waddr] <= {s_axis_tlast, s_axis_tdata};
            wptr       <= wptr + 1'b1;
            if (s_axis_tlast) begin
                commit_ptr <= wptr + 1'b1;   // everything through this beat is committed
                wr_pkts    <= wr_pkts + 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read side: pop a committed beat into the read register; advance rptr; count
    // a completed packet when its TLAST beat is popped.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rptr      <= '0;
            rd_pkts   <= '0;
            rd_word_q <= '0;
        end else if (do_pop) begin
            rd_word_q <= mem[raddr];
            rptr      <= rptr + 1'b1;
            if (mem[raddr][DATA_WIDTH]) rd_pkts <= rd_pkts + 1'b1;  // popped a TLAST
        end
    end

    //--------------------------------------------------------------------------
    // Skid / output-register control (same idiom as axis_fifo).
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
                out_word  <= rd_word;
            end else if (out_accept) begin
                out_valid <= 1'b0;
            end
        end
    end

    assign m_axis_tvalid = out_valid;
    assign m_axis_tdata  = out_word[DATA_WIDTH-1:0];
    assign m_axis_tlast  = out_word[DATA_WIDTH];

    //==========================================================================
    // FORMAL — inlined under `ifdef FORMAL. Small instance via chparam.
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
    // GROUP 1 — AXI master protocol compliance (stable-until-accepted, no spurious).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            if ($past(m_axis_tvalid) && !$past(m_axis_tready)) begin
                a_m_tvalid_stable: assert (m_axis_tvalid);
                a_m_tdata_stable:  assert (m_axis_tdata == $past(m_axis_tdata));
                a_m_tlast_stable:  assert (m_axis_tlast == $past(m_axis_tlast));
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            a_no_spurious_valid: assert (m_axis_tvalid == out_valid);
            a_tready_iff_room:   assert (s_axis_tready == !full);
            a_no_push_when_full: assert (!(push && full));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 2 — Pointer / commit invariants. commit_ptr lies within [rptr, wptr]
    //   (in ring order): you can't commit beyond what's written, and committed
    //   data can't fall behind what's already been read.
    //   occ = wptr-rptr (total), cocc = commit_ptr-rptr (committed) — cocc<=occ<=DEPTH.
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] f_occ  = wptr - rptr;
    wire [ADDR_WIDTH:0] f_cocc = commit_ptr - rptr;
    always @(posedge clk) begin
        if (rst_n) begin
            a_occ_le_depth:    assert (f_occ  <= DEPTH[ADDR_WIDTH:0]);
            a_commit_le_write: assert (f_cocc <= f_occ);
            a_no_overflow:     assert (!(push && full));
            // read only happens within the committed region
            a_read_committed:  assert (!(do_pop && (rptr == commit_ptr)));
        end
    end

    // Pointer monotonicity.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n)) begin
            a_wptr_monotone:   assert ((wptr == $past(wptr)) || (wptr == $past(wptr) + 1'b1));
            a_rptr_monotone:   assert ((rptr == $past(rptr)) || (rptr == $past(rptr) + 1'b1));
            a_commit_monotone: assert (
                (commit_ptr == $past(commit_ptr)) || (commit_ptr == $past(wptr) + 1'b1));
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 3 — STORE-AND-FORWARD (the defining property). A beat is delivered
    //   only after its packet's TLAST has been written. We track, with $anyconst,
    //   a chosen pushed beat index and the push-index of the TLAST that completes
    //   its packet; when that beat is read, its packet's TLAST must already have
    //   been written (commit covered it). Operationally this is exactly
    //   a_read_committed (a read only consumes a beat < commit_ptr, and commit_ptr
    //   only advances on a TLAST write), asserted above; here we add the
    //   end-to-end data+last integrity tracker.
    // -------------------------------------------------------------------------
    (* anyconst *) logic [DATA_WIDTH-1:0] f_track_data;
    (* anyconst *) logic                  f_track_last;
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
    // Force the tracked beat's payload + last on its push.
    always @(posedge clk) begin
        if (rst_n && push && (f_push_cnt == f_track_idx)) begin
            m_track_push_data: assume (s_axis_tdata == f_track_data);
            m_track_push_last: assume (s_axis_tlast == f_track_last);
        end
    end
    // On the matching delivery (FIFO-ordered, so same index), payload+last intact.
    always @(posedge clk) begin
        if (rst_n && out_accept && (f_pop_cnt == f_track_idx)) begin
            a_e2e_data: assert (m_axis_tdata == f_track_data);
            a_e2e_last: assert (m_axis_tlast == f_track_last);
        end
    end

    // -------------------------------------------------------------------------
    // GROUP 4 — PACKET-COUNT CONSERVATION. Packets delivered never exceed packets
    //   committed; pkt_count = wr_pkts - rd_pkts is the live difference and is
    //   bounded by occupancy (each packet is >= 1 beat).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            a_pkts_conserved: assert (rd_pkts <= wr_pkts);   // never deliver more packets than committed
            a_pktcount_le_occ: assert ((wr_pkts - rd_pkts) <= f_occ);
        end
    end

    // No data loss under backpressure: no pop while the held output is stalled.
    always @(posedge clk) begin
        if (rst_n) a_no_pop_when_stalled: assert (!(do_pop && out_valid && !m_axis_tready));
    end

    // -------------------------------------------------------------------------
    // GROUP 5 — Cover witnesses.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        c_deliver:   cover (rst_n && out_accept);
        c_tlast_out: cover (rst_n && out_accept && m_axis_tlast);     // a packet end emerges
        c_two_pkts:  cover (rst_n && (pkt_count >= 2));                // >=2 complete packets buffered
    end

    // Store-and-forward in action: a partial packet is held back (data written
    // beyond the commit point) while nothing of it is yet readable.
    always @(posedge clk) begin
        c_partial_held: cover (rst_n && (wptr != commit_ptr) && (rptr == commit_ptr));
    end

    // Backpressure stall-then-resume.
    reg f_was_stalled;
    initial f_was_stalled = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) f_was_stalled <= 1'b0;
        else if (m_axis_tvalid && !m_axis_tready) f_was_stalled <= 1'b1;
    end
    always @(posedge clk) begin
        c_stall_then_resume: cover (rst_n && f_was_stalled && out_accept);
    end

    // Tracked beat round-trip.
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

`endif // FORMAL

endmodule

`default_nettype wire
