// =============================================================================
// Module      : async_fifo_formal_tb
// Description : Multi-clock formal harness for async_fifo.
//
//   The async FIFO has two genuinely independent clocks (wr_clk, rd_clk). To
//   verify it with yosys-smtbmc we model both from a single $global_clock and
//   gate each domain with its own solver-chosen clock enable (the "gclk"
//   technique). On every global tick the solver may advance the write domain,
//   the read domain, both, or neither — covering every relative phase /
//   frequency relationship the two real clocks could have, including the
//   adversarial ones that stress CDC.
//
//   Reset for each domain is held low for exactly the first global tick, then
//   high forever, mirroring the sync harness's reset-first-cycle convention.
//
//   All CDC-aware properties live INLINE in async_fifo.sv under `ifdef FORMAL
//   (the Yosys OSS frontend cannot wire `bind` to a separate module's
//   internals), so this file is pure harness: it provides the clocks, resets,
//   and free symbolic inputs, then instantiates the DUT.
// =============================================================================

`default_nettype none

module async_fifo_formal_tb (
    input wire gclk   // single global clock (yosys $global_clock)
);

    localparam int DATA_WIDTH  = 8;
    localparam int DEPTH       = 8;
    localparam int SYNC_STAGES = 2;

    // -------------------------------------------------------------------------
    // Per-domain clock enables. $anyseq lets the solver choose, each global
    // tick, whether each domain's clock edge occurs. The gated clocks below
    // therefore advance independently — modelling two asynchronous clocks.
    // -------------------------------------------------------------------------
    wire wr_en_clk = $anyseq;
    wire rd_en_clk = $anyseq;

    wire wr_clk = gclk & wr_en_clk;
    wire rd_clk = gclk & rd_en_clk;

    // -------------------------------------------------------------------------
    // Free symbolic data-path inputs.
    // -------------------------------------------------------------------------
    wire                  wr_en   = $anyseq;
    wire [DATA_WIDTH-1:0] wr_data = $anyseq;
    wire                  rd_en   = $anyseq;

    wire                  full;
    wire                  empty;
    wire [DATA_WIDTH-1:0] rd_data;

    // -------------------------------------------------------------------------
    // Reset generation. `init` is 1 at elaboration and cleared on the first
    // global tick, so each domain sees reset low for exactly the first cycle.
    // -------------------------------------------------------------------------
    reg init = 1'b1;
    always @(posedge gclk) init <= 1'b0;

    wire wr_rst_n = ~init;
    wire rd_rst_n = ~init;

    // -------------------------------------------------------------------------
    // DUT. DEPTH=8 for formal tractability.
    // -------------------------------------------------------------------------
    async_fifo #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DEPTH       (DEPTH),
        .SYNC_STAGES (SYNC_STAGES)
    ) dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .full     (full),

        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .empty    (empty)
    );

endmodule

`default_nettype wire
