// =============================================================================
// File        : tb_axis_pkt_fifo.cpp
// Description : Verilator C++ testbench + golden-reference scoreboard for the
//               STORE-AND-FORWARD packet FIFO axis_pkt_fifo.sv. The golden model
//               is packet-aware: a packet's beats become deliverable only once
//               its TLAST has been pushed (mirroring the DUT commit pointer). It
//               validates the delivered {tdata,tlast} stream in order and the
//               pkt_count output every cycle.
//
// Build (via Makefile): make sim-pktfifo DEPTH=8 DATA_WIDTH=8
//
// Robust driving: the scoreboard keys off the DUT's OWN handshake signals
// (s_axis_tvalid && s_axis_tready ; m_axis_tvalid && m_axis_tready) sampled
// before each edge — never a predicted/golden full() — so the model can never
// desync from the DUT. tick() returns whether the offered slave beat was
// accepted, and callers advance their stimulus only on a real accept.
//
// Store-and-forward modeling:
//   inflight[] : beats of the packet currently being written (NOT deliverable).
//   expected[] : committed beats in delivery order (a whole packet migrates here
//                when its TLAST is pushed). The DUT must never deliver a beat not
//                at the front of expected[] — i.e. no beat released before its
//                packet's TLAST landed.
//   committed_pkts / delivered_pkts give the expected pkt_count.
//
// Fault injection (-DINJECT_FAULT): corrupts an occasional pushed beat so the
// scoreboard MUST report a mismatch (anti-vacuity).
// =============================================================================

#include <cstdint>
#include <cstdio>
#include <deque>
#include <sys/stat.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vaxis_pkt_fifo.h"

#ifndef DEPTH_PARAM
#  define DEPTH_PARAM 8
#endif
#ifndef DW_PARAM
#  define DW_PARAM 8
#endif

static constexpr int      DEPTH      = DEPTH_PARAM;
static constexpr int      DATA_WIDTH = DW_PARAM;
static constexpr uint64_t DMASK      =
    (DATA_WIDTH >= 64) ? ~0ull : ((1ull << DATA_WIDTH) - 1ull);

static Vaxis_pkt_fifo *dut      = nullptr;
static VerilatedVcdC  *tfp      = nullptr;
static uint64_t        sim_time = 0;
static int             total_errors = 0;

struct Beat { uint64_t data; bool last; };
static std::deque<Beat> inflight;     // current in-progress packet (uncommitted)
static std::deque<Beat> expected;     // committed beats, in delivery order
static int committed_pkts = 0;        // packets fully written (TLAST pushed)
static int delivered_pkts = 0;        // packets fully delivered (TLAST accepted)

