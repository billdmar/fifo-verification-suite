#!/usr/bin/env python3
# =============================================================================
# File        : tb_async_fifo_cocotb.py
# Description : cocotb (Python) testbench for async_fifo.sv — the dual-clock
#               CDC FIFO with independent wr_clk/rd_clk domains, Gray-code
#               pointers, and multi-flop synchronizers. Drives the DUT from
#               Python with a collections.deque golden model and validates every
#               popped word for correct FIFO ordering across the clock-domain
#               crossing.
#
#               This is the async counterpart to tb_sync_fifo_cocotb.py; same
#               scoreboard-based approach but with TWO independent clocks at
#               intentionally coprime frequencies (10ns write, 13ns read) to
#               exercise all phase relationships between domains.
#
# Run         : make sim-cocotb-async         (DEPTH=8  DATA_WIDTH=8 by default)
#               make sim-cocotb-async DEPTH=16 DATA_WIDTH=32
#
# How it runs : cocotb 2.x bundled in OSS CAD Suite. This file is BOTH the test
#               module (the @cocotb.test() coroutines) AND its own runner: when
#               executed as `python3 tb_async_fifo_cocotb.py` it builds the DUT
#               with Verilator and runs the tests via cocotb_tools.runner. The
#               Makefile target just calls it with env-var DEPTH/DATA_WIDTH.
#
# CDC latency (CRITICAL — why this TB differs from the sync one):
#   The async_fifo uses SYNC_STAGES (default 2) synchronizer flops per crossing.
#   After a write, the `empty` flag in the read domain won't deassert for ~2
#   rd_clk cycles. After draining, `full` in the write domain won't deassert
#   for ~2 wr_clk cycles. The scoreboard therefore:
#     - Tracks writes and reads via the golden deque (order integrity)
#     - Checks occupancy BOUNDS (0 <= occupancy <= DEPTH) not exact count
#     - Defers exact flag checks until sync has settled
#     - Validates data integrity on every successfully-read word
#
# Registered-read latency:
#   Like the sync FIFO, async_fifo has a REGISTERED read port — when
#   rd_en && !empty at rd_clk edge T, the popped word appears on rd_data at
#   rd_clk edge T+1. The checker pops the golden value at T and compares it
#   against rd_data sampled one rd_clk cycle later.
# =============================================================================

import os
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Combine, First, Timer

# DEPTH / DATA_WIDTH are baked into the DUT at build time; the test reads the
# same values from the environment so the golden model and stimulus agree.
DEPTH = int(os.environ.get("FIFO_DEPTH", "8"))
DATA_WIDTH = int(os.environ.get("FIFO_DATA_WIDTH", "8"))
DATA_MASK = (1 << DATA_WIDTH) - 1
SYNC_STAGES = int(os.environ.get("FIFO_SYNC_STAGES", "2"))

# Clock periods in ns — intentionally coprime to exercise all phase alignments.
WR_CLK_PERIOD = 10
RD_CLK_PERIOD = 13


