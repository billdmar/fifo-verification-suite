// =============================================================================
// File        : tb_sync_fifo_width.cpp
// Description : Verilator C++ testbench + golden-reference scoreboard for the
//               ASYMMETRIC-WIDTH FIFO sync_fifo_width.sv. The golden model works
//               at the NARROW granularity: every write transaction is unpacked
//               into WR_BEATS narrow words pushed to a std::deque, and every read
//               transaction pops RD_BEATS narrow words and repacks them, exactly
//               mirroring the DUT's pack/unpack + SUB_WORD_ORDER. This validates
//               that data crosses the width change in order and bit-accurate.
//
// Build (via Makefile): make sim-width-fifo WR_WIDTH=32 RD_WIDTH=8
//   The Makefile passes -G{WR,RD}_WIDTH / -GDEPTH_NARROW / -GSUB_WORD_ORDER to
//   Verilator and the matching -D defines here so one .cpp covers every config.
//
// Registered read: rd_data is valid the cycle AFTER an accepted read, so the
// scoreboard latches the expected packed word and checks it next cycle.
//
// Fault injection (-DINJECT_FAULT): corrupts an occasional narrow word in the
// golden model so the scoreboard MUST report a mismatch — proves non-vacuity.
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <deque>
#include <string>
#include <sys/stat.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vsync_fifo_width.h"

#ifndef WR_WIDTH_PARAM
#  define WR_WIDTH_PARAM 32
#endif
#ifndef RD_WIDTH_PARAM
#  define RD_WIDTH_PARAM 8
#endif
#ifndef DEPTH_NARROW_PARAM
#  define DEPTH_NARROW_PARAM 16
#endif
// SUB_WORD_ORDER: 0 = LITTLE (default), 1 = BIG. Matches -GSUB_WORD_ORDER.
#ifndef SUB_WORD_BIG
#  define SUB_WORD_BIG 0
#endif

static constexpr int WR_WIDTH     = WR_WIDTH_PARAM;
static constexpr int RD_WIDTH     = RD_WIDTH_PARAM;
static constexpr int DEPTH_NARROW = DEPTH_NARROW_PARAM;
static constexpr int NARROW       = (WR_WIDTH < RD_WIDTH) ? WR_WIDTH : RD_WIDTH;
static constexpr int RATIO        = ((WR_WIDTH > RD_WIDTH) ? WR_WIDTH : RD_WIDTH) / NARROW;
static constexpr int WR_BEATS     = WR_WIDTH / NARROW;
static constexpr int RD_BEATS     = RD_WIDTH / NARROW;
static constexpr int AF_TH        = DEPTH_NARROW - 2;
static constexpr int AE_TH        = 2;
static constexpr uint64_t NARROW_MASK =
    (NARROW >= 64) ? ~0ull : ((1ull << NARROW) - 1ull);
static constexpr uint64_t WR_MASK =
    (WR_WIDTH >= 64) ? ~0ull : ((1ull << WR_WIDTH) - 1ull);

static Vsync_fifo_width *dut      = nullptr;
static VerilatedVcdC    *tfp      = nullptr;
static uint64_t          sim_time = 0;
static int               total_errors = 0;

// Golden model: narrow words in FIFO (oldest at front).
static std::deque<uint64_t> gold_q;

// Registered-read pending check.
static bool     pending_valid = false;
static uint64_t pending_expected = 0;   // expected packed RD_WIDTH word

// Map beat i -> bit-slice position within that side's word (mirror of RTL
// sub_index(i, beats)): reversal is over THAT side's beat count.
static inline int sub_index(int i, int beats) {
    return SUB_WORD_BIG ? (beats - 1 - i) : i;
}

static int free_beats() { return DEPTH_NARROW - (int)gold_q.size(); }
static bool g_wr_full()  { return free_beats() < WR_BEATS; }
static bool g_rd_empty() { return (int)gold_q.size() < RD_BEATS; }

