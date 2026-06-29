# FPGA Synthesis & Timing Results

Real place-and-route resource utilisation and post-route timing for
`rtl/sync_fifo.sv` (`DATA_WIDTH = 8`) across the depth sweep, on two concrete
Lattice targets using the **100% open-source Yosys + nextpnr flow**.

Every number below is read directly from tool output — nothing is estimated.
Reproduce with:

```sh
./scripts/fpga_report.sh            # default sweep 4 8 16 64 256
make fpga-report                    # same, via the Makefile
```

## Flow & versions

| Item | Value |
|------|-------|
| Synthesis | `yosys` Yosys 0.64+308 (git 78e05dfb0) |
| Place & route | `nextpnr` 0.10-76-g885b71e5 (`nextpnr-ecp5`, `nextpnr-ice40`) |
| ECP5 target | **LFE5U-85F**, package **CABGA381**, `--freq 100` constraint |
| iCE40 target | **UP5K**, package **SG48**, `--freq 50` constraint |
| Seed | `--seed 1` (fixed, for reproducibility) |
| Date | 2026-06-11 |

> **Caveat:** these are open-source-flow (Yosys + nextpnr) numbers. Vendor tools
> (Lattice Diamond / Radiant, or Xilinx Vivado on a Xilinx part) will report
> different LUT/FF/BRAM counts and Fmax — different mappers, timing models, and
> architectures. Fmax is the **post-route** maximum reported by nextpnr's static
> timing analysis for the FIFO clock; nextpnr is heuristic, so values vary
> slightly with seed.

## ECP5 — LFE5U-85F (CABGA381)

| DEPTH | LUT (TRELLIS_COMB) | FF (TRELLIS_FF) | BRAM (DP16KD) | Fmax (MHz) | mem mapped to |
|-------|--------------------|-----------------|---------------|------------|---------------|
| 4   | 49  | 14 | 0 | 294.38 | logic (distributed) |
| 8   | 84  | 16 | 0 | 266.81 | logic (distributed) |
| 16  | 63  | 18 | 0 | 249.13 | logic (distributed) |
| 64  | 164 | 22 | 0 | 174.46 | logic (distributed) |
| 256 | 96  | 18 | 1 | 221.34 | **BRAM** (1× DP16KD) |

All depths fit comfortably on the 85k part. Yosys keeps the shallow FIFOs in
distributed LUT RAM; at DEPTH=256 the memory is large enough that `synth_ecp5`
maps it into a single DP16KD block RAM, which is why the LUT count *drops*
between 64 and 256 and Fmax recovers (BRAM has a clean registered timing path
versus a wide distributed-RAM mux tree).

## iCE40 — UP5K (SG48)

| DEPTH | LC (ICESTORM_LC) | BRAM (ICESTORM_RAM) | Fmax (MHz) | mem mapped to |
|-------|------------------|---------------------|------------|---------------|
| 4   | 86  | 0 | 61.53 | logic (distributed) |
| 8   | 155 | 0 | 59.17 | logic (distributed) |
| 16  | 49  | 1 | 73.01 | **BRAM** (1× SB_RAM40_4K) |
| 64  | 73  | 1 | 60.40 | **BRAM** (1× SB_RAM40_4K) |
| 256 | 82  | 1 | 72.73 | **BRAM** (1× SB_RAM40_4K) |

All depths fit on the UP5K. On iCE40 the logic-cell (`ICESTORM_LC`) count is the
combined LUT4+DFF count — the architecture packs a LUT and a flip-flop into one
cell — so a separate FF column is not reported (the LC figure already includes
the registers). `synth_ice40` moves the memory into a single 4 Kbit block RAM
(`SB_RAM40_4K`) from DEPTH=16 upward, collapsing the distributed-RAM logic and
lifting Fmax back to ~73 MHz.

## Reading the numbers

- **ECP5 is the high-performance part** (~175–294 MHz here); **iCE40 UP5K is the
  small/low-power part** (~59–73 MHz) — the Fmax gap is expected and reflects the
  fabric, not the design.
- The **BRAM-vs-logic crossover** is visible on both parts and is the most
  instructive result: a single FIFO RTL maps to distributed RAM when shallow and
  to dedicated block RAM when deep, with no source changes — exactly the
  portability the parameterised design is meant to demonstrate.
- Counts are not strictly monotonic in DEPTH because the mapper's
  distributed-vs-block-RAM decision and packing change the resource mix at each
  size; each row is an independent real P&R run.

## Real bitstream build (RTL → chip)

Beyond the area/timing *report* above, `scripts/build_bitstream.sh`
(`make bitstream`) takes a synthesizable demo top all the way to a real,
flashable **bitstream** on both Lattice targets — the full
`yosys → nextpnr → ecppack/icepack` flow:

| Target | Flow | Output | Size | Post-route Fmax |
|--------|------|--------|------|-----------------|
| ECP5 LFE5U-85F (CABGA381) | `synth_ecp5` → `nextpnr-ecp5` → `ecppack` | `demo_top_ecp5.bit` | ~1.93 MB | ~146 MHz |
| iCE40 UP5K (SG48) | `synth_ice40` → `nextpnr-ice40` → `icepack` | `demo_top_ice40.bin` | ~104 KB | ~31 MHz |

`rtl/demo_top.sv` is a self-checking loopback: a free-running byte counter is
streamed through an **8→32 up-sizer** then a **32→8 down-sizer**
(`axis_width_conv`), and an on-chip checker compares the round-tripped byte
against a reference, driving a heartbeat LED (solid-off on a — never-expected —
mismatch). It exercises the round-trip composition of the round-2 width
converters on real silicon resources.

The two converters cascaded are heavier than a single FIFO, so the **UP5K** (the
small/low-power part) closes timing around ~31 MHz here versus the ~59–73 MHz of
the bare FIFO above — expected for the larger design on the slower fabric.

> **Honest scope:** this is **build-only** — CI (and `make bitstream`) emit and
> archive the `.bit`/`.bin`, but no physical board is programmed. The flow proves
> the RTL routes and packs into a legal bitstream end-to-end; **functional**
> correctness is established by the formal proofs and the Verilator/cocotb
> testbenches, not by this step. Open-source flow (Yosys + nextpnr), seed 1.
