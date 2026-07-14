#!/usr/bin/env bash
# =============================================================================
# scripts/perf_report.sh — throughput / latency characterization for sync_fifo,
#   sync_fifo_fwft, and sync_fifo_ecc
#
#   Builds tb/perf_sync_fifo*.cpp with Verilator at a range of DEPTHs and runs a
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
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/perf_report.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

DEPTHS=("$@")
[ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(8 16 64)

echo "=== sync_fifo performance report — $(date -u +%Y-%m-%d) ==="
echo "verilator: $(verilator --version 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: sync_fifo (registered read, 1-cycle latency)
# ─────────────────────────────────────────────────────────────────────────────
RTL="$ROOT/rtl/sync_fifo.sv"
TB="$ROOT/tb/perf_sync_fifo.cpp"

for d in "${DEPTHS[@]}"; do
  echo ""
  echo "############################################################"
  echo "# sync_fifo  DEPTH=$d"
  echo "############################################################"
  obj="$SCRATCH/obj_sync_d${d}"
  if ! verilator --cc --exe --build -Wall \
        -GDEPTH="$d" --top-module sync_fifo \
        "$RTL" "$TB" \
        -CFLAGS "-DDEPTH_PARAM=$d" \
        -Mdir "$obj" -o perf >"$SCRATCH/build_sync_d${d}.log" 2>&1; then
    echo "  BUILD FAILED (see log)"
    tail -5 "$SCRATCH/build_sync_d${d}.log"
    continue
  fi
  "$obj/perf"
done

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: sync_fifo_fwft (show-ahead / FWFT, 0-cycle read latency)
# ─────────────────────────────────────────────────────────────────────────────
RTL_FWFT="$ROOT/rtl/sync_fifo_fwft.sv"
TB_FWFT="$ROOT/tb/perf_sync_fifo_fwft.cpp"

for d in "${DEPTHS[@]}"; do
  echo ""
  echo "############################################################"
  echo "# sync_fifo_fwft  DEPTH=$d"
  echo "############################################################"
  obj="$SCRATCH/obj_fwft_d${d}"
  if ! verilator --cc --exe --build -Wall \
        -GDEPTH="$d" --top-module sync_fifo_fwft \
        "$RTL_FWFT" "$TB_FWFT" \
        -CFLAGS "-DDEPTH_PARAM=$d" \
        -Mdir "$obj" -o perf_fwft >"$SCRATCH/build_fwft_d${d}.log" 2>&1; then
    echo "  BUILD FAILED (see log)"
    tail -5 "$SCRATCH/build_fwft_d${d}.log"
    continue
  fi
  "$obj/perf_fwft"
done

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: sync_fifo_ecc (SECDED ECC, 8-bit data / 13-bit codewords)
# ─────────────────────────────────────────────────────────────────────────────
RTL_ECC="$ROOT/rtl/sync_fifo_ecc.sv"
TB_ECC="$ROOT/tb/perf_sync_fifo_ecc.cpp"

for d in "${DEPTHS[@]}"; do
  echo ""
  echo "############################################################"
  echo "# sync_fifo_ecc  DEPTH=$d"
  echo "############################################################"
  obj="$SCRATCH/obj_ecc_d${d}"
  if ! verilator --cc --exe --build -Wall \
        -GDEPTH="$d" --top-module sync_fifo_ecc \
        "$RTL_ECC" "$TB_ECC" \
        -CFLAGS "-DDEPTH_PARAM=$d" \
        -Mdir "$obj" -o perf_ecc >"$SCRATCH/build_ecc_d${d}.log" 2>&1; then
    echo "  BUILD FAILED (see log)"
    tail -5 "$SCRATCH/build_ecc_d${d}.log"
    continue
  fi
  "$obj/perf_ecc"
done

echo ""
echo "=== done ==="
