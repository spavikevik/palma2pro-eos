#!/usr/bin/env bash
# Set the bootloader unlock flags directly in `devinfo` over EDL.
#
# WHY THIS EXISTS
# ---------------
# The normal route -- `fastboot flashing unlock` -- puts a confirmation menu on
# the screen and waits for a physical keypress. On the Palma 2 Pro that menu is
# invisible: the Fairphone ABL renders to a standard DSI framebuffer, while this
# device's panel is an EPD driven through the sepdc/EBC controller, which the
# Fairphone bootloader knows nothing about. You end up pressing keys blind at a
# menu whose default option is "do not unlock".
#
# STRUCT
# ------
# Qualcomm's device_info, confirmed against this device's own dumps:
#
#   offset 0..12   "ANDROID-BOOT!"              magic
#   offset 13      is_unlocked                  observed 0x00
#   offset 14      is_unlock_critical           observed 0x00
#   offset 15      is_charger_screen_enabled    observed 0x01
#
# Cross-checked against `fastboot oem device-info`, which reported
# unlocked=false, critical unlocked=false, charger screen enabled=TRUE --
# all three agree, so the field mapping is established rather than assumed.
#
# SAFETY
# ------
# Patches a local copy, writes it, reads it back and verifies. devinfo is 4 KiB
# and fully backed up. If anything looks wrong, restore is a single command
# printed at the end. Unlike the fastboot route this does NOT wipe userdata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
LOADER="${FW}/palma2pro-firehose.bin"
BACKUP_DIR="${1:-}"
WORK="${FW}/analysis"

OFF_UNLOCKED=13
OFF_UNLOCK_CRITICAL=14

die() { echo "!!! $*" >&2; exit 1; }

[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || {
  echo "usage: $0 <backup-dir>"; exit 2; }

BAK_DEVINFO="$(awk -F'\t' '$1=="devinfo"{print $2;exit}' "${BACKUP_DIR}/partitions.idx" 2>/dev/null)"
[[ -n "$BAK_DEVINFO" ]] || die "devinfo not found in ${BACKUP_DIR}/partitions.idx"
BAK_DEVINFO="${BACKUP_DIR}/${BAK_DEVINFO}"

command -v edl >/dev/null || die "edl not found"
mkdir -p "$WORK"

E=(edl --loader="$LOADER" --memory=ufs)

echo ">>> Reading current devinfo"
"${E[@]}" r devinfo "${WORK}/devinfo-current.bin" >/dev/null 2>&1 \
  || die "Could not read devinfo. Is the device in EDL? (adb reboot edl)"

python3 - "${WORK}/devinfo-current.bin" "${WORK}/devinfo-patched.bin" \
         "$OFF_UNLOCKED" "$OFF_UNLOCK_CRITICAL" <<'PY'
import sys
src, dst, o_unlock, o_crit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d = bytearray(open(src, 'rb').read())

magic = bytes(d[:13])
if magic != b'ANDROID-BOOT!':
    sys.exit(f"error: unexpected devinfo magic {magic!r} -- refusing to patch")

print(f"  magic                     : {magic.decode()}")
print(f"  is_unlocked        [{o_unlock:>2}] : {d[o_unlock]:#04x}")
print(f"  is_unlock_critical [{o_crit:>2}] : {d[o_crit]:#04x}")
print(f"  charger_screen     [15] : {d[15]:#04x}  (expect 0x01 -- sanity check)")

if d[15] != 1:
    print("  WARNING: charger_screen is not 0x01. The struct layout may differ")
    print("           from what was decoded. Review before writing.")

d[o_unlock] = 1
d[o_crit] = 1
open(dst, 'wb').write(bytes(d))
print(f"\n  patched -> is_unlocked=0x01 is_unlock_critical=0x01")
PY

echo
echo ">>> Diff against current (should be exactly 2 bytes):"
# `cmp -l` exits 1 when the files differ -- which is the expected outcome here.
# Under `set -o pipefail` that aborts the script, so swallow the status.
{ cmp -l "${WORK}/devinfo-current.bin" "${WORK}/devinfo-patched.bin" || true; } | \
  awk '{printf "    offset %d: %s -> %s\n", $1-1, $2, $3}'

NDIFF="$({ cmp -l "${WORK}/devinfo-current.bin" "${WORK}/devinfo-patched.bin" || true; } | wc -l | tr -d '[:space:]')"
[[ "$NDIFF" == "2" ]] || die "Expected exactly 2 changed bytes, got ${NDIFF}. Refusing to write."

cat <<EOF

--------------------------------------------------------------
About to write devinfo with the unlock flags set.

  - does NOT wipe userdata
  - devinfo is backed up at:
      ${BAK_DEVINFO}
  - restore command if needed:
      edl w devinfo ${BAK_DEVINFO} --loader=${LOADER} --memory=ufs
--------------------------------------------------------------

EOF
read -rp "Type PATCH to write: " ans
[[ "$ans" == "PATCH" ]] || { echo "Aborted."; exit 1; }

echo ">>> Writing devinfo"
"${E[@]}" w devinfo "${WORK}/devinfo-patched.bin"

echo ">>> Reading back to verify"
"${E[@]}" r devinfo "${WORK}/devinfo-verify.bin" >/dev/null 2>&1 || die "read-back failed"

SZ="$(wc -c < "${WORK}/devinfo-patched.bin" | tr -d '[:space:]')"
A="$(head -c "$SZ" "${WORK}/devinfo-patched.bin" | shasum -a 256 | cut -d' ' -f1)"
B="$(head -c "$SZ" "${WORK}/devinfo-verify.bin"  | shasum -a 256 | cut -d' ' -f1)"

if [[ "$A" == "$B" ]]; then
  echo ">>> VERIFIED: devinfo written correctly"
else
  echo "!!! Read-back mismatch. Restoring original devinfo."
  "${E[@]}" w devinfo "$BAK_DEVINFO"
  die "devinfo restored; nothing changed"
fi

cat <<EOF

>>> Done. Now reboot and check:

    edl reset --loader=${LOADER}
    # wait for Android, then:
    adb shell getprop ro.boot.flash.locked        # expect 0
    adb shell getprop ro.boot.verifiedbootstate   # expect orange

If it still reports locked/green, the ABL may keep unlock state elsewhere as
well. Restore and tell me:
    edl w devinfo ${BAK_DEVINFO} --loader=${LOADER} --memory=ufs
EOF
