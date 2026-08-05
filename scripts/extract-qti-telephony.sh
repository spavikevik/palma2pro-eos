#!/usr/bin/env bash
# extract-qti-telephony -- pull QtiTelephonyService.apk out of the stock image.
#
# WHAT THIS IS FOR
# ----------------
# It carries com.qualcomm.qti.telephonyservice, whose QcRilAudioHidl /
# QcRilAudioAidl classes are the client for
# vendor.qti.hardware.radio.am@1.0::IQcRilAudio. Without a client, qcrild has
# nowhere to deliver "vsid=...;call_state=2", the audio HAL never opens the
# VoiceMMode PCMs, and calls connect silently in both directions. docs/23-volte.
#
# YOU PROBABLY DO NOT NEED THIS
# -----------------------------
# The build already includes QcRilAm, an Apache-2.0 reimplementation of exactly
# this, at device/onyx/Palma2_Pro_C/qcrilam/. It ships in the image and needs no
# extraction. This script exists for two cases:
#
#   1. QcRilAm does not work on your build. It dates from 2020 and uses the HIDL
#      Java bindings; the stock APK also implements the stable-AIDL flavour, so
#      it is the better bet if the HIDL path has rotted.
#   2. You want to compare against what stock actually did.
#
# Do not install both. qcrild keeps ONE callback -- mQcRilAudioCallback -- so
# whichever registers last silently wins, and you will be debugging a race.
#
# LICENSING
# ---------
# This APK is Qualcomm proprietary. It is extracted from firmware you already
# have, into gitignored firmware/, and is never committed and never shipped in
# an image this repo publishes. Same rule as ims.apk and the FP4 ABL. That
# restriction is exactly why QcRilAm is the default.
#
# Note the asymmetry with scripts/install-ims.sh: the ImsService has no free
# replacement, so the blob is the only route there. Here there is a choice, and
# the licence is the reason the choice went the other way.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
SUPER="${FW}/super.img"
OUT="${FW}/qti-telephony"
LPUNPACK="${REPO_ROOT}/scripts/lpunpack.py"

# Where it lives in stock system_ext. The image unpacks with system_ext as its
# root, so there is no /system_ext prefix inside it.
APK_PATH="/app/QtiTelephonyService/QtiTelephonyService.apk"

# e2fsprogs is keg-only under Homebrew, so it is not on PATH by default.
DEBUGFS="$(command -v debugfs || true)"
for p in /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs; do
  [[ -n "$DEBUGFS" ]] && break
  [[ -x "$p" ]] && DEBUGFS="$p"
done

[[ -n "$DEBUGFS" ]] || {
    echo "MISSING debugfs -> brew install e2fsprogs" >&2
    echo "  Reads ext4 images without mounting: no macFUSE, no kext, no root." >&2
    exit 1
}
[[ -f "$SUPER" ]] || {
    echo "MISSING $SUPER" >&2
    echo "  Dump it first: scripts/dump-and-analyze-super.sh" >&2
    exit 1
}

mkdir -p "$OUT" "${FW}/logical"

SYSEXT="${FW}/logical/system_ext_a.img"
if [[ ! -f "$SYSEXT" ]]; then
    echo "==> unpacking system_ext_a from super.img"
    python3 "$LPUNPACK" "$SUPER" "${FW}/logical" system_ext_a >/dev/null
fi

echo "==> extracting $APK_PATH"
"$DEBUGFS" -R "dump $APK_PATH $OUT/QtiTelephonyService.apk" "$SYSEXT" 2>/dev/null

[[ -s "$OUT/QtiTelephonyService.apk" ]] || {
    echo "extraction produced nothing -- is $APK_PATH present in this image?" >&2
    echo "  list it with: $DEBUGFS -R 'ls -l /app' $SYSEXT" >&2
    exit 1
}

# Confirm we got the client and not merely a file with the right name. The
# strings live in classes.dex, which is DEFLATE-compressed inside the APK, so
# grepping the .apk itself finds nothing -- that exact mistake is why this
# component was declared missing from stock for several hours. Unzip first.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -qo "$OUT/QtiTelephonyService.apk" classes.dex -d "$TMP" 2>/dev/null || true
if [[ -f "$TMP/classes.dex" ]] && LC_ALL=C grep -qa "QcRilAudio" "$TMP/classes.dex"; then
    echo "    verified: dex references QcRilAudio"
else
    echo "    WARNING: no QcRilAudio in classes.dex -- this may be the wrong build" >&2
fi

ls -l "$OUT/QtiTelephonyService.apk" | awk '{print "    " $5 " bytes"}'

cat <<'EOS'

==> to install (INSTEAD OF QcRilAm, never alongside it):

    adb root && adb remount
    adb shell 'pm uninstall com.sony.qcrilam 2>/dev/null; \
               rm -rf /system_ext/app/QcRilAm'
    adb shell 'mkdir -p /system_ext/app/QtiTelephonyService'
    adb push firmware/qti-telephony/QtiTelephonyService.apk \
             /system_ext/app/QtiTelephonyService/
    adb shell 'chmod 644 /system_ext/app/QtiTelephonyService/*.apk'
    adb reboot

Stock also ships a companion config that this APK reads:

    /system_ext/etc/sysconfig/qti_telephony_system_packages_config.xml

It is not required for the audio callback -- QcRilAm has no equivalent and works
without it -- but extract it the same way if the app misbehaves.

==> to verify, on a call:

    adb shell 'logcat -d | grep -iE "QcRilAudio|update_calls: INACTIVE -> ACTIVE"'
EOS
