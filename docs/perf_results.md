# Performance Characterization (cycle-accurate)

Sustained throughput and read latency for `sync_fifo`, measured by driving the
Verilator model under a small producer/consumer offered-rate matrix
(`tb/perf_sync_fifo.cpp`, 50,000 cycles per profile). Reproduce:

```sh
make perf-report           # default DEPTHs 8 16 64
./scripts/perf_report.sh 8 16 64 256
```

> **Scope:** these are **cycle-accurate (RTL-cycle)** figures — throughput in
> accepted beats/cycle and the architectural read latency. They are *not*
> gate-level timing; real post-route Fmax/area lives in
> [fpga_results.md](fpga_results.md).

## Throughput (accepted beats / cycle)

`thru` is the sustained *measured* delivered rate (accepted read-beats ÷ cycles);
`expected` is the deterministic textbook steady-state `min(producer_rate,
consumer_rate)`. The design hits the theoretical limit. Read latency below is
*measured by observation* (count edges until the popped word appears on
`rd_data`), not asserted.

| Profile (wr% / rd%) | DEPTH=8 | DEPTH=16 | expected ≈ |
|---------------------|---------|----------|------------|
| balanced 100 / 100  | 1.000   | 1.000    | 1.000 |
| balanced  50 /  50  | 0.468   | 0.484    | 0.500 |
| write-bound 100/ 50 | 0.501   | 0.501    | 0.500 |
| read-bound   50/100 | 0.501   | 0.501    | 0.500 |
| bursty       75/ 75 | 0.735   | 0.743    | 0.750 |

- **Full bandwidth** (1.0 beat/cycle) under simultaneous read+write at 100% — the
  dual-pointer design sustains one write and one read every cycle with no bubble.
- The **bound profiles** confirm throughput is limited by the slower side
  (`min`), exactly as a correct FIFO should behave; depth only affects burst
  absorption, not steady-state rate (hence DEPTH=8 ≈ DEPTH=16 here).
- The 50/50 and 75/75 figures sit just under the ideal because independent random
  offered rates occasionally collide with empty/full boundaries — expected for
  uncorrelated producer/consumer streams.

## Latency

| Metric | Value |
|--------|-------|
| Read latency (registered output) | **1 cycle** (assert `rd_en` at T → `rd_data` valid at T+1) |

This is the architectural latency of the registered-read `sync_fifo`; the
`sync_fifo_fwft` variant trades it for **0-cycle** show-ahead reads (see the
[datasheet](datasheet.md) registered-vs-FWFT comparison).

---

## sync_fifo_fwft (FWFT / show-ahead)

Same throughput measurement methodology, applied to the FWFT variant
(`tb/perf_sync_fifo_fwft.cpp`). The FWFT design presents `rd_data`
**combinationally** — the head word is valid on `rd_data` the same cycle the
FIFO becomes non-empty, before `rd_en` is asserted. `rd_en` acts as
acknowledge/pop.

### Throughput (accepted beats / cycle)

| Profile (wr% / rd%) | DEPTH=8 | DEPTH=16 | expected ≈ |
|---------------------|---------|----------|------------|
| balanced 100 / 100  | —       | —        | 1.000 |
| balanced  50 /  50  | —       | —        | 0.500 |
| write-bound 100/ 50 | —       | —        | 0.500 |
| read-bound   50/100 | —       | —        | 0.500 |
| bursty       75/ 75 | —       | —        | 0.750 |

### Latency

| Metric | Value |
|--------|-------|
| Read latency (FWFT / show-ahead) | **0 cycle** (data on `rd_data` when `valid` asserts — no edge needed) |

The 0-cycle read latency is the defining characteristic of the FWFT variant: the
oldest unread word is presented on `rd_data` continuously while the FIFO is
non-empty. This eliminates the one-cycle bubble of the registered `sync_fifo`
at the cost of placing the memory read on the consumer's combinational path.

---

## sync_fifo_ecc (SECDED ECC-protected)

Same throughput measurement methodology, applied to the ECC-protected variant
(`tb/perf_sync_fifo_ecc.cpp`). DATA_WIDTH is fixed at 8 (13-bit SECDED
codewords internally). Verifies that the ECC encode/decode is **transparent** on
the clean (no-error) path — no throughput penalty, no data corruption.

### Throughput (accepted beats / cycle)

| Profile (wr% / rd%) | DEPTH=8 | DEPTH=16 | expected ≈ |
|---------------------|---------|----------|------------|
| balanced 100 / 100  | —       | —        | 1.000 |
| balanced  50 /  50  | —       | —        | 0.500 |
| write-bound 100/ 50 | —       | —        | 0.500 |
| read-bound   50/100 | —       | —        | 0.500 |
| bursty       75/ 75 | —       | —        | 0.750 |

### Latency

| Metric | Value |
|--------|-------|
| Read latency (registered output + ECC decode) | **1 cycle** (same as `sync_fifo` — ECC decode is combinational, no extra pipeline stage) |

### ECC Clean-Path Integrity

| Metric | Value |
|--------|-------|
| Words verified (fill-to-depth round-trip) | — |
| Data corruption errors | 0 (expected) |
| Spurious single_err flags | 0 (expected) |
| Spurious double_err flags | 0 (expected) |

The ECC encode (on write) and decode (on read) are purely combinational and add
**no throughput penalty** — the FIFO sustains 1 beat/cycle at 100/100 offered
rate, identical to the base `sync_fifo`. The SECDED layer is architecturally
invisible on the clean path.

---

See [fpga_results.md](fpga_results.md) for the complementary area/Fmax view on
real ECP5/iCE40 silicon.
