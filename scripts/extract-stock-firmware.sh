#!/usr/bin/env bash
# Extract stock Boox firmware into individual partition images.
#
# Onyx ships OTAs as an encrypted `update.upx`. Chain:
#   update.upx --decrypt--> update.zip --unpack--> payload.bin --extract--> *.img
#   super.img --lpunpack--> system.img vendor.img product.img odm.img
#
# These are the reference vendor images and the restore source. Everything here
# is proprietary Onyx material -- firmware/ is gitignored, keep it that way.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
UPX="${1:-}"

[[ -n "$UPX" && -f "$UPX" ]] || cat <<'EOF' >&2
usage: extract-stock-firmware.sh <path/to/update.upx>

Getting update.upx: Boox stopped publishing firmware on downloads.boox.com in
2023 -- OTAs now come through Settings. Pull it off the device after the OTA
downloads but before it applies:

    adb shell find /data /sdcard -iname '*.upx' -o -iname 'update*.zip' 2>/dev/null

Tools needed:
    decryptBooxUpdateUpx   https://github.com/Hagb/decryptBooxUpdateUpx
    extract_android_ota_payload  https://github.com/cyxx/extract_android_ota_payload
    lpunpack               (from android-tools, or build from AOSP)
EOF
[[ -n "$UPX" && -f "$UPX" ]] || exit 1

mkdir -p "$FW"/{ota,partitions,logical}

echo ">>> Decrypting update.upx"
# decryptBooxUpdateUpx emits a recovery-readable zip
python3 -m decryptBooxUpdateUpx "$UPX" "${FW}/ota/update.zip" \
  || { echo "Install: pip install git+https://github.com/Hagb/decryptBooxUpdateUpx"; exit 1; }

echo ">>> Unpacking OTA zip"
unzip -o "${FW}/ota/update.zip" -d "${FW}/ota" >/dev/null

PAYLOAD="${FW}/ota/payload.bin"
[[ -f "$PAYLOAD" ]] || { echo "No payload.bin in OTA -- this may be a full image zip instead. Inspect ${FW}/ota"; exit 1; }

echo ">>> Extracting payload.bin"
python3 -m extract_android_ota_payload "$PAYLOAD" "${FW}/partitions"

echo ">>> Partitions extracted:"
ls -lh "${FW}/partitions"

SUPER="${FW}/partitions/super.img"
if [[ -f "$SUPER" ]]; then
  echo ">>> Unpacking super.img into logical partitions"
  lpunpack "$SUPER" "${FW}/logical" || echo "lpunpack failed -- super may be sparse; run simg2img first"
  ls -lh "${FW}/logical"
fi

cat <<EOF

>>> Done.

Key outputs:
  firmware/partitions/boot.img     -> prebuilt kernel, needed for any device tree port
  firmware/partitions/vbmeta.img   -> AVB, patched to disable verity before GSI flash
  firmware/logical/vendor.img      -> the Onyx vendor blobs the GSI runs against
  firmware/logical/system.img      -> stock system; grep this for the e-ink framework code

Next, for the e-ink question, unpack vendor and system and look for the Onyx
display stack:
  grep -ril 'eink\|epd' firmware/logical/vendor/lib64/ firmware/logical/system/framework/
EOF
