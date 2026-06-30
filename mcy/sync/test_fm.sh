#!/bin/bash
# mcy test: a mutant is KILLED (FAIL) if our formal property suite detects a
# counterexample on the mutated sync_fifo; SURVIVES (PASS) if all assertions
# still hold. Mirrors the mcy_demo/bitcnt/test_fm.sh protocol.
exec 2>&1
set -ex

## Create the mutated sync_fifo as RTLIL.
bash "$SCRIPTS/create_mutated.sh" -o mutated.il

## Run our formal property check against the mutated design.
ln -sf ../../test_fm.sby .
sby -f test_fm.sby || true

## Report the verdict: PASS = mutant survived; anything else (FAIL, or an
## ERROR/UNKNOWN from a mutation that makes the design un-checkable) = killed.
st=$(cat test_fm/status 2>/dev/null | awk '{print $1}')
if [ "$st" = "PASS" ]; then echo "1 PASS" >> output.txt; else echo "1 FAIL" >> output.txt; fi

exit 0
