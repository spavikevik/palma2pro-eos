#!/usr/bin/env bash
# Palma 2 Pro recon — read-only. Nothing here modifies the device.
# Usage: bash palma-recon.sh > palma-recon.txt 2>&1
set -u

hr() { echo; echo "===== $* ====="; }

hr "build props"
adb shell getprop | grep -Ei 'ro\.(product|build\.(version|fingerprint|description)|boot\.slot|treble|vndk|board)|onyx|eink|epd'

hr "device-info (needs fastboot separately; skipped here)"

hr "partition layout"
adb shell 'ls -l /dev/block/by-name/ 2>/dev/null || su -c "ls -l /dev/block/by-name/"'

hr "dynamic partitions / super"
adb shell 'cat /proc/partitions'

hr "--- E-INK CONTROL SURFACE (the important part) ---"

hr "framebuffer sysfs"
adb shell 'ls -R /sys/class/graphics/ 2>/dev/null'

hr "DRM nodes + properties"
adb shell 'ls -l /dev/dri/ 2>/dev/null; ls -R /sys/class/drm/ 2>/dev/null | head -100'

hr "anything named eink/epd/onyx in sysfs"
adb shell 'find /sys -iname "*eink*" -o -iname "*epd*" -o -iname "*onyx*" 2>/dev/null'

hr "same in /proc and /dev"
adb shell 'ls /proc | grep -iE "eink|epd|onyx"; ls -l /dev | grep -iE "eink|epd|onyx"'

hr "vendor HALs registered"
adb shell 'lshal 2>/dev/null | grep -iE "onyx|eink|epd|display"'

hr "vendor libs mentioning eink"
adb shell 'ls /vendor/lib64 /vendor/lib /system/lib64 2>/dev/null | grep -iE "onyx|eink|epd"'

hr "onyx framework jars / overlays"
adb shell 'ls /system/framework/ | grep -iE "onyx|eink"; ls /system/etc/permissions/ | grep -iE "onyx"'

hr "init services from onyx"
adb shell 'ls /vendor/etc/init/ /system/etc/init/ 2>/dev/null | grep -iE "onyx|eink|epd"'

hr "SELinux mode"
adb shell getenforce

hr "--- TELEMETRY SURFACE ---"

hr "all onyx/chinese packages"
adb shell 'pm list packages -f' | grep -iE 'onyx|boox|umeng|baidu|tencent|alipay|jpush|getui|xiaomi|huawei'

hr "full package list (for debloat triage)"
adb shell 'pm list packages'

hr "system apps with INTERNET + location"
adb shell 'dumpsys package | grep -iE "^Package \[|android.permission.(INTERNET|ACCESS_FINE_LOCATION)"' | head -200

echo
echo "DONE. Send palma-recon.txt back."
