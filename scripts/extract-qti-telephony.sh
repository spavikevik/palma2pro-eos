#!/usr/bin/env bash
# extract-qti-telephony -- install the client that makes VoLTE calls carry audio.
#
#   scripts/extract-qti-telephony.sh              extract from firmware, install, reboot
#   scripts/extract-qti-telephony.sh --extract    extract only, do not touch the device
#   scripts/extract-qti-telephony.sh --uninstall  remove it again
#
# WHAT IS MISSING WITHOUT THIS
# ----------------------------
# qcrild registers vendor.qti.hardware.radio.am@1.0::IQcRilAudio and waits for a
# client to call setCallback. When a call goes active it pushes
# "vsid=0x11C05000;call_type=LTE;call_state=2" through that callback, which
# reaches the audio HAL as adev_set_parameters -> update_call_states ->
# start_call, and only then are the VoiceMMode PCMs opened.
#
# /e/OS ships no such client, so calls connect and are silent in both
# directions. Stock Onyx does ship one, inside QtiTelephonyService.apk; the port
# lost it when /e/OS replaced system_ext. This puts it back. docs/23-volte.md.
#
# WHY IT NEEDS priv-app AND AN ALLOWLIST, WHEN STOCK DOES NOT
# -----------------------------------------------------------
# The app wants MODIFY_AUDIO_ROUTING, which is signature|privileged. On stock
# both halves are satisfied trivially: it is signed with Onyx's platform key, so
# the signature half matches and it can live unprivileged in /system_ext/app.
#
# Our build has a different platform key. The signature half can never match, so
# the permission has to come from the privileged half instead: /system_ext/
# priv-app plus an entry in privapp-permissions-qtitelephony.xml.
#
# Install it stock-style, in /system_ext/app with no allowlist, and it fails in
# a way that is easy to misread:
#
#     SecurityException: Not allowed to monitor audioserver state
#     NullPointerException ... AudioController.updateAudioCallbacks
#         at QtiTelephonyService.onCreate(QtiTelephonyService.java:109)
#
# AudioController never constructs, the field stays null, and because the app is
# android:persistent the framework restarts it forever.
#
# LICENSING
# ---------
# This APK is Qualcomm proprietary. It is extracted from firmware you already
# have into gitignored firmware/, never committed, and never shipped in an image
# this repo publishes. Same rule as ims.apk and the FP4 ABL.
#
# There is a free alternative -- sonyxperiadev/QcRilAm, Apache-2.0 -- and this
# repo carried it briefly. It was dropped: VoLTE signalling already requires the
# proprietary ims.apk, so no published image can place calls anyway, and the
# redistributability it bought was worth nothing in practice. The blob is what
# Onyx shipped and tested on this exact vendor stack. Recoverable from git
# history if that reasoning ever stops holding.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${REPO_ROOT}/firmware"
SUPER="${FW}/super.img"
OUT="${FW}/qti-telephony"
LPUNPACK="${REPO_ROOT}/scripts/lpunpack.py"
TEL="${REPO_ROOT}/device/onyx/Palma2_Pro_C/telephony"

APK_NAME="QtiTelephonyService.apk"
PRIVAPP="/system_ext/priv-app/QtiTelephonyService"
ALLOWLIST="privapp-permissions-qtitelephony.xml"

# Where it lives in stock system_ext. That image unpacks with system_ext as its
# root, so there is no /system_ext prefix inside it.
APK_PATH="/app/QtiTelephonyService/${APK_NAME}"

MODE="${1:-}"

# --------------------------------------------------------------------------

uninstall() {
    adb root >/dev/null 2>&1; sleep 2
    adb remount >/dev/null 2>&1
    adb shell "rm -rf $PRIVAPP /system_ext/app/QtiTelephonyService \
                      /system_ext/etc/permissions/$ALLOWLIST"
    echo "removed. reboot to take effect:  adb reboot"
    exit 0
}
[ "$MODE" = "--uninstall" ] && uninstall

# --- extract ---------------------------------------------------------------

# e2fsprogs is keg-only under Homebrew, so it is not on PATH by default.
DEBUGFS="$(command -v debugfs || true)"
for p in /opt/homebrew/opt/e2fsprogs/sbin/debugfs /usr/local/opt/e2fsprogs/sbin/debugfs; do
  [ -n "$DEBUGFS" ] && break
  [ -x "$p" ] && DEBUGFS="$p"
