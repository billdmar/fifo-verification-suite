#!/bin/bash
# mcy test for async_fifo: a mutant is KILLED (FAIL) if the inlined multi-clock
# CDC properties detect a counterexample on the mutated design.
exec 2>&1
set -ex

bash "$SCRIPTS/create_mutated.sh" -o mutated.il
ln -sf ../../test_fm.sby .
sby -f test_fm.sby || true
st=$(cat test_fm/status 2>/dev/null | awk '{print $1}')
if [ "$st" = "PASS" ]; then echo "1 PASS" >> output.txt; else echo "1 FAIL" >> output.txt; fi
exit 0