static void tick(const char *ctx) {
    // Mask wr_data to WR_WIDTH at the drive point (Verilator won't truncate).
    dut->wr_data &= WR_MASK;

    bool do_write = dut->wr_en && !g_wr_full();
    bool do_read  = dut->rd_en && !g_rd_empty();

    // Golden write: unpack the wide word into WR_BEATS narrow chunks, in the
    // same sub-order the DUT uses, and push them.
    if (do_write) {
        uint64_t wd = (uint64_t)dut->wr_data & WR_MASK;
        // Mirror the RTL exactly: FIFO sub-position s (pushed oldest-first) holds
        // wr_data[sub_index(s)*NARROW +: NARROW]. (RTL: mem[waddr+s] <=
        // wr_data[sub_index(s)*NARROW +: NARROW].)
        for (int s = 0; s < WR_BEATS; s++) {
            uint64_t chunk = (wd >> (sub_index(s, WR_BEATS) * NARROW)) & NARROW_MASK;
#ifdef INJECT_FAULT
            static int fc = 0;
            if (++fc % 5 == 0) chunk ^= NARROW_MASK;
#endif
            gold_q.push_back(chunk);
        }
    }

    // Golden read: pop RD_BEATS narrow chunks and repack into the expected word.
    if (do_read) {
        uint64_t packed = 0;
        // Mirror the RTL exactly: the s-th popped narrow word (oldest-first)
        // lands at rd_data[sub_index(s)*NARROW +: NARROW].
        for (int s = 0; s < RD_BEATS; s++) {
            uint64_t chunk = gold_q.front(); gold_q.pop_front();
            packed |= (chunk & NARROW_MASK) << (sub_index(s, RD_BEATS) * NARROW);
        }
        pending_valid = true;
        pending_expected = packed;
    }

    // Posedge.
    dut->clk = 1; dut->eval();
    if (tfp) tfp->dump(sim_time++);

    // Post-edge consistency.
    uint32_t cnt = (uint32_t)dut->count;
    if (cnt != (uint32_t)gold_q.size()) {
        printf("  [FAIL] %s: count=%u expected=%zu\n", ctx, cnt, gold_q.size());
        total_errors++;
    }
    if ((bool)dut->wr_full != g_wr_full()) {
        printf("  [FAIL] %s: wr_full=%d expected=%d (cnt=%u)\n",
               ctx, (int)dut->wr_full, g_wr_full(), cnt);
        total_errors++;
    }
    if ((bool)dut->rd_empty != g_rd_empty()) {
        printf("  [FAIL] %s: rd_empty=%d expected=%d (cnt=%u)\n",
               ctx, (int)dut->rd_empty, g_rd_empty(), cnt);
        total_errors++;
    }
    if ((bool)dut->wr_almost_full != (cnt >= (uint32_t)AF_TH)) {
        printf("  [FAIL] %s: wr_almost_full wrong at cnt=%u\n", ctx, cnt); total_errors++;
    }
    if ((bool)dut->rd_almost_empty != (cnt <= (uint32_t)AE_TH)) {
        printf("  [FAIL] %s: rd_almost_empty wrong at cnt=%u\n", ctx, cnt); total_errors++;
    }
    if (pending_valid) {
        uint64_t got = (uint64_t)dut->rd_data;
        // rd_data is RD_WIDTH bits; mask for comparison.
        uint64_t rdmask = (RD_WIDTH >= 64) ? ~0ull : ((1ull << RD_WIDTH) - 1ull);
        if ((got & rdmask) != (pending_expected & rdmask)) {
            printf("  [FAIL] %s: rd_data=0x%llx expected=0x%llx\n", ctx,
                   (unsigned long long)(got & rdmask),
                   (unsigned long long)(pending_expected & rdmask));
            total_errors++;
        }
        pending_valid = false;
    }

    // Negedge.
    dut->clk = 0; dut->eval();
    if (tfp) tfp->dump(sim_time++);
}

static void do_reset(int cycles = 4) {
    dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->clk = 0; dut->eval();
    gold_q.clear();
    pending_valid = false;
    for (int i = 0; i < cycles; i++) {
        dut->clk = 1; dut->eval(); if (tfp) tfp->dump(sim_time++);
        dut->clk = 0; dut->eval(); if (tfp) tfp->dump(sim_time++);
    }
    dut->rst_n = 1;
}

