#!/usr/bin/env bash
#
#  THE BRICK-RISK STEP.
#
# Onyx ships an ABL with the unlock commands stripped out, so stock fastboot has
# neither `flashing unlock` nor `oem unlock`. This temporarily swaps in the
# Fairphone 4 ABL -- same SM7225 SoC, GPL-licensed, publicly distributed, and it
# has working unlock commands -- unlocks, then puts Onyx's ABL back.
#
# People have hard-bricked Boox devices on the analogous Palma 2 procedure.
# Onyx sells no unbrick service and publishes no firehose recovery package for
# this device. EDL is the entire safety net.
#
# Every gate below must pass. They are checks in code rather than warnings in a
# document so that the procedure cannot be skipped by forgetting, only by
# deciding.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
LOADER="${FW}/palma2pro-firehose.bin"
FP4_ABL="${FW}/abl-fp4.img"
BACKUP_DIR="${1:-}"

# Recon: ro.boot.slot_suffix = _b
ACTIVE_SLOT="${ACTIVE_SLOT:-b}"

die() { echo "!!! $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: unlock-bootloader.sh <backup-dir>

e.g.:  unlock-bootloader.sh backup/20260729-140322

Prerequisites:
  - backup taken           (scripts/edl-backup.sh)
  - restore path verified  (scripts/edl-verify-restore.sh -> GATE3-PASS receipt)
  - Fairphone 4 ABL        (scripts/fetch-fp4-abl.sh -> firmware/abl-fp4.img)
  - "OEM unlocking" enabled in Developer Options
EOF
  exit 2
}

[[ -n "$BACKUP_DIR" ]] || usage
[[ -d "$BACKUP_DIR" ]] || die "No such backup dir: $BACKUP_DIR"

echo "=============================================================="
echo " Palma 2 Pro bootloader unlock"
echo "=============================================================="
echo

# --- Gate 1: tooling and loader --------------------------------------------
command -v edl      >/dev/null || die "edl not found. pip install edlclient"
command -v fastboot >/dev/null || die "fastboot not found. brew install android-platform-tools"
[[ -f "$LOADER" ]] || die "Missing firehose loader: $LOADER"
echo ">>> Gate 1 OK: edl, fastboot, loader present"

# --- Gate 2: backup is complete and intact ---------------------------------
IDX="${BACKUP_DIR}/partitions.idx"
[[ -f "$IDX" ]] || die "No partitions.idx in $BACKUP_DIR -- re-run edl-backup.sh"

resolve_part() {
  local name="$1" hit
  hit="$(awk -v n="$name" -F'\t' '$1==n {print $2; exit}' "$IDX")"
  [[ -n "$hit" ]] || return 1
  echo "${BACKUP_DIR}/${hit}"
}

# Losing any of these is unrecoverable -- they are not downloadable from anywhere.
for p in abl_a abl_b boot_a boot_b vbmeta_a vbmeta_b devinfo \
         modemst1 modemst2 fsg persist onyxconfig; do
  f="$(resolve_part "$p")" || die "Backup is missing $p -- do not proceed"
  [[ -s "$f" ]] || die "Backup entry for $p is empty: $f"
done
echo ">>> Gate 2 OK: all critical partitions present in backup"

if [[ -f "${BACKUP_DIR}/SHA256SUMS" ]]; then
  echo ">>> Verifying backup checksums (this takes a moment)"
  ( cd "$BACKUP_DIR" && shasum -a 256 --quiet -c SHA256SUMS ) \
    || die "Backup checksums DO NOT match. The backup is corrupt. Stop."
  echo ">>> Gate 2b OK: checksums verify"
else
  die "No SHA256SUMS in $BACKUP_DIR -- cannot trust this backup"
fi

# --- Gate 3: the restore path is proven, not assumed -----------------------
[[ -f "${BACKUP_DIR}/GATE3-PASS" ]] || die \
"Gate 3 not passed. Run:

    adb reboot edl
    scripts/edl-verify-restore.sh ${BACKUP_DIR}

That writes one inactive-slot partition back from the backup and reads it to
confirm EDL writes actually land on this unit. Without a proven write path, a
bad abl flash is an unrecoverable brick. This is not a formality."
echo ">>> Gate 3 OK: EDL write path verified"
sed 's/^/      /' "${BACKUP_DIR}/GATE3-PASS"

# --- Gate 4: Fairphone 4 ABL ------------------------------------------------
[[ -f "$FP4_ABL" ]] || die \
"Missing ${FP4_ABL}. Run scripts/fetch-fp4-abl.sh, or extract abl.img from an
/e/OS Fairphone 4 community build and place it there."
echo ">>> Gate 4 OK: FP4 ABL present ($(wc -c < "$FP4_ABL" | tr -d '[:space:]') bytes)"

ONYX_ABL_A="$(resolve_part abl_a)"
ONYX_ABL_B="$(resolve_part abl_b)"

