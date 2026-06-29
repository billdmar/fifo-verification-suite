#!/usr/bin/env bash
# =============================================================================
# scripts/perf_report.sh — throughput / latency characterization for sync_fifo
#
#   Builds tb/perf_sync_fifo.cpp with Verilator at a range of DEPTHs and runs a
#   small producer/consumer offered-rate matrix, reporting sustained throughput
#   (accepted beats per cycle) and the architectural read latency.
#
#   These are CYCLE-ACCURATE (RTL-cycle) numbers — capacity/behaviour figures,
#   NOT gate-level timing. Real FPGA Fmax/area lives in docs/fpga_results.md.
#
#   Usage:  ./scripts/perf_report.sh [DEPTHS...]      (default: 8 16 64)
#   Env  :  OSS_ENV=path/to/oss-cad-suite/environment (auto-sourced if present)
# =============================================================================
set -u

OSS_ENV="${OSS_ENV:-$HOME/oss-cad-suite/environment}"
if [ -f "$OSS_ENV" ]; then
  # shellcheck disable=SC1090
  source "$OSS_ENV"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="$ROOT/rtl/sync_fifo.sv"
TB="$ROOT/tb/perf_sync_fifo.cpp"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/perf_report.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

DEPTHS=("$@")
[ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(8 16 64)

echo "=== sync_fifo performance report — $(date -u +%Y-%m-%d) ==="
echo "verilator: $(verilator --version 2>/dev/null)"

for d in "${DEPTHS[@]}"; do
  echo ""
  echo "############################################################"
  echo "# DEPTH=$d"
  echo "############################################################"
  obj="$SCRATCH/obj_d${d}"
  if ! verilator --cc --exe --build -Wall \
        -GDEPTH="$d" --top-module sync_fifo \
        "$RTL" "$TB" \
        -CFLAGS "-DDEPTH_PARAM=$d" \
        -Mdir "$obj" -o perf >"$SCRATCH/build_d${d}.log" 2>&1; then
    echo "  BUILD FAILED (see log)"
    tail -5 "$SCRATCH/build_d${d}.log"
    continue
  fi
  "$obj/perf"
done

echo ""
echo "=== done ==="
