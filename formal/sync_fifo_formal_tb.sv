// =============================================================================
// Module      : sync_fifo_formal_tb
// Description : Top-level formal verification wrapper for sync_fifo.
//
//   Provides free symbolic inputs via $anyseq, constrains reset to be low for
//   exactly the first cycle, instantiates the DUT, maintains a shadow pointer
//   model, and instantiates sync_fifo_properties explicitly (rather than via
//   `bind` — see sync_fifo_properties.sv header for why the Yosys open-source
//   frontend requires explicit instantiation instead).
//
//   All properties live in sync_fifo_properties.sv; this file is pure harness.
// =============================================================================

`default_nettype none

module sync_fifo_formal_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 8;
    localparam int ADDR_WIDTH = $clog2(DEPTH);   // 3

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
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
    logic [ADDR_WIDTH:0]    count;   // $clog2(8)+1 = 4 bits

    // -------------------------------------------------------------------------
    // Free symbolic inputs every cycle.
    // -------------------------------------------------------------------------
    always @(*) begin
        wr_en   = $anyseq;
        wr_data = $anyseq;
        rd_en   = $anyseq;
    end

    // -------------------------------------------------------------------------
    // Reset: low for exactly the first cycle, then high forever.
    //   init is 1 at elaboration and cleared on the first posedge, so the
    //   `if (init)` branch fires before the first rising edge only.
    // -------------------------------------------------------------------------
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;

    always @(*) begin
        if (init)
            assume (!rst_n);
        else
            assume (rst_n);
    end

    // -------------------------------------------------------------------------
    // DUT instantiation — DEPTH=8 for formal tractability.
    // -------------------------------------------------------------------------
    sync_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (DEPTH)
    ) dut (
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

    // -------------------------------------------------------------------------
    // Re-derive qualified strobes (mirrors DUT-internal do_write / do_read).
    // -------------------------------------------------------------------------
    wire do_write_w = wr_en && !full;
    wire do_read_w  = rd_en && !empty;

    // -------------------------------------------------------------------------
    // Shadow pointers: mirror DUT's wptr/rptr from port-observable events.
    //   These give us the write/read address at each cycle so the property
    //   module can track which memory slot is written/read.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Property module instantiation.
    //   All property groups (1-8) live there.  Explicit port connections
    //   replace the `bind sync_fifo ...` that would be used with Verific.
    // -------------------------------------------------------------------------
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
