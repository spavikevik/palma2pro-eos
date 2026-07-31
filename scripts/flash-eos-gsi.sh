#!/usr/bin/env bash
#
# Flash the /e/OS A14 GSI onto stock vendor (task 5).
#
# This is a HARDWARE-COMPATIBILITY EXPERIMENT, not a daily driver. A prebuilt
# GSI ships stock SurfaceFlinger and therefore cannot set the EPDC_UPDATE_PARMS_ADDR
# / EPDC_UPDATE_CNT DRM plane properties that drive e-ink refresh on this device
# (see docs/03-ebc-api.md). Expect a poor display. Judge the result on modem,
# wifi, bluetooth, sensors and audio -- that is the question this answers.
#
# FULL UNDO (restores every logical partition byte-for-byte):
#   adb reboot edl
#   edl w super firmware/super.img --loader=firmware/palma2pro-firehose.bin --memory=ufs
#   edl reset --loader=firmware/palma2pro-firehose.bin
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
GSI="${1:-${FW}/eos-a14-gsi.img}"
BACKUP_DIR="${2:-}"
SLOT_SUFFIX="_b"        # recon + lpdump both confirm slot b is active

die() { echo "!!! $*" >&2; exit 1; }

# --- preflight --------------------------------------------------------------
[[ -f "$GSI" ]] || die "GSI not found: $GSI"
GSI_SIZE="$(wc -c < "$GSI" | tr -d '[:space:]')"
[[ "$GSI_SIZE" -gt 0 ]] || die "GSI is empty"

# Raw ext4, not sparse: ext4 superblock magic 0xef53 lives at offset 0x438.
MAGIC="$(dd if="$GSI" bs=1 skip=1080 count=2 2>/dev/null | xxd -p)"
[[ "$MAGIC" == "53ef" ]] || die "Not a raw ext4 image (magic ${MAGIC}). If sparse, run simg2img first."

[[ -f "${FW}/super.img" ]] || die "Missing ${FW}/super.img -- that is the undo path. Refusing."
SMAGIC="$(dd if="${FW}/super.img" bs=1 skip=4096 count=4 2>/dev/null | xxd -p)"
[[ "$SMAGIC" == "67446c61" ]] || die "super.img has no LP magic -- undo path is not valid. Refusing."

command -v fastboot >/dev/null || die "fastboot not found"
command -v adb >/dev/null || die "adb not found"

VBMETA=""
if [[ -n "$BACKUP_DIR" && -f "${BACKUP_DIR}/partitions.idx" ]]; then
  rel="$(awk -F'\t' '$1=="vbmeta_b"{print $2;exit}' "${BACKUP_DIR}/partitions.idx")"
  [[ -n "$rel" ]] && VBMETA="${BACKUP_DIR}/${rel}"
fi

cat <<EOF

==============================================================
 /e/OS A14 GSI flash
==============================================================
  GSI          : ${GSI}
                 ${GSI_SIZE} bytes, raw ext4, arm64
  target       : system${SLOT_SUFFIX}
  vbmeta       : ${VBMETA:-<none supplied -- verity will NOT be disabled>}
  undo         : edl w super ${FW}/super.img

This will:
  1. delete the three inert -cow logical partitions (~1.05 GiB)
     (verified inert: snapshotctl reports "Update state: none")
  2. delete and recreate system${SLOT_SUFFIX} at the GSI's size
  3. flash the GSI into it
  4. flash vbmeta with verification disabled (if supplied)
  5. WIPE USERDATA

Expect poor e-ink. That is structural, not a bug -- see the header comment.
==============================================================

EOF
read -rp "Type FLASH to proceed: " a
[[ "$a" == "FLASH" ]] || { echo "Aborted."; exit 1; }

# --- into fastbootd ---------------------------------------------------------
# Logical-partition ops require USERSPACE fastboot (fastbootd), not bootloader
# fastboot. `adb reboot fastboot` lands there; `adb reboot bootloader` does not.
echo ">>> Rebooting to fastbootd"
adb reboot fastboot
for i in $(seq 1 30); do
  sleep 3
  fastboot devices 2>/dev/null | grep -q fastboot && break
done
fastboot devices | grep -q fastboot || die "Device did not reach fastbootd"

IS_USER="$(fastboot getvar is-userspace 2>&1 | sed -n 's/^is-userspace: *//p' | head -1)"
echo ">>> is-userspace: ${IS_USER}"
[[ "$IS_USER" == "yes" ]] || die \
"Not in fastbootd (is-userspace=${IS_USER}). Logical partition commands will fail here."

# --- free space -------------------------------------------------------------
# Inert leftovers from a completed OTA. snapshotctl reported "Update state: none"
# and /metadata/ota/snapshots is empty, so nothing depends on these.
echo ">>> Deleting inert cow partitions"
for p in "odm${SLOT_SUFFIX}-cow" "product${SLOT_SUFFIX}-cow" "system${SLOT_SUFFIX}-cow"; do
  fastboot delete-logical-partition "$p" 2>&1 | tail -1 | sed "s/^/    ${p}: /" || true
done

# --- resize + flash ---------------------------------------------------------
echo ">>> Recreating system${SLOT_SUFFIX} at ${GSI_SIZE} bytes"
fastboot delete-logical-partition "system${SLOT_SUFFIX}" || die "delete system failed"
fastboot create-logical-partition "system${SLOT_SUFFIX}" "$GSI_SIZE" \
  || die "create failed -- not enough free space in the super group"

echo ">>> Flashing GSI (this takes a few minutes)"
fastboot flash system "$GSI" || die "flash failed -- restore with the undo command above"

if [[ -n "$VBMETA" ]]; then
  echo ">>> Flashing vbmeta with verification disabled"
  fastboot --disable-verity --disable-verification flash vbmeta "$VBMETA" \
    || echo "!!! vbmeta flash failed -- the GSI may refuse to boot under verity"
else
  echo "!!! No vbmeta supplied. If it bootloops, re-run passing your backup dir:"
  echo "    $0 $GSI backup/<timestamp>"
fi

echo ">>> Wiping userdata (required after a system/lock-state change)"
fastboot -w || true

echo ">>> Rebooting"
fastboot reboot

cat <<EOF

>>> First boot on a GSI can take 5-10 minutes. Do not pull power.

Triage once booted -- this is the point of the exercise:

  adb shell getprop gsm.sim.state          # modem / SIM
  adb shell dumpsys wifi | head -20        # wifi
  adb shell dumpsys bluetooth_manager | head
  adb shell dumpsys sensorservice | head -30
  adb shell dumpsys audio | head -20

If it bootloops or the radio is dead, restore everything:
  adb reboot edl   # or hardware EDL
  edl w super ${FW}/super.img --loader=${FW}/palma2pro-firehose.bin --memory=ufs
  edl reset --loader=${FW}/palma2pro-firehose.bin
EOF
