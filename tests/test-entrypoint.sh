#!/usr/bin/env bash
# Security behaviour of build/ssh/entrypoint.sh.
#
# These are the tests that matter most in this repo: the entrypoint is the only
# thing standing between a borrowed machine and an open SSH server. Each case
# asserts it FAILS CLOSED rather than degrading to something weaker.
#
# Driven via SELFTEST=1, which runs the validation phase and exits without
# touching /home/builder, sshd_config or host keys -- so this runs on macOS.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/lib.sh"

EP="$REPO_ROOT/build/ssh/entrypoint.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REAL_KEY="<host key removed> palma2pro-builder"

# run_ep <keyfile-or-empty> <allowed_from-or-unset> [extra env assignments...]
run_ep() {
    local keyfile=$1; shift
    local allowed=$1; shift
    local -a env=(SELFTEST=1)
    [ -n "$keyfile" ] && env+=("KEYS_SRC=$keyfile") || env+=("KEYS_SRC=$TMP/definitely-absent")
    [ "$allowed" != "__unset__" ] && env+=("ALLOWED_FROM=$allowed")
    env "${env[@]}" "$@" bash "$EP" 2>&1
}

section "entrypoint: refuses to start without credentials"

out=$(run_ep "" "192.168.1.42"); rc=$?
assert_eq  "no key file -> non-zero exit" "1" "$rc"
assert_contains "no key file -> explains both ways to supply one" "$out" "AUTHORIZED_KEYS"

: > "$TMP/empty"
out=$(run_ep "$TMP/empty" "192.168.1.42"); rc=$?
assert_eq "empty key file -> non-zero exit" "1" "$rc"
assert_contains "empty key file -> says why" "$out" "no key lines"

printf '# just a comment\n\n   \n' > "$TMP/comments"
out=$(run_ep "$TMP/comments" "192.168.1.42"); rc=$?
assert_eq "comments-only key file -> rejected" "1" "$rc"
assert_contains "comments-only -> counted as empty" "$out" "no key lines"

section "entrypoint: rejects a private key (operator mistake worth stopping for)"

printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----\n' > "$TMP/priv"
out=$(run_ep "$TMP/priv" "192.168.1.42"); rc=$?
assert_eq "private key file -> rejected" "1" "$rc"
assert_contains "private key -> names the mistake" "$out" "PRIVATE key"

out=$(SELFTEST=1 KEYS_SRC="$TMP/definitely-absent" ALLOWED_FROM=1.2.3.4 \
      AUTHORIZED_KEYS="$(cat "$TMP/priv")" bash "$EP" 2>&1); rc=$?
assert_eq "private key via env -> rejected too" "1" "$rc"
assert_contains "private key via env -> names the mistake" "$out" "PRIVATE key"

section "entrypoint: rejects malformed key material"

printf 'this is not a key at all\n' > "$TMP/garbage"
out=$(run_ep "$TMP/garbage" "192.168.1.42"); rc=$?
assert_eq "garbage line -> rejected" "1" "$rc"
assert_contains "garbage -> says not an OpenSSH public key" "$out" "not an OpenSSH public key"

section "entrypoint: host allow-list is mandatory"

printf '%s\n' "$REAL_KEY" > "$TMP/good"
out=$(run_ep "$TMP/good" "__unset__"); rc=$?
assert_eq "valid key but no ALLOWED_FROM -> rejected" "1" "$rc"
assert_contains "missing ALLOWED_FROM -> explains" "$out" "ALLOWED_FROM is required"

out=$(run_ep "$TMP/good" ",  ,"); rc=$?
assert_eq "ALLOWED_FROM of only separators -> rejected" "1" "$rc"
assert_contains "separator-only -> says parsed to nothing" "$out" "parsed to nothing"

section "entrypoint: accepts valid config and builds the right AllowUsers"

out=$(run_ep "$TMP/good" "192.168.1.42"); rc=$?
assert_eq "valid single host -> exit 0" "0" "$rc"
assert_contains "single host -> AllowUsers builder@ip" "$out" "SELFTEST_ALLOW AllowUsers builder@192.168.1.42"
assert_contains "single host -> counts one key" "$out" "SELFTEST_OK key_count=1"

