// =============================================================================
// File        : perf_sync_fifo_ecc.cpp
// Description : Throughput / latency characterization harness for sync_fifo_ecc.
//               Same methodology as perf_sync_fifo.cpp but adapted for the
//               SECDED ECC FIFO: DATA_WIDTH is effectively 8 (hardcoded 8-bit
//               data words → 13-bit codewords). Measures throughput under
//               offered-rate profiles, verifies that the ECC encode/decode layer
//               is transparent (no throughput penalty on the clean path), and
//               confirms data integrity (all reads return the expected written
//               values).
//
// Build/run : make perf-report-ecc  (drives this for a range of DEPTHs and
//             prints a table; see scripts/perf_report.sh).
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
#include "Vsync_fifo_ecc.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 16
#endif
static constexpr int DEPTH = DEPTH_PARAM;

static Vsync_fifo_ecc *dut = nullptr;

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

// Measure read latency by OBSERVATION (same as sync_fifo — registered read):
// push one known word into an empty FIFO, assert rd_en, and count clock edges
// until rd_data actually equals that word. For the ECC FIFO (registered output
// with encode/decode), this should resolve to 1 cycle — the ECC decode is
// combinational on the read path and does not add an extra pipeline stage.
// Returns -1 if the word never appears within a bounded window (defensive).
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

// Verify ECC transparency on the clean path: write N known values, then read
// them all back and confirm every value matches. On a clean memory (no injected
// bit errors), the SECDED encode/decode must be perfectly lossless — this is
// the throughput-neutral integrity check.
static int verify_ecc_transparency(int n) {
    reset();
    int errors = 0;
    // Phase 1: fill N words.
    for (int i = 0; i < n; i++) {
        dut->wr_en = 1; dut->wr_data = (uint8_t)(i + 1); dut->rd_en = 0;
        step();
    }
    dut->wr_en = 0;
    // Phase 2: drain N words and verify.
    for (int i = 0; i < n; i++) {
        dut->rd_en = 1;
        step();
        uint8_t expected = (uint8_t)(i + 1);
        uint8_t got = (uint8_t)dut->rd_data;
        if (got != expected) {
            fprintf(stderr, "  ECC transparency FAIL: word[%d] expected 0x%02X got 0x%02X\n", i, expected, got);
            errors++;
        }
        // single_err and double_err must be quiescent on a clean path
        if (dut->single_err) {
            fprintf(stderr, "  ECC transparency FAIL: spurious single_err on word[%d]\n", i);
            errors++;
        }
        if (dut->double_err) {
            fprintf(stderr, "  ECC transparency FAIL: spurious double_err on word[%d]\n", i);
            errors++;
        }
    }
    dut->rd_en = 0;
    return errors;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsync_fifo_ecc;
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

    printf("# sync_fifo_ecc throughput (DEPTH=%d, %d cycles/profile, cycle-accurate)\n", DEPTH, CYCLES);
    printf("# %-22s %12s  %12s\n", "profile (wr%/rd%)", "thru(beat/cyc)", "expected~");
    for (auto &p : profs) {
        uint64_t d = run_profile(p.wr, p.rd, CYCLES);
        double thru = (double)d / CYCLES;
        double expect = (p.wr < p.rd ? p.wr : p.rd) / 100.0;   // min(rates)
        printf("  %-22s %12.3f  %12.3f\n", p.name, thru, expect);
    }
    printf("# read latency (registered-output + ECC decode, measured): %d cycle\n", measure_latency());

    // ECC transparency verification: fill to DEPTH, read back, check all match.
    int fill_count = (DEPTH < 256) ? DEPTH : 256;
    int ecc_errors = verify_ecc_transparency(fill_count);
    printf("# ECC clean-path transparency: %d words verified, %d errors\n", fill_count, ecc_errors);

    dut->final();
    delete dut;
    return (ecc_errors > 0) ? 1 : 0;
}
