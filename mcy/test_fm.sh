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
sby -f test_fm.sby

## Report the engine's verdict (pass = mutant survived, fail = mutant killed).
## Use awk (gawk is not bundled in this OSS CAD Suite); BSD awk is sufficient.
awk "{ print 1, \$1; }" test_fm/status >> output.txt

exit 0
