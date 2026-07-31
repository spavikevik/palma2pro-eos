#!/usr/bin/env python3
"""Make BPF program-load failures non-fatal in NetBpfLoad.

Run inside the AOSP tree root:  python3 netbpfload-nonfatal.py

WHY
---
Onyx ships a Qualcomm 4.19.157 kernel and no kernel source. Android 15's BPF
loader refuses it two separate ways, and BOTH have to be handled:

  1. A version gate -- `REQUIRE(4, 19, 236)` -- which returns 1 outright.
     Handled by the sibling change to that line.

  2. Program-load failures. `loadAllElfObjects()` returning non-zero causes an
     early `return 2`, which skips the re-exec that sets `bpf.progs_loaded=1`.
     init's `bpfloader` service then trips `reboot_on_failure` and the device
     reboots with 'netbpfload-missing'. Observed at ~17-20s via pstore on this
     device.

Fixing only (1) walks straight into (2).

This mirrors TrebleDroid's
`platform_system_bpf/0001-bpfloader-relax-kernel-version-gates-and-fatal-error`,
which GSI builds depend on for exactly this class of old-kernel device: let the
loader finish so `bpf.progs_loaded` is set, and accept that programs requiring
post-4.19.157 backports do not load.

Honest consequence: networking features backed by those programs are degraded,
not repaired. Boot is preserved. Stock Android 15 works on this kernel with
Onyx's own tethering APEX, which suggests most programs will in fact load.

Idempotent; writes a .orig backup on first run.
"""

import os
import shutil
import sys

TARGET = "packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"

OLD = """        if (loadAllElfObjects(bpfloader_ver, location) != 0) {
            ALOGE("=== CRITICAL FAILURE LOADING BPF PROGRAMS FROM %s ===", location.dir);
            ALOGE("If this triggers reliably, you're probably missing kernel options or patches.");
            ALOGE("If this triggers randomly, you might be hitting some memory allocation "
                  "problems or startup script race.");
            ALOGE("--- DO NOT EXPECT SYSTEM TO BOOT SUCCESSFULLY ---");
            sleep(20);
            return 2;
        }"""

NEW = """        if (loadAllElfObjects(bpfloader_ver, location) != 0) {
            ALOGE("=== FAILURE LOADING BPF PROGRAMS FROM %s ===", location.dir);
            ALOGE("If this triggers reliably, you're probably missing kernel options or patches.");
            // PALMA2PRO: deliberately NOT returning here.
            //
            // Upstream returns 2, which skips the re-exec that sets
            // bpf.progs_loaded=1; init's bpfloader service then trips
            // 'reboot_on_failure' and the device reboots with
            // 'netbpfload-missing'. Observed on this device (Qualcomm 4.19.157,
            // no kernel source available) at ~17-20s via pstore.
            //
            // Same approach as TrebleDroid's
            // platform_system_bpf/0001-bpfloader-relax-kernel-version-gates-and-fatal-error,
            // which GSI builds rely on for this class of old-kernel device.
            //
            // Consequence, stated plainly: networking features backed by the
            // programs that fail to load are degraded, not fixed. Boot survives.
            ALOGE("--- CONTINUING ANYWAY: some BPF programs may be absent ---");
        }"""


def main():
    if not os.path.exists(TARGET):
        print(f"ERROR: {TARGET} not found -- run from the AOSP tree root", file=sys.stderr)
        return 1
    src = open(TARGET).read()
    if "CONTINUING ANYWAY" in src:
        print("already patched")
        return 0
    if OLD not in src:
        print("ERROR: anchor not found; upstream code changed. Refusing to guess.",
              file=sys.stderr)
        return 1
    if not os.path.exists(TARGET + ".orig"):
        shutil.copy2(TARGET, TARGET + ".orig")
    open(TARGET, "w").write(src.replace(OLD, NEW, 1))
    print(f"patched {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