// One clock cycle. Inputs must be driven BEFORE the call. Returns true iff the
// offered slave beat was accepted this cycle (s_axis_tvalid && s_axis_tready).
static bool tick(const char *ctx) {
    dut->s_axis_tdata &= DMASK;

    // Handshakes from the DUT's OWN signals (pre-edge) — the single source of truth.
    bool push       = dut->s_axis_tvalid && dut->s_axis_tready;
    bool out_accept = dut->m_axis_tvalid && dut->m_axis_tready;

    // Golden push, store-and-forward commit on TLAST.
    if (push) {
        uint64_t d = (uint64_t)dut->s_axis_tdata & DMASK;
        bool last  = dut->s_axis_tlast;
#ifdef INJECT_FAULT
        static int fc = 0;
        if (++fc % 7 == 0) d ^= DMASK;
#endif
        inflight.push_back({d, last});
        if (last) {
            for (auto &b : inflight) expected.push_back(b);
            inflight.clear();
            committed_pkts++;
        }
    }

    // Validate a delivered master beat against the committed stream, in order.
    if (out_accept) {
        if (expected.empty()) {
            printf("  [FAIL] %s: master delivered a beat the golden model didn't commit "
                   "(store-and-forward violation)\n", ctx);
            total_errors++;
        } else {
            Beat e = expected.front(); expected.pop_front();
            uint64_t got_d = (uint64_t)dut->m_axis_tdata & DMASK;
            bool     got_l = dut->m_axis_tlast;
            if (got_d != e.data || got_l != e.last) {
                printf("  [FAIL] %s: delivered {0x%llx,%d} expected {0x%llx,%d}\n", ctx,
                       (unsigned long long)got_d, (int)got_l,
                       (unsigned long long)e.data, (int)e.last);
                total_errors++;
            }
            if (got_l) delivered_pkts++;
        }
    }

    // Posedge.
    dut->clk = 1; dut->eval();
    if (tfp) tfp->dump(sim_time++);

    // pkt_count semantics: the DUT decrements its packet count when a packet's
    // TLAST is POPPED into the output skid (rd_pkts on do_pop), which is 1–2
    // cycles BEFORE that beat is accepted on the master port. So the
    // committed-not-yet-delivered figure (committed_pkts − delivered_pkts) is an
    // UPPER bound on dut->pkt_count, and at most one TLAST can sit in the
    // skid/in-flight ahead of acceptance. Check the tight bound:
    //   committed_pkts − delivered_pkts − 1  <=  pkt_count  <=  committed_pkts − delivered_pkts
    int hi = committed_pkts - delivered_pkts;
    int lo = hi - 1; if (lo < 0) lo = 0;
    if ((int)dut->pkt_count > hi || (int)dut->pkt_count < lo) {
        printf("  [FAIL] %s: pkt_count=%d out of expected range [%d,%d]\n",
               ctx, (int)dut->pkt_count, lo, hi);
        total_errors++;
    }

    // Negedge.
    dut->clk = 0; dut->eval();
    if (tfp) tfp->dump(sim_time++);

    return push;
}

static void do_reset(int cycles = 4) {
    dut->rst_n = 0; dut->s_axis_tvalid = 0; dut->s_axis_tdata = 0;
    dut->s_axis_tlast = 0; dut->m_axis_tready = 0;
    dut->clk = 0; dut->eval();
    inflight.clear(); expected.clear();
    committed_pkts = 0; delivered_pkts = 0;
    for (int i = 0; i < cycles; i++) {
        dut->clk = 1; dut->eval(); if (tfp) tfp->dump(sim_time++);
        dut->clk = 0; dut->eval(); if (tfp) tfp->dump(sim_time++);
    }
    dut->rst_n = 1;
}

// Offer one beat until it is accepted (tready high), holding it stable meanwhile
// (AXI requires a master to hold valid+payload until accepted). `ready_out`
// drives m_axis_tready during the wait. Bounded retry guards against any hang.
static void send_beat(uint64_t data, bool last, bool ready_out) {
    dut->s_axis_tvalid = 1; dut->s_axis_tdata = (data & DMASK); dut->s_axis_tlast = last;
    dut->m_axis_tready = ready_out;
    int guard = 0;
    while (!tick("send") && ++guard < 100000) { /* hold stable until accepted */ }
    dut->s_axis_tvalid = 0; dut->s_axis_tlast = 0;
}

static void idle(int cycles, bool ready_out) {
    dut->s_axis_tvalid = 0; dut->s_axis_tlast = 0;
    for (int i = 0; i < cycles; i++) { dut->m_axis_tready = ready_out; tick("idle"); }
}

