#!/usr/bin/env bash
# flash-logical-via-edl.py and sync-to-builder.sh.
#
# flash-logical writes raw sectors into a live device's `super`. Getting an
# extent offset wrong there overwrites a neighbouring partition, so the dry-run
# plan and its refusals are worth testing properly. A fake `edl` is placed on
# PATH to prove nothing is ever invoked without --go.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/lib.sh"

FL="$REPO_ROOT/scripts/flash-logical-via-edl.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Tripwire: if the script shells out to edl during a dry run, this records it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/edl" <<'EOF'
#!/bin/sh
echo "EDL_WAS_INVOKED $*" >> "$EDL_TRIPWIRE"
exit 0
EOF
chmod +x "$TMP/bin/edl"
export EDL_TRIPWIRE="$TMP/tripwire"
: > "$EDL_TRIPWIRE"

# lpdump fixture in the real format the parser expects.
cat > "$TMP/lpdump.txt" <<'EOF'
Metadata version: 10.2
Partition table:
------------------------
  Name: product_b
  Group: qti_dynamic_partitions
  Attributes: readonly
  Extents:
    0 .. 2047 linear super 4096
    2048 .. 4095 linear super 8192
------------------------
  Name: system_b
  Group: qti_dynamic_partitions
  Attributes: readonly
  Extents:
    0 .. 2047 linear super 16384
------------------------
  Name: misaligned_b
  Group: qti_dynamic_partitions
  Extents:
    0 .. 2047 linear super 1
------------------------
EOF

# Two 2048-sector extents = 2 MiB total for product_b.
dd if=/dev/zero of="$TMP/fits.img" bs=1024 count=1500 2>/dev/null
dd if=/dev/zero of="$TMP/toobig.img" bs=1024 count=4096 2>/dev/null

SUPER_OFFSET=186679296   # 0x0b208000, verified against this device's GPT

section "flash-logical-via-edl.py: dry-run plan"

out=$(PATH="$TMP/bin:$PATH" python3 "$FL" "$TMP/fits.img" "$TMP/lpdump.txt" product_b 2>&1)
assert_eq "exit 0 on a valid dry run" "0" "$?"
assert_contains "reports both extents" "$out" "2 extents"
assert_contains "says plan only" "$out" "plan only"

# Sector for extent 1: (SUPER_OFFSET + 4096*512) / 4096
exp1=$(( (SUPER_OFFSET + 4096 * 512) / 4096 ))
exp2=$(( (SUPER_OFFSET + 8192 * 512) / 4096 ))
assert_contains "extent 1 maps to the right absolute sector" "$out" "sector=$exp1"
assert_contains "extent 2 maps to the right absolute sector" "$out" "sector=$exp2"

# 1500 KiB of image across two 1 MiB extents: all of the first, part of the second.
assert_contains "splits the image across extents" "$out" "image[0:1048576]"
assert_contains "second extent takes the remainder" "$out" "image[1048576:1536000]"

section "flash-logical-via-edl.py: refusals"

assert_fails "refuses an image larger than the partition" \
  env PATH="$TMP/bin:$PATH" python3 "$FL" "$TMP/toobig.img" "$TMP/lpdump.txt" product_b
out=$(PATH="$TMP/bin:$PATH" python3 "$FL" "$TMP/toobig.img" "$TMP/lpdump.txt" product_b 2>&1 || true)
assert_contains "oversize refusal names the reason" "$out" "LARGER than partition"

assert_fails "refuses an unknown partition name" \
  env PATH="$TMP/bin:$PATH" python3 "$FL" "$TMP/fits.img" "$TMP/lpdump.txt" nosuch_b

# Must be small enough to pass the size check, so the alignment check is what
# rejects it -- the size check runs first, by design.
dd if=/dev/zero of="$TMP/small.img" bs=1024 count=100 2>/dev/null
out=$(PATH="$TMP/bin:$PATH" python3 "$FL" "$TMP/small.img" "$TMP/lpdump.txt" misaligned_b --go 2>&1 || true)
assert_contains "refuses a non-4096-aligned extent" "$out" "not 4096-aligned"
assert_eq "no edl call for a misaligned extent" "" "$(cat "$EDL_TRIPWIRE")"

section "flash-logical-via-edl.py: never writes without --go"

assert_eq "edl was never invoked during dry runs" "" "$(cat "$EDL_TRIPWIRE")"

section "sync-to-builder.sh: argument and key validation"

SB="$REPO_ROOT/scripts/sync-to-builder.sh"
assert_fails "no target -> usage" bash "$SB"
out=$(bash "$SB" 2>&1 || true)
assert_contains "usage mentions the expected form" "$out" "user@host"

assert_fails "missing builder key -> refuses" \
  env BUILDER_KEY="$TMP/nonexistent-key" bash "$SB" build@example.invalid
out=$(BUILDER_KEY="$TMP/nonexistent-key" bash "$SB" build@example.invalid 2>&1 || true)
assert_contains "missing key refusal names the path" "$out" "no builder key"

section "shell scripts: syntax"

for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/build/ssh/entrypoint.sh \
         /Volumes/Storage/aosp-builder/start-builder.sh \
         /Volumes/Storage/aosp-builder/stop-builder.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then ok "syntax: $(basename "$f")"
    else nok "syntax: $(basename "$f")"; fi
done

section "python scripts: syntax"

for f in "$REPO_ROOT"/scripts/*.py "$REPO_ROOT"/tests/mkbootfixture.py; do
    [ -f "$f" ] || continue
    if python3 -m py_compile "$f" 2>/dev/null; then ok "syntax: $(basename "$f")"
    else nok "syntax: $(basename "$f")"; fi
done
rm -rf "$REPO_ROOT/scripts/__pycache__" "$REPO_ROOT/tests/__pycache__" 2>/dev/null

summary
