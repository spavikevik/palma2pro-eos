#!/usr/bin/env bash
# Extract the Fairphone 4 ABL from an /e/OS FP4 community build.
#
# Why Fairphone: the FP4 uses the same SM7225 SoC as the Palma 2 Pro, so its ABL
# is signed for this platform and the PBL accepts it. Unlike Onyx's, it has the
# unlock commands intact.
#
# Why the /e/OS build specifically: it is a plain zip containing abl.img, freely
# redistributable, and it is what the known-good Palma 2 Pro procedure used
# (Kisuke-CZE/Palma_2_Pro-tips referenced IMG-e-3.3-a15-...-community-FP4.zip).
# A Fairphone stock factory image works equally well if you already have one.
#
# LICENSING: the Fairphone ABL is GPL-2.0 and separately licensed. Using it to
# unlock hardware you own is fine. Redistributing a Boox image containing it is
# not -- this script fetches it to your machine, it is never committed here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
OUT="${FW}/abl-fp4.img"
SRC="${1:-}"

mkdir -p "$FW"

if [[ -z "$SRC" ]]; then
  cat <<'EOF'
usage: fetch-fp4-abl.sh <path-to-FP4-build.zip | url>

Get an /e/OS Fairphone 4 community build:

    https://images.ecloud.global/community/FP4/
    (any recent IMG-e-*-community-FP4.zip)

or use a Fairphone stock factory image if you have one -- any source of a
Fairphone 4 abl.img will do.

Then:
    scripts/fetch-fp4-abl.sh ~/Downloads/IMG-e-3.3-a15-...-community-FP4.zip

The Android version of the donor build does not need to match this device. The
ABL only has to be signed for SM7225, which every FP4 build is.
EOF
  exit 2
fi

ZIP="$SRC"
if [[ "$SRC" =~ ^https?:// ]]; then
  ZIP="${FW}/fp4-build.zip"
  echo ">>> Downloading ${SRC}"
  curl -fL --progress-bar -o "$ZIP" "$SRC"
fi

[[ -f "$ZIP" ]] || { echo "Not found: $ZIP"; exit 1; }

echo ">>> Looking for abl.img in $(basename "$ZIP")"
ABL_ENTRY="$(unzip -Z1 "$ZIP" | grep -E '(^|/)abl(_a)?\.img$' | head -1 || true)"
[[ -n "$ABL_ENTRY" ]] || {
  echo "No abl.img inside. Contents:" >&2
  unzip -Z1 "$ZIP" | head -40 >&2
  exit 1
}
echo ">>> Found: $ABL_ENTRY"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -o -j "$ZIP" "$ABL_ENTRY" -d "$TMP" >/dev/null
mv "${TMP}/$(basename "$ABL_ENTRY")" "$OUT"

echo ">>> Wrote ${OUT} ($(wc -c < "$OUT" | tr -d '[:space:]') bytes)"
shasum -a 256 "$OUT"

# Sanity: Onyx's own abl is a useful size reference. Wildly different sizes are
# worth a second look before writing this to the boot chain.
echo
echo ">>> For comparison, Onyx's abl_a from your backup:"
find "${REPO_ROOT}/backup" -name 'abl_a.bin' -exec sh -c \
  'echo "    $1  $(wc -c < "$1" | tr -d "[:space:]") bytes"' _ {} \; 2>/dev/null || true

cat <<'EOF'

>>> Next: scripts/unlock-bootloader.sh <backup-dir>
    It re-checks every gate before touching anything.
EOF