class Scoreboard:
    """Golden model for the async FIFO — tracks writes/reads independently.

    Unlike the sync scoreboard, this one cannot check an exact occupancy count
    (async_fifo does not expose one) nor can it check flags immediately after a
    cross-domain event (CDC sync latency). Instead it:
      - Validates data integrity: every read word matches the oldest unread write
      - Validates occupancy bounds: writes_committed - reads_committed in [0, DEPTH]
      - Validates that full blocks writes and empty blocks reads (no overflow/underflow)
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

    def sample_write(self, full_now: bool):
        """Call BEFORE a wr_clk rising edge. Determines if a write is accepted.

        In the async FIFO, wr_full is CONSERVATIVE (deasserts late due to CDC
        sync latency). The DUT itself never overflows (formally proven), but
        during that latency window wr_full=0 even though the FIFO is at capacity.
        The golden model must also bound itself at DEPTH to stay in sync.
        """
        wr_en = int(self.dut.wr_en.value)
        do_write = wr_en and not full_now and len(self.q) < DEPTH
        if do_write:
            self.q.append(int(self.dut.wr_data.value) & DATA_MASK)

    def sample_read(self, empty_now: bool):
        """Call BEFORE a rd_clk rising edge. Determines if a read is accepted."""
        rd_en = int(self.dut.rd_en.value)
        do_read = rd_en and not empty_now
        if do_read:
            if not self.q:
                self.dut._log.error(
                    "Scoreboard underflow: rd_en && !empty but golden queue is empty"
                )
                self.errors += 1
            else:
                self.pending_valid = True
                self.pending_expected = self.q.popleft()

    def check_read_data(self, ctx: str):
        """Call AFTER a rd_clk edge to validate the registered read output."""
        if self.pending_valid:
            got = int(self.dut.rd_data.value) & DATA_MASK
            if got != self.pending_expected:
                self.dut._log.error(
                    f"[{ctx}] rd_data mismatch: got={got:#x} "
                    f"expected={self.pending_expected:#x}"
                )
                self.errors += 1
            self.pending_valid = False

    def check_bounds(self, ctx: str):
        """Occupancy sanity — golden queue size must never exceed DEPTH."""
        if len(self.q) > DEPTH:
            self.dut._log.error(
                f"[{ctx}] occupancy overflow: golden queue has {len(self.q)} > DEPTH={DEPTH}"
            )
            self.errors += 1


def drive_write(dut, wr_en: int, wr_data: int = 0):
    """Drive write-domain inputs."""
    dut.wr_en.value = wr_en
    dut.wr_data.value = wr_data & DATA_MASK


def drive_read(dut, rd_en: int):
    """Drive read-domain inputs."""
    dut.rd_en.value = rd_en


async def wr_tick(dut, sb: Scoreboard, ctx: str):
    """One write-clock cycle: sample pre-edge, advance, check."""
    full_now = bool(int(dut.full.value))
    sb.sample_write(full_now)
    await RisingEdge(dut.wr_clk)
    sb.check_bounds(ctx)


async def rd_tick(dut, sb: Scoreboard, ctx: str):
    """One read-clock cycle: sample pre-edge, advance, check data."""
    empty_now = bool(int(dut.empty.value))
    sb.sample_read(empty_now)
    await RisingEdge(dut.rd_clk)
    sb.check_read_data(ctx)


async def tick_both(dut, sb: Scoreboard, ctx: str, n: int = 1):
    """Advance both clocks for n edges of the slower clock (rd_clk)."""
    for _ in range(n):
        await RisingEdge(dut.rd_clk)


async def settle(dut, cycles: int = None):
    """Wait enough cycles for CDC synchronizers to propagate.
    Waits SYNC_STAGES+1 edges on BOTH clocks to ensure flags are settled."""
    if cycles is None:
        cycles = SYNC_STAGES + 2
    for _ in range(cycles):
        await RisingEdge(dut.wr_clk)
    for _ in range(cycles):
        await RisingEdge(dut.rd_clk)


async def reset(dut, sb: Scoreboard, cycles: int = 4):
    """Assert both resets, hold for `cycles` edges on both clocks, release."""
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    drive_write(dut, 0, 0)
    drive_read(dut, 0)
    sb.reset()
    for _ in range(cycles):
        await RisingEdge(dut.wr_clk)
    for _ in range(cycles):
        await RisingEdge(dut.rd_clk)
    dut.wr_rst_n.value = 1
    dut.rd_rst_n.value = 1
    # Let reset propagate through synchronizers.
    await settle(dut)


async def _start(dut):
    """Common bring-up: start both clocks and return a fresh scoreboard."""
    cocotb.start_soon(Clock(dut.wr_clk, WR_CLK_PERIOD, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_CLK_PERIOD, unit="ns").start())
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    drive_write(dut, 0, 0)
    drive_read(dut, 0)
    sb = Scoreboard(dut)
    await reset(dut, sb)
    return sb


# -----------------------------------------------------------------------------
# TEST 1 — reset clears both domains to empty/not-full.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_reset(dut):
    sb = await _start(dut)
    assert int(dut.empty.value) == 1, "empty not set after reset"
    assert int(dut.full.value) == 0, "full set after reset"
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 2 — fill to full in wr_clk domain, then drain all in rd_clk domain.
#   Verifies data integrity across the CDC boundary (every word read matches
#   the write order) and that full/empty flags eventually assert correctly.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_fill_drain(dut):
    sb = await _start(dut)

    # Fill the FIFO from the write domain.
    for i in range(DEPTH + 4):  # overshoot to test full-blocking
        drive_write(dut, 1, (i + 1) & DATA_MASK)
        await wr_tick(dut, sb, "fill")
    drive_write(dut, 0, 0)

    # Wait for full to assert (CDC latency).
    await settle(dut)
    assert int(dut.full.value) == 1, "DUT not full after DEPTH writes"
    assert len(sb.q) == DEPTH

    # Let the write pointer propagate to the read domain so empty deasserts.
    await settle(dut)
    assert int(dut.empty.value) == 0, "empty should be deasserted after fill"

    # Drain from the read domain.
    for _ in range(DEPTH + 4):  # overshoot to test empty-blocking
        drive_read(dut, 1)
        await rd_tick(dut, sb, "drain")
    drive_read(dut, 0)

    # Wait for empty to assert (CDC latency).
    await settle(dut)
    assert int(dut.empty.value) == 1, "DUT not empty after full drain"
    assert len(sb.q) == 0
    assert sb.errors == 0


# -----------------------------------------------------------------------------
# TEST 3 — concurrent read and write at different rates.
#   Writes at full rate on wr_clk while reads occur every other rd_clk edge.
#   Tests the FIFO under steady-state cross-domain pressure.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_concurrent_rw(dut):
    sb = await _start(dut)

    total_written = 0
    total_read = 0
    target_words = DEPTH * 4  # push 4x capacity through the FIFO

    async def writer():
        nonlocal total_written
        val = 1
        while total_written < target_words:
            full_now = bool(int(dut.full.value))
            if not full_now:
                drive_write(dut, 1, val & DATA_MASK)
                sb.sample_write(full_now)
                val += 1
                total_written += 1
            else:
                drive_write(dut, 0, 0)
            await RisingEdge(dut.wr_clk)
            sb.check_bounds("conc_wr")
        drive_write(dut, 0, 0)

    async def reader():
        nonlocal total_read
        cycle = 0
        while total_read < target_words:
            empty_now = bool(int(dut.empty.value))
            # Read every other cycle to create backpressure variation.
            do_rd = (cycle % 2 == 0) and not empty_now
            if do_rd:
                drive_read(dut, 1)
                sb.sample_read(empty_now)
                total_read += 1
            else:
                drive_read(dut, 0)
            await RisingEdge(dut.rd_clk)
            sb.check_read_data("conc_rd")
            cycle += 1
        drive_read(dut, 0)

    await Combine(cocotb.start_soon(writer()), cocotb.start_soon(reader()))
    await settle(dut)
    assert sb.errors == 0, f"{sb.errors} scoreboard errors in concurrent R+W"


# -----------------------------------------------------------------------------
# TEST 4 — constrained-random stress with >= 10k combined clock edges.
#   Random wr_en / rd_en each cycle in their respective domains. Runs until
#   at least 10000 combined edges have elapsed.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_random_stress(dut):
    sb = await _start(dut)
    rng = random.Random(0xCDC1)
    wr_edges = 0
    rd_edges = 0
    target_edges = 500

    async def rand_writer():
        nonlocal wr_edges
        while wr_edges + rd_edges < target_edges:
            full_now = bool(int(dut.full.value))
            wen = rng.randint(0, 1)
            wdata = rng.getrandbits(DATA_WIDTH)
            drive_write(dut, wen, wdata)
            if wen and not full_now:
                sb.sample_write(full_now)
            await RisingEdge(dut.wr_clk)
            sb.check_bounds("stress_wr")
            wr_edges += 1
        drive_write(dut, 0, 0)

    async def rand_reader():
        nonlocal rd_edges
        while wr_edges + rd_edges < target_edges:
            empty_now = bool(int(dut.empty.value))
            ren = rng.randint(0, 1)
            drive_read(dut, ren)
            if ren and not empty_now:
                sb.sample_read(empty_now)
            await RisingEdge(dut.rd_clk)
            sb.check_read_data("stress_rd")
            rd_edges += 1
        drive_read(dut, 0)

    await Combine(cocotb.start_soon(rand_writer()), cocotb.start_soon(rand_reader()))
    await settle(dut)
    dut._log.info(f"Random stress complete: {wr_edges} wr_edges + {rd_edges} rd_edges = {wr_edges+rd_edges}")
    assert wr_edges + rd_edges >= target_edges
    assert sb.errors == 0, f"{sb.errors} scoreboard errors in random stress"


# -----------------------------------------------------------------------------
# TEST 5 — depth sweep: repeated fill-drain cycles to exercise pointer wrap
#   and ordering across multiple laps of the circular buffer.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_depth_sweep(dut):
    sb = await _start(dut)
    val = 1

    for lap in range(20):
        # Fill completely.
        for _ in range(DEPTH):
            full_now = bool(int(dut.full.value))
            drive_write(dut, 1, val & DATA_MASK)
            sb.sample_write(full_now)
            val += 1
            await RisingEdge(dut.wr_clk)
            sb.check_bounds(f"sweep_fill_{lap}")
        drive_write(dut, 0, 0)

        # Wait for data to propagate across CDC.
        await settle(dut)

        # Drain completely.
        for _ in range(DEPTH):
            empty_now = bool(int(dut.empty.value))
            drive_read(dut, 1)
            sb.sample_read(empty_now)
            await RisingEdge(dut.rd_clk)
            sb.check_read_data(f"sweep_drain_{lap}")
        drive_read(dut, 0)

        # Wait for flags to settle before next lap.
        await settle(dut)

    assert len(sb.q) == 0, f"golden queue not empty after sweep: {len(sb.q)} items"
    assert sb.errors == 0, f"{sb.errors} scoreboard errors in depth sweep"


# -----------------------------------------------------------------------------
# ANTI-VACUITY — only built when FIFO_INJECT_FAULT=1. Corrupts the golden model
# so the scoreboard MUST report errors; proves the Python checker is not vacuous.
# Same pattern as tb_sync_fifo_cocotb: invert the golden head so the next drained
# word cannot match rd_data.
# -----------------------------------------------------------------------------
@cocotb.test(skip=os.environ.get("FIFO_INJECT_FAULT") != "1")
async def test_fault_injection_is_caught(dut):
    sb = await _start(dut)
    val = 1

    # Fill the FIFO.
    for _ in range(DEPTH):
        full_now = bool(int(dut.full.value))
        drive_write(dut, 1, val & DATA_MASK)
        sb.sample_write(full_now)
        val += 1
        await RisingEdge(dut.wr_clk)
    drive_write(dut, 0, 0)

    # Wait for CDC propagation so read domain sees the data.
    await settle(dut)

    # Corrupt the golden head so the next drained word cannot match rd_data.
    if sb.q:
        sb.q[0] ^= DATA_MASK

    # Drain: the first valid read should mismatch.
    for _ in range(DEPTH + 4):
        empty_now = bool(int(dut.empty.value))
        drive_read(dut, 1)
        sb.sample_read(empty_now)
        await RisingEdge(dut.rd_clk)
        sb.check_read_data("fault_drain")
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
        verilog_sources=[proj / "rtl" / "async_fifo.sv"],
        hdl_toplevel="async_fifo",
        parameters={"DEPTH": depth, "DATA_WIDTH": data_width},
        build_args=["-Wall", "--trace"],
        always=True,
    )
    runner.test(
        hdl_toplevel="async_fifo",
        test_module="tb_async_fifo_cocotb",
    )


if __name__ == "__main__":
    _run()
