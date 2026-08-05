#!/usr/bin/env bash
# install-ims-stock -- install Onyx's OWN ImsService, from your stock dump.
#
#   scripts/install-ims-stock.sh              extract, install, print next steps
#   scripts/install-ims-stock.sh --extract    extract only, do not touch the device
#   scripts/install-ims-stock.sh --uninstall  remove it again
#
# WHY THIS EXISTS, AND WHY install-ims.sh STILL DOES
# --------------------------------------------------
# install-ims.sh takes org.codeaurora.ims from a Fairphone 4 build. That was a
# mistake of searching, not of judgement: the original hunt for an ImsService
# covered stock system and product and never looked in system_ext, which is
# where Onyx keeps theirs.
#
#   /system_ext/priv-app/ims/ims.apk    org.codeaurora.ims    1754379 bytes
#
# Same package, built for this device's own vendor stack, and stock is Android
# 15 / SDK 35 exactly like our build -- so the version-match argument that
# picked FP4 does not favour FP4 either.
#
# HOW MUCH SIMPLER IT IS
# ----------------------
# The FP4 route pushes 20 framework jars and rewrites library XMLs because
# ims-ext-common.jar lives in PRODUCT on FP4 and this device has no
# /product/framework. Onyx's APK declares exactly two uses-library entries:
#
#   qti-telephony-utils
#   qti-telephony-hidl-wrapper
#
# both of which stock ships in /system_ext/framework with their declarations
# already pointing at /system_ext. Nothing needs rewriting.
#
# The privapp allowlist does not change either: stock's entry for
# org.codeaurora.ims lists the same six permissions as the one already in
# device/onyx/Palma2_Pro_C/telephony/, so that file is reused as-is.
#
# ONE TRAP CARRIED OVER
# ---------------------
# In /priv-app/ims/lib/arm64 the two .so files are SYMLINKS into
# /system_ext/lib64 -- mode 120644, size 36 and 37 bytes, which is just the
# length of the target path. Copying the directory entries yields zero-byte
# files and dlopen fails with "file offset >= file size: 0 >= 0". The real ones
# are taken from /lib64.
#
# LICENSING
# ---------
# Qualcomm proprietary, extracted from firmware you already own into gitignored
# firmware/, never committed, never shipped in an image this repo publishes.
# Same rule as ims.apk from FP4, QtiTelephonyService.apk and the FP4 ABL.
#
# THIS IS SIGNALLING ONLY. Audio needs the IQcRilAudio client:
# scripts/extract-qti-telephony.sh. Neither is sufficient alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
SUPER="${FW}/super.img"
OUT="${FW}/stock-ims"
LPUNPACK="${REPO_ROOT}/scripts/lpunpack.py"
TEL="${REPO_ROOT}/device/onyx/Palma2_Pro_C/telephony"

JARS="qti-telephony-utils.jar qti-telephony-hidl-wrapper.jar qti-telephony-common.jar"
LIB_XMLS="qti_telephony_utils.xml qti_telephony_hidl_wrapper.xml"
# Real files, not the symlinks in the app's own lib directory.
NATIVE="libimsmedia_jni.so libimscamera_jni.so"

MODE="${1:-}"

uninstall() {
    adb root >/dev/null 2>&1; sleep 2
    adb remount >/dev/null 2>&1
    adb shell 'rm -rf /system_ext/priv-app/ims'
    echo "removed the APK. Framework jars and library XMLs are left in place --"
    echo "they are shared, and harmless without a client. Reboot: adb reboot"
    exit 0
}
[ "$MODE" = "--uninstall" ] && uninstall

DEBUGFS="$(command -v debugfs || true)"
for p in /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs; do
  [ -n "$DEBUGFS" ] && break
  [ -x "$p" ] && DEBUGFS="$p"
done
[ -n "$DEBUGFS" ] || { echo "MISSING debugfs -> brew install e2fsprogs" >&2; exit 1; }
[ -f "$SUPER" ] || {
    echo "MISSING $SUPER -- dump it first: scripts/dump-and-analyze-super.sh" >&2
    exit 1
}

mkdir -p "$OUT/framework" "$OUT/lib/arm64" "$OUT/permissions" "${FW}/logical"

SYSEXT="${FW}/logical/system_ext_a.img"
if [ ! -f "$SYSEXT" ]; then
    echo "==> unpacking system_ext_a from super.img"
    python3 "$LPUNPACK" "$SUPER" "${FW}/logical" system_ext_a >/dev/null
fi

dump() {  # dump <path-in-image> <dest>
    "$DEBUGFS" -R "dump $1 $2" "$SYSEXT" 2>/dev/null
    [ -s "$2" ] || { echo "  FAILED to extract $1" >&2; return 1; }
}

