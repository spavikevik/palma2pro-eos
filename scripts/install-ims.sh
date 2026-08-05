#!/usr/bin/env bash
# install-ims -- put a QTI ImsService on the device, to get VoLTE signalling up.
#
# STATUS: this gets SIGNALLING up -- calls connect. It does not get you audio,
# and for a while this header claimed the remaining blocker was modem side. It
# is not. See docs/23-volte.md.
#
# Audio needs a client for vendor.qti.hardware.radio.am@1.0::IQcRilAudio, which
# tells the audio HAL a call went active. The build ships one: QcRilAm, at
# device/onyx/Palma2_Pro_C/qcrilam/, Apache-2.0, installed automatically. If you
# need the stock proprietary one instead, scripts/extract-qti-telephony.sh pulls
# it from your own firmware -- but install exactly one of the two.
#
# WHY THIS EXISTS AT ALL
# ----------------------
# Onyx ships the whole vendor IMS stack -- vendor.qti.hardware.radio.ims@1.0
# through 1.7, the daemons, five libs -- and no framework client for it. Their
# ImsService is absent from stock system and product, so it was never lost in
# the port; it was never there. Consistent with a reader that has a modem for
# data and SMS and was never meant to place calls.
#
# WHERE THE PIECES COME FROM
# --------------------------
# An /e/OS community build for Fairphone 4: same SoC (SM7225/lito), same Android
# version as ours, and org.codeaurora.ims built from CAF source rather than a
# Qualcomm blob. The ABL for this project came from the same place, so the
# precedent and the platform match are both established.
#
#   https://images.ecloud.global/community/FP4/IMG-e-4.1.1-a15-*-community-FP4.zip
#
# LICENSING: extracted to firmware/, gitignored, never committed, never shipped
# in an image this repo publishes. Same rule as the FP4 ABL and Onyx binaries.
#
# SIX THINGS HAD TO BE RIGHT, each hiding the next
# ------------------------------------------------
#  1. the APK itself, from system_ext/priv-app/ims/
#  2. a privapp allowlist, installed WITH the APK. Without it PackageManager
#     throws at boot and the device loops. And the XML must be well formed: a
#     literal double hyphen in a comment makes SystemConfig drop the block while
#     still logging that it read the file. That cost one boot loop.
#  3. 20 framework jars. qti-telephony-utils and friends from system_ext.
#  4. ims-ext-common.jar, which lives in PRODUCT on FP4 and holds
#     QtiCarrierConfigHelper. This device has no /product/framework, so the jars
#     go to /system_ext/framework and the library XMLs are rewritten to match.
#  5. the native libs. In the APK directory they are SYMLINKS into
#     /system_ext/lib64; copying the directory entries yields zero byte files and
#     dlopen fails with "file offset >= file size: 0 >= 0". Take the real ones.
#  6. android.hardware.telephony.calling. Android 14 split telephony into
#     sub-features and voice calling is gated on this one. Without it the
#     framework will not hold MODE_IN_CALL, so audio_hw sets mode 2, then mode 0,
#     and tears the voice path down while the call is active.
#
# NOT PERSISTENT: the ImsService designation is a runtime override and is lost on
# reboot. Making it permanent needs config_ims_package_override_string in the
# carrier config, see device/onyx/Palma2_Pro_C/carrierconfig/.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO}/firmware/fp4-ims"
TEL="${REPO}/device/onyx/Palma2_Pro_C/telephony"

[ -f "$SRC/ims.apk" ] || {
    echo "missing $SRC/ims.apk -- extract it from an /e/OS FP4 build first." >&2
    echo "see the header of this script for the source and the licensing rule." >&2
    exit 1
}

echo "==> adb root + remount"
adb root >/dev/null 2>&1; sleep 3
adb remount >/dev/null 2>&1

echo "==> app, native libs"
adb shell 'mkdir -p /system_ext/priv-app/ims/lib/arm64'
adb push "$SRC/ims.apk" /system_ext/priv-app/ims/ims.apk >/dev/null
for l in libimsmedia_jni.so libimscamera_jni.so; do
    # Both locations: the app dir is where the APK looks, lib64 is where FP4
    # keeps the real file. These must be the REAL libraries, not the symlinks.
    adb push "$SRC/lib/arm64/$l" "/system_ext/lib64/$l" >/dev/null
    adb push "$SRC/lib/arm64/$l" "/system_ext/priv-app/ims/lib/arm64/$l" >/dev/null
done

echo "==> framework jars"
for j in "$SRC"/framework/*.jar; do
    [ -e "$j" ] && adb push "$j" /system_ext/framework/ >/dev/null
done

echo "==> permissions and feature declarations"
# Validate before pushing. A malformed permissions XML is a boot loop, not an
# error message.
for x in "$TEL"/*.xml "$SRC"/permissions/*.xml; do
    [ -e "$x" ] || continue
    python3 -c "import xml.dom.minidom,sys;xml.dom.minidom.parse(sys.argv[1])" "$x" \
        || { echo "INVALID XML: $x -- refusing to install" >&2; exit 1; }
    adb push "$x" /system_ext/etc/permissions/ >/dev/null
done

adb shell 'chmod 644 /system_ext/priv-app/ims/ims.apk \
                     /system_ext/priv-app/ims/lib/arm64/*.so \
                     /system_ext/lib64/libims*_jni.so \
                     /system_ext/framework/*.jar \
                     /system_ext/etc/permissions/*.xml 2>/dev/null || true
           chmod 755 /system_ext/priv-app/ims /system_ext/priv-app/ims/lib \
                     /system_ext/priv-app/ims/lib/arm64'

cat <<'EOS'

==> installed. Now:

    adb reboot

If it does NOT boot, adbd still starts before system_server, so:

    adb wait-for-device && adb root && adb remount
    adb shell 'rm -rf /system_ext/priv-app/ims \
        /system_ext/etc/permissions/privapp-permissions-codeaurora-ims.xml; reboot'

After boot, designate the ImsService (runtime only, repeat after every reboot):

    adb shell 'cmd phone ims set-ims-service -s 0 -d -f 1 org.codeaurora.ims'
    adb shell 'cmd phone ims set-ims-service -s 0 -d -f 0 org.codeaurora.ims'
    adb shell 'settings put global volte_vt_enabled 1'

Verify:

    adb shell 'logcat -d | grep -oE "updateRegistrationState.*to [A-Z_]+" | tail -1'
      expect: ... to REGISTRATION_STATE_REGISTERED
EOS
