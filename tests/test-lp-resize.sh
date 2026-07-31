#!/usr/bin/env bash
# scripts/lp-resize-partition.py -- growing a logical partition by editing LP
# metadata directly, which is what bring-up needs because fastbootd's
# resize-logical-partition requires a system that boots.
#
# The risk here is a plausible-looking metadata region that liblp then rejects,
# or worse accepts with an extent laid on top of live data. So the assertions
# are about refusals as much as about the happy path.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

RESIZE="$REPO_ROOT/scripts/lp-resize-partition.py"
LPDUMP="$REPO_ROOT/scripts/lpdump-from-super.py"
MKFIX="$HERE/mklpfixture.py"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MIB=$((1024 * 1024))

python3 "$MKFIX" "$TMP/fix.bin" >/dev/null
python3 "$MKFIX" "$TMP/fix-full.bin" --slot1-full >/dev/null

section "fixture is well-formed"
out=$(python3 "$LPDUMP" "$TMP/fix.bin" --slot 0 2>&1)
assert_contains "fixture parses" "$out" "Name: alpha"
assert_contains "fixture has 2 partitions" "$out" "2 partitions"
assert_contains "alpha extent as built" "$out" "0 .. 409599 linear super 2048"

section "grows a partition and reports it"
out=$(python3 "$RESIZE" "$TMP/fix.bin" beta $((250 * MIB)) --slot 0 -o "$TMP/g.bin" 2>&1)
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "reports new size" "$out" "262144000 bytes"
assert_contains "patches both copies" "$out" "patched 2 metadata copies"

section "the grown partition reads back correctly"
out=$(python3 "$LPDUMP" "$TMP/g.bin" --slot 0 2>&1)
# beta was 100 MiB at sector 411648; the new extent is appended at the tail,
# which sits right after beta, so it stays contiguous in address but is a
# SEPARATE extent -- the tool never merges, and must not claim to.
assert_contains "beta keeps its first extent" "$out" "0 .. 204799 linear super 411648"
assert_contains "beta gained a second extent" "$out" "204800 .. 511999 linear super"
assert_contains "alpha untouched" "$out" "0 .. 409599 linear super 2048"

section "total size is exactly what was asked for"
tot=$(python3 - "$TMP/g.bin" <<'EOF'
import struct,sys
d=open(sys.argv[1],'rb').read(); base=4096+8192
hs=struct.unpack_from("<I",d,base+8)[0]
po,pn,ps=struct.unpack_from("<III",d,base+0x50)
eo,en,es=struct.unpack_from("<III",d,base+0x5c)
for i in range(pn):
    p=base+hs+po+i*ps
    if d[p:p+36].split(b'\0')[0]==b'beta':
        f,n=struct.unpack_from("<II",d,p+40)
        print(sum(struct.unpack_from("<QIQ",d,base+hs+eo+(f+k)*es)[0] for k in range(n))*512)
EOF
)
assert_eq "beta is 250 MiB" "$((250 * MIB))" "$tot"

section "refuses a stale layout whose tail is occupied"
# This is the Jul-29 super.img case: slot 1 still had *-cow snapshot partitions
# covering the tail. Patching it would place an extent over live data.
out=$(python3 "$RESIZE" "$TMP/fix-full.bin" beta $((250 * MIB)) --slot 1 -o "$TMP/no.bin" 2>&1)
rc=$?
assert_eq "exit 1" "1" "$rc"
assert_contains "explains there is no room" "$out" "free at tail"
[ -f "$TMP/no.bin" ] && nok "wrote output despite failing" || ok "no output written on failure"

section "refuses to exceed the group maximum"
# grp caps at 600 MiB and already holds 300 MiB.
out=$(python3 "$RESIZE" "$TMP/fix.bin" beta $((500 * MIB)) --slot 0 -o "$TMP/no2.bin" 2>&1)
rc=$?
assert_eq "exit 1" "1" "$rc"
assert_contains "names the group" "$out" "grp"
assert_contains "cites the maximum" "$out" "over its maximum"

section "requires an explicit slot"
out=$(python3 "$RESIZE" "$TMP/fix.bin" beta $((250 * MIB)) -o "$TMP/no3.bin" 2>&1)
assert_contains "usage shown without --slot" "$out" "lp-resize-partition.py"
[ -f "$TMP/no3.bin" ] && nok "wrote output without --slot" || ok "no output without --slot"

section "rejects an unknown partition, and says what exists"
out=$(python3 "$RESIZE" "$TMP/fix.bin" nosuch $((10 * MIB)) --slot 0 -o "$TMP/no4.bin" 2>&1)
assert_eq "exit 1" "1" "$?"
assert_contains "lists real partitions" "$out" "alpha"

section "shrinking is a no-op, not a truncation"
out=$(python3 "$RESIZE" "$TMP/fix.bin" beta $((10 * MIB)) --slot 0 -o "$TMP/no5.bin" 2>&1)
assert_contains "says nothing to do" "$out" "nothing to do"

section "idempotent: re-running at the same size changes nothing"
python3 "$RESIZE" "$TMP/g.bin" beta $((250 * MIB)) --slot 0 -o "$TMP/g2.bin" >/dev/null 2>&1
if [ -f "$TMP/g2.bin" ]; then
    nok "second run rewrote metadata" "expected a no-op"
else
    ok "second run is a no-op"
fi

section "only the named slot is touched"
before=$(python3 "$LPDUMP" "$TMP/fix.bin" --slot 2 2>&1)
after=$(python3 "$LPDUMP" "$TMP/g.bin" --slot 2 2>&1)
assert_eq "slot 2 untouched" "$before" "$after"
before1=$(python3 "$LPDUMP" "$TMP/fix.bin" --slot 1 2>&1)
after1=$(python3 "$LPDUMP" "$TMP/g.bin" --slot 1 2>&1)
assert_eq "slot 1 untouched" "$before1" "$after1"

section "checksums are recomputed, not copied"
# A stale header/tables checksum is the failure that liblp catches and we would
# not: the file still parses with our own reader.
python3 - "$TMP/g.bin" <<'EOF'
import hashlib,struct,sys
d=open(sys.argv[1],'rb').read()
bad=0
for base in (4096+8192, 4096+8192+65536*3):
    hs=struct.unpack_from("<I",d,base+8)[0]
    ts=struct.unpack_from("<I",d,base+44)[0]
    tables=d[base+hs:base+hs+ts]
    if hashlib.sha256(tables).digest()!=d[base+48:base+80]: bad+=1
    h=bytearray(d[base:base+hs]); h[12:44]=b"\0"*32
    if hashlib.sha256(bytes(h)).digest()!=d[base+12:base+44]: bad+=1
sys.exit(1 if bad else 0)
EOF
if [ $? -eq 0 ]; then ok "primary and backup checksums both valid"
else nok "checksum mismatch after patch"; fi

section "the backup copy matches the primary"
python3 - "$TMP/g.bin" <<'EOF'
import struct,sys
d=open(sys.argv[1],'rb').read()
a=4096+8192; b=a+65536*3
hs=struct.unpack_from("<I",d,a+8)[0]; ts=struct.unpack_from("<I",d,a+44)[0]
sys.exit(0 if d[a:a+hs+ts]==d[b:b+hs+ts] else 1)
EOF
if [ $? -eq 0 ]; then ok "backup is byte-identical to primary"
else nok "backup diverged from primary"; fi

summary
