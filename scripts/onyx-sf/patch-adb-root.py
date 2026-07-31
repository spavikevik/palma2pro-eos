#!/usr/bin/env python3
"""Let `adb root` work on the onyx-sf branch.

/e/OS gates adbd's root restart behind an adbroot binder service. Ours reports
enabled (`service call adbroot_service 1` -> 1) yet adbd still refuses, so its
getEnabled() sees something different. Rather than chase that, force `enabled`
true on debuggable builds only -- which is already the condition AOSP itself
uses to allow adb root at all.

BRANCH ONLY. This weakens a deliberate /e/OS security control; it exists here so
we can read /proc/<pid>/maps, remount /system for hot-swapping, and drive the
EPD experiments without a full flash each time.
"""
F = "/aosp/packages/modules/adb/daemon/restart_service.cpp"
s = open(F).read()
OLD = """    if (!enabled) {"""
NEW = """    // onyx-sf branch: /e/OS's adbroot gate reports disabled to adbd even when
    // the service itself answers getEnabled()==true. On a debuggable build we
    // already satisfy AOSP's own condition for allowing adb root, so honour it.
    if (__android_log_is_debuggable()) {
        enabled = true;
    }
    if (!enabled) {"""
assert OLD in s and NEW not in s
s = s.replace(OLD, NEW, 1)
open(F, "w").write(s)
print("adb root gate patched (debuggable builds only)")