static void test_reset() {
    int pre = total_errors;
    printf("[TEST 1] Reset (WR=%d RD=%d NARROW=%d RATIO=%d ORDER=%s)...\n",
           WR_WIDTH, RD_WIDTH, NARROW, RATIO, SUB_WORD_BIG ? "BIG" : "LITTLE");
    do_reset(4);
    dut->wr_en = 0; dut->rd_en = 0; tick("reset_check");
    if (!dut->rd_empty) { printf("  [FAIL] not empty after reset\n"); total_errors++; }
    if ( dut->wr_full)  { printf("  [FAIL] full after reset\n");      total_errors++; }
    if ( dut->count)    { printf("  [FAIL] count!=0 after reset\n");  total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// Fill then drain: write distinct wide words, read them back, scoreboard checks
// the unpacked/repacked narrow stream matches in order.
static void test_fill_drain() {
    int pre = total_errors;
    printf("[TEST 2] Fill then drain (width crossing, ordered)...\n");
    do_reset(4);
    // Write until full.
    uint64_t wv = 1;
    for (int i = 0; i < DEPTH_NARROW + 8; i++) {
        dut->wr_en = 1; dut->rd_en = 0;
        dut->wr_data = (wv * 0x9E3779B1ull) & WR_MASK;  // varied payloads
        wv++;
        tick("fill");
    }
    dut->wr_en = 0; tick("fill_settle");
    // Drain fully.
    for (int i = 0; i < DEPTH_NARROW + 8; i++) {
        dut->wr_en = 0; dut->rd_en = 1; tick("drain");
    }
    dut->rd_en = 0; tick("drain_settle");
    if (!dut->rd_empty) { printf("  [FAIL] not empty after drain\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// Constrained-random read+write, 20k cycles.
static void test_random() {
    int pre = total_errors;
    printf("[TEST 3] Random R+W 20k cycles...\n");
    do_reset(4);
    uint32_t lfsr = 0xC0FFEE;
    auto next = [&]() { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xD0000001u); return lfsr; };
    for (int c = 0; c < 20000; c++) {
        uint32_t r = next();
        dut->wr_en = (r >> 0) & 1;
        dut->rd_en = (r >> 1) & 1;
        dut->wr_data = (((uint64_t)next() << 32) | next()) & WR_MASK;
        tick("rand");
    }
    dut->wr_en = 0; dut->rd_en = 0; tick("settle");
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// Boundary: hammer writes while full, then reads while empty — both ignored.
static void test_boundaries() {
    int pre = total_errors;
    printf("[TEST 4] Full/empty boundary hammer...\n");
    do_reset(4);
    uint64_t wv = 0x55;
    // Fill to full.
    for (int i = 0; i < DEPTH_NARROW; i++) { dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = wv++; tick("bf"); }
    // Hammer writes while full.
    for (int i = 0; i < 100; i++) { dut->wr_en = 1; dut->rd_en = 0; dut->wr_data = wv++; tick("hammer_full"); }
    // Drain to empty.
    dut->wr_en = 0;
    for (int i = 0; i < DEPTH_NARROW + 4; i++) { dut->rd_en = 1; tick("be"); }
    // Hammer reads while empty.
    for (int i = 0; i < 100; i++) { dut->rd_en = 1; dut->wr_en = 0; tick("hammer_empty"); }
    dut->rd_en = 0; tick("settle");
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    dut = new Vsync_fifo_width;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    mkdir("docs", 0755);
    mkdir("docs/waveforms", 0755);
    tfp->open("docs/waveforms/sim_waves_width.vcd");

    printf("=== sync_fifo_width TB  WR=%d RD=%d DEPTH_NARROW=%d ORDER=%s ===\n",
           WR_WIDTH, RD_WIDTH, DEPTH_NARROW, SUB_WORD_BIG ? "BIG" : "LITTLE");
#ifdef INJECT_FAULT
    printf("  *** FAULT INJECTION ENABLED — scoreboard should report errors ***\n");
#endif

    dut->clk = 0; dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->eval();

    test_reset();
    test_fill_drain();
    test_random();
    test_boundaries();

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
