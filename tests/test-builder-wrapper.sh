#!/usr/bin/env bash
# scripts/builder.sh -- argument handling and the host-key guard.
#
# No network here: these assert the wrapper refuses to act on an unpinned or
# mismatched host key, and that its config loads. The commands that do reach the
# builder are exercised for real against the live container.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/lib.sh"

B="$REPO_ROOT/scripts/builder.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

section "builder.sh: config and usage"

assert_succeeds "config file parses as shell" bash -n "$REPO_ROOT/build/ssh/builder.env"

out=$(bash "$B" bogus 2>&1 || true)
assert_contains "unknown command prints usage" "$out" "One entry point for the remote AOSP builder"
assert_contains "usage lists build" "$out" "build [target]"
assert_contains "usage lists logs" "$out" "logs [-f]"
bash "$B" bogus >/dev/null 2>&1; rc=$?
assert_eq "unknown command exits 2" "2" "$rc"

# Required values must be present, or every command silently targets the wrong box.
for v in BUILDER_HOST BUILDER_PORT BUILDER_USER BUILDER_KEY BUILDER_TREE BUILDER_LUNCH; do
    val=$(. "$REPO_ROOT/build/ssh/builder.env"; eval "printf '%s' \"\${$v:-}\"")
    if [ -n "$val" ]; then ok "config defines $v"; else nok "config defines $v" "empty"; fi
done

lunch=$(. "$REPO_ROOT/build/ssh/builder.env"; printf '%s' "$BUILDER_LUNCH")
assert_contains "lunch target uses the bp1a release (matches BUILD_ID)" "$lunch" "-bp1a-"
assert_contains "lunch target names our product" "$lunch" "lineage_Palma2_Pro_C"

section "builder.sh: pin validates before trusting"

out=$(bash "$B" pin 2>&1 || true)
assert_contains "pin without a fingerprint is rejected" "$out" "usage: builder.sh pin"

# A wrong fingerprint must refuse and must NOT write known_hosts.
cp "$REPO_ROOT/build/ssh/known_hosts" "$TMP/known_hosts.bak" 2>/dev/null || true
out=$(bash "$B" pin "SHA256:definitelyNotTheRealFingerprintAAAAAAAAAAAA" 2>&1 || true)
assert_contains "wrong fingerprint refuses" "$out" "MISMATCH"
assert_contains "wrong fingerprint says not to proceed" "$out" "Do not proceed"
if [ -f "$TMP/known_hosts.bak" ]; then
    if diff -q "$TMP/known_hosts.bak" "$REPO_ROOT/build/ssh/known_hosts" >/dev/null; then
        ok "known_hosts untouched after a mismatch"
    else
        nok "known_hosts untouched after a mismatch" "file was modified"
        cp "$TMP/known_hosts.bak" "$REPO_ROOT/build/ssh/known_hosts"
    fi
fi

section "builder.sh: refuses to act without a pinned key"

# Point the wrapper at an empty repo copy so known_hosts is absent.
mkdir -p "$TMP/fake/scripts" "$TMP/fake/build/ssh"
cp "$B" "$TMP/fake/scripts/"
cp "$REPO_ROOT/build/ssh/builder.env" "$TMP/fake/build/ssh/"
: > "$TMP/fake/build/ssh/known_hosts"   # exists but empty -> not pinned
for c in status sync logs; do
    out=$(bash "$TMP/fake/scripts/builder.sh" "$c" 2>&1 || true)
    assert_contains "$c refuses when host key is not pinned" "$out" "host key not pinned"
done

section "builder.sh: build guards"

# The build subcommand must not hardcode a target; default is the cheap config check.
assert_contains "default build target is 'nothing'" "$(grep -m1 'target=\${1:-' "$B")" "nothing"
# The env prefix is assembled from builder.env rather than hardcoded, so assert
# the mechanism exists and that the build actually applies it.
assert_contains "env prefix is built from BUILDER_UNSET_ENV" \
  "$(grep -m1 'for v in \${BUILDER_UNSET_ENV' "$B")" "-u \$v"
assert_contains "env prefix is built from BUILDER_SET_ENV" \
  "$(grep -m1 'for a in \${BUILDER_SET_ENV' "$B")" "BUILDER_SET_ENV"
assert_contains "build invokes the login shell through the env prefix" \
  "$(grep -m1 'nohup \$ENV_PREFIX' "$B")" "nohup \$ENV_PREFIX bash -lc"
assert_contains "build refuses if a build is already running" \
  "$(grep -m1 'a build is already running' "$B")" "a build is already running"
assert_contains "build refuses before the sync finishes" \
  "$(grep -m1 'repo sync has not finished' "$B")" "repo sync has not finished"

section "Dockerfile: no memory caps baked in"

DF="$REPO_ROOT/build/ssh/Dockerfile"
assert_not_contains "no NINJA_HIGHMEM_NUM_JOBS in ENV" "$(grep -E '^ENV|^ +[A-Z_]+=' "$DF" | grep -v '^#')" "NINJA_HIGHMEM_NUM_JOBS="
assert_not_contains "no _JAVA_OPTIONS in ENV" "$(grep -E '^ENV|^ +[A-Z_]+=' "$DF" | grep -v '^#')" "_JAVA_OPTIONS="
assert_contains "ccache still enabled" "$(grep -E 'USE_CCACHE' "$DF")" "USE_CCACHE=1"
assert_contains "builder account created unlocked (-p '*')" "$(grep -m1 useradd "$DF" || grep -A8 'BUILDER_UID=' "$DF" | grep useradd)" "-p '*'"

section "environment: Docker ENV does not reach SSH sessions"

# Verified empirically on the live container: LANG and USE_CCACHE were unset in
# BOTH login and non-login SSH shells despite the Dockerfile ENV setting them.
# Docker ENV populates PID 1 only, and sshd builds a fresh environment per
# session (UsePAM no, so /etc/environment is not read either). Two consequences
# are guarded here.

# 1. The image must ALSO write profile.d, which a login shell does source.
assert_contains "Dockerfile writes /etc/profile.d for SSH login shells" \
  "$(grep -c 'profile.d/aosp-build.sh' "$DF")" "2"
assert_contains "profile.d exports ccache" \
  "$(grep -A8 'profile.d' "$DF" | grep -m1 USE_CCACHE)" "export USE_CCACHE=1"
assert_contains "profile.d exports the locale" \
  "$(grep -A8 'profile.d' "$DF" | grep -m1 LC_ALL)" "export LC_ALL=C.UTF-8"

# 2. The runtime override must carry everything the build needs, so a container
#    started from an older image is still correct without a rebuild.
setenv=$(. "$REPO_ROOT/build/ssh/builder.env"; printf '%s' "$BUILDER_SET_ENV")
for v in USE_CCACHE=1 CCACHE_DIR=/aosp/.ccache CCACHE_EXEC=/usr/bin/ccache LC_ALL=C.UTF-8 LANG=C.UTF-8; do
    assert_contains "runtime override sets $v" "$setenv" "$v"
done
unsetenv=$(. "$REPO_ROOT/build/ssh/builder.env"; printf '%s' "$BUILDER_UNSET_ENV")
for v in NINJA_HIGHMEM_NUM_JOBS _JAVA_OPTIONS; do
    assert_contains "runtime override unsets $v" "$unsetenv" "$v"
done

summary
