#!/usr/bin/env bash
# Dump `super` over EDL (READ-ONLY) and analyse the Onyx display stack.
#
# EDL reads do NOT require an unlocked bootloader. Nothing here writes to the
# device. This answers the two open questions from recon before we take on any
# brick risk:
#
#   1. Did Onyx patch SurfaceFlinger / services.jar / framework.jar in place?
#      (a name-based grep can't tell -- the filenames are stock)
#   2. What is the actual sysfs/ioctl surface of onyx_epdc_fb?
#      (the spec for the refresh shim)
#
# ext4 images are read with debugfs, not mounted -- no macFUSE, no kext, no root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
LOADER="${FW}/palma2pro-firehose.bin"
SUPER="${FW}/super.img"
A="${FW}/analysis"

# e2fsprogs is keg-only under Homebrew, so it is not on PATH by default.
DEBUGFS="$(command -v debugfs || true)"
for p in /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs; do
  [[ -n "$DEBUGFS" ]] && break
  [[ -x "$p" ]] && DEBUGFS="$p"
done

LPUNPACK="${REPO_ROOT}/scripts/lpunpack.py"

preflight() {
  [[ -n "$DEBUGFS" ]] || {
    cat <<'EOF'
MISSING debugfs -> brew install e2fsprogs

  debugfs reads ext4 images without mounting -- no macFUSE, no kext, no root.
  Homebrew keeps e2fsprogs keg-only so it stays off PATH; this script finds it
  at the keg path anyway.

Note: simg2img is NOT needed. An EDL read produces a raw image, not a sparse
one. It only matters for images pulled out of an OTA zip.
EOF
    exit 1
  }
  [[ -f "$LPUNPACK" ]] || { echo "Missing ${LPUNPACK}"; exit 1; }
}
preflight

# Metadata slot 0 describes the _a partitions as single clean extents. Slot 1
# describes _b plus -cow snapshot devices (this device uses Virtual A/B), where
# extent concatenation yields the pre-merge base rather than live content.
#
# vendor and odm are absent from ro.product.ab_ota_partitions, so vendor_a is
# byte-identical to what is running. system_a is the pre-OTA system, which still
# answers the "did Onyx patch the framework" question.
LP_SLOT="${LP_SLOT:-0}"
LP_SUFFIX="${LP_SUFFIX:-_a}"

mkdir -p "${FW}/logical" "$A"

# --- get super -------------------------------------------------------------
if [[ ! -f "$SUPER" ]]; then
  command -v edl >/dev/null || { echo "edl not found. pip install edlclient"; exit 1; }
  [[ -f "$LOADER" ]] || { echo "Missing loader. Run edl-backup.sh first."; exit 1; }
  echo ">>> Reading super over EDL (read-only, ~6 GB, this takes a while)"
  edl r super "$SUPER" --loader="$LOADER" --memory=ufs
fi

# LP metadata geometry magic 'gDla' lives at offset 4096 of a valid super image.
MAGIC="$(dd if="$SUPER" bs=1 skip=4096 count=4 2>/dev/null | xxd -p)"
if [[ "$MAGIC" != "67446c61" ]]; then
  echo "!!! super.img has no LP geometry magic at 4096 (got: ${MAGIC:-nothing})."
  echo "!!! The image may be sparse or the read may be truncated."
  echo "!!! If sparse: simg2img super.img super.raw.img && re-run against that."
  exit 1
fi
echo ">>> super.img: valid LP metadata, $(wc -c < "$SUPER" | tr -d '[:space:]') bytes"

# --- unpack ----------------------------------------------------------------
echo ">>> Partitions in super (metadata slot ${LP_SLOT}):"
python3 "$LPUNPACK" --slot "$LP_SLOT" --list "$SUPER"

for p in system vendor; do
  if [[ ! -f "${FW}/logical/${p}${LP_SUFFIX}.img" ]]; then
    echo ">>> Extracting ${p}${LP_SUFFIX}"
    python3 "$LPUNPACK" --slot "$LP_SLOT" "$SUPER" "${FW}/logical" "${p}${LP_SUFFIX}"
  fi
done
ls -lh "${FW}/logical"

# --- debugfs helpers -------------------------------------------------------
# Layouts differ: some system images have content at the root (bin/, lib64/),
# others nest it under /system. Probe once and use the right prefix.
img_prefix() {
  local img="$1"
  if "$DEBUGFS" -R "ls -l /system" "$img" 2>/dev/null | grep -q .; then
    echo "/system"
  else
    echo ""
  fi
}

# Extract one file out of an ext4 image to stdout-ish (a temp path).
img_extract() {
  local img="$1" path="$2" dest="$3"
  "$DEBUGFS" -R "dump ${path} ${dest}" "$img" 2>/dev/null || return 1
  [[ -s "$dest" ]]
}

