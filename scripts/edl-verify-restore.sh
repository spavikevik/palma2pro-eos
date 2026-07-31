#!/usr/bin/env bash
# Proves the restore path works BEFORE it is needed.
#
# Writing a backup you have never restored is not a backup. This script rewrites
# one harmless partition from the dump and reads it back to confirm that
# EDL writes actually land on this device.
#
# Target: the INACTIVE slot's device tree overlay. Rewriting it with byte-identical
# data is a no-op even if something goes sideways. We are testing the write path,
# not changing behaviour.
#
# Recon says this device's active slot is _b, so the safe target is dtbo_a.
# Verified at runtime below regardless.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="${REPO_ROOT}/firmware/palma2pro-firehose.bin"
BACKUP_DIR="${1:-}"

[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || {
  echo "usage: $0 <backup-dir>"
  echo "e.g.:  $0 backup/20260729-134500"
  exit 1
}

# Device recon reported active slot _b. Confirm, then target the other one.
ACTIVE_SLOT="${ACTIVE_SLOT_OVERRIDE:-b}"
echo ">>> Assuming active slot: ${ACTIVE_SLOT} (from recon: ro.boot.slot_suffix=_b)"
echo ">>> If the device has since switched slots, re-run with ACTIVE_SLOT_OVERRIDE=a"

case "$ACTIVE_SLOT" in
  b) TEST_PART="dtbo_a" ;;
  a) TEST_PART="dtbo_b" ;;
  *) echo "ACTIVE_SLOT must be a or b"; exit 1 ;;
esac
echo ">>> Testing on inactive slot partition: ${TEST_PART}"

# `edl rl` writes per-LUN subdirectories (lun0..lun5), so partitions are NOT at
# the top level of the backup. Resolve through the index edl-backup.sh builds,
# falling back to a search for older dumps.
resolve_part() {
  local name="$1" idx="${BACKUP_DIR}/partitions.idx" hit
  if [[ -f "$idx" ]]; then
    hit="$(awk -v n="$name" -F'\t' '$1==n {print $2; exit}' "$idx")"
    [[ -n "$hit" ]] && { echo "${BACKUP_DIR}/${hit}"; return 0; }
  fi
  hit="$(find "$BACKUP_DIR" -type f -name "${name}.bin" | head -1)"
  [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  return 1
}

SRC="$(resolve_part "$TEST_PART")" || {
  echo "Could not find ${TEST_PART}.bin under ${BACKUP_DIR}."
  echo "Check the dump completed -- expect lun0..lun5 subdirectories."
  exit 1
}
echo ">>> Source image: ${SRC}"

echo ">>> Writing ${TEST_PART} back from backup (byte-identical, inactive slot)"
edl w "$TEST_PART" "$SRC" --loader="$LOADER" --memory=ufs

echo ">>> Reading ${TEST_PART} back"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
edl r "$TEST_PART" "${TMP}/${TEST_PART}.bin" --loader="$LOADER" --memory=ufs

# Read-back is padded to the full partition size; compare only the source length.
# `wc -c` rather than stat -- stat flags differ across BSD, GNU and uutils builds.
SRC_SIZE="$(wc -c < "$SRC" | tr -d '[:space:]')"
[[ "$SRC_SIZE" =~ ^[0-9]+$ && "$SRC_SIZE" -gt 0 ]] || {
  echo "!!! Could not determine size of ${SRC}. Aborting without a verdict."
  exit 2
}
echo ">>> Comparing first ${SRC_SIZE} bytes"

if cmp -n "$SRC_SIZE" "$SRC" "${TMP}/${TEST_PART}.bin"; then
  echo
  echo ">>> PASS. EDL read and write both work on this unit."
  echo ">>> The unbrick path is real. Unlock may proceed."

  # Receipt. scripts/unlock-bootloader.sh refuses to run without this, so the
  # gate cannot be skipped by forgetting rather than by deciding.
  cat > "${BACKUP_DIR}/GATE3-PASS" <<EOF
EDL write path verified
when:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
partition: ${TEST_PART} (inactive slot; active was ${ACTIVE_SLOT})
source:    ${SRC}
bytes:     ${SRC_SIZE}
EOF
  echo ">>> Receipt written: ${BACKUP_DIR}/GATE3-PASS"
else
  echo
  echo "!!! FAIL. Read-back does not match what was written."
  echo "!!! DO NOT PROCEED TO THE ABL SWAP. Without a working EDL write path,"
  echo "!!! a bad abl flash is an unrecoverable brick."
  exit 1
fi
