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

`thru` is the sustained delivered rate; `expected` is the textbook steady-state
`min(producer_rate, consumer_rate)`. The design hits the theoretical limit.

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

See [fpga_results.md](fpga_results.md) for the complementary area/Fmax view on
real ECP5/iCE40 silicon.
