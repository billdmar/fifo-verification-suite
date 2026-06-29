// =============================================================================
// File        : tb_sync_fifo_fwft.cpp
// Description : Verilator C++ testbench with golden-reference scoreboard for
//               sync_fifo_fwft.sv — the FIRST-WORD-FALL-THROUGH (show-ahead)
//               FIFO. Validates the defining FWFT contract that the registered
//               sync_fifo does NOT have: the head word is on rd_data
//               COMBINATIONALLY (zero latency), and is checked the SAME cycle a
//               pop is accepted — not one cycle later.
//
// Build (via Makefile):
//   make sim-fwft                 (DEPTH=8 DATA_WIDTH=8)
//   make sim-fwft DEPTH=16 DATA_WIDTH=32
//
// Show-ahead (0-cycle) read vs the registered TB's 1-cycle latency:
//   sync_fifo (registered): pop at T, rd_data valid at T+1 -> the scoreboard
//     latches the expected value and compares NEXT cycle.
//   sync_fifo_fwft (this): rd_data ALWAYS shows the head word while !empty, so
//     on an accepted pop (rd_en && !empty) we compare rd_data against the
//     golden head IMMEDIATELY (combinationally, before the edge advances rptr).
//
// Fault-injection self-test:
//   Compile with -DINJECT_FAULT to corrupt the golden model so the scoreboard
//   detects a mismatch and exits nonzero — proving the checker is not vacuous.
//   Invoked via: make sim-fwft-fault
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <queue>
#include <sys/stat.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vsync_fifo_fwft.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 8
#endif
#ifndef DW_PARAM
#  define DW_PARAM 8
#endif

static constexpr int      DEPTH          = DEPTH_PARAM;
static constexpr int      DATA_WIDTH     = DW_PARAM;
static constexpr uint64_t DATA_MASK      =
    (DATA_WIDTH >= 64) ? ~0ull : ((1ull << DATA_WIDTH) - 1ull);
static constexpr int      ALMOST_FULL_TH = DEPTH - 2;
static constexpr int      ALMOST_EMPTY_TH = 2;

static Vsync_fifo_fwft *dut      = nullptr;
static VerilatedVcdC   *tfp      = nullptr;
static uint64_t         sim_time = 0;
static int              total_errors = 0;
static std::queue<uint64_t> gold_q;