# --- Gate 5: the device agrees to be unlocked -------------------------------
# Run this with the device booted into Android; the script moves it to EDL
# itself. Checking sys.oem_unlock_allowed here avoids discovering the toggle is
# off *after* the FP4 bootloader is already written.
command -v adb >/dev/null || die "adb not found. brew install android-platform-tools"

if ! adb get-state >/dev/null 2>&1; then
  die "No adb device.

Boot the device into Android and enable USB debugging, then re-run. This script
puts the device into EDL itself -- do not do it beforehand."
fi

OEM_OK="$(adb shell getprop sys.oem_unlock_allowed 2>/dev/null | tr -d '\r\n')"
LOCKED="$(adb shell getprop ro.boot.flash.locked 2>/dev/null | tr -d '\r\n')"
SLOT="$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n')"

echo ">>> Device reports: oem_unlock_allowed=${OEM_OK:-?} flash.locked=${LOCKED:-?} slot=${SLOT:-?}"

[[ "$OEM_OK" == "1" ]] || die \
"OEM unlocking is not enabled (sys.oem_unlock_allowed=${OEM_OK:-unset}).

On the device: Settings -> About -> tap Build number 7x to enable Developer
Options, then Developer Options -> enable 'OEM unlocking'.

Without this the Fairphone bootloader will refuse to unlock, and you would have
swapped the bootloader for nothing."

if [[ "$LOCKED" == "0" ]]; then
  echo ">>> NOTE: device already reports flash.locked=0 (unlocked). Nothing to do?"
  read -rp "Continue anyway? [y/N] " a
  [[ "$a" == "y" ]] || exit 0
fi

# Track the real slot rather than the value recorded during recon.
if [[ -n "$SLOT" ]]; then
  ACTIVE_SLOT="${SLOT#_}"
  echo ">>> Using active slot from device: ${ACTIVE_SLOT}"
fi
echo ">>> Gate 5 OK: device is ready to be unlocked"

# --- Confirmation -----------------------------------------------------------
cat <<EOF

--------------------------------------------------------------
This will:
  1. write the Fairphone 4 ABL to abl_a and abl_b via EDL
  2. set the active slot to ${ACTIVE_SLOT} and reboot
  3. run fastboot flashing unlock + unlock_critical
       -> BOTH WIPE ALL USER DATA
       -> each needs a physical Vol Up + Power confirmation on the device
  4. restore Onyx's ABL to both slots via EDL
  5. leave you to verify the device still boots stock

Recovery if it goes wrong:
  edl w abl_a ${ONYX_ABL_A} --loader=${LOADER} --memory=ufs
  edl w abl_b ${ONYX_ABL_B} --loader=${LOADER} --memory=ufs
--------------------------------------------------------------

EOF

read -rp "Type UNLOCK to proceed: " ans
[[ "$ans" == "UNLOCK" ]] || { echo "Aborted."; exit 1; }

echo ">>> Rebooting device into EDL"
adb reboot edl || die "adb reboot edl failed"
echo ">>> Waiting for the device to enumerate in EDL..."
sleep 8

# Storage commands (r/w/rl/printgpt) take --memory; control commands
# (reset/setactiveslot) do not and will print usage and exit if given it.
E=(edl --loader="$LOADER" --memory=ufs)
EC=(edl --loader="$LOADER")

VTMP="$(mktemp -d)"
trap 'rm -rf "$VTMP"' EXIT

# Write, then read back and compare before trusting it. Gate 3 proved read-back
# comparison works on this unit, so there is no excuse for rebooting into an
# unverified bootloader -- that is precisely the write that bricks devices.
write_verified() {
  local part="$1" img="$2" size
  size="$(wc -c < "$img" | tr -d '[:space:]')"

  echo ">>> Writing ${part}"
  "${E[@]}" w "$part" "$img"

  echo ">>> Verifying ${part} read-back"
  "${E[@]}" r "$part" "${VTMP}/${part}.bin"

  # Read-back covers the whole partition; the image is shorter. Compare by
  # hashing the first $size bytes of each.
  #
  # Not `cmp -n $size` -- BSD cmp reports "EOF on <file1>" and exits non-zero
  # when file1 is exactly $size and file2 is longer, even though every compared
  # byte matched. That produced a false mismatch on a good write.
  local sha_src sha_dst
  sha_src="$(head -c "$size" "$img"                  | shasum -a 256 | cut -d' ' -f1)"
  sha_dst="$(head -c "$size" "${VTMP}/${part}.bin"   | shasum -a 256 | cut -d' ' -f1)"

  if [[ "$sha_src" == "$sha_dst" && -n "$sha_src" ]]; then
    echo ">>> ${part} verified OK (${size} bytes, sha256 ${sha_src:0:16}...)"
  else
    echo "    expected ${sha_src}"
    echo "    got      ${sha_dst}"
    echo
    echo "!!! ${part} DOES NOT MATCH what was written."
    echo "!!! NOT rebooting. Restoring Onyx ABL to both slots now."
    "${E[@]}" w abl_a "$ONYX_ABL_A" || true
    "${E[@]}" w abl_b "$ONYX_ABL_B" || true
    die "Aborted before reboot. Device should still be in its original state."
  fi
}

