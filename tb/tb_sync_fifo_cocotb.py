#!/usr/bin/env python3
# =============================================================================
# File        : tb_sync_fifo_cocotb.py
# Description : cocotb (Python) testbench for sync_fifo.sv, complementary to the
#               C++/Verilator scoreboard in tb_sync_fifo.cpp. Drives the DUT from
#               Python with a collections.deque golden model and validates every
#               popped word, plus count/empty/full each cycle.
#
#               This exists to show the *industry-standard* open-source Python
#               verification flow (cocotb + Verilator) alongside the hand-rolled
#               C++ harness — same DUT, two independent checkers in two languages.
#
# Run         : make sim-cocotb            (DEPTH=8  DATA_WIDTH=8 by default)
#               make sim-cocotb DEPTH=16 DATA_WIDTH=32
#
# How it runs : cocotb 2.x bundled in OSS CAD Suite. This file is BOTH the test
#               module (the @cocotb.test() coroutines) AND its own runner: when
#               executed as `python3 tb_sync_fifo_cocotb.py` it builds the DUT
#               with Verilator and runs the tests via cocotb_tools.runner. The
#               Makefile target just calls it with env-var DEPTH/DATA_WIDTH.
#
# Registered-read latency (mirrors the C++ TB exactly):
#   sync_fifo has a REGISTERED read port — when rd_en && !empty at edge T, the
#   popped word appears on rd_data at edge T+1. The checker therefore pops the
#   golden value at T and compares it against rd_data sampled one cycle later.
# =============================================================================

import os
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# DEPTH / DATA_WIDTH are baked into the DUT at build time; the test reads the
# same values from the environment so the golden model and stimulus agree.
DEPTH = int(os.environ.get("FIFO_DEPTH", "8"))
DATA_WIDTH = int(os.environ.get("FIFO_DATA_WIDTH", "8"))
DATA_MASK = (1 << DATA_WIDTH) - 1
ALMOST_FULL_TH = DEPTH - 2
ALMOST_EMPTY_TH = 2


class Scoreboard:
    """std::queue-style golden model + per-cycle consistency checks.

    Usage each cycle: BEFORE the clock edge call sample() with the inputs the
    DUT will qualify against this edge; AFTER the edge call check() to compare
    count/empty/full and any pending registered-read result.
    """

    def __init__(self, dut):
        self.dut = dut
        self.q: deque[int] = deque()
        self.pending_valid = False
        self.pending_expected = 0
        self.errors = 0

    def reset(self):
        self.q.clear()
        self.pending_valid = False

    def sample(self, full_now: bool, empty_now: bool):
        """Advance the golden model on the accepted ops for THIS edge, using the
        combinational flags captured before the edge (the state the inputs are
        qualified against)."""
        wr_en = int(self.dut.wr_en.value)
        rd_en = int(self.dut.rd_en.value)
        do_write = wr_en and not full_now
        do_read = rd_en and not empty_now

        if do_write:
            # wr_data is driven masked (see drive_inputs); match it in the model.
            self.q.append(int(self.dut.wr_data.value) & DATA_MASK)
        if do_read:
            # Registered read: schedule the rd_data check for the NEXT edge.
            self.pending_valid = True
            self.pending_expected = self.q.popleft()

    def check(self, ctx: str):
        dcnt = int(self.dut.count.value)
        qs = len(self.q)
        if dcnt != qs:
            self.dut._log.error(f"[{ctx}] count mismatch: DUT={dcnt} GOLD={qs}")
            self.errors += 1

        dut_empty = bool(int(self.dut.empty.value))
        dut_full = bool(int(self.dut.full.value))
        if dut_empty != (qs == 0):
            self.dut._log.error(f"[{ctx}] empty mismatch: DUT={dut_empty} GOLD={qs==0}")
            self.errors += 1
        if dut_full != (qs == DEPTH):
            self.dut._log.error(f"[{ctx}] full mismatch: DUT={dut_full} GOLD={qs==DEPTH}")
            self.errors += 1

        # almost_full / almost_empty track count combinationally.
        exp_af = dcnt >= ALMOST_FULL_TH
        exp_ae = dcnt <= ALMOST_EMPTY_TH
        if bool(int(self.dut.almost_full.value)) != exp_af:
            self.dut._log.error(f"[{ctx}] almost_full mismatch at count={dcnt}")
            self.errors += 1
        if bool(int(self.dut.almost_empty.value)) != exp_ae:
            self.dut._log.error(f"[{ctx}] almost_empty mismatch at count={dcnt}")
            self.errors += 1

        if self.pending_valid:
            got = int(self.dut.rd_data.value) & DATA_MASK
            if got != self.pending_expected:
                self.dut._log.error(
                    f"[{ctx}] rd_data mismatch: got={got:#x} "
                    f"expected={self.pending_expected:#x}"
                )
                self.errors += 1
            self.pending_valid = False


