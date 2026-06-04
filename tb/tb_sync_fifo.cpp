// =============================================================================
// File        : tb_sync_fifo.cpp
// Description : Verilator C++ testbench with golden-reference scoreboard for
//               sync_fifo.sv.  Covers 7 test scenarios including reset, fill,
//               drain, random R+W, threshold checks, depth sweep hooks, and
//               back-to-back fill/drain.
//
// Build (example, DEPTH=8):
//   source ~/oss-cad-suite/environment
//   verilator --cc --exe --build -Wall --trace \
//     -GDEPTH=8 --top-module sync_fifo \
//     rtl/sync_fifo.sv tb/tb_sync_fifo.cpp \
//     -Mdir obj_dir_d8 -o sim_fifo_d8
//   ./obj_dir_d8/sim_fifo_d8
//
// Depth sweep:
//   Run with different -GDEPTH= values (4, 8, 16, 64, 256).
//   The testbench reads DEPTH at runtime from the Verilated model constant
//   sync_fifo___024unit::DEPTH (exposed as a public param) – but Verilator
//   does not always expose SV parameters as C++ constants automatically.
//   Instead, we read it via the VL_IN/OUT macros or pass DEPTH as a
//   compile-define (preferred).  Set -CFLAGS "-DDEPTH_PARAM=8" etc., OR
//   the testbench uses a fallback via the Verilated model's 'count' output
//   width.  The simplest portable approach used here: the Makefile passes
//   -CFLAGS "-DDEPTH_PARAM=<N>" matching -GDEPTH=<N>.
//
// Fault-injection self-test:
//   Compile with -CFLAGS "-DINJECT_FAULT" to corrupt the golden model
//   (swaps two expected pop values) so the scoreboard detects a mismatch
//   and exits nonzero.  This validates the checker is not vacuously passing.
//   Invoked via: make sim-fault
//
// Registered-output (1-cycle read latency) handling:
//   When a read is accepted at posedge T  (rd_en && !empty at sampling point),
//   the DUT captures mem[raddr] into rd_data on that same posedge edge.
//   rd_data is therefore VALID and STABLE from posedge T+1 onward.
//   Scoreboard approach:
//     - At posedge T: pop queue.front() -> store in pending_rd_data; flag
//       pending_rd_check = true.
//     - After next posedge T+1: compare dut->rd_data == pending_rd_data.
//   We implement this with a one-entry pipeline latch (pending_check_valid /
//   pending_expected) updated each tick.
// =============================================================================

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <queue>
#include <cassert>
#include <string>
#include <vector>
#include <sys/stat.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vsync_fifo.h"

// ---------------------------------------------------------------------------
// Depth parameter: passed as -CFLAGS "-DDEPTH_PARAM=N" at build time so the
// single .cpp works for any depth without source edits.
// ---------------------------------------------------------------------------
#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 16
#endif

static constexpr int DEPTH           = DEPTH_PARAM;
static constexpr int DATA_WIDTH      = 8;   // default; DUT uses 8
// Thresholds must match the DUT defaults: DEPTH-2 and 2
static constexpr int ALMOST_FULL_TH  = DEPTH - 2;
static constexpr int ALMOST_EMPTY_TH = 2;

// ---------------------------------------------------------------------------
// Global sim state
// ---------------------------------------------------------------------------
static Vsync_fifo   *dut     = nullptr;
static VerilatedVcdC *tfp    = nullptr;
static uint64_t      sim_time = 0;   // counts half-periods (rising edge = even)
static int           total_errors = 0;

// Golden reference queue
static std::queue<uint64_t> gold_q;

// 1-cycle read latency pending check
static bool     pending_check_valid = false;
static uint64_t pending_expected    = 0;

// ---------------------------------------------------------------------------
// Clock helpers
// ---------------------------------------------------------------------------

// Advance one half-period.  Returns true on rising edge (posedge).
static void half_tick() {
    dut->clk ^= 1;
    dut->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time++;
}

// Full clock cycle: drive inputs BEFORE rising edge, then eval posedge,
// then eval negedge.  Inputs must be set before calling tick().
// After tick() returns, all registered outputs reflect the posedge.
//
// The function also runs the scoreboard checks that must happen AFTER
// the rising edge has updated DUT state.
static void tick();   // forward decl

