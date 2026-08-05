#!/usr/bin/env bash
# volte-audio-probe -- supply the call-state notification the audio HAL never gets.
#
# WHAT IS ACTUALLY MISSING
# ------------------------
# On a QTI stack the audio HAL learns that a call is up from qcrild, not from the
# framework. qcrild registers
#
#     vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
#
# and waits for a client to call setCallback(IQcRilAudioCallback). When a call
# goes active it invokes that callback with
#
#     vsid=0x........;call_state=2
#
# which reaches adev_set_parameters -> voice_set_parameters ->
# voice_extn_set_parameters -> update_call_states -> start_call, and only then
# does the HAL open the VoiceMMode PCMs.
#
# There is no such client on this device. Scanning /system, /system_ext,
# /product, /vendor and /apex finds exactly two files that mention IQcRilAudio:
# qcrild's own server implementation and the HIDL stub. Stock Onyx firmware is
# the same -- its /system carries the compatibility-matrix entry requiring the
# HAL and no code that ever binds to it. Onyx shipped a reader, so nothing was
# lost in the port; the bridge was never built.
#
# Without it every voice session stays INACTIVE for the whole call, the voice
# PCMs are never opened, and there is no audio in either direction.
#
# WHAT THIS SCRIPT DOES
# ---------------------
# Stands in for that missing client, crudely: waits for the framework to put the
# HAL into AUDIO_MODE_IN_CALL, then injects the parameters over binder.
#
# This is a PROBE, not the fix. It proves whether the notification is the only
# missing piece. The fix is a daemon that binds to IQcRilAudio properly and
# forwards what qcrild sends -- see docs/23.
#
# WHY BINDER AND NOT AN APP
# -------------------------
# AudioManager.setParameters needs an app; IAudioFlingerService.setParameters is
# reachable from the shell. Transaction 20 is not a guess -- it is
# TRANSACTION_setParameters = FIRST_CALL_TRANSACTION + 19 from the generated
# BnAudioFlingerService.h in the tree we build. Root passes settingsAllowed().

set -uo pipefail

AF=media.audio_flinger
TXN_SET_PARAMETERS=20            # FIRST_CALL_TRANSACTION + 19, from the tree
CALL_ACTIVE=2
CALL_INACTIVE=1

# The HAL keeps seven sessions. VOICEMMODE1 is the one that works on this
# device, confirmed on a live call: it starts usecase voicemmode1-call and
# exits status(0).
#
# The legacy VoLTE vsid 0x10C02000 looks like the obvious choice and is not. It
# is accepted, and update_calls does take it INACTIVE -> ACTIVE, but then
# voice_start_usecase() fails for usecase 38. Accepting a vsid says only that
# the HAL knows the constant, not that the modem has a session behind it. It is
# kept in the list as a fallback, second, because a wrong vsid fails loudly and
# harmlessly.
VSIDS_DEFAULT="0x11C05000 0x10C02000 0x10C01000"
VSIDS="${VSIDS:-$VSIDS_DEFAULT}"

adbsh() { adb shell "$@" 2>/dev/null; }

# Put every session back to INACTIVE and the HAL back to NORMAL. Worth running
# after a probe: a session left ACTIVE with no modem behind it makes the next
# real call behave oddly.
if [ "${1:-}" = "--clear" ]; then
    for v in $VSIDS; do
        adbsh "service call $AF $TXN_SET_PARAMETERS i32 0 s16 \"vsid=$v;call_state=$CALL_INACTIVE\"" >/dev/null
    done
    echo "cleared: all sessions INACTIVE"
    exit 0
fi

# Trigger on the HAL's own log line, not on dumpsys. Polling `dumpsys audio`
# missed a real call outright: each poll costs a second or two, and the window
# closes while you are still asking. This blocks until the HAL itself says it
# entered the mode, and returns the instant it does.
#
# mode 2 is AUDIO_MODE_IN_CALL. Do not confuse it with Java's AudioManager,
# where IN_CALL is 2 but IN_COMMUNICATION is 3; audio_mode_t and AudioManager
# happen to agree here, but forcing "mode 3" by hand tests IN_COMMUNICATION and
# proves nothing.
wait_in_call() { adbsh "logcat -v brief | grep -m1 'adev_set_mode: mode 2 '"; }
pcm_state() { adbsh 'for d in 2 15; do printf "pcm%s=%s " $d "$(cat /proc/asound/card0/pcm${d}p/sub0/status 2>/dev/null | head -1)"; done'; }

set_params() {
    adbsh "service call $AF $TXN_SET_PARAMETERS i32 0 s16 \"vsid=$1;call_state=$2\"" >/dev/null
}

echo "==> enabling HAL voice logging"
adbsh 'setprop log.tag.voice VERBOSE
       setprop log.tag.voice_extn VERBOSE
       setprop log.tag.audio_hw_primary VERBOSE
       setprop persist.vendor.radio.adb_log_on 1'
adbsh 'logcat -c'

echo "==> baseline: $(pcm_state)"
echo
echo "PLACE A CALL NOW. Waiting for the framework to enter IN_CALL mode..."

if ! timeout "${WAIT:-180}" bash -c "$(declare -f adbsh wait_in_call); wait_in_call"; then
    echo "timed out -- the HAL never entered AUDIO_MODE_IN_CALL." >&2
    echo "  Either no call was placed, or the framework is not holding the mode;" >&2
    echo "  check that android.hardware.telephony.calling is still installed." >&2
    exit 1
fi

echo "==> HAL entered AUDIO_MODE_IN_CALL"
echo "==> voice PCMs before injection: $(pcm_state)"

started=""
for vsid in $VSIDS; do
    echo "==> injecting vsid=$vsid call_state=$CALL_ACTIVE"
    set_params "$vsid" "$CALL_ACTIVE"
    sleep 3
    state=$(pcm_state)
    echo "    $state"
    # Both voice front-ends read "closed" until the HAL opens one. Anything else
    # on either of them means a session actually started.
    if ! echo "$state" | grep -q 'pcm2=closed .*pcm15=closed'; then
        echo "    *** a voice PCM opened on $vsid ***"
        started="$vsid"
        break
    fi
    # Not this one. Put it back before trying the next, so the HAL's session
    # table does not accumulate half-started sessions.
    set_params "$vsid" "$CALL_INACTIVE"
done

echo
echo "=== HAL log ==="
adbsh 'logcat -d | grep -iE "vsid|call_state|update_call|start_call|voice_|pcm_open" | tail -40'

echo
if [ -n "$started" ]; then
    echo "RESULT: session started with vsid=$started."
    echo "  If you can hear audio, the missing call-state notification was the"
    echo "  whole problem and the daemon in docs/23 is the fix."
else
    echo "RESULT: no voice PCM opened. The notification alone is not sufficient;"
    echo "  read the HAL log above before theorising."
fi
echo
echo "Hang up, then run:  scripts/volte-audio-probe.sh --clear"
