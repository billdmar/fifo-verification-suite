// =============================================================================
// File        : tb_sync_fifo_ecc.cpp
// Description : Verilator C++ testbench for the SECDED-protected FIFO
//               sync_fifo_ecc.sv. Validates the CLEAN (no-error) datapath: data
//               written → encoded → stored → decoded → read back must equal the
//               golden std::queue model every cycle, with single_err/double_err
//               both quiescent (no spurious flags when no error is injected).
//
//               Error-correction/detection itself is proven EXHAUSTIVELY by the
//               formal gate (sync_fifo_ecc_bmc.sby injects an $anyconst error and
//               proves correct/detect over every position) — far stronger than a
//               handful of simulated bit-flips, and it needs no error-injection
//               port in the synth design. This TB therefore owns the complementary
//               job: the encode/decode round-trip is lossless and the flags stay
//               low on a clean memory.
//
// Build (via Makefile): make sim-ecc DEPTH=8
//
// Fault injection (-DINJECT_FAULT): corrupts the golden model so the scoreboard
// MUST report a mismatch (anti-vacuity — proves the checker isn't asleep).
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <queue>
#include <sys/stat.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vsync_fifo_ecc.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 8
#endif
static constexpr int DEPTH = DEPTH_PARAM;
static constexpr uint64_t DMASK = 0xFF;   // DATA_WIDTH fixed at 8

static Vsync_fifo_ecc *dut = nullptr;
static VerilatedVcdC  *tfp = nullptr;
static uint64_t        sim_time = 0;
static int             total_errors = 0;
static std::queue<uint64_t> gold_q;

static bool     pending_valid = false;
static uint64_t pending_expected = 0;

static void tick(const char *ctx) {
    dut->wr_data &= DMASK;
    bool do_write = dut->wr_en && !dut->full;
    bool do_read  = dut->rd_en && !dut->empty;

    if (do_write) {
        uint64_t w = (uint64_t)dut->wr_data & DMASK;
#ifdef INJECT_FAULT
        static int fc = 0;
        if (++fc % 4 == 0) w ^= 0x55;   // corrupt golden — scoreboard must catch
#endif
        gold_q.push(w);
    }
    if (do_read) {
        pending_valid = true;
        pending_expected = gold_q.front();
        gold_q.pop();
    }

    dut->clk = 1; dut->eval();
    if (tfp) tfp->dump(sim_time++);

    // count/empty/full consistency.
    uint32_t qs = (uint32_t)gold_q.size();
    if ((uint32_t)dut->count != qs) { printf("  [FAIL] %s: count=%u exp=%u\n", ctx,(uint32_t)dut->count,qs); total_errors++; }
    if ((bool)dut->empty != (qs==0)) { printf("  [FAIL] %s: empty mismatch\n", ctx); total_errors++; }
    if ((bool)dut->full  != (qs==(uint32_t)DEPTH)) { printf("  [FAIL] %s: full mismatch\n", ctx); total_errors++; }

    // Clean-path read check + flag quiescence.
    if (pending_valid) {
        uint64_t got = (uint64_t)dut->rd_data & DMASK;
        if (got != pending_expected) {
            printf("  [FAIL] %s: rd_data=0x%llx expected=0x%llx\n", ctx,
                   (unsigned long long)got, (unsigned long long)pending_expected);
            total_errors++;
        }
        if (dut->single_err || dut->double_err) {
            printf("  [FAIL] %s: spurious ECC flag on clean read (single=%d double=%d)\n",
                   ctx, (int)dut->single_err, (int)dut->double_err);
            total_errors++;
        }
        pending_valid = false;
    }

    dut->clk = 0; dut->eval();
    if (tfp) tfp->dump(sim_time++);
}

static void do_reset(int cycles = 4) {
    dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->clk = 0; dut->eval();
    while (!gold_q.empty()) gold_q.pop();
    pending_valid = false;
    for (int i = 0; i < cycles; i++) tick("reset");
    dut->rst_n = 1;
}

// TEST 1 — reset clears to empty, flags low.
static void test_reset() {
    int pre = total_errors;
    printf("[TEST 1] Reset...\n");
    do_reset(4);
    dut->wr_en = 0; dut->rd_en = 0; tick("reset_chk");
    if (!dut->empty) { printf("  [FAIL] not empty after reset\n"); total_errors++; }
    if (dut->single_err || dut->double_err) { printf("  [FAIL] flags set after reset\n"); total_errors++; }
    printf("  -> %s\n", total_errors==pre?"PASS":"FAIL");
}

// TEST 2 — fill then drain, every encoded/decoded word matches the golden model.
static void test_fill_drain() {
    int pre = total_errors;
    printf("[TEST 2] Fill + drain (encode/decode round-trip)...\n");
    do_reset(4);
    for (int i = 0; i < DEPTH; i++) { dut->wr_en=1; dut->rd_en=0; dut->wr_data=(uint8_t)(i*37+1); tick("fill"); }
    dut->wr_en=0; tick("settle");
    for (int i = 0; i < DEPTH+4; i++) { dut->rd_en=1; dut->wr_en=0; tick("drain"); }
    dut->rd_en=0; tick("final");
    if (!dut->empty) { printf("  [FAIL] not empty after drain\n"); total_errors++; }
    printf("  -> %s\n", total_errors==pre?"PASS":"FAIL");
}

// TEST 3 — constrained-random R+W (every 8-bit value exercised across the run).
static void test_random() {
    int pre = total_errors;
    printf("[TEST 3] Random R+W 20k cycles (all-values encode/decode)...\n");
    do_reset(4);
    uint32_t lfsr = 0xBEEF;
    auto nxt=[&](){ lfsr=(lfsr>>1)^(-(lfsr&1u)&0xB400u); return lfsr; };
    for (int c=0;c<20000;c++){
        uint32_t r=nxt();
        dut->wr_en=(r>>0)&1; dut->rd_en=(r>>1)&1; dut->wr_data=(uint8_t)((r>>2)&0xFF);
        tick("rand");
    }
    dut->wr_en=0; dut->rd_en=0; tick("settle");
    printf("  -> %s\n", total_errors==pre?"PASS":"FAIL");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    dut = new Vsync_fifo_ecc;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    mkdir("docs", 0755); mkdir("docs/waveforms", 0755);
    tfp->open("docs/waveforms/sim_waves_ecc.vcd");

    printf("=== sync_fifo_ecc TB  DEPTH=%d  DATA_WIDTH=8 (SECDED 13,8) ===\n", DEPTH);
#ifdef INJECT_FAULT
    printf("  *** FAULT INJECTION ENABLED — scoreboard should report errors ***\n");
#endif
    dut->clk=0; dut->rst_n=0; dut->wr_en=0; dut->rd_en=0; dut->wr_data=0; dut->eval();

    test_reset();
    test_fill_drain();
    test_random();

    dut->wr_en=0; dut->rd_en=0; for (int i=0;i<4;i++) tick("end");

    tfp->close(); dut->final(); delete dut;
    printf("\n%s\n", total_errors==0 ? "=== SIM RESULT: PASS (0 errors) ===" : "=== SIM RESULT: FAIL ===");
    return total_errors>0 ? 1 : 0;
}
