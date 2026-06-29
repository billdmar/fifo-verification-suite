//==============================================================================
// Module      : sync_fifo
// Description : Parameterizable synchronous (single-clock) FIFO using a
//               dual-pointer architecture with an extra MSB bit for
//               unambiguous empty/full detection.
// Parameters  : DATA_WIDTH          - width of each data word        [1..64]
//               DEPTH               - number of entries, power of 2  [4..1024]
//               ALMOST_FULL_THRESH  - count >= thresh -> almost_full
//               ALMOST_EMPTY_THRESH - count <= thresh -> almost_empty
// Author      : William Mar
// Date        : 2026-06
// Notes       : Verified with SymbiYosys (BMC + k-induction) and a Verilator
//               constrained-random testbench. Fully synthesizable: no initial
//               blocks, no $display, no gray coding (single-clock design).
//
// Empty/full detection (extra-MSB technique):
//   wptr / rptr are each ADDR_WIDTH+1 bits. The low ADDR_WIDTH bits index the
//   memory; the top bit is a wrap flag that toggles each time a pointer wraps.
//     empty = (wptr == rptr)
//     full  = (wptr[MSB] != rptr[MSB]) && (wptr[MSB-1:0] == rptr[MSB-1:0])
//
// Hand walk-through for DEPTH=4 (ADDR_WIDTH=2, 3-bit pointers):
//   start:        wptr=000 rptr=000 -> empty (equal)
//   +4 writes:    wptr=100 rptr=000 -> full  (MSB differ 1!=0, low 00==00)
//   +4 reads:     wptr=100 rptr=100 -> empty (equal, both wrapped once)
//   +1 write:     wptr=101 rptr=100 -> not full (MSB 1==1)
//   +3 writes:    wptr=000 rptr=100 -> full  (MSB differ 0!=1, low 00==00)
//   This confirms the extra MSB disambiguates the wptr==rptr aliasing that a
//   plain ADDR_WIDTH pointer would suffer between the empty and full states.
//==============================================================================

`default_nettype none

module sync_fifo #(
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
    output logic                  full,
    output logic                  empty,
    output logic                  almost_full,
    output logic                  almost_empty,
    output logic [$clog2(DEPTH):0] count         // valid entries, 0..DEPTH
);

    // ADDR_WIDTH is derived internally — never expose it as a top-level
    // parameter, so DEPTH and the pointer widths can never disagree.
    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // Compile-time sanity checks on the parameterization. A named generate
    // block of elaboration-time $error calls fires during elaboration on every
    // tool (Verilator, Yosys, commercial) and emits nothing for legal params.
    if (DATA_WIDTH < 1 || DATA_WIDTH > 64) begin : gen_chk_data_width
        $error("sync_fifo: DATA_WIDTH=%0d out of range [1,64]", DATA_WIDTH);
    end
    if (DEPTH < 4 || DEPTH > 1024) begin : gen_chk_depth_range
        $error("sync_fifo: DEPTH=%0d out of range [4,1024]", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin : gen_chk_depth_pow2
        $error("sync_fifo: DEPTH=%0d must be a power of two", DEPTH);
    end
    if (ALMOST_FULL_THRESH < 1 || ALMOST_FULL_THRESH > DEPTH-1) begin : gen_chk_af_thresh
        $error("sync_fifo: ALMOST_FULL_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_FULL_THRESH);
    end
    if (ALMOST_EMPTY_THRESH < 1 || ALMOST_EMPTY_THRESH > DEPTH-1) begin : gen_chk_ae_thresh
        $error("sync_fifo: ALMOST_EMPTY_THRESH=%0d out of range [1,DEPTH-1]", ALMOST_EMPTY_THRESH);
    end

    // Storage.
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Dual pointers: ADDR_WIDTH+1 bits each (extra MSB = wrap flag).
    logic [ADDR_WIDTH:0] wptr;
    logic [ADDR_WIDTH:0] rptr;

    // Address slices into the memory array.
    wire [ADDR_WIDTH-1:0] waddr = wptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] raddr = rptr[ADDR_WIDTH-1:0];

    // Qualified write/read strobes (the handshake: no write when full, no
    // read when empty). These define the legal operations each cycle.
    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    //--------------------------------------------------------------------------
    // Empty / full / count : combinationally derived from the pointers only.
    //--------------------------------------------------------------------------
    assign empty = (wptr == rptr);
    assign full  = (wptr[ADDR_WIDTH] != rptr[ADDR_WIDTH]) &&
                   (wptr[ADDR_WIDTH-1:0] == rptr[ADDR_WIDTH-1:0]);

    // count = wptr - rptr in (ADDR_WIDTH+1)-bit unsigned arithmetic. This wraps
    // correctly and yields 0..DEPTH inclusive.
    assign count = wptr - rptr;

    // Thresholds derived combinationally from count (no separate counter, so a
    // flag can never drift out of sync with count). The comparison is done in
    // full integer width: count zero-extends to the 32-bit parameter so no high
    // bits are ever silently dropped (the earlier explicit [$clog2(DEPTH):0]
    // slice could mask an out-of-range threshold; the elaboration guards above
    // already reject those, and a full-width compare is the honest expression).
    assign almost_full  = (32'(count) >= ALMOST_FULL_THRESH);
    assign almost_empty = (32'(count) <= ALMOST_EMPTY_THRESH);

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
    // Read port. Registered-output FIFO: rd_data is updated on the clock edge
    // when a read is accepted, so it reflects the popped word one cycle after
    // rd_en is asserted (NOT fall-through / show-ahead).
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rptr    <= '0;
            rd_data <= '0;
        end else begin
            if (do_read) begin
                rd_data <= mem[raddr];
                rptr    <= rptr + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