// -----------------------------------------------------------------------------
// One clock cycle. The FWFT scoreboard is fundamentally SAME-CYCLE: rd_data
// shows the head combinationally, so we check it (and pop the golden head) on
// an accepted pop BEFORE the edge, then advance the model and the DUT together.
// -----------------------------------------------------------------------------
static void tick(const char *ctx) {
    // Mask the driven input to DATA_WIDTH (Verilator does not truncate narrow
    // inputs — the TB owns input masking).
    dut->wr_data &= DATA_MASK;

    bool in_reset = !dut->rst_n;
    bool do_write = dut->wr_en && !dut->full && !in_reset;
    bool do_read  = dut->rd_en && !dut->empty && !in_reset;

    // SHOW-AHEAD CHECK: while running and non-empty, rd_data must equal the
    // golden head NOW (combinationally). Skipped under reset, where DUT memory
    // may hold stale data and the golden model is being cleared (the pre-edge
    // `empty` can still reflect stale pointers for the first reset tick).
    if (!in_reset && !dut->empty && !gold_q.empty()) {
        uint64_t shown = (uint64_t)dut->rd_data & DATA_MASK;
        uint64_t exp   = gold_q.front();
        if (shown != exp) {
            printf("  [FAIL] %s: show-ahead rd_data=0x%llx expected head=0x%llx\n",
                   ctx, (unsigned long long)shown, (unsigned long long)exp);
            total_errors++;
        }
    }

    // Advance the golden model on accepted ops (qualified on pre-edge flags).
    if (do_write) {
        uint64_t wdata = (uint64_t)dut->wr_data & DATA_MASK;
#ifdef INJECT_FAULT
        static int fault_ctr = 0;
        if (++fault_ctr % 3 == 0) wdata ^= DATA_MASK;
#endif
        gold_q.push(wdata);
    }
    if (do_read) {
        gold_q.pop();   // the shown word was already validated above
    }

    // Posedge.
    dut->clk = 1; dut->eval();
    if (tfp) tfp->dump(sim_time++);

    // Post-edge consistency: count / empty / full / almost_* vs the model.
    uint32_t qs = (uint32_t)gold_q.size();
    if ((uint32_t)dut->count != qs) {
        printf("  [FAIL] %s: count=%u expected=%u\n", ctx, (uint32_t)dut->count, qs);
        total_errors++;
    }
    if ((bool)dut->empty != (qs == 0)) {
        printf("  [FAIL] %s: empty=%d expected=%d\n", ctx, (int)dut->empty, qs == 0);
        total_errors++;
    }
    if ((bool)dut->full != (qs == (uint32_t)DEPTH)) {
        printf("  [FAIL] %s: full=%d expected=%d\n", ctx, (int)dut->full, qs == (uint32_t)DEPTH);
        total_errors++;
    }
    if ((bool)dut->valid != (qs != 0)) {
        printf("  [FAIL] %s: valid=%d expected=%d\n", ctx, (int)dut->valid, qs != 0);
        total_errors++;
    }
    if ((bool)dut->almost_full != (dut->count >= (uint32_t)ALMOST_FULL_TH)) {
        printf("  [FAIL] %s: almost_full wrong at count=%u\n", ctx, (uint32_t)dut->count);
        total_errors++;
    }
    if ((bool)dut->almost_empty != (dut->count <= (uint32_t)ALMOST_EMPTY_TH)) {
        printf("  [FAIL] %s: almost_empty wrong at count=%u\n", ctx, (uint32_t)dut->count);
        total_errors++;
    }

    // Negedge.
    dut->clk = 0; dut->eval();
    if (tfp) tfp->dump(sim_time++);
}

static void do_reset(int cycles = 4) {
    dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->clk = 0; dut->eval();
    while (!gold_q.empty()) gold_q.pop();
    for (int i = 0; i < cycles; i++) tick("reset");
    dut->rst_n = 1;
}

