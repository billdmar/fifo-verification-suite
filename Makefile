################################################################################
# Makefile — SystemVerilog FIFO Verification Suite
# Targets: help lint synth formal-bmc formal-prove formal sim sim-sweep
#          sim-fault all clean
################################################################################

SHELL := /bin/bash

# OSS CAD Suite environment script (local use; CI puts tools on PATH directly)
OSS_ENV ?= $(HOME)/oss-cad-suite/environment

# Always-exit-0 guard: source env when present, silently skip when absent.
ENV = if [ -f $(OSS_ENV) ]; then source $(OSS_ENV); fi;

# Simulation depth for a single `make sim` run (override: make sim DEPTH=32)
DEPTH ?= 8

# Simulation data width for a single `make sim` run (override: make sim DATA_WIDTH=32)
DATA_WIDTH ?= 8

# Depth sweep list for `make sim-sweep`
DEPTHS := 4 8 16 64 256

# Data-width sweep list for `make sim-width-sweep` (parameter range bounds)
DATA_WIDTHS := 1 8 64

# Sources
RTL_TOP  := rtl/sync_fifo.sv
ASYNC_TOP := rtl/async_fifo.sv
TB_SRC   := tb/tb_sync_fifo.cpp
BMC_SCR  := formal/sync_fifo_bmc.sby
PROVE_SCR := formal/sync_fifo.sby
COVER_SCR := formal/sync_fifo_cover.sby
LIVE_SCR  := formal/sync_fifo_live.sby
ASYNC_BMC_SCR   := formal/async_fifo_bmc.sby
ASYNC_COVER_SCR := formal/async_fifo_cover.sby
ASYNC_PROVE_SCR := formal/async_fifo_prove.sby
AXIS_TOP        := rtl/axis_fifo.sv
AXIS_BMC_SCR    := formal/axis_fifo_bmc.sby
AXIS_COVER_SCR  := formal/axis_fifo_cover.sby

# Verible (style/lint gate). On CI it is on PATH; locally pass the full path:
#   make lint-verible VERIBLE=$$HOME/verible/bin/verible-verilog-lint
VERIBLE ?= verible-verilog-lint
VERIBLE_RTL := rtl/sync_fifo.sv rtl/sync_fifo_properties.sv rtl/async_fifo.sv rtl/axis_fifo.sv

.DEFAULT_GOAL := help

.PHONY: help lint lint-async lint-axis lint-verible synth formal-bmc formal-prove formal-cover formal-live formal \
        formal-async-bmc formal-async-cover formal-async-prove formal-async \
        formal-axis-bmc formal-axis-cover formal-axis \
        sim sim-sweep sim-width-sweep sim-fault sim-coverage fpga-report waveforms all clean

##─────────────────────────────────────────────────────────────────────────────
## help         : Show this help message (default target)
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo ""
	@echo "Variables:"
	@echo "  DEPTH=$(DEPTH)   single sim depth  (override: make sim DEPTH=32)"
	@echo "  DEPTHS=$(DEPTHS)  sweep depths"

##─────────────────────────────────────────────────────────────────────────────
## lint         : Lint RTL with Verilator -Wall
lint:
	$(ENV) verilator --lint-only -Wall --top-module sync_fifo $(RTL_TOP)

##─────────────────────────────────────────────────────────────────────────────
## lint-async   : Lint the async (dual-clock) FIFO with Verilator -Wall
lint-async:
	$(ENV) verilator --lint-only -Wall --top-module async_fifo $(ASYNC_TOP)

##─────────────────────────────────────────────────────────────────────────────
## lint-axis    : Lint the AXI4-Stream wrapper with Verilator -Wall
lint-axis:
	$(ENV) verilator --lint-only -Wall --top-module axis_fifo $(AXIS_TOP) $(RTL_TOP)

##─────────────────────────────────────────────────────────────────────────────
## lint-verible : Style/lint gate via Verible (config in .rules.verible_lint)
lint-verible:
	$(VERIBLE) --rules_config_search $(VERIBLE_RTL)

##─────────────────────────────────────────────────────────────────────────────
## synth        : Elaborate + synthesise with Yosys and print stats
synth:
	$(ENV) yosys -q -p \
	  "read_verilog -sv $(RTL_TOP); \
	   hierarchy -top sync_fifo; \
	   proc; opt; synth -top sync_fifo; stat"

