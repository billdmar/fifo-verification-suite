// =============================================================================
// Module      : sync_fifo_formal_tb (mcy variant)
// Description : Formal harness for MUTATION TESTING of sync_fifo with mcy.
//
//   Identical in intent to formal/sync_fifo_formal_tb.sv, but instantiates the
//   DUT (`sync_fifo`) WITHOUT parameter overrides, because under mcy the DUT is
//   supplied pre-elaborated (mutated.il, built at DEPTH=8 via the config.mcy
//   [script] chparam). Re-applying `#(...)` to an already-elaborated module is
//   rejected by Yosys ("used with parameters but is not parametric"), so the
//   instantiation here is bare. Everything else — symbolic inputs, reset
//   convention, shadow pointers, and the sync_fifo_properties instance — matches
//   the production harness so the SAME assertions decide whether each mutant is
//   killed (FAIL) or survives (PASS).
//
//   Module name kept as sync_fifo_formal_tb so test_fm.sby's `prep -top` is
//   unchanged from the production convention.
// =============================================================================

`default_nettype none

module sync_fifo_formal_tb;

    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 8;
    localparam int ADDR_WIDTH = $clog2(DEPTH);

    logic                   clk;
    logic                   rst_n;
    logic                   wr_en;
    logic [DATA_WIDTH-1:0]  wr_data;
    logic                   rd_en;
    logic [DATA_WIDTH-1:0]  rd_data;
    logic                   full;
    logic                   empty;
    logic                   almost_full;
    logic                   almost_empty;
    logic [ADDR_WIDTH:0]    count;

    always @(*) begin
        wr_en   = $anyseq;
        wr_data = $anyseq;
        rd_en   = $anyseq;
    end

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) begin
        if (init) assume (!rst_n);
        else      assume (rst_n);
    end

    // DUT — BARE instantiation (mutant is pre-elaborated to DEPTH=8).
    sync_fifo dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (wr_en),
        .wr_data     (wr_data),
        .rd_en       (rd_en),
        .rd_data     (rd_data),
        .full        (full),
        .empty       (empty),
        .almost_full (almost_full),
        .almost_empty(almost_empty),
        .count       (count)
    );

    wire do_write_w = wr_en && !full;
    wire do_read_w  = rd_en && !empty;

    logic [ADDR_WIDTH:0] sf_wptr;
    logic [ADDR_WIDTH:0] sf_rptr;
    always @(posedge clk) begin
        if (!rst_n) begin
            sf_wptr <= '0;
            sf_rptr <= '0;
        end else begin
            if (do_write_w) sf_wptr <= sf_wptr + 1'b1;
            if (do_read_w)  sf_rptr <= sf_rptr + 1'b1;
        end
    end
    wire [ADDR_WIDTH-1:0] sf_waddr = sf_wptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] sf_raddr = sf_rptr[ADDR_WIDTH-1:0];

    sync_fifo_properties #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (DEPTH)
    ) u_props (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (wr_en),
        .wr_data     (wr_data),
        .rd_en       (rd_en),
        .rd_data     (rd_data),
        .full        (full),
        .empty       (empty),
        .almost_full (almost_full),
        .almost_empty(almost_empty),
        .count       (count),
        .do_write    (do_write_w),
        .do_read     (do_read_w),
        .waddr       (sf_waddr),
        .raddr       (sf_raddr),
        .sf_wptr     (sf_wptr),
        .sf_rptr     (sf_rptr)
    );

endmodule

`default_nettype wire
