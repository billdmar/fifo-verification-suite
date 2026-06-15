#!/usr/bin/env bash
# =============================================================================
# scripts/fpga_report.sh — real FPGA place-and-route resource + timing report
#
#   Synthesises rtl/sync_fifo.sv (DATA_WIDTH=8) across a depth sweep on two
#   concrete Lattice targets using the 100%-open-source Yosys + nextpnr flow:
#
#     ECP5   : LFE5U-85F, package CABGA381   (yosys synth_ecp5  + nextpnr-ecp5)
#     iCE40  : UP5K,      package SG48        (yosys synth_ice40 + nextpnr-ice40)
#
#   For each (target, depth) it captures LUTs, FFs, BRAM and the POST-ROUTE
#   maximum clock frequency reported by nextpnr, plus whether the memory mapped
#   to dedicated block RAM or to distributed logic.  nextpnr is pinned with
#   --seed 1 for reproducibility.
#
#   These are open-source-flow numbers (Yosys/nextpnr) — NOT vendor numbers
#   (Lattice Diamond/Radiant), which will differ.  Every value printed is read
#   straight from the tool output; nothing is estimated.
#
#   Usage:  ./scripts/fpga_report.sh [DEPTHS...]      (default: 4 8 16 64 256)
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
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fpga_report.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

DEPTHS=("$@")
[ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(4 8 16 64 256)

SEED=1
DATA_WIDTH=8

# Extract the LAST "Max frequency for clock" value (post-route) in MHz.
fmax_of() {
  grep -oE "Max frequency for clock '[^']+': [0-9.]+ MHz" "$1" \
    | tail -1 | grep -oE "[0-9.]+ MHz" | grep -oE "[0-9.]+"
}
# Extract a utilisation count: util_of <logfile> <CELLTYPE>
util_of() {
  grep -E "^Info:[[:space:]]+$2:" "$1" | tail -1 | grep -oE "[0-9]+/" | head -1 | tr -d '/'
}

run_target() {
  local slug="$1" target="$2" synth="$3" pnr="$4" pnr_args="$5"
  local lut_cell="$6" ff_cell="$7" bram_cell="$8"
  echo ""
  echo "############################################################"
  echo "# Target: $target   (seed=$SEED, DATA_WIDTH=$DATA_WIDTH)"
  echo "############################################################"
  printf "%-6s | %-8s | %-8s | %-6s | %-10s | %s\n" "DEPTH" "LUT" "FF" "BRAM" "Fmax(MHz)" "mem->"
  printf -- "-------|----------|----------|--------|------------|----------\n"
  for d in "${DEPTHS[@]}"; do
    # Filenames use the short slug (no spaces) so the yosys -json arg is safe.
    local json="$SCRATCH/${slug}_d${d}.json"
    local slog="$SCRATCH/${slug}_d${d}_synth.log"
    local plog="$SCRATCH/${slug}_d${d}_pnr.log"

    if ! yosys -q -p \
        "read_verilog -sv $RTL; chparam -set DEPTH $d -set DATA_WIDTH $DATA_WIDTH sync_fifo; \
         $synth -top sync_fifo -json $json" >"$slog" 2>&1; then
      printf "%-6s | %s\n" "$d" "SYNTH FAILED (see log)"
      continue
    fi

    if ! "$pnr" $pnr_args --json "$json" --seed "$SEED" >"$plog" 2>&1; then
      # Distinguish "does not fit" from other errors.
      if grep -qiE "unable to place|out of|not enough|failed to place|overutil" "$plog"; then
        printf "%-6s | %s\n" "$d" "DOES NOT FIT on $target"
      else
        printf "%-6s | %s\n" "$d" "PNR FAILED (see log)"
      fi
      continue
    fi

    local lut ff bram fmax memto
    lut="$(util_of "$plog" "$lut_cell")";   lut="${lut:-?}"
    ff="$(util_of "$plog" "$ff_cell")";     ff="${ff:-?}"
    bram="$(util_of "$plog" "$bram_cell")"; bram="${bram:-0}"
    fmax="$(fmax_of "$plog")";              fmax="${fmax:-?}"
    if [ "${bram:-0}" != "0" ] && [ "${bram:-0}" != "?" ]; then memto="BRAM"; else memto="logic"; fi
    printf "%-6s | %-8s | %-8s | %-6s | %-10s | %s\n" "$d" "$lut" "$ff" "$bram" "$fmax" "$memto"
  done
}

echo "=== sync_fifo FPGA report — $(date -u +%Y-%m-%d) ==="
echo "yosys        : $(yosys --version 2>/dev/null)"
echo "nextpnr-ice40: $(nextpnr-ice40 --version 2>&1)"
echo "nextpnr-ecp5 : $(nextpnr-ecp5 --version 2>&1)"

# ECP5 LFE5U-85F CABGA381 ; target 100 MHz constraint for the timing engine.
run_target "ecp5" "ECP5 (LFE5U-85F CABGA381)" \
  "synth_ecp5" "nextpnr-ecp5" "--85k --package CABGA381 --freq 100" \
  "TRELLIS_COMB" "TRELLIS_FF" "DP16KD"

# iCE40 UP5K SG48 ; target 50 MHz constraint.
run_target "ice40" "iCE40 (UP5K SG48)" \
  "synth_ice40" "nextpnr-ice40" "--up5k --package sg48 --freq 50" \
  "ICESTORM_LC" "ICESTORM_LC" "ICESTORM_RAM"

echo ""
echo "=== done ==="