done

[ -n "$DEBUGFS" ] || {
    echo "MISSING debugfs -> brew install e2fsprogs" >&2
    echo "  Reads ext4 images without mounting: no macFUSE, no kext, no root." >&2
    exit 1
}
[ -f "$SUPER" ] || {
    echo "MISSING $SUPER -- dump it first: scripts/dump-and-analyze-super.sh" >&2
    exit 1
}

mkdir -p "$OUT" "${FW}/logical"

SYSEXT="${FW}/logical/system_ext_a.img"
if [ ! -f "$SYSEXT" ]; then
    echo "==> unpacking system_ext_a from super.img"
    python3 "$LPUNPACK" "$SUPER" "${FW}/logical" system_ext_a >/dev/null
fi

echo "==> extracting $APK_PATH"
"$DEBUGFS" -R "dump $APK_PATH $OUT/$APK_NAME" "$SYSEXT" 2>/dev/null

[ -s "$OUT/$APK_NAME" ] || {
    echo "extraction produced nothing -- is $APK_PATH in this image?" >&2
    echo "  list it with: $DEBUGFS -R 'ls -l /app' $SYSEXT" >&2
    exit 1
}

# Confirm we got the client, not merely a file with the right name. The strings
# live in classes.dex, which is DEFLATE-compressed inside the APK, so grepping
# the .apk finds nothing. That exact mistake is why this component was declared
# absent from stock for several hours. Unzip first.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -qo "$OUT/$APK_NAME" classes.dex -d "$TMP" 2>/dev/null || true
if [ -f "$TMP/classes.dex" ] && LC_ALL=C grep -qa "QcRilAudio" "$TMP/classes.dex"; then
    echo "    verified: dex references QcRilAudio ($(wc -c <"$OUT/$APK_NAME" | tr -d ' ') bytes)"
else
    echo "    WARNING: no QcRilAudio in classes.dex -- wrong build?" >&2
fi

[ "$MODE" = "--extract" ] && { echo "extract only; not installing."; exit 0; }

# --- install ---------------------------------------------------------------

# A malformed permissions XML is a boot loop, not an error message: a literal
# double hyphen in a comment makes SystemConfig drop the block while still
# logging that it read the file. Validate before it goes anywhere near /system_ext.
python3 -c "import xml.dom.minidom,sys;xml.dom.minidom.parse(sys.argv[1])" \
    "$TEL/$ALLOWLIST" || {
        echo "INVALID XML: $TEL/$ALLOWLIST -- refusing to install" >&2
        exit 1
    }

echo "==> adb root + remount"
adb root >/dev/null 2>&1; sleep 3
adb remount >/dev/null 2>&1

echo "==> installing to $PRIVAPP"
# Clear the unprivileged location too. Left behind it is a second copy of a
# persistent app, and PackageManager will happily pick the wrong one.
adb shell "rm -rf /system_ext/app/QtiTelephonyService; mkdir -p $PRIVAPP"
adb push "$OUT/$APK_NAME" "$PRIVAPP/" >/dev/null
adb push "$TEL/$ALLOWLIST" /system_ext/etc/permissions/ >/dev/null
adb shell "chmod 755 $PRIVAPP
           chmod 644 $PRIVAPP/$APK_NAME /system_ext/etc/permissions/$ALLOWLIST"

cat <<EOS

==> installed. Reboot:

    adb reboot

If it does NOT boot, adbd still starts before system_server:

    adb wait-for-device && adb root && adb remount
    scripts/extract-qti-telephony.sh --uninstall && adb reboot

==> verify after boot (should print no crash, and both slots bound):

    adb shell 'logcat -d | grep -E "QcRilAudioHidl|QtiTelephonyService"'
      expect: onRegistration ... IQcRilAudio name=slot1
              QtiTelephonyService: Service started

==> verify on a call, with no manual injection:

    adb shell 'logcat -d | grep -E "INACTIVE -> ACTIVE|voice_start_usecase"'
      expect: update_calls: INACTIVE -> ACTIVE vsid:11c05000
              voice_start_usecase: enter usecase:voicemmode1-call

Signalling is separate and still needs scripts/install-ims.sh.
EOS
