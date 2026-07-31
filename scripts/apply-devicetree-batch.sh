#!/usr/bin/env bash
# Apply the batched device-tree changes once the in-flight ckati run finishes.
#
#   scripts/apply-devicetree-batch.sh [build-target]
#
# Default target: systemimage (what we actually need -- we flash logical
# partitions over EDL, so `bacon` would waste hours building an OTA package).
#
# WHY WAIT
#
# Any device-tree change invalidates the ninja file and forces a full
# soong + ckati regeneration: ~35 min on this host, single-threaded under
# Rosetta. Pushing changes while a regen is already running just throws that
# regen away and starts another. So: wait for idle, push everything at once,
# then one regen covers the whole batch.
#
# TO REVERT the debug additions afterwards:
#   rm device/onyx/Palma2_Pro_C/bringup-debug.mk
#   scripts/builder.sh push && scripts/builder.sh build systemimage
# (device.mk uses inherit-product-if-exists, so no edit is needed.)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
TARGET=${1:-systemimage}

echo "==> batch contents:"
echo "    device/onyx/Palma2_Pro_C/bringup-debug.mk   (new: logcatd persistence)"
echo "    device/onyx/Palma2_Pro_C/device.mk          (inherit-product-if-exists hook)"
echo "    device/onyx/Palma2_Pro_C/prebuilt/dtbo.img  (truncated to 213484 B)"
echo "    device/onyx/Palma2_Pro_C/BoardConfig.mk     (BOARD_PREBUILT_DTBOIMAGE + notes)"
echo

# --- wait for the tree to be idle -----------------------------------------
echo "==> waiting for any in-flight soong/ckati to finish"
while :; do
    busy=$(bash scripts/builder.sh ssh \
        'pgrep -x ckati >/dev/null || pgrep -x soong_build >/dev/null || pgrep -x ninja >/dev/null; echo $?' \
        2>/dev/null | tr -d '[:space:]')
    if [ "$busy" = "1" ]; then
        echo "    tree idle"
        break
    fi
    el=$(bash scripts/builder.sh ssh 'ps -o etime= -C ckati 2>/dev/null | tr -d " " | head -1' 2>/dev/null | tr -d '[:space:]')
    printf '    still building%s ... waiting 120s\n' "${el:+ (ckati $el)}"
    sleep 120
done

# --- report what the in-flight build concluded ----------------------------
echo "==> previous build verdict:"
bash scripts/builder.sh ssh \
    'grep -E "build completed successfully|failed to build some targets" /aosp/build.log 2>/dev/null | tail -1' \
    | sed 's/^/    /'
bash scripts/builder.sh ssh \
    'ls -l /aosp/out/target/product/Palma2_Pro_C/dtbo.img 2>/dev/null | awk "{print \"    dtbo.img: \" \$5 \" bytes\"}"' || true

# --- push and build -------------------------------------------------------
echo "==> pushing device tree"
bash scripts/builder.sh push >/dev/null
bash scripts/builder.sh ssh 'ls -l /aosp/device/onyx/Palma2_Pro_C/bringup-debug.mk >/dev/null 2>&1 && echo "    bringup-debug.mk present" || echo "    WARNING: bringup-debug.mk did not transfer"'

echo "==> starting build: $TARGET"
bash scripts/builder.sh build "$TARGET"
echo
echo "Expect ~35 min of regeneration before compilation starts."
echo "Watch:  scripts/builder.sh logs     |  scripts/builder.sh status"
