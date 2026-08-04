#!/system/bin/sh
# epd-debug-arm -- put the device into the state driver reverse-engineering needs.
#
# Run once after every boot. Everything here is runtime-only and resets on
# reboot, which is deliberate: none of it should be on for daily use.
#
# WHAT AND WHY
#
#   sysrq=1
#       CONFIG_MAGIC_SYSRQ is compiled in but the runtime gate is 0. Turning it
#       on gives two things nothing else on this kernel provides:
#         echo w > /proc/sysrq-trigger   dump every task in D state
#         echo c > /proc/sysrq-trigger   crash on demand -> ramoops -> reboot
#       The first is the diagnostic for a wedged display. The three EPD kernel
#       threads sit in down() when idle:
#         mdss_fb_epdc     mdss_mdp_epdc_thread+0x1cc
#         epdc_refresh_wa  epdc_refresh_waveform_task+0xa4
#         commit_epdc      mdss_commit_epdc_thread+0x90
#       Different offsets during a hang say which one is stuck and where.
#
#   kptr_restrict=0
#       Makes /proc/kallsyms show real addresses instead of zeros. That is what
#       makes the shipped kernel disassemblable: file_offset = addr - _text.
#       A security downgrade -- it hands any reader the kernel layout -- so it
#       is not persisted, and there is no reason to leave it on.
#
# WHAT IS ALREADY SET, AND WHAT CANNOT BE
#
#   panic=5, panic_on_oops=1 are set by init and survive reboot, so a genuine
#   oops already reboots on its own and leaves a dmesg-ramoops record behind.
#
#   The lockup detectors are NOT compiled in and cannot be enabled at runtime:
#       CONFIG_DETECT_HUNG_TASK, CONFIG_SOFTLOCKUP_DETECTOR,
#       CONFIG_WQ_WATCHDOG, CONFIG_WATCHDOG   -- all unset
#   That is the gap epd-deadman.sh fills. The SoC watchdog (bark 11s, bite ~14s)
#   only helps when the kernel stops running entirely; a stuck display pipeline
#   keeps petting it, which is why one earlier probe hung for 220 seconds.

set -u

sysfs=/sys/devices/virtual/sepdc/debug

echo 1 > /proc/sys/kernel/sysrq        2>/dev/null
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null

printf 'sysrq=%s kptr_restrict=%s panic=%s panic_on_oops=%s\n' \
    "$(cat /proc/sys/kernel/sysrq)" \
    "$(cat /proc/sys/kernel/kptr_restrict)" \
    "$(cat /proc/sys/kernel/panic)" \
    "$(cat /proc/sys/kernel/panic_on_oops)"

# pstore keeps the previous boot's console across a reboot, which is how a
# crash gets read after the fact. Say whether a crash record is waiting:
# console-ramoops is always there, dmesg-ramoops only appears after an oops.
if [ -e /sys/fs/pstore/dmesg-ramoops-0 ]; then
    echo "pstore: CRASH RECORD PRESENT -- /sys/fs/pstore/dmesg-ramoops-0"
else
    echo "pstore: console log only (no crash since last clear)"
fi

echo "epd status: $(cat $sysfs/status 2>/dev/null)"
echo
echo "  hang check:  adb shell 'echo w > /proc/sysrq-trigger; dmesg | tail -40'"
echo "  probe guard: /data/local/tmp/epd-deadman.sh arm 30"
