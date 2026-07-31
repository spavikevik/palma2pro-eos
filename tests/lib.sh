#!/usr/bin/env bash
# Minimal test helpers. No bats, no pip -- neither is available on this host,
# and a test suite that cannot be run is worse than none.

set -uo pipefail

PASS=0
FAIL=0
FAILED_NAMES=()

: "${REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_green() { printf '\033[32m%s\033[0m' "$1"; }
_red()   { printf '\033[31m%s\033[0m' "$1"; }

ok() {
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green 'ok  ')" "$1"
}

nok() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '  %s %s\n' "$(_red 'FAIL')" "$1"
    [ $# -gt 1 ] && printf '       %s\n' "$2"
    return 0
}

# assert_eq <name> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected [$2] got [$3]"; fi
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) nok "$1" "output did not contain [$3]; got: $(printf '%s' "$2" | head -c 200)" ;;
    esac
}

# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
    case "$2" in
        *"$3"*) nok "$1" "output unexpectedly contained [$3]" ;;
        *) ok "$1" ;;
    esac
}

# assert_fails <name> <cmd...>  -- command must exit non-zero
assert_fails() {
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then
        nok "$name" "command succeeded but should have failed: $*"
    else
        ok "$name"
    fi
}

# assert_succeeds <name> <cmd...>
assert_succeeds() {
    local name=$1; shift
    local out
    if out=$("$@" 2>&1); then
        ok "$name"
    else
        nok "$name" "command failed: $* -> $(printf '%s' "$out" | tail -3)"
    fi
}

section() { printf '\n%s\n' "$1"; }

summary() {
    printf '\n----------------------------------------\n'
    if [ "$FAIL" -eq 0 ]; then
        printf '%s  %d passed\n' "$(_green 'ALL PASS')" "$PASS"
        return 0
    fi
    printf '%s  %d passed, %d failed\n' "$(_red 'FAILURES')" "$PASS" "$FAIL"
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    return 1
}
