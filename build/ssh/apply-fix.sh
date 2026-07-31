#!/usr/bin/env bash
# Fix the two reasons the first container could not be logged into, then rebuild.
# Run this ON THE BUILD MACHINE, from the aosp-builder directory:
#
#     cd /Volumes/Storage/aosp-builder
#     bash apply-fix.sh
#
# 1. LOCKED ACCOUNT (the actual blocker)
#    `useradd` with no password writes '!' into /etc/shadow. sshd with
#    `UsePAM no` treats that as a locked account and refuses BEFORE looking at
#    the key, logging the misleading:
#        User builder not allowed because account is locked
#    '*' means "no password can ever match" without locking, so public-key auth
#    works and password auth stays impossible.
#
# 2. WRONG ALLOWED SOURCE
#    Docker publishes ports through a NAT, so connections arrive from the
#    Docker Desktop gateway (192.168.65.1), not from the client's LAN address.
#    `AllowUsers builder@192.168.1.42` could never match.
#
#    Being honest about what this means: because every connection arrives as the
#    gateway, the source-host restriction is syntactic, not a security control.
#    The real gate is the dedicated key, plus no forwarding, no root, no sudo.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> 1/3 patching Dockerfile: useradd -p '*'"
if grep -q "useradd -m -u \"\${BUILDER_UID}\" -g \"\${BUILDER_GID}\" -s /bin/bash -p '\*' builder" Dockerfile; then
    echo "    already patched"
else
    cp Dockerfile Dockerfile.bak
    # Insert -p '*' before the trailing username.
    sed -i.tmp "s|useradd -m -u \"\${BUILDER_UID}\" -g \"\${BUILDER_GID}\" -s /bin/bash builder|useradd -m -u \"\${BUILDER_UID}\" -g \"\${BUILDER_GID}\" -s /bin/bash -p '*' builder|" Dockerfile
    rm -f Dockerfile.tmp
    grep -q -- "-p '\*' builder" Dockerfile || {
        echo "ERROR: patch did not apply; Dockerfile left as Dockerfile.bak" >&2
        mv Dockerfile.bak Dockerfile
        exit 1
    }
    echo "    patched (backup: Dockerfile.bak)"
fi

echo "==> 2/3 setting allowed source to the Docker gateway"
echo "192.168.65.1" > allowed-from.txt
echo "    allowed-from.txt = $(cat allowed-from.txt)"

echo "==> 3/3 adding REBUILD=1 support to start-builder.sh"
if grep -q 'REBUILD' start-builder.sh; then
    echo "    already present"
else
    cp start-builder.sh start-builder.sh.bak
    python3 - <<'PY'
p = "start-builder.sh"
s = open(p).read()
old = 'if ! $ENGINE image inspect "$NAME:latest" >/dev/null 2>&1; then'
new = ('if [ "${REBUILD:-0}" = "1" ]; then\n'
       '    echo "==> REBUILD=1: discarding existing image"\n'
       '    $ENGINE image rm -f "$NAME:latest" >/dev/null 2>&1 || true\n'
       'fi\n'
       + old)
assert old in s, "anchor not found in start-builder.sh"
open(p, "w").write(s.replace(old, new, 1))
print("    patched (backup: start-builder.sh.bak)")
PY
fi

bash -n start-builder.sh || { echo "ERROR: start-builder.sh has a syntax error" >&2; exit 1; }

echo
echo "==> rebuilding and restarting (the image must be rebuilt for the shadow fix)"
REBUILD=1 bash ./start-builder.sh