echo "==> extracting from stock system_ext"
dump /priv-app/ims/ims.apk "$OUT/ims.apk"
for l in $NATIVE;   do dump "/lib64/$l"            "$OUT/lib/arm64/$l"; done
for j in $JARS;     do dump "/framework/$j"        "$OUT/framework/$j"; done
for x in $LIB_XMLS; do dump "/etc/permissions/$x"  "$OUT/permissions/$x"; done

# Prove it is the ImsService and not something else with the right filename.
# classes.dex is DEFLATE-compressed inside the APK, so grepping the .apk finds
# nothing -- that mistake is why this component was declared absent from stock
# for most of a day. Read the manifest instead.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -qo "$OUT/ims.apk" AndroidManifest.xml -d "$TMP" 2>/dev/null || true
if [ -f "$TMP/AndroidManifest.xml" ] && \
   python3 - "$TMP/AndroidManifest.xml" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
# Binary XML stores strings UTF-16LE; plain `strings` sees nothing.
s = ''.join(chr(d[i]) if d[i+1] == 0 and 32 <= d[i] < 127 else '\n'
            for i in range(0, len(d)-1, 2))
sys.exit(0 if 'org.codeaurora.ims' in s and 'android.telephony.ims.ImsService' in s
         else 1)
PY
then
    echo "    verified: org.codeaurora.ims, declares android.telephony.ims.ImsService"
else
    echo "    WARNING: manifest does not look like an ImsService" >&2
fi

[ "$MODE" = "--extract" ] && { echo "extract only; not installing."; exit 0; }

# --- install ---------------------------------------------------------------

# A malformed permissions XML is a boot loop, not an error message.
for x in "$TEL/privapp-permissions-codeaurora-ims.xml" "$OUT"/permissions/*.xml; do
    python3 -c "import xml.dom.minidom,sys;xml.dom.minidom.parse(sys.argv[1])" "$x" \
        || { echo "INVALID XML: $x -- refusing to install" >&2; exit 1; }
done

echo "==> adb root + remount"
adb root >/dev/null 2>&1; sleep 3
adb remount >/dev/null 2>&1

echo "==> app and native libs"
adb shell 'mkdir -p /system_ext/priv-app/ims/lib/arm64'
adb push "$OUT/ims.apk" /system_ext/priv-app/ims/ims.apk >/dev/null
for l in $NATIVE; do
    adb push "$OUT/lib/arm64/$l" "/system_ext/lib64/$l" >/dev/null
    adb push "$OUT/lib/arm64/$l" "/system_ext/priv-app/ims/lib/arm64/$l" >/dev/null
done

echo "==> framework jars and library declarations"
for j in $JARS;     do adb push "$OUT/framework/$j" /system_ext/framework/ >/dev/null; done
for x in $LIB_XMLS; do adb push "$OUT/permissions/$x" /system_ext/etc/permissions/ >/dev/null; done
adb push "$TEL/privapp-permissions-codeaurora-ims.xml" /system_ext/etc/permissions/ >/dev/null
adb push "$TEL/android.hardware.telephony.calling.xml" /system_ext/etc/permissions/ >/dev/null

adb shell 'chmod 644 /system_ext/priv-app/ims/ims.apk \
                     /system_ext/priv-app/ims/lib/arm64/*.so \
                     /system_ext/lib64/libims*_jni.so \
                     /system_ext/framework/qti-telephony-*.jar \
                     /system_ext/etc/permissions/*.xml 2>/dev/null || true
           chmod 755 /system_ext/priv-app/ims /system_ext/priv-app/ims/lib \
                     /system_ext/priv-app/ims/lib/arm64'

cat <<'EOS'

==> installed. Reboot:

    adb reboot

If it does NOT boot, adbd still starts before system_server:

    adb wait-for-device && adb root && adb remount
    scripts/install-ims-stock.sh --uninstall && adb reboot

==> verify after boot:

    adb shell 'dumpsys telephony.registry | grep -m1 -oE "availableServices=\[[A-Z,]*\]"'
      expect: availableServices=[VOICE,SMS,VIDEO]

With PhoneImsServiceOverlay in the build, no `cmd phone ims set-ims-service` is
needed -- config_ims_mmtel_package names org.codeaurora.ims at boot. Without it,
designate by hand and repeat after every reboot:

    adb shell 'cmd phone ims set-ims-service -s 0 -d -f 1 org.codeaurora.ims'
    adb shell 'cmd phone ims set-ims-service -s 0 -d -f 0 org.codeaurora.ims'

Audio is separate: scripts/extract-qti-telephony.sh
EOS