img_ls() { "$DEBUGFS" -R "ls -l $2" "$1" 2>/dev/null; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYS_IMG="${FW}/logical/system${LP_SUFFIX}.img"
VEN_IMG="${FW}/logical/vendor${LP_SUFFIX}.img"

# --- Q1: is the framework Onyx-patched? ------------------------------------
echo
echo ">>> ============ Q1: is the framework Onyx-patched? ============"
: > "${A}/framework-patch.txt"

if [[ -f "$SYS_IMG" ]]; then
  SP="$(img_prefix "$SYS_IMG")"
  echo ">>> system.img content prefix: '${SP:-/}'" | tee -a "${A}/framework-patch.txt"

  for f in bin/surfaceflinger \
           framework/framework.jar \
           framework/services.jar \
           lib64/libsurfaceflinger.so \
           lib64/libgui.so; do
    out="${TMP}/$(basename "$f")"
    if img_extract "$SYS_IMG" "${SP}/${f}" "$out"; then
      n=$(strings -a "$out" | grep -ci 'onyx\|epd\|eink' || true)
      printf '%-34s %10s bytes   onyx/epd/eink strings: %s\n' \
        "$f" "$(wc -c < "$out" | tr -d '[:space:]')" "$n" | tee -a "${A}/framework-patch.txt"
    else
      printf '%-34s (not present)\n' "$f" | tee -a "${A}/framework-patch.txt"
    fi
  done

  if [[ -s "${TMP}/surfaceflinger" ]]; then
    echo ">>> Onyx-ish strings in surfaceflinger:"
    strings -a "${TMP}/surfaceflinger" \
      | grep -i 'onyx\|epd\|eink\|waveform' | sort -u \
      | tee "${A}/sf-onyx-strings.txt" || true
  fi

  echo ">>> Onyx-named files in system (top dirs):"
  for d in "" /bin /lib64 /framework /etc /app /priv-app; do
    img_ls "$SYS_IMG" "${SP}${d}" | grep -i onyx || true
  done | tee "${A}/system-onyx-files.txt"
else
  echo "!!! No system.img -- check lpunpack output above."
fi

# --- Q2: the EPD driver interface ------------------------------------------
echo
echo ">>> ============ Q2: the EPD driver interface ============"

scan_blob() {  # scan_blob <img> <path-in-img> <label>
  # Separate declarations: under `set -u`, referring to an earlier name inside
  # the same `local` statement is not reliable.
  local img="$1"
  local path="$2"
  local label="$3"
  local out="${TMP}/${label}"
  img_extract "$img" "$path" "$out" || return 1
  echo ">>> strings: ${label}"
  strings -a "$out" \
    | grep -iE 'waveform|update_mode|refresh|epd|dither|temperature|/sys/|/dev/|ioctl|gc16|gl16|du4|a2' \
    | sort -u | tee "${A}/${label}.strings.txt"
}

if [[ -f "$VEN_IMG" ]]; then
  VP="$(img_prefix "$VEN_IMG")"
  echo ">>> vendor.img content prefix: '${VP:-/}'"

  echo ">>> Looking for Onyx kernel modules:"
  for d in /lib/modules /lib64/modules /modules; do
    img_ls "$VEN_IMG" "${VP}${d}" | grep -iE 'onyx|epd|sepdc|dsi' || true
  done | tee "${A}/onyx-modules.txt"

  # Kernel modules and the JNI shim: sysfs attribute names and waveform-mode
  # constants appear as plain strings, which is the cheapest route to the API.
  for m in onyx_epdc_fb onyxdsi onyx_epdc_mfd; do
    for d in /lib/modules /lib64/modules /modules; do
      scan_blob "$VEN_IMG" "${VP}${d}/${m}.ko" "${m}.ko" && break
    done
  done

  for d in /lib64 /lib; do
    scan_blob "$VEN_IMG" "${VP}${d}/libonyx_epd_listener.so" "libonyx_epd_listener.so" && break
  done
fi

# The JNI shim may live in system rather than vendor.
if [[ -f "$SYS_IMG" && ! -f "${A}/libonyx_epd_listener.so.strings.txt" ]]; then
  SP="$(img_prefix "$SYS_IMG")"
  for d in /lib64 /lib; do
    scan_blob "$SYS_IMG" "${SP}${d}/libonyx_epd_listener.so" "libonyx_epd_listener.so" && break
  done
fi

cat <<'EOF'

>>> Analysis written to firmware/analysis/.

Read framework-patch.txt first. Interpretation:

  ~0 onyx/epd strings in surfaceflinger and the jars
     -> refresh policy lives in Onyx's apps, not the framework.
        The GSI loses only replaceable app-level code. Best case.

  many onyx/epd strings in surfaceflinger or services.jar
     -> Onyx patched the framework in place. The GSI discards that policy layer
        and we reimplement it on top of the kernel interface. Harder, still viable,
        because the kernel side is open.

Then read the .strings.txt files. Any sysfs attribute names or waveform mode
constants there (GC16, GL16, DU, A2 are the standard E-ink waveform modes) are
the literal API for the refresh shim.
EOF