// ---------------------------------------------------------------------------
// Scoreboard check: called every rising edge AFTER dut->eval()
// ---------------------------------------------------------------------------
static void scoreboard_check(const char *context) {
    // 1) Count / empty / full consistency
    uint32_t qs   = (uint32_t)gold_q.size();
    uint32_t dcnt = (uint32_t)dut->count;
    if (dcnt != qs) {
        printf("  [FAIL] %s: count mismatch: DUT=%u GOLD=%u\n",
               context, dcnt, qs);
        total_errors++;
    }
    bool dut_empty = (bool)dut->empty;
    bool dut_full  = (bool)dut->full;
    bool gold_empty = (qs == 0);
    bool gold_full  = (qs == (uint32_t)DEPTH);
    if (dut_empty != gold_empty) {
        printf("  [FAIL] %s: empty mismatch: DUT=%d GOLD=%d (count=%u)\n",
               context, dut_empty, gold_empty, qs);
        total_errors++;
    }
    if (dut_full != gold_full) {
        printf("  [FAIL] %s: full mismatch: DUT=%d GOLD=%d (count=%u)\n",
               context, dut_full, gold_full, qs);
        total_errors++;
    }

    // 2) Pending rd_data check (1-cycle latency: check was scheduled last cycle)
    if (pending_check_valid) {
        uint64_t got = (uint64_t)dut->rd_data;
        if (got != pending_expected) {
            printf("  [FAIL] %s: rd_data mismatch: got=0x%llx expected=0x%llx\n",
                   context,
                   (unsigned long long)got,
                   (unsigned long long)pending_expected);
            total_errors++;
        }
        pending_check_valid = false;
    }
}

// ---------------------------------------------------------------------------
// Sample accepted transactions and advance golden model.
// Called BEFORE the clock edge so inputs (wr_en, rd_en, etc.) are stable.
// The pointers and count update on the RISING edge, so:
//   - We check !full / !empty using the COMBINATIONAL DUT outputs (which
//     reflect the current state, before the edge).
//   - We push/pop the golden model accordingly.
//   - We latch the pending read expected value for the next-cycle check.
// ---------------------------------------------------------------------------
static void sample_transactions(const char *context) {
    bool do_write = dut->wr_en && !dut->full;
    bool do_read  = dut->rd_en && !dut->empty;

    if (do_write) {
        uint64_t wdata = (uint64_t)dut->wr_data;
#ifdef INJECT_FAULT
        // Fault injection: corrupt every 3rd push so the scoreboard catches it.
        static int fault_ctr = 0;
        fault_ctr++;
        if (fault_ctr % 3 == 0) wdata ^= 0xFF;
#endif
        gold_q.push(wdata);
    }

    if (do_read) {
        // Schedule rd_data check for NEXT cycle (1-cycle registered output).
        pending_check_valid = true;
        pending_expected    = gold_q.front();
        gold_q.pop();
        (void)context;
    }
}

// ---------------------------------------------------------------------------
// Full tick implementation
// ---------------------------------------------------------------------------
static void tick_impl(const char *context) {
    // Sample accepted transactions on current inputs (before posedge).
    sample_transactions(context);

    // Posedge
    dut->clk = 1;
    dut->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time++;

    // Scoreboard: check after posedge (registered outputs now valid).
    scoreboard_check(context);

    // Negedge
    dut->clk = 0;
    dut->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time++;
}

// Wrapper with a default context string
static void tick(const char *context = "cycle") {
    tick_impl(context);
}

// ---------------------------------------------------------------------------
// Reset helper: drives reset for N cycles then releases.
// ---------------------------------------------------------------------------
static void do_reset(int cycles = 4) {
    dut->rst_n  = 0;
    dut->wr_en  = 0;
    dut->rd_en  = 0;
    dut->wr_data = 0;
    // Initial negedge to stabilise combinational
    dut->clk = 0;
    dut->eval();
    // Clear golden model
    while (!gold_q.empty()) gold_q.pop();
    pending_check_valid = false;

    for (int i = 0; i < cycles; i++) tick("reset");
    dut->rst_n = 1;
}