##─────────────────────────────────────────────────────────────────────────────
## formal-bmc   : Bounded Model Check (depth 20) via SymbiYosys
formal-bmc:
	$(ENV) sby -f $(BMC_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-prove : k-induction proof (depth 15) via SymbiYosys
formal-prove:
	$(ENV) sby -f $(PROVE_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-cover : Cover reachability (fill-to-full, drain-to-empty, tracked round-trip)
formal-cover:
	$(ENV) sby -f $(COVER_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-live  : Bounded liveness / progress gate (BMC depth 20) via SymbiYosys
formal-live:
	$(ENV) sby -f $(LIVE_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-async-bmc   : Async (dual-clock CDC) BMC gate (depth 16, multiclock)
formal-async-bmc:
	$(ENV) sby -f $(ASYNC_BMC_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-async-cover : Async cover reachability (full, non-empty, gray wrap, round-trip)
formal-async-cover:
	$(ENV) sby -f $(ASYNC_COVER_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-async-prove : Async k-induction (informational — basecase passes, step open)
formal-async-prove:
	$(ENV) sby -f $(ASYNC_PROVE_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-async : Run async BMC + cover (the async formal gate)
formal-async: formal-async-bmc formal-async-cover

##─────────────────────────────────────────────────────────────────────────────
## formal-axis-bmc    : AXI4-Stream protocol-compliance BMC (depth 20)
formal-axis-bmc:
	$(ENV) sby -f $(AXIS_BMC_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-axis-cover  : AXI4-Stream handshake cover witnesses (depth 30)
formal-axis-cover:
	$(ENV) sby -f $(AXIS_COVER_SCR)

##─────────────────────────────────────────────────────────────────────────────
## formal-axis  : Run AXI BMC + cover (the AXI formal gate)
formal-axis: formal-axis-bmc formal-axis-cover

##─────────────────────────────────────────────────────────────────────────────
## formal       : Run all sync + async + AXI formal gates
formal: formal-bmc formal-prove formal-cover formal-live formal-async formal-axis

##─────────────────────────────────────────────────────────────────────────────
## sim          : Build + run Verilator TB at DEPTH=$(DEPTH) DATA_WIDTH=$(DATA_WIDTH); VCD -> docs/waveforms/
sim:
	rm -rf obj_dir
	$(ENV) verilator --cc --exe --build -Wall --trace \
	  -GDEPTH=$(DEPTH) -GDATA_WIDTH=$(DATA_WIDTH) \
	  --top-module sync_fifo \
	  $(RTL_TOP) $(TB_SRC) \
	  -CFLAGS "-DDEPTH_PARAM=$(DEPTH) -DDW_PARAM=$(DATA_WIDTH)" \
	  -o sim_fifo
	./obj_dir/sim_fifo

##─────────────────────────────────────────────────────────────────────────────
## sim-sweep    : Run sim at each depth in DEPTHS ($(DEPTHS))
sim-sweep:
	@for d in $(DEPTHS); do \
	  echo ""; \
	  echo "════ sim DEPTH=$$d ════"; \
	  $(MAKE) sim DEPTH=$$d || exit 1; \
	done

##─────────────────────────────────────────────────────────────────────────────
## sim-width-sweep : Run sim at each data width in DATA_WIDTHS ($(DATA_WIDTHS))
sim-width-sweep:
	@for w in $(DATA_WIDTHS); do \
	  echo ""; \
	  echo "════ sim DATA_WIDTH=$$w ════"; \
	  $(MAKE) sim DATA_WIDTH=$$w || exit 1; \
	done

##─────────────────────────────────────────────────────────────────────────────
## sim-fault    : Inject fault via INJECT_FAULT; SUCCEEDS only if checker catches it
sim-fault:
	rm -rf obj_dir
	$(ENV) verilator --cc --exe --build -Wall --trace \
	  -GDEPTH=$(DEPTH) \
	  --top-module sync_fifo \
	  $(RTL_TOP) $(TB_SRC) \
	  -CFLAGS "-DDEPTH_PARAM=$(DEPTH) -DINJECT_FAULT" \
	  -o sim_fifo
	@if ./obj_dir/sim_fifo; then \
	  echo "ERROR: fault was NOT caught — scoreboard is vacuous!"; \
	  exit 1; \
	else \
	  echo "PASS: fault correctly caught by scoreboard."; \
	fi

##─────────────────────────────────────────────────────────────────────────────
## sim-coverage : Build with --coverage, run TB, post-process coverage.dat
sim-coverage:
	rm -rf obj_dir_cov coverage.dat logs_annotated
	$(ENV) verilator --cc --exe --build -Wall --trace --coverage \
	  -GDEPTH=$(DEPTH) \
	  --top-module sync_fifo \
	  $(RTL_TOP) $(TB_SRC) \
	  -CFLAGS "-DDEPTH_PARAM=$(DEPTH)" \
	  -Mdir obj_dir_cov -o sim_fifo_cov
	./obj_dir_cov/sim_fifo_cov
	$(ENV) verilator_coverage --annotate logs_annotated coverage.dat

##─────────────────────────────────────────────────────────────────────────────
## fpga-report  : Real Yosys+nextpnr P&R area/timing sweep (ECP5 + iCE40)
fpga-report:
	./scripts/fpga_report.sh

##─────────────────────────────────────────────────────────────────────────────
## waveforms    : Regenerate docs/waveforms/*.svg from the sim VCD (needs `make sim`)
waveforms:
	python3 scripts/gen_waveforms.py

##─────────────────────────────────────────────────────────────────────────────
## all          : CI gate set — lint, synth, formal (sync/async/AXI), sim
all: lint lint-async lint-axis synth formal-bmc formal-live formal-async formal-axis sim

##─────────────────────────────────────────────────────────────────────────────
## clean        : Remove build artefacts (leaves source and docs/waveforms/ intact)
clean:
	rm -rf obj_dir/ obj_dir_*/
	rm -rf formal/sync_fifo_bmc/
	rm -rf formal/sync_fifo_prove/
	rm -rf formal/sync_fifo/
	rm -rf formal/sync_fifo_cover/
	rm -rf formal/sync_fifo_live/
	rm -rf formal/async_fifo_bmc/
	rm -rf formal/async_fifo_cover/
	rm -rf formal/async_fifo_prove/
	rm -rf formal/axis_fifo_bmc/
	rm -rf formal/axis_fifo_cover/
	rm -rf logs_annotated/
	rm -f  *.vcd
	rm -f  coverage.dat
	rm -f  logfile.txt
