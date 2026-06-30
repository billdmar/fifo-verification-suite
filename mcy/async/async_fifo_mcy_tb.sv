// =============================================================================
// Module      : async_fifo_formal_tb (mcy variant)
// Description : Multi-clock formal harness for MUTATION TESTING of async_fifo.
//               Identical to formal/async_fifo_formal_tb.sv but instantiates the
//               DUT (`async_fifo`) WITHOUT parameter overrides — under mcy the DUT
//               is supplied pre-elaborated (mutated.il, built at DEPTH=8/
//               SYNC_STAGES=2 via config.mcy chparam), and re-applying `#(...)` to
//               an already-elaborated module is rejected by Yosys. All CDC-aware
//               properties live inline in async_fifo.sv under `ifdef FORMAL, so a
//               mutation that breaks any of them yields a counterexample (killed).
//               Module name kept as async_fifo_formal_tb so test_fm.sby's
//               `prep -top` matches the production convention.
// =============================================================================

`default_nettype none

module async_fifo_formal_tb (
    input wire gclk
);
    localparam int DATA_WIDTH  = 8;

    wire wr_en_clk = $anyseq;
    wire rd_en_clk = $anyseq;
    wire wr_clk = gclk & wr_en_clk;
    wire rd_clk = gclk & rd_en_clk;

    wire                  wr_en   = $anyseq;
    wire [DATA_WIDTH-1:0] wr_data = $anyseq;
    wire                  rd_en   = $anyseq;
    wire                  full;
    wire                  empty;
    wire [DATA_WIDTH-1:0] rd_data;

    reg init = 1'b1;
    always @(posedge gclk) init <= 1'b0;
    wire wr_rst_n = ~init;
    wire rd_rst_n = ~init;

    // DUT — BARE instantiation (mutant is pre-elaborated to DEPTH=8/SYNC_STAGES=2).
    async_fifo dut (
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
