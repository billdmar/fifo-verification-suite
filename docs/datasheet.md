# FIFO Suite — Datasheet

Compact reference for the eight verified FIFO designs. Full prose, waveforms, and
the verification narrative live in the [README](../README.md); this page is the
at-a-glance signal/parameter/performance summary.

All designs: parameterizable, fully synthesizable (no `initial`/`$display`
outside `ifdef FORMAL`), Verilator `-Wall` + Verible clean, formally verified.

---

## 1. `sync_fifo` — single-clock, registered read

Extra-MSB dual-pointer ring buffer. `rd_data` is **registered** (1-cycle read
latency). The reference design; maps cleanly to synchronous block RAM.

| Parameter | Range | Default |
|-----------|-------|---------|
| `DATA_WIDTH` | 1–64 | 8 |
| `DEPTH` | 4–1024 (2ⁿ) | 16 |
| `ALMOST_FULL_THRESH` | 1–DEPTH-1 | DEPTH-2 |
| `ALMOST_EMPTY_THRESH` | 1–DEPTH-1 | 2 |

| Port | Dir | Width | Notes |
|------|-----|-------|-------|
| `clk` / `rst_n` | in | 1 | rising-edge / **synchronous** active-low reset |
| `wr_en` / `wr_data` | in | 1 / `DATA_WIDTH` | write enable / data |
| `rd_en` / `rd_data` | in / out | 1 / `DATA_WIDTH` | read enable / **registered** data (valid N+1) |
| `full` / `empty` | out | 1 | write/read inhibit flags |
| `almost_full` / `almost_empty` | out | 1 | count ≥ / ≤ threshold |
| `count` | out | `$clog2(DEPTH)+1` | occupancy 0..DEPTH |

## 2. `sync_fifo_fwft` — single-clock, first-word-fall-through

Same ring core, **combinational show-ahead read**: `rd_data` presents the head
word continuously while `valid` (==`!empty`); `rd_en` is a pop/acknowledge. Zero
read latency, at the cost of the memory read on the consumer's combinational path.

Parameters identical to `sync_fifo`. Ports identical **except**: `rd_data` is
combinational, and an extra `valid` output (== `!empty`) for valid/ready-style
handshaking. No registered-read latency.

## 3. `async_fifo` — dual-clock CDC

Independent write/read clocks bridged with Gray-code pointers + multi-flop
synchronizers (Cummings architecture). Conservative full/empty (never
over/underflow). See [cdc_architecture.md](cdc_architecture.md).

| Parameter | Range | Default |
|-----------|-------|---------|
| `DATA_WIDTH` | 1–64 | 8 |
| `DEPTH` | 4–1024 (2ⁿ) | 16 |
| `SYNC_STAGES` | 2–8 | 2 |

| Port group | Signals |
|------------|---------|
| Write domain | `wr_clk`, `wr_rst_n` (async-assert), `wr_en`, `wr_data`, `full` |
| Read domain | `rd_clk`, `rd_rst_n` (async-assert), `rd_en`, `rd_data`, `empty` |

## 4. `axis_fifo` — AXI4-Stream wrapper

Wraps `sync_fifo` with standard AXI4-Stream slave→master ports; a 1-deep output
skid register absorbs the registered-read latency so no beat is dropped or
duplicated under backpressure. `{tlast, tdata}` buffered together.

`DATA_WIDTH` 1–63 (the widened `{tlast,tdata}` word stays ≤64), `DEPTH` 4–1024.

| Port | Dir | Width | Notes |
|------|-----|-------|-------|
| `s_axis_tvalid` / `s_axis_tready` | in / out | 1 | slave handshake (tready = space) |
| `s_axis_tdata` / `s_axis_tlast` | in | `DATA_WIDTH` / 1 | slave payload / last-of-packet |
| `m_axis_tvalid` / `m_axis_tready` | out / in | 1 | master handshake |
| `m_axis_tdata` / `m_axis_tlast` | out | `DATA_WIDTH` / 1 | master payload / last |

---

## Guarantees (formally established)

- **No overflow / no underflow** — qualified strobes can never fire against an
  asserted flag (all designs).
- **FIFO ordering / data integrity** — per-slot `$anyconst` tracking; words exit
  in entry order, uncorrupted (sync/async/AXI/FWFT).
- **Mutual exclusion & bounded progress** — `!(full && empty)`; under sustained
  pressure occupancy strictly de/increases (sync: PROVEN unbounded).
- **CDC safety** — Gray pointers change exactly one bit per step; conservative
  flags (async).
- **AXI4-Stream compliance** — TVALID/TDATA/TLAST stable-until-accepted, no loss
  under backpressure, no spurious valid (axis).
- **Show-ahead timing** — head word on `rd_data` with zero latency (FWFT).

Full method/status: [assertions.md](assertions.md) ·
[verification_matrix.md](verification_matrix.md) ·
[proven_vs_tested.md](proven_vs_tested.md).

## Performance (real open-source P&R, `DATA_WIDTH=8`, `sync_fifo`)

| Part | DEPTH=8 Fmax | DEPTH=256 Fmax | mem→BRAM from |
|------|--------------|----------------|---------------|
| ECP5 LFE5U-85F | 266.8 MHz | 221.3 MHz | DEPTH=256 |
| iCE40 UP5K | 59.2 MHz | 72.7 MHz | DEPTH=16 |

Open-source flow (Yosys + nextpnr), seed-dependent. All swept depths fit on both
parts. Full tables + methodology: [fpga_results.md](fpga_results.md).
