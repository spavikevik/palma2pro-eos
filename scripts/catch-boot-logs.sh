#!/usr/bin/env bash
# Catch the GSI's adb window during a failing boot and pull everything.
#
# The /e/OS GSI ships ro.adb.secure=0 / ro.debuggable=1, so its adbd accepts a
# host with no "Allow USB debugging" dialog -- which matters because the dialog
# never renders: system_server aborts at StorageManagerService.initUser0() and
# the framework reboots to recovery.
#
# Stock recovery's adbd DOES require authorisation, so the two are trivially
# distinguishable: state `device` is the GSI, state `unauthorized` is recovery.
# Only `device` is worth acting on.
#
# adbd starts on sys.usb.config=adb, long before system_server, so there is a
# window of roughly 10-30s. Poll fast and grab the logs the moment it opens.

set -u
OUT=${1:-firmware/diag/bootlogs}
mkdir -p "$OUT"

TRACE="$OUT/usb-trace.txt"
: > "$TRACE"
echo "polling for GSI adbd (state=device). transitions -> $TRACE"
deadline=$((SECONDS + 300))
got=0
last=""

while [ $SECONDS -lt $deadline ]; do
    state=$(adb devices 2>/dev/null | sed -n '2p' | awk '{print $2}')
    # Record every change, including disappearing (empty), so we can see the
    # actual boot sequence rather than guessing at it.
    if [ "$state" != "$last" ]; then
        printf '[t+%3ds] %s\n' "$SECONDS" "${state:-<gone>}" | tee -a "$TRACE"
        last="$state"
    fi
    case "$state" in
        device)
            echo "[t+$SECONDS] GSI adbd UP -- capturing"
            # Ordered by how fast we lose them: logcat first, it holds the
            # vold/keystore failure behind init_user0_failed.
            adb shell logcat -b all -d            > "$OUT/logcat-all.txt"    2>&1 &
            adb shell dmesg                       > "$OUT/dmesg.txt"         2>&1 &
            wait
            adb shell 'logcat -b crash -d'        > "$OUT/logcat-crash.txt"  2>&1
            adb shell 'getprop'                   > "$OUT/getprop.txt"       2>&1
            adb shell 'cat /proc/cmdline'         > "$OUT/cmdline.txt"       2>&1
            adb shell 'ls -la /data /metadata'    > "$OUT/data-ls.txt"       2>&1
            adb shell 'dumpsys mount'             > "$OUT/dumpsys-mount.txt" 2>&1
            got=1
            break
            ;;
        unauthorized)
            # recovery, not the GSI -- the boot already failed
            :
            ;;
    esac
    sleep 0.4
done

if [ "$got" = 1 ]; then
    echo "--- captured into $OUT ---"
    wc -l "$OUT"/*.txt 2>/dev/null
    echo
    echo "=== vold / keystore / storage lines ==="
    grep -iE 'vold|keystore|keymint|keymaster|initUser0|StorageManager|e4crypt|fscrypt|metadata' \
        "$OUT/logcat-all.txt" 2>/dev/null | tail -60
else
    echo "never saw state=device within the window"
fi