# --- 1. FP4 ABL -------------------------------------------------------------
echo
echo ">>> Writing Fairphone 4 ABL to both slots"
write_verified abl_a "$FP4_ABL"
write_verified abl_b "$FP4_ABL"

echo ">>> Setting active slot to ${ACTIVE_SLOT} and rebooting"
"${EC[@]}" setactiveslot "$ACTIVE_SLOT"
"${EC[@]}" reset

# --- 2. unlock --------------------------------------------------------------
# `edl reset` performs a NORMAL boot -- it does not land in fastboot. Go via
# Android and adb reboot bootloader.
wait_for_adb() {
  local n=0
  until adb get-state 2>/dev/null | grep -q device; do
    n=$((n+1)); [[ $n -gt 30 ]] && return 1; sleep 5
  done
}
wait_for_fastboot() {
  local n=0
  until fastboot devices 2>/dev/null | grep -q fastboot; do
    n=$((n+1)); [[ $n -gt 20 ]] && return 1; sleep 3
  done
}

echo ">>> Waiting for Android to come up after reset..."
wait_for_adb || die "Device did not return to Android. Check the screen."

echo ">>> Rebooting into the bootloader"
adb reboot bootloader
wait_for_fastboot || die "Device did not reach fastboot."

PRODUCT="$(fastboot getvar product 2>&1 | sed -n 's/^product: *//p' | head -1)"
echo ">>> fastboot product: ${PRODUCT}"
[[ "$PRODUCT" == "FP4" ]] || die \
"Expected the Fairphone ABL (product: FP4) but got '${PRODUCT}'.
The ABL swap did not take effect. Do not continue."

unlocked_now() {
  fastboot oem device-info 2>&1 | grep -qi 'Device unlocked: true'
}

cat <<'EOF'

--------------------------------------------------------------
 NEXT: fastboot flashing unlock -- THIS WIPES ALL USER DATA
--------------------------------------------------------------
On the device screen a confirmation prompt appears.

  The default selection is "DO NOT UNLOCK".
  Press VOLUME UP to change the selection to unlock.
  Then press POWER to confirm.

Pressing POWER alone declines the unlock. That is the single most
common way this step silently fails.
--------------------------------------------------------------
EOF
read -rp "Press Enter when ready to send the unlock command: " _

echo ">>> fastboot flashing unlock  -- NOW CONFIRM ON DEVICE (Vol Up, then Power)"
fastboot flashing unlock || echo "!!! command returned an error; checking actual state anyway"

echo ">>> Waiting for the device to wipe and return to the bootloader..."
sleep 10
wait_for_fastboot || {
  echo ">>> Not in fastboot; the device is probably wiping and rebooting."
  wait_for_adb || die "Lost the device after unlock. Check the screen."
  adb reboot bootloader
  wait_for_fastboot || die "Could not get back to fastboot to verify."
}

# Verify rather than assume. A declined unlock returns success on some ABLs.
if unlocked_now; then
  echo ">>> CONFIRMED: Device unlocked: true"
else
  fastboot oem device-info 2>&1 | head -5
  die \
"Device still reports locked. The unlock was declined or did not take.

On the confirmation screen you must press VOLUME UP to move the selection
onto the unlock option BEFORE pressing POWER.

The Fairphone ABL is still installed, so you can simply re-run this script."
fi

echo ">>> fastboot flashing unlock_critical  -- CONFIRM ON DEVICE (Vol Up, then Power)"
fastboot flashing unlock_critical || echo "!!! unlock_critical returned an error"
sleep 8
wait_for_fastboot || { wait_for_adb && adb reboot bootloader && wait_for_fastboot; } || true

echo ">>> Final device info:"
fastboot oem device-info 2>&1 | head -5

# --- 3. restore Onyx ABL ----------------------------------------------------
cat <<'EOF'

>>> Now restoring Onyx's own ABL. Put the device back into EDL mode:
        adb reboot edl
    (or the hardware EDL method if adb is unavailable)
Then press Enter.
EOF
read -r _

echo ">>> Restoring Onyx ABL to both slots"
write_verified abl_a "$ONYX_ABL_A"
write_verified abl_b "$ONYX_ABL_B"
"${EC[@]}" setactiveslot "$ACTIVE_SLOT"
"${EC[@]}" reset

cat <<EOF

>>> Done.

Verify BEFORE building anything on top of this:
  - the device boots stock normally
  - fastboot oem device-info reports unlocked
  - SIM / IMEI still work  (settings -> about phone)

If it does not boot, restore from backup via EDL:
  edl w abl_a ${ONYX_ABL_A} --loader=${LOADER} --memory=ufs
  edl w abl_b ${ONYX_ABL_B} --loader=${LOADER} --memory=ufs
  edl w boot_a $(resolve_part boot_a) --loader=${LOADER} --memory=ufs
  edl w boot_b $(resolve_part boot_b) --loader=${LOADER} --memory=ufs

Next: scripts/build-ebctool.sh, then run it as root. That confirms the EBC
struct layout and unblocks the refresh controller.
EOF
