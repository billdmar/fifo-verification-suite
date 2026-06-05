################################################################################
# Makefile — sync-fifo-formal
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

# Depth sweep list for `make sim-sweep`
DEPTHS := 4 8 16 64 256

# Sources
RTL_TOP  := rtl/sync_fifo.sv
TB_SRC   := tb/tb_sync_fifo.cpp
BMC_SCR  := formal/sync_fifo_bmc.sby
PROVE_SCR := formal/sync_fifo.sby
COVER_SCR := formal/sync_fifo_cover.sby

.DEFAULT_GOAL := help

.PHONY: help lint synth formal-bmc formal-prove formal-cover formal sim sim-sweep sim-fault all clean

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
## formal       : Run formal-bmc, formal-prove, and formal-cover
formal: formal-bmc formal-prove formal-cover

##─────────────────────────────────────────────────────────────────────────────
## sim          : Build + run Verilator TB at DEPTH=$(DEPTH); VCD -> docs/waveforms/
sim:
	rm -rf obj_dir
	$(ENV) verilator --cc --exe --build -Wall --trace \
	  -GDEPTH=$(DEPTH) \
	  --top-module sync_fifo \
	  $(RTL_TOP) $(TB_SRC) \
	  -CFLAGS "-DDEPTH_PARAM=$(DEPTH)" \
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
## all          : CI gate set — lint synth formal-bmc sim
all: lint synth formal-bmc sim

##─────────────────────────────────────────────────────────────────────────────
## clean        : Remove build artefacts (leaves source and docs/waveforms/ intact)
clean:
	rm -rf obj_dir/ obj_dir_*/
	rm -rf formal/sync_fifo_bmc/
	rm -rf formal/sync_fifo_prove/
	rm -rf formal/sync_fifo/
	rm -rf formal/sync_fifo_cover/
	rm -f  *.vcd
	rm -f  coverage.dat
	rm -f  logfile.txt
