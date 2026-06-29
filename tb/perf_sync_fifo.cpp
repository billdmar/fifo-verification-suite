// =============================================================================
// File        : perf_sync_fifo.cpp
// Description : Throughput / latency characterization harness for sync_fifo.
//               Drives the FIFO under several producer/consumer offered-rate
//               profiles and reports sustained throughput (accepted beats per
//               cycle) and average first-word read latency. Cycle-accurate
//               (Verilator), so these are RTL-cycle figures — NOT gate-level
//               timing (FPGA Fmax lives in docs/fpga_results.md).
//
// Build/run : make perf-report  (drives this for a range of DEPTHs and prints a
//             table; see scripts/perf_report.sh).
//
// Profiles (producer offered-rate × consumer ready-rate, as percentages):
//   the harness sweeps a small matrix and reports the steady-state throughput,
//   which is min(producer_rate, consumer_rate) once the FIFO reaches its regime
//   — a textbook result the numbers should confirm.
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "verilated.h"
#include "Vsync_fifo.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 16
#endif
static constexpr int DEPTH = DEPTH_PARAM;

static Vsync_fifo *dut = nullptr;

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
static uint64_t run_profile(int wr_pct, int rd_pct, int cycles) {
    reset();
    uint64_t delivered = 0;
    uint8_t  v = 1;
    for (int c = 0; c < cycles; c++) {
        dut->wr_en  = chance(wr_pct) ? 1 : 0;
        dut->wr_data = v++;
        dut->rd_en  = chance(rd_pct) ? 1 : 0;
        // A read is accepted this cycle iff rd_en && !empty (pre-edge).
        bool rd_ok = dut->rd_en && !dut->empty;
        step();
        if (rd_ok) delivered++;
    }
    return delivered;
}

// Measure read latency by OBSERVATION (not a hardcoded constant): push one known
// word into an empty FIFO, assert rd_en, and count clock edges until rd_data
// actually equals that word. For the registered-read sync_fifo this resolves to
// 1; measuring it (rather than asserting it) keeps the number honest and would
// catch a latency regression. Returns -1 if the word never appears within a
// bounded window (defensive).
static int measure_latency() {
    reset();
    const uint8_t W = 0xA5;
    // Push exactly one word.
    dut->wr_en = 1; dut->wr_data = W; dut->rd_en = 0; step();
    dut->wr_en = 0;
    // Assert rd_en and count edges until rd_data reflects the popped word.
    dut->rd_en = 1;
    for (int cyc = 1; cyc <= 8; cyc++) {
        step();
        if ((uint8_t)dut->rd_data == W) { dut->rd_en = 0; return cyc; }
    }
    dut->rd_en = 0;
    return -1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsync_fifo;
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

    printf("# sync_fifo throughput (DEPTH=%d, %d cycles/profile, cycle-accurate)\n", DEPTH, CYCLES);
    printf("# %-22s %12s  %12s\n", "profile (wr%/rd%)", "thru(beat/cyc)", "expected~");
    for (auto &p : profs) {
        uint64_t d = run_profile(p.wr, p.rd, CYCLES);
        double thru = (double)d / CYCLES;
        double expect = (p.wr < p.rd ? p.wr : p.rd) / 100.0;   // min(rates)
        printf("  %-22s %12.3f  %12.3f\n", p.name, thru, expect);
    }
    printf("# read latency (registered-output, measured): %d cycle\n", measure_latency());

    dut->final();
    delete dut;
    return 0;
}
