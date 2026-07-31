#!/usr/bin/env bash
# Run every test suite. No dependencies beyond bash and python3.
#
#   tests/run-all.sh
#
# Everything here runs on the dev Mac with no device attached and no container
# engine: the suites drive pure logic (image patching, extent arithmetic, the
# SSH entrypoint's validation phase) rather than hardware.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TOTAL_FAIL=0
declare -a FAILED_SUITES=()

for suite in tests/test-*.sh; do
    printf '\n========================================\n'
    printf '%s\n' "$suite"
    printf '========================================\n'
    if bash "$suite"; then :; else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        FAILED_SUITES+=("$suite")
    fi
done

printf '\n########################################\n'
if [ "$TOTAL_FAIL" -eq 0 ]; then
    printf 'ALL SUITES PASSED\n'
    exit 0
fi
printf '%d SUITE(S) FAILED:\n' "$TOTAL_FAIL"
for s in "${FAILED_SUITES[@]}"; do printf '  - %s\n' "$s"; done
exit 1
