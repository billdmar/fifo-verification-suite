#!/bin/bash
# mcy test for axis_fifo: a mutant is KILLED (FAIL) if the inlined AXI4-Stream
# protocol properties detect a counterexample on the mutated wrapper.
exec 2>&1
set -ex

bash "$SCRIPTS/create_mutated.sh" -o mutated.il
ln -sf ../../test_fm.sby .
# Don't let a nonzero sby exit abort the whole campaign; classify from status.
sby -f test_fm.sby || true
# status is PASS (mutant survived) or FAIL (assertion fired => killed). Any other
# outcome (ERROR/UNKNOWN — e.g. a mutation that makes the design un-checkable) is
# treated as FAIL: such a mutant is caught, not a silent survivor.
st=$(cat test_fm/status 2>/dev/null | awk '{print $1}')
if [ "$st" = "PASS" ]; then echo "1 PASS" >> output.txt; else echo "1 FAIL" >> output.txt; fi
exit 0