// -----------------------------------------------------------------------------
// TEST 1 — store-and-forward: a partial packet must NOT be delivered until its
// TLAST is pushed.
// -----------------------------------------------------------------------------
static void test_store_and_forward() {
    int pre = total_errors;
    printf("[TEST 1] Store-and-forward hold-back...\n");
    do_reset(4);
    // Push 3 beats WITHOUT tlast, master ready throughout.
    for (int i = 0; i < 3; i++) send_beat(0x10 + i, false, 1);
    // Nothing committed yet → master must stay idle.
    for (int i = 0; i < 6; i++) {
        idle(1, 1);
        if (dut->m_axis_tvalid) { printf("  [FAIL] delivered before TLAST committed\n"); total_errors++; break; }
    }
    // Close the packet; beats become deliverable and drain (generous margin for
    // the registered-read + skid latency: ~2 cycles/beat at startup).
    send_beat(0x13, true, 1);
    idle(4 * DEPTH + 8, 1);
    if (!expected.empty()) { printf("  [FAIL] not all committed beats delivered\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 2 — back-to-back packets of varied length, master always ready.
// -----------------------------------------------------------------------------
static void test_backtoback_packets() {
    int pre = total_errors;
    printf("[TEST 2] Back-to-back packets...\n");
    do_reset(4);
    uint64_t v = 1;
    for (int pkt = 0; pkt < 30; pkt++) {
        int len = 1 + (pkt % 4);
        if (len > DEPTH) len = DEPTH;
        for (int i = 0; i < len; i++) send_beat(v++, (i == len - 1), 1);
        idle(2, 1);
    }
    idle(DEPTH + 8, 1);
    if (!expected.empty()) { printf("  [FAIL] residual undelivered beats\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

// -----------------------------------------------------------------------------
// TEST 3 — constrained-random packets with random backpressure (10k cycles).
//   Drives via the real handshake (send_beat waits for tready), so no desync.
// -----------------------------------------------------------------------------
static void test_random() {
    int pre = total_errors;
    printf("[TEST 3] Random packets + backpressure 10k cycles...\n");
    do_reset(4);
    uint32_t lfsr = 0x1234;
    auto nxt = [&]() { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u); return lfsr; };
    uint64_t v = 0x80;
    int cyc = 0;
    while (cyc < 10000) {
        uint32_t r = nxt();
        int len = 1 + (int)((r >> 3) % 4);     // packet length 1..4
        // Send a whole packet (each beat waits for tready), with random master
        // backpressure during the sends.
        for (int i = 0; i < len; i++) {
            bool ready = ((nxt() >> 1) & 3) != 0;   // ~75% ready
            send_beat(v++, (i == len - 1), ready);
            cyc++;
        }
        // Random idle gap with random readiness.
        int gap = (int)(r % 4);
        for (int i = 0; i < gap; i++) { idle(1, ((nxt() >> 2) & 1)); cyc++; }
    }
    idle(4 * DEPTH + 16, 1);    // final drain, master ready
    if (!expected.empty()) { printf("  [FAIL] residual undelivered beats after drain\n"); total_errors++; }
    printf("  -> %s\n", total_errors == pre ? "PASS" : "FAIL");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    dut = new Vaxis_pkt_fifo;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    mkdir("docs", 0755); mkdir("docs/waveforms", 0755);
    tfp->open("docs/waveforms/sim_waves_pktfifo.vcd");

    printf("=== axis_pkt_fifo TB  DEPTH=%d DATA_WIDTH=%d ===\n", DEPTH, DATA_WIDTH);
#ifdef INJECT_FAULT
    printf("  *** FAULT INJECTION ENABLED — scoreboard should report errors ***\n");
#endif
    dut->clk = 0; dut->rst_n = 0; dut->s_axis_tvalid = 0; dut->s_axis_tdata = 0;
    dut->s_axis_tlast = 0; dut->m_axis_tready = 0; dut->eval();

    test_store_and_forward();
    test_backtoback_packets();
    test_random();

    dut->s_axis_tvalid = 0; dut->m_axis_tready = 0;
    for (int i = 0; i < 4; i++) tick("end");

    tfp->close(); dut->final(); delete dut;
    printf("\n%s\n", total_errors == 0 ? "=== SIM RESULT: PASS (0 errors) ==="
                                       : "=== SIM RESULT: FAIL ===");
    return total_errors > 0 ? 1 : 0;
}