out=$(run_ep "$TMP/good" "192.168.1.42, 10.0.0.5 ,192.168.1.*")
assert_contains "multiple hosts -> all terms present, whitespace stripped" "$out" \
  "SELFTEST_ALLOW AllowUsers builder@192.168.1.42 builder@10.0.0.5 builder@192.168.1.*"

out=$(run_ep "$TMP/good" "any")
assert_contains "ALLOWED_FROM=any -> unrestricted AllowUsers" "$out" "SELFTEST_ALLOW AllowUsers builder"
assert_contains "ALLOWED_FROM=any -> warns loudly" "$out" "WARNING"

# Two keys, one commented out: the count must reflect only the live one.
{ printf '%s\n' "$REAL_KEY"; printf '# %s\n' "$REAL_KEY"; } > "$TMP/two"
out=$(run_ep "$TMP/two" "1.2.3.4")
assert_contains "commented key not counted" "$out" "SELFTEST_OK key_count=1"

out=$(SELFTEST=1 KEYS_SRC="$TMP/definitely-absent" ALLOWED_FROM=1.2.3.4 \
      AUTHORIZED_KEYS="$REAL_KEY" bash "$EP" 2>&1)
assert_contains "key via AUTHORIZED_KEYS env accepted" "$out" "SELFTEST_OK key_count=1"
assert_contains "env path reported" "$out" "from \$AUTHORIZED_KEYS"

section "entrypoint: no side effects in the validation phase"

# A rejected config must not have appended anything anywhere. Point SSHD_CONFIG
# at a sentinel and confirm it is untouched even on the success path.
printf 'ORIGINAL\n' > "$TMP/sshd_config"
SELFTEST=1 KEYS_SRC="$TMP/good" ALLOWED_FROM=1.2.3.4 SSHD_CONFIG="$TMP/sshd_config" \
    bash "$EP" >/dev/null 2>&1
assert_eq "selftest does not modify sshd_config" "ORIGINAL" "$(cat "$TMP/sshd_config")"

section "entrypoint: detects a locked build account"

# sshd with UsePAM no rejects a '!' shadow field with "account is locked" BEFORE
# checking the key, so a good key looks rejected. This cost a debugging round
# trip on the real container.
printf 'builder:!:19000:0:99999:7:::\n' > "$TMP/shadow-locked"
out=$(SELFTEST=1 KEYS_SRC="$TMP/good" ALLOWED_FROM=1.2.3.4 \
      SHADOW_FILE="$TMP/shadow-locked" bash "$EP" 2>&1)
assert_contains "locked account is detected" "$out" "is LOCKED"
assert_contains "locked account reported for tests" "$out" "SELFTEST_LOCKED builder"
assert_contains "explains the misleading sshd message" "$out" "account is locked"

printf 'builder:!!:19000:0:99999:7:::\n' > "$TMP/shadow-locked2"
out=$(SELFTEST=1 KEYS_SRC="$TMP/good" ALLOWED_FROM=1.2.3.4 \
      SHADOW_FILE="$TMP/shadow-locked2" bash "$EP" 2>&1)
assert_contains "'!!' also detected as locked" "$out" "is LOCKED"

printf 'builder:*:19000:0:99999:7:::\n' > "$TMP/shadow-ok"
out=$(SELFTEST=1 KEYS_SRC="$TMP/good" ALLOWED_FROM=1.2.3.4 \
      SHADOW_FILE="$TMP/shadow-ok" bash "$EP" 2>&1)
assert_not_contains "'*' is not treated as locked" "$out" "is LOCKED"
assert_contains "'*' still validates fine" "$out" "SELFTEST_OK"

printf 'builder:$6$abc$hash:19000:0:99999:7:::\n' > "$TMP/shadow-hash"
out=$(SELFTEST=1 KEYS_SRC="$TMP/good" ALLOWED_FROM=1.2.3.4 \
      SHADOW_FILE="$TMP/shadow-hash" bash "$EP" 2>&1)
assert_not_contains "a real hash is not treated as locked" "$out" "is LOCKED"

summary