def drive_inputs(dut, wr_en: int, rd_en: int, wr_data: int = 0):
    dut.wr_en.value = wr_en
    dut.rd_en.value = rd_en
    # Mask to DATA_WIDTH: Verilator does not truncate narrow inputs, so the TB
    # must (same reason the C++ TB masks at the drive point).
    dut.wr_data.value = wr_data & DATA_MASK


async def tick(dut, sb: Scoreboard, ctx: str):
    """One full clock cycle with golden-model sample (pre-edge) + check (post)."""
    full_now = bool(int(dut.full.value))
    empty_now = bool(int(dut.empty.value))
    sb.sample(full_now, empty_now)
    await RisingEdge(dut.clk)
    sb.check(ctx)


async def reset(dut, sb: Scoreboard, cycles: int = 4):
    dut.rst_n.value = 0
    drive_inputs(dut, 0, 0, 0)
    sb.reset()
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _start(dut):
    """Common bring-up: start the clock and return a fresh scoreboard."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    drive_inputs(dut, 0, 0, 0)
    sb = Scoreboard(dut)
    await reset(dut, sb)
    return sb


# -----------------------------------------------------------------------------
# TEST 1 — reset clears to empty.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_reset(dut):
    sb = await _start(dut)
    assert int(dut.empty.value) == 1, "empty not set after reset"
    assert int(dut.full.value) == 0, "full set after reset"
    assert int(dut.count.value) == 0, "count nonzero after reset"
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 2 — sequential fill to full.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_sequential_fill(dut):
    sb = await _start(dut)
    for i in range(DEPTH + 4):
        drive_inputs(dut, 1, 0, (i + 1))
        await tick(dut, sb, "fill")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "fill_settle")
    assert int(dut.full.value) == 1, "DUT not full after DEPTH writes"
    assert len(sb.q) == DEPTH
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 3 — fill then sequential drain, order checked every pop.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_sequential_drain(dut):
    sb = await _start(dut)
    for i in range(DEPTH):
        drive_inputs(dut, 1, 0, (i + 1))
        await tick(dut, sb, "drain_prefill")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "drain_settle")
    for _ in range(DEPTH + 4):
        drive_inputs(dut, 0, 1, 0)
        await tick(dut, sb, "drain")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "drain_final")
    assert int(dut.empty.value) == 1, "DUT not empty after draining all"
    assert len(sb.q) == 0
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 4 — constrained-random simultaneous read+write.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_random_rw(dut):
    sb = await _start(dut)
    rng = random.Random(0xACE1)
    for _ in range(5000):
        drive_inputs(dut, rng.randint(0, 1), rng.randint(0, 1), rng.getrandbits(DATA_WIDTH))
        await tick(dut, sb, "random")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "random_settle")
    assert sb.errors == 0, f"{sb.errors} scoreboard errors in random R+W"


# -----------------------------------------------------------------------------
# TEST 5 — almost-full / almost-empty thresholds (checked inside the scoreboard
# every cycle while filling then draining one at a time).
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_thresholds(dut):
    sb = await _start(dut)
    for i in range(DEPTH):
        drive_inputs(dut, 1, 0, i)
        await tick(dut, sb, "thresh_fill")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "thresh_mid")
    for _ in range(DEPTH + 2):
        drive_inputs(dut, 0, 1, 0)
        await tick(dut, sb, "thresh_drain")
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "thresh_settle")
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 6 — back-to-back fill/drain x50 (pointer wrap + ordering across laps).
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_backtoback(dut):
    sb = await _start(dut)
    val = 1
    for _ in range(50):
        for _ in range(DEPTH):
            drive_inputs(dut, 1, 0, val)
            val += 1
            await tick(dut, sb, "b2b_fill")
        drive_inputs(dut, 0, 0, 0)
        await tick(dut, sb, "b2b_settle_fill")
        for _ in range(DEPTH):
            drive_inputs(dut, 0, 1, 0)
            await tick(dut, sb, "b2b_drain")
        drive_inputs(dut, 0, 0, 0)
        await tick(dut, sb, "b2b_settle_drain")
    assert int(dut.empty.value) == 1
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# ANTI-VACUITY — only built when FIFO_INJECT_FAULT=1. Corrupts the golden model
# so the scoreboard MUST report errors; the runner inverts the pass/fail so the
# `make sim-cocotb-fault` target succeeds only if the checker fires (mirrors the
# C++ `make sim-fault` philosophy — proves the Python checker is not vacuous).
# -----------------------------------------------------------------------------
@cocotb.test(skip=os.environ.get("FIFO_INJECT_FAULT") != "1")
async def test_fault_injection_is_caught(dut):
    sb = await _start(dut)
    val = 1
    for _ in range(DEPTH):
        drive_inputs(dut, 1, 0, val)
        val += 1
        await tick(dut, sb, "fault_fill")
    # Corrupt the golden head so the next drained word cannot match rd_data.
    if sb.q:
        sb.q[0] ^= DATA_MASK
    drive_inputs(dut, 0, 0, 0)
    await tick(dut, sb, "fault_settle")
    for _ in range(DEPTH + 2):
        drive_inputs(dut, 0, 1, 0)
        await tick(dut, sb, "fault_drain")
    assert sb.errors > 0, "fault injection NOT caught — Python checker is vacuous!"


# -----------------------------------------------------------------------------
# Self-runner: build the DUT with Verilator and run the tests above.
# -----------------------------------------------------------------------------
def _macos_dylib_shim(tb_dir):
    """OSS CAD Suite's libpython on macOS references libintl via
    @executable_path/../lib; the cocotb-built test executable lives under
    tb/sim_build/, so '../lib' resolves to tb/lib. Symlink that to the suite's
    real lib dir so the test can dlopen Python. No-op on Linux (CI), where ELF
    loading uses rpaths and this whole problem does not exist."""
    import platform
    import sys

    if platform.system() != "Darwin":
        return
    suite_lib = os.path.join(os.path.dirname(os.path.dirname(sys.executable)), "lib")
    link = os.path.join(tb_dir, "lib")
    if os.path.isdir(suite_lib) and not os.path.exists(link):
        try:
            os.symlink(suite_lib, link)
        except OSError:
            pass  # best-effort; the run will surface the real error if it fails


def _run():
    from pathlib import Path
    from cocotb_tools.runner import get_runner

    tb_dir = Path(__file__).resolve().parent
    proj = tb_dir.parent
    depth = int(os.environ.get("FIFO_DEPTH", "8"))
    data_width = int(os.environ.get("FIFO_DATA_WIDTH", "8"))

    _macos_dylib_shim(str(tb_dir))

    runner = get_runner("verilator")
    runner.build(
        verilog_sources=[proj / "rtl" / "sync_fifo.sv"],
        hdl_toplevel="sync_fifo",
        parameters={"DEPTH": depth, "DATA_WIDTH": data_width},
        build_args=["-Wall", "--trace"],
        always=True,
    )
    runner.test(
        hdl_toplevel="sync_fifo",
        test_module="tb_sync_fifo_cocotb",
    )


if __name__ == "__main__":
    _run()