// -----------------------------------------------------------------------------
// TEST 1 — reset clears to empty, valid low.
// -----------------------------------------------------------------------------
static void test_reset() {
    int pre = total_errors;
    printf("[TEST 1] Reset (DEPTH=%d DATA_WIDTH=%d)...\n", DEPTH, DATA_WIDTH);
    do_reset(4);
    dut->wr_en = 0; dut->rd_en = 0; tick("reset_check");
    if (!dut->empty)  { printf("  [FAIL] not empty after reset\n"); total_errors++; }
    if ( dut->valid)  { printf("  [FAIL] valid high after reset\n"); total_errors++; }
    if ( dut->full)   { printf("  [FAIL] full after reset\n");       total_errors++; }
    if ( dut->count)  { printf("  [FAIL] count!=0 after reset\n");   total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 2 — fill to full; verify show-ahead presents the FIRST word immediately
// after the first write (the defining FWFT behavior).
// -----------------------------------------------------------------------------
static void test_fill_and_show_ahead() {
    int pre = total_errors;
    printf("[TEST 2] Fill + show-ahead head visibility...\n");
    do_reset(4);

    // Single write, then with rd_en=0 the head must already be visible.
    dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = 0xA5; tick("first_write");
    dut->wr_en = 0;
    // Now non-empty: rd_data must show 0xA5 WITHOUT any rd_en asserted.
    if (dut->empty || ((uint64_t)dut->rd_data & DATA_MASK) != (0xA5ull & DATA_MASK)) {
        printf("  [FAIL] head not shown combinationally after one write\n");
        total_errors++;
    }
    // Fill the rest.
    for (int i = 1; i < DEPTH + 4; i++) {
        dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = (uint8_t)(i + 1); tick("fill");
    }
    dut->wr_en = 0; tick("fill_settle");
    if (!dut->full) { printf("  [FAIL] not full after DEPTH writes\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 3 — drain all in order (each pop validated same-cycle by tick()).
// -----------------------------------------------------------------------------
static void test_drain() {
    int pre = total_errors;
    printf("[TEST 3] Sequential drain (show-ahead order)...\n");
    do_reset(4);
    for (int i = 0; i < DEPTH; i++) {
        dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = (uint8_t)(i + 1); tick("prefill");
    }
    dut->wr_en = 0; tick("settle");
    for (int i = 0; i < DEPTH + 4; i++) { dut->rd_en = 1; dut->wr_en = 0; tick("drain"); }
    dut->rd_en = 0; tick("final");
    if (!dut->empty) { printf("  [FAIL] not empty after drain\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 4 — constrained-random R+W (LFSR), 10k cycles; show-ahead + counts.
// -----------------------------------------------------------------------------
static void test_random_rw() {
    int pre = total_errors;
    printf("[TEST 4] Random R+W 10k cycles...\n");
    do_reset(4);
    uint32_t lfsr = 0xBEEF;
    auto next = [&]() { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u); return lfsr; };
    for (int c = 0; c < 10000; c++) {
        uint32_t r = next();
        dut->wr_en = (r >> 0) & 1; dut->rd_en = (r >> 1) & 1;
        dut->wr_data = (uint8_t)((r >> 2) & 0xFF);
        tick("rand");
    }
    dut->wr_en = 0; dut->rd_en = 0; tick("settle");
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 5 — single-entry oscillation: write 1, immediately pop 1 (same-cycle
// show-ahead at minimal occupancy stresses the 0-latency head path).
// -----------------------------------------------------------------------------
static void test_oscillation() {
    int pre = total_errors;
    printf("[TEST 5] Single-entry oscillation...\n");
    do_reset(4);
    uint8_t v = 0x40;
    for (int i = 0; i < 500; i++) {
        dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = v++; tick("osc_w");
        dut->wr_en = 0; dut->rd_en = 1;                     tick("osc_r");
    }
    dut->wr_en = 0; dut->rd_en = 0; tick("osc_settle");
    if (!dut->empty) { printf("  [FAIL] not empty after oscillation\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 6 — simultaneous write+pop at steady mid-occupancy: the popped (head)
// word is validated same-cycle while a new word enters the tail.
// -----------------------------------------------------------------------------
static void test_simultaneous_rw() {
    int pre = total_errors;
    printf("[TEST 6] Simultaneous write+pop, mid-occupancy...\n");
    do_reset(4);
    // Prime to half full.
    for (int i = 0; i < DEPTH / 2; i++) {
        dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = (uint8_t)(i + 1); tick("prime");
    }
    uint8_t v = 0x80;
    for (int i = 0; i < 2000; i++) {
        dut->wr_en = 1; dut->rd_en = 1; dut->wr_data = v++; tick("simul");
    }
    dut->wr_en = 0; dut->rd_en = 1;
    for (int i = 0; i < DEPTH + 2; i++) tick("drain");
    dut->rd_en = 0; tick("settle");
    if (!dut->empty) { printf("  [FAIL] not empty after simul drain\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    dut = new Vsync_fifo_fwft;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    mkdir("docs", 0755);
    mkdir("docs/waveforms", 0755);
    tfp->open("docs/waveforms/sim_waves_fwft.vcd");

    printf("=== sync_fifo_fwft Verilator TB  DEPTH=%d  DATA_WIDTH=%d ===\n", DEPTH, DATA_WIDTH);
#ifdef INJECT_FAULT
    printf("  *** FAULT INJECTION ENABLED — scoreboard should report errors ***\n");
#endif

    dut->clk = 0; dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->eval();

    test_reset();
    test_fill_and_show_ahead();
    test_drain();
    test_random_rw();
    test_oscillation();
    test_simultaneous_rw();

    dut->wr_en = 0; dut->rd_en = 0;
    for (int i = 0; i < 4; i++) tick("end");

    tfp->close();
    dut->final();
    delete dut;

    printf("\n%s\n", total_errors == 0
           ? "=== SIM RESULT: PASS (0 errors) ==="
           : "=== SIM RESULT: FAIL ===");
    return total_errors > 0 ? 1 : 0;
}