// ---------------------------------------------------------------------------
// TEST 1: Reset test
// After reset: empty=1, full=0, count=0.
// ---------------------------------------------------------------------------
static void test_reset() {
    int pre = total_errors;
    printf("[TEST 1] Reset test...\n");

    do_reset(4);

    // Check immediately after reset releases (one more tick to settle)
    dut->wr_en = 0; dut->rd_en = 0;
    tick("reset_check");

    bool pass = true;
    if (!dut->empty)  { printf("  [FAIL] empty not asserted after reset\n"); total_errors++; pass=false; }
    if ( dut->full)   { printf("  [FAIL] full asserted after reset\n");       total_errors++; pass=false; }
    if ( dut->count)  { printf("  [FAIL] count=%u after reset (expect 0)\n", (uint32_t)dut->count); total_errors++; pass=false; }
    if (gold_q.size() != 0) { printf("  [FAIL] golden queue not empty after reset\n"); total_errors++; pass=false; }

    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 2: Sequential fill — write DEPTH items; full asserts at count==DEPTH
// ---------------------------------------------------------------------------
static void test_sequential_fill() {
    int pre = total_errors;
    printf("[TEST 2] Sequential fill (DEPTH=%d)...\n", DEPTH);

    do_reset(4);

    bool saw_full_at_depth = false;
    for (int i = 0; i < DEPTH + 4; i++) {
        uint64_t wdata = (uint64_t)(i + 1) & 0xFF;
        dut->wr_en  = 1;
        dut->rd_en  = 0;
        dut->wr_data = (uint8_t)wdata;

        // Capture full BEFORE tick (combinational output reflects current state)
        bool was_full = dut->full;

        tick("fill");

        // Once DUT says full, no more writes should be accepted.
        if (was_full && gold_q.size() == (size_t)DEPTH) {
            saw_full_at_depth = true;
        }
    }

    dut->wr_en = 0;
    tick("fill_settle");

    bool pass = true;
    if (!dut->full) { printf("  [FAIL] DUT not full after DEPTH writes\n"); total_errors++; pass=false; }
    if (gold_q.size() != (size_t)DEPTH) {
        printf("  [FAIL] golden queue size=%zu, expected %d\n", gold_q.size(), DEPTH);
        total_errors++; pass=false;
    }
    if (!saw_full_at_depth) {
        // full must have been seen during fill
        printf("  [WARN] did not observe full flag during fill loop\n");
    }
    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 3: Sequential drain — read all items in correct order
// ---------------------------------------------------------------------------
static void test_sequential_drain() {
    int pre = total_errors;
    printf("[TEST 3] Sequential drain (DEPTH=%d)...\n", DEPTH);

    // Refill first (starting from reset)
    do_reset(4);
    for (int i = 0; i < DEPTH; i++) {
        dut->wr_en  = 1;
        dut->rd_en  = 0;
        dut->wr_data = (uint8_t)((i + 1) & 0xFF);
        tick("drain_prefill");
    }
    dut->wr_en = 0;
    tick("drain_settle");

    // Drain all
    for (int i = 0; i < DEPTH + 4; i++) {
        dut->rd_en = 1;
        dut->wr_en = 0;
        tick("drain");
    }
    dut->rd_en = 0;
    tick("drain_final");

    bool pass = true;
    if (!dut->empty) { printf("  [FAIL] DUT not empty after draining all items\n"); total_errors++; pass=false; }
    if (gold_q.size() != 0) {
        printf("  [FAIL] golden queue not empty after drain (size=%zu)\n", gold_q.size());
        total_errors++; pass=false;
    }
    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 4: Simultaneous/random R+W — 10,000 cycles
// ---------------------------------------------------------------------------
static void test_random_rw() {
    int pre = total_errors;
    printf("[TEST 4] Random R+W (10000 cycles, DEPTH=%d)...\n", DEPTH);

    do_reset(4);

    // Use a simple LFSR for repeatable pseudo-random stimulus
    uint32_t lfsr = 0xACE1u;
    auto lfsr_next = [&]() -> uint32_t {
        lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
        return lfsr;
    };

    for (int cyc = 0; cyc < 10000; cyc++) {
        uint32_t r    = lfsr_next();
        dut->wr_en  = (r >> 0) & 1;
        dut->rd_en  = (r >> 1) & 1;
        dut->wr_data = (uint8_t)((r >> 2) & 0xFF);
        tick("random");
    }
    dut->wr_en = 0; dut->rd_en = 0;
    // Drain any pending read check
    tick("random_settle");

    bool pass = (total_errors == pre);
    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 5: Almost-full / almost-empty threshold check
// ---------------------------------------------------------------------------
static void test_thresholds() {
    int pre = total_errors;
    printf("[TEST 5] Almost-full/empty thresholds (AF_THRESH=%d, AE_THRESH=%d, DEPTH=%d)...\n",
           ALMOST_FULL_TH, ALMOST_EMPTY_TH, DEPTH);

    do_reset(4);
    dut->wr_en = 0; dut->rd_en = 0;

    bool pass = true;

    // Fill one at a time, check thresholds
    for (int i = 0; i < DEPTH; i++) {
        dut->wr_en  = 1;
        dut->rd_en  = 0;
        dut->wr_data = (uint8_t)(i & 0xFF);
        tick("thresh_fill");

        uint32_t cnt = dut->count;
        // almost_full: count >= ALMOST_FULL_TH
        bool exp_af = (cnt >= (uint32_t)ALMOST_FULL_TH);
        bool exp_ae = (cnt <= (uint32_t)ALMOST_EMPTY_TH);
        if ((bool)dut->almost_full != exp_af) {
            printf("  [FAIL] almost_full: count=%u expected=%d got=%d\n",
                   cnt, exp_af, (int)dut->almost_full);
            total_errors++; pass = false;
        }
        if ((bool)dut->almost_empty != exp_ae) {
            printf("  [FAIL] almost_empty: count=%u expected=%d got=%d\n",
                   cnt, exp_ae, (int)dut->almost_empty);
            total_errors++; pass = false;
        }
    }

    // Drain one at a time, check thresholds
    dut->wr_en = 0;
    for (int i = 0; i < DEPTH + 2; i++) {
        dut->rd_en = 1;
        dut->wr_en = 0;
        tick("thresh_drain");

        uint32_t cnt = dut->count;
        bool exp_af = (cnt >= (uint32_t)ALMOST_FULL_TH);
        bool exp_ae = (cnt <= (uint32_t)ALMOST_EMPTY_TH);
        if ((bool)dut->almost_full != exp_af) {
            printf("  [FAIL] almost_full: count=%u expected=%d got=%d\n",
                   cnt, exp_af, (int)dut->almost_full);
            total_errors++; pass = false;
        }
        if ((bool)dut->almost_empty != exp_ae) {
            printf("  [FAIL] almost_empty: count=%u expected=%d got=%d\n",
                   cnt, exp_ae, (int)dut->almost_empty);
            total_errors++; pass = false;
        }
    }
    dut->rd_en = 0;
    tick("thresh_settle");

    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 6: Depth behavior — wrap-around and pointer handling
// Fills to DEPTH, drains half, fills again, drains all.  Exercises pointer
// wrap (memory array wraparound) and count monotonicity.
// The depth itself is already parameterized via DEPTH_PARAM at build time.
// For a full sweep the Makefile builds separate obj_dirs for each depth.
// ---------------------------------------------------------------------------
static void test_depth_behavior() {
    int pre = total_errors;
    printf("[TEST 6] Depth behavior / pointer wrap (DEPTH=%d)...\n", DEPTH);

    do_reset(4);

    // Fill completely
    for (int i = 0; i < DEPTH; i++) {
        dut->wr_en  = 1; dut->rd_en = 0;
        dut->wr_data = (uint8_t)((i * 3 + 7) & 0xFF);
        tick("depth_fill");
    }
    dut->wr_en = 0; tick("depth_settle1");

    bool pass = true;
    if (!dut->full) { printf("  [FAIL] not full after fill\n"); total_errors++; pass=false; }

    // Drain half
    int half = DEPTH / 2;
    for (int i = 0; i < half; i++) {
        dut->rd_en = 1; dut->wr_en = 0;
        tick("depth_drain_half");
    }
    dut->rd_en = 0; tick("depth_settle2");

    if ((uint32_t)dut->count != (uint32_t)(DEPTH - half)) {
        printf("  [FAIL] count after half-drain: got=%u expected=%d\n",
               (uint32_t)dut->count, DEPTH - half);
        total_errors++; pass=false;
    }

    // Re-fill (exercises wraparound in memory array)
    for (int i = 0; i < half; i++) {
        dut->wr_en  = 1; dut->rd_en = 0;
        dut->wr_data = (uint8_t)((i * 5 + 3) & 0xFF);
        tick("depth_rewrap");
    }
    dut->wr_en = 0; tick("depth_settle3");

    // Drain all
    for (int i = 0; i < DEPTH + 4; i++) {
        dut->rd_en = 1; dut->wr_en = 0;
        tick("depth_drain_all");
    }
    dut->rd_en = 0; tick("depth_settle4");

    if (!dut->empty) { printf("  [FAIL] not empty after full drain\n"); total_errors++; pass=false; }

    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// TEST 7: Back-to-back fill/drain repeated 100 times
// ---------------------------------------------------------------------------
static void test_backtoback() {
    int pre = total_errors;
    printf("[TEST 7] Back-to-back fill/drain x100 (DEPTH=%d)...\n", DEPTH);

    do_reset(4);

    uint8_t data_val = 0x01;
    for (int iter = 0; iter < 100; iter++) {
        // Fill
        for (int i = 0; i < DEPTH; i++) {
            dut->wr_en  = 1; dut->rd_en = 0;
            dut->wr_data = data_val++;
            tick("b2b_fill");
        }
        dut->wr_en = 0; tick("b2b_settle_fill");
        if (!dut->full) {
            printf("  [FAIL] iter %d: not full after fill\n", iter);
            total_errors++;
        }

        // Drain
        for (int i = 0; i < DEPTH; i++) {
            dut->rd_en = 1; dut->wr_en = 0;
            tick("b2b_drain");
        }
        dut->rd_en = 0; tick("b2b_settle_drain");
        if (!dut->empty) {
            printf("  [FAIL] iter %d: not empty after drain\n", iter);
            total_errors++;
        }
    }

    bool pass = (total_errors == pre);
    printf("  -> %s (%d new errors)\n", pass ? "PASS" : "FAIL", total_errors - pre);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    dut = new Vsync_fifo;

    // Set up VCD output
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);

    // Ensure output directory exists
    mkdir("docs", 0755);
    mkdir("docs/waveforms", 0755);
    tfp->open("docs/waveforms/sim_waves.vcd");

    printf("=== sync_fifo Verilator Testbench  DEPTH=%d  DATA_WIDTH=%d ===\n",
           DEPTH, DATA_WIDTH);
#ifdef INJECT_FAULT
    printf("  *** FAULT INJECTION ENABLED — scoreboard should report errors ***\n");
#endif

    // Initialize DUT
    dut->clk    = 0;
    dut->rst_n  = 0;
    dut->wr_en  = 0;
    dut->rd_en  = 0;
    dut->wr_data = 0;
    dut->eval();

    // Run all 7 tests
    test_reset();
    test_sequential_fill();
    test_sequential_drain();
    test_random_rw();
    test_thresholds();
    test_depth_behavior();
    test_backtoback();

    // Final settle and VCD flush
    dut->wr_en = 0; dut->rd_en = 0;
    for (int i = 0; i < 4; i++) tick("final");

    tfp->close();
    dut->final();
    delete dut;

    printf("\n");
    if (total_errors == 0) {
        printf("=== SIM RESULT: PASS (0 errors) ===\n");
    } else {
        printf("=== SIM RESULT: FAIL (%d errors) ===\n", total_errors);
    }

    // Coverage note (when built with --coverage, Verilator writes coverage.dat
    // automatically; we just note where it lands).
    printf("  Coverage: if built with --coverage, see coverage.dat in obj_dir\n");

    // Return 1 (nonzero) on any errors to avoid exit-code wrap for large counts.
    return (total_errors > 0) ? 1 : 0;
}
