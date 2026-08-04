#!/system/bin/sh
# epd-deadman -- arm an automatic reboot, then disarm it if the probe survives.
#
# WHY
# ---
# Probing this driver has taken the device down twice. Once it rebooted on its
# own (a stack variable passed where a struct was expected). Once it did not:
# reagl_enable=1 driving glr16 wedged the display pipeline and the device sat
# unresponsive for 220 seconds.
#
# That 220s is worth understanding, because the obvious explanation is wrong.
# The SoC watchdog is alive and configured -- devicetree says
#
#     qcom,bark-time = 0x2af8   (11000 ms)
#     qcom,pet-time  = 0x2490   ( 9360 ms)
#
# so a genuinely dead kernel is reset in about 14 seconds. It took 220 because
# the kernel was NOT dead: the watchdog kept being petted while only the display
# pipeline was stuck. A hang of that shape is invisible to every automatic
# recovery this kernel has -- and it has fewer than you would hope:
#
#     CONFIG_DETECT_HUNG_TASK      not set
#     CONFIG_SOFTLOCKUP_DETECTOR   not set
#     CONFIG_WQ_WATCHDOG           not set
#     CONFIG_WATCHDOG              not set   (so no /dev/watchdog to arm)
#
# None of those can be turned on without building a kernel. So the deadman is
# in userspace: arm a reboot before touching anything, disarm it afterwards.
# If the probe wedges the display but leaves the system schedulable -- exactly
# the case that cost 220 seconds -- this fires and the loop is ~30s instead.
#
# WHAT SURVIVES A HANG
# --------------------
# Nothing here needs adb, a shell, or a responsive UI: the timer is already
# running in the background before the risky call is made. `reboot` is a
# clean shutdown; if even that cannot run, the SoC watchdog is the backstop.
#
# USAGE
#   epd-deadman.sh arm 30        # reboot in 30s unless disarmed
#   ... do the risky thing ...
#   epd-deadman.sh disarm
#   epd-deadman.sh status

STAMP=/data/local/tmp/epd-deadman.armed
PIDF=/data/local/tmp/epd-deadman.pid

case "$1" in
arm)
    SECS="${2:-30}"
    "$0" disarm >/dev/null 2>&1
    : > "$STAMP"
    # setsid so the timer is not a child of the adb shell: killing the shell,
    # or losing USB, must not disarm it. That is the whole point.
    setsid sh -c '
        sleep '"$SECS"'
        if [ -f '"$STAMP"' ]; then
            echo "epd-deadman: not disarmed after '"$SECS"'s, rebooting" > /dev/kmsg
            sync
            reboot
        fi
    ' >/dev/null 2>&1 &
    echo $! > "$PIDF"
    echo "armed: reboot in ${SECS}s unless disarmed (pid $(cat $PIDF))"
    ;;
disarm)
    rm -f "$STAMP"
    [ -f "$PIDF" ] && kill "$(cat $PIDF)" 2>/dev/null
    rm -f "$PIDF"
    echo "disarmed"
    ;;
status)
    if [ -f "$STAMP" ]; then echo "ARMED (pid $(cat $PIDF 2>/dev/null))";
    else echo "disarmed"; fi
    ;;
*)
    echo "usage: $0 arm [seconds] | disarm | status" >&2
    exit 2
    ;;
esac
