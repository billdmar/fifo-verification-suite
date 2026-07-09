// =============================================================================
// File        : perf_sync_fifo_fwft.cpp
// Description : Throughput / latency characterization harness for sync_fifo_fwft.
//               Same methodology as perf_sync_fifo.cpp but adapted for the FWFT
//               (show-ahead) read semantics: rd_data is COMBINATIONAL — the head
//               word is visible on rd_data the same cycle the FIFO becomes
//               non-empty, BEFORE rd_en is asserted.  rd_en acts as acknowledge /
//               pop.  Latency measurement should confirm 0 cycles (data visible
//               without waiting an extra edge).
//
// Build/run : make perf-report-fwft  (drives this for a range of DEPTHs and prints
//             a table; see scripts/perf_report.sh).
//
// Profiles (producer offered-rate x consumer ready-rate, as percentages):
//   the harness sweeps a small matrix and reports the steady-state throughput,
//   which is min(producer_rate, consumer_rate) once the FIFO reaches its regime
//   — a textbook result the numbers should confirm.
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "verilated.h"
#include "Vsync_fifo_fwft.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 16
#endif
static constexpr int DEPTH = DEPTH_PARAM;

static Vsync_fifo_fwft *dut = nullptr;

// A cheap deterministic PRNG so the profiles are reproducible (no <random> dep).
static uint32_t lfsr = 0xACE1u;
static inline uint32_t rnd() { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u); return lfsr; }
static inline bool chance(int pct) { return (int)(rnd() % 100) < pct; }

static void step() {
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
}

static void reset() {
    dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->clk = 0; dut->eval();
    for (int i = 0; i < 4; i++) step();
    dut->rst_n = 1;
}

// Run `cycles` cycles offering writes at wr_pct and reads at rd_pct; return the
// number of beats actually accepted (read-accepted) — the delivered throughput.
// For FWFT, a read is accepted when rd_en && valid (== !empty). The data is
// already visible on rd_data combinationally.
static uint64_t run_profile(int wr_pct, int rd_pct, int cycles) {
    reset();
    uint64_t delivered = 0;
    uint8_t  v = 1;
    for (int c = 0; c < cycles; c++) {
        dut->wr_en  = chance(wr_pct) ? 1 : 0;
        dut->wr_data = v++;
        dut->rd_en  = chance(rd_pct) ? 1 : 0;
        // A read is accepted this cycle iff rd_en && valid (!empty) — for FWFT
        // the data is already on rd_data combinationally (no extra cycle needed).
        bool rd_ok = dut->rd_en && dut->valid;
        step();
        if (rd_ok) delivered++;
    }
    return delivered;
}

// Measure read latency by OBSERVATION for the FWFT variant:
// Push one known word into an empty FIFO, then check rd_data IMMEDIATELY
// (before any further clock edge). In a true show-ahead/FWFT design, the data
// appears combinationally the same cycle the write makes the FIFO non-empty —
// so the measured latency should be 0 cycles (no additional edge needed).
// Returns -1 if the word never appears within a bounded window (defensive).
static int measure_latency() {
    reset();
    const uint8_t W = 0xA5;
    // Push exactly one word.
    dut->wr_en = 1; dut->wr_data = W; dut->rd_en = 0;
    step();
    dut->wr_en = 0;
    // After the write edge, the FIFO is non-empty. For FWFT, rd_data should
    // already reflect the head word COMBINATIONALLY (no rd_en needed yet).
    // Evaluate combinational outputs without a clock edge.
    dut->eval();
    if (dut->valid && (uint8_t)dut->rd_data == W) {
        return 0;  // 0-cycle latency confirmed: data visible immediately
    }
    // Fallback: check across a few edges (should not be needed for a correct FWFT)
    dut->rd_en = 0;
    for (int cyc = 1; cyc <= 8; cyc++) {
        step();
        dut->eval();
        if (dut->valid && (uint8_t)dut->rd_data == W) { return cyc; }
    }
    return -1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsync_fifo_fwft;
    dut->clk = 0; dut->rst_n = 0; dut->wr_en = 0; dut->rd_en = 0; dut->wr_data = 0;
    dut->eval();

    const int CYCLES = 50000;
    struct Prof { const char *name; int wr; int rd; };
    Prof profs[] = {
        { "balanced 100/100",      100, 100 },
        { "balanced  50/ 50",       50,  50 },
        { "write-bound 100/ 50",   100,  50 },
        { "read-bound   50/100",    50, 100 },
        { "bursty       75/ 75",    75,  75 },
    };

    printf("# sync_fifo_fwft throughput (DEPTH=%d, %d cycles/profile, cycle-accurate)\n", DEPTH, CYCLES);
    printf("# %-22s %12s  %12s\n", "profile (wr%/rd%)", "thru(beat/cyc)", "expected~");
    for (auto &p : profs) {
        uint64_t d = run_profile(p.wr, p.rd, CYCLES);
        double thru = (double)d / CYCLES;
        double expect = (p.wr < p.rd ? p.wr : p.rd) / 100.0;   // min(rates)
        printf("  %-22s %12.3f  %12.3f\n", p.name, thru, expect);
    }
    printf("# read latency (show-ahead/FWFT, measured): %d cycle\n", measure_latency());

    dut->final();
    delete dut;
    return 0;
}
