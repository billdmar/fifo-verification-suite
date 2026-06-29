#!/usr/bin/env bash
# =============================================================================
# scripts/build_bitstream.sh — real FPGA BITSTREAM build for rtl/demo_top.sv
#
#   Takes the synthesizable demo top (a self-checking width-converter loopback)
#   all the way to a real, flashable bitstream on two concrete Lattice targets
#   using the 100%-open-source flow:
#
#     ECP5  : LFE5U-85F CABGA381 : yosys synth_ecp5  -> nextpnr-ecp5  -> ecppack -> .bit
#     iCE40 : UP5K      SG48     : yosys synth_ice40 -> nextpnr-ice40 -> icepack -> .bin
#
#   This proves the RTL completes a full synthesis -> place-and-route -> bitstream
#   pack flow (RTL -> chip), not just simulation/formal. It is BUILD-ONLY: no
#   board is required or programmed; the emitted .bit/.bin are the artifacts.
#   Functional correctness is established by the formal proofs + Verilator TBs.
#
#   Outputs (under build/bitstream/, gitignored):
#     demo_top_ecp5.bit   demo_top_ice40.bin
#
#   Usage:  ./scripts/build_bitstream.sh
#   Env  :  OSS_ENV=path/to/oss-cad-suite/environment (auto-sourced if present)
# =============================================================================
set -u

OSS_ENV="${OSS_ENV:-$HOME/oss-cad-suite/environment}"
if [ -f "$OSS_ENV" ]; then
  # shellcheck disable=SC1090
  source "$OSS_ENV"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL=("$ROOT/rtl/demo_top.sv" "$ROOT/rtl/axis_width_conv.sv" "$ROOT/rtl/sync_fifo_width.sv")
OUT="$ROOT/build/bitstream"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bitstream.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$OUT"

fail=0

echo "=== demo_top bitstream build — $(date -u +%Y-%m-%d) ==="
echo "yosys        : $(yosys --version 2>/dev/null)"
echo "nextpnr-ecp5 : $(nextpnr-ecp5 --version 2>&1)"
echo "nextpnr-ice40: $(nextpnr-ice40 --version 2>&1)"
echo "ecppack      : $(command -v ecppack)"
echo "icepack      : $(command -v icepack)"

# ---------------------------------------------------------------------------
# ECP5 LFE5U-85F CABGA381. Minimal LPF: clk + rst_n + led (placeholder pins;
# the goal is a legal routed bitstream, not a specific board pinout).
# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# ECP5 LFE5U-85F (CABGA381)"
echo "############################################################"
cat > "$SCRATCH/ecp5.lpf" <<'LPF'
LOCATE COMP "clk"   SITE "A10";
LOCATE COMP "rst_n" SITE "B10";
LOCATE COMP "led"   SITE "C10";
IOBUF PORT "clk"   IO_TYPE=LVCMOS33;
IOBUF PORT "rst_n" IO_TYPE=LVCMOS33;
IOBUF PORT "led"   IO_TYPE=LVCMOS33;
FREQUENCY PORT "clk" 50 MHZ;
LPF

if yosys -q -p "read_verilog -sv ${RTL[*]}; synth_ecp5 -top demo_top -json $SCRATCH/ecp5.json" \
      > "$SCRATCH/ecp5_synth.log" 2>&1 \
   && nextpnr-ecp5 --85k --package CABGA381 --freq 50 --seed 1 \
        --json "$SCRATCH/ecp5.json" --lpf "$SCRATCH/ecp5.lpf" \
        --textcfg "$SCRATCH/ecp5.config" > "$SCRATCH/ecp5_pnr.log" 2>&1 \
   && ecppack "$SCRATCH/ecp5.config" "$OUT/demo_top_ecp5.bit" > "$SCRATCH/ecp5_pack.log" 2>&1; then
  sz=$(wc -c < "$OUT/demo_top_ecp5.bit" | tr -d ' ')
  fmax=$(grep -oE "Max frequency for clock '[^']+': [0-9.]+ MHz" "$SCRATCH/ecp5_pnr.log" | tail -1)
  echo "  OK  -> $OUT/demo_top_ecp5.bit ($sz bytes)   ${fmax:-(fmax n/a)}"
else
  echo "  FAILED — see scratch logs (kept on failure):"
  cp "$SCRATCH"/ecp5_*.log "$OUT/" 2>/dev/null
  tail -5 "$SCRATCH/ecp5_pnr.log" 2>/dev/null
  fail=1
fi

# ---------------------------------------------------------------------------
# iCE40 UP5K SG48. Minimal PCF.
# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# iCE40 UP5K (SG48)"
echo "############################################################"
cat > "$SCRATCH/ice40.pcf" <<'PCF'
set_io clk   35
set_io rst_n 36
set_io led   37
PCF

if yosys -q -p "read_verilog -sv ${RTL[*]}; synth_ice40 -top demo_top -json $SCRATCH/ice40.json" \
      > "$SCRATCH/ice40_synth.log" 2>&1 \
   && nextpnr-ice40 --up5k --package sg48 --freq 20 --seed 1 \
        --json "$SCRATCH/ice40.json" --pcf "$SCRATCH/ice40.pcf" \
        --asc "$SCRATCH/ice40.asc" > "$SCRATCH/ice40_pnr.log" 2>&1 \
   && icepack "$SCRATCH/ice40.asc" "$OUT/demo_top_ice40.bin" > "$SCRATCH/ice40_pack.log" 2>&1; then
  sz=$(wc -c < "$OUT/demo_top_ice40.bin" | tr -d ' ')
  fmax=$(grep -oE "Max frequency for clock '[^']+': [0-9.]+ MHz" "$SCRATCH/ice40_pnr.log" | tail -1)
  echo "  OK  -> $OUT/demo_top_ice40.bin ($sz bytes)   ${fmax:-(fmax n/a)}"
else
  echo "  FAILED — see scratch logs (kept on failure):"
  cp "$SCRATCH"/ice40_*.log "$OUT/" 2>/dev/null
  tail -5 "$SCRATCH/ice40_pnr.log" 2>/dev/null
  fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "=== bitstream build OK (both targets) ==="
else
  echo "=== bitstream build had failures ==="
fi
exit "$fail"
