#!/usr/bin/env bash
# Full EDL partition backup for Boox Palma 2 Pro (SM7225).
#
# This is the ONLY unbrick path for this device. Onyx publishes no firehose
# recovery package and offers no unbrick service. Run this, then run
# edl-verify-restore.sh, BEFORE touching abl.
#
# Requires: bkerler/edl  (pip install edlclient), device in EDL mode.
#   adb reboot edl
# macOS: no Zadig needed, but the Qualcomm 9008 device must enumerate --
#   check with: system_profiler SPUSBDataType | grep -i -A4 qualcomm
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/backup/$(date +%Y%m%d-%H%M%S)"
LOADER="${REPO_ROOT}/firmware/palma2pro-firehose.bin"

# SM7225 firehose loader. Same SoC as Fairphone 4 / Moto, so this Lenovo-Motorola
# loader is signed for the platform and accepted by the Palma 2 Pro's PBL.
LOADER_URL='https://github.com/bkerler/Loaders/raw/refs/heads/main/lenovo_motorola/0000000000000000_bdaf51b59ba21d8a_fhprg.bin'

command -v edl >/dev/null || { echo "edl not found. pip install edlclient"; exit 1; }

if [[ ! -f "$LOADER" ]]; then
  echo ">>> Fetching firehose loader"
  mkdir -p "${REPO_ROOT}/firmware"
  curl -fL -o "$LOADER" "$LOADER_URL"
fi

mkdir -p "$BACKUP_DIR"
echo ">>> Backing up to $BACKUP_DIR"

echo ">>> Partition table"
edl printgpt --loader="$LOADER" --memory=ufs | tee "${BACKUP_DIR}/gpt.txt"

# Dump everything except the two partitions that are huge and reconstructible.
# super comes back from the OTA; userdata is getting wiped by the unlock anyway.
#
# Note: `edl rl` writes per-LUN subdirectories (lun0..lun5 -- this is UFS with six
# LUNs, matching sda..sdf on the device), not a flat directory.
echo ">>> Dumping all partitions (skipping super, userdata)"
edl rl "$BACKUP_DIR" --loader="$LOADER" --memory=ufs --skip=super,userdata --genxml

echo ">>> Checksums"
( cd "$BACKUP_DIR" && find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} + > SHA256SUMS )

# Flat name -> path index, so restore doesn't have to know which LUN a partition
# lives on. edl-verify-restore.sh and the unlock procedure both read this.
echo ">>> Partition index"
( cd "$BACKUP_DIR" && find . -type f -name '*.bin' \
    | sed 's|^\./||' \
    | awk -F/ '{name=$NF; sub(/\.bin$/,"",name); print name"\t"$0}' \
    | sort > partitions.idx )
echo ">>> Indexed $(wc -l < "${BACKUP_DIR}/partitions.idx" | tr -d ' ') partitions"

cat > "${BACKUP_DIR}/README.txt" <<EOF
Boox Palma 2 Pro (OPC1410R, SM7225) EDL backup
Taken: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Loader: $(basename "$LOADER")
Skipped: super, userdata

CONTAINS DEVICE IDENTITY: IMEI, serials, DRM/attestation keys, modem calibration.
Do not publish. Do not commit. Keep an offline copy somewhere that is not this laptop.

Critical for unbrick: abl_a, abl_b, xbl_a, xbl_b, boot_a, boot_b, vbmeta*, devinfo.
Critical and UNREPLACEABLE if lost: modemst1, modemst2, fsg, persist.
EOF

echo
echo ">>> Done. $(ls -1 "$BACKUP_DIR" | wc -l | tr -d ' ') files."
echo ">>> NOW COPY $BACKUP_DIR SOMEWHERE OFF THIS MACHINE."
echo ">>> Then run edl-verify-restore.sh. Do not skip it."
