#!/usr/bin/env python3
"""Generate Android.bp + onyx-sf.mk for the Onyx SurfaceFlinger prebuilts.

Run on the builder. ELF files CANNOT go through PRODUCT_COPY_FILES -- the build
rejects them outright:

    error: found ELF prebuilt in PRODUCT_COPY_FILES,
           use cc_prebuilt_binary / cc_prebuilt_library_shared instead.

So each lib becomes a cc_prebuilt_library_shared. Two details matter:

  * module names must not collide with the real modules (there is already a
    `libgui`), so they are prefixed `onyxsf_` and `stem` restores the real
    filename on disk;
  * `relative_install_path: "onyxsf"` puts them in /system/lib64/onyxsf, which
    is what surfaceflinger.rc points LD_LIBRARY_PATH at. They must NOT land in
    /system/lib64 -- they would shadow ours for every process.

check_elf_files is disabled: these are vendor binaries whose DT_NEEDED closure
deliberately does not resolve against our system (libbinder is ours on purpose).
"""
import os, re

D = "/aosp/device/onyx/Palma2_Pro_C"
LD = f"{D}/onyx-sf/lib64"

for f in os.listdir(LD):
    if f.startswith("._"):
        os.unlink(os.path.join(LD, f))

libs = sorted(x for x in os.listdir(LD) if x.endswith(".so"))
mod = lambda f: "onyxsf_" + re.sub(r"[^A-Za-z0-9_]", "_", f[:-3])

bp = ["""// Onyx stock SurfaceFlinger prebuilts -- onyx-sf branch only.
//
// PROPRIETARY Onyx/Qualcomm binaries extracted from the device we own. Fine for
// that device, NOT redistributable. Never merge this branch to main.
//
// Installed to /system/lib64/onyxsf, NOT /system/lib64: their libgui and ours
// cannot coexist at the same path, and every other process needs ours.
// surfaceflinger.rc points LD_LIBRARY_PATH here.
//
// libbinder.so / libbinder_ndk.so are deliberately absent -- theirs speak a
// different IServiceManager AIDL revision and addService fails silently.

cc_prebuilt_binary {
    name: "surfaceflinger_onyx",
    srcs: ["onyx-sf/surfaceflinger_onyx"],
    compile_multilib: "64",
    check_elf_files: false,
    strip: { none: true },
}
"""]

for f in libs:
    bp.append(f"""cc_prebuilt_library_shared {{
    name: "{mod(f)}",
    stem: "{f[:-3]}",
    srcs: ["onyx-sf/lib64/{f}"],
    relative_install_path: "onyxsf",
    compile_multilib: "64",
    check_elf_files: false,
    strip: {{ none: true }},
    prefer: false,
}}
""")

open(f"{D}/Android.bp", "w").write("\n".join(bp))

mk = ["""#
# onyx-sf: run Onyx's stock SurfaceFlinger instead of ours. NOT FOR main.
# Prebuilt modules are declared in Android.bp; this only selects them and sets
# the two properties their SF needs or it SIGSEGVs during startup.
#

PRODUCT_PACKAGES += \\
    surfaceflinger_onyx"""]
for f in libs:
    mk[-1] += " \\"
    mk.append(f"    {mod(f)}")
mk.append("""
# use_smooth_motion=0    else SIGSEGV in QtiSurfaceFlingerExtension::qtiCreateSmomoInstance
# prime_shader_cache.*=0 else SIGSEGV in Skia shadow-layer priming
PRODUCT_SYSTEM_PROPERTIES += \\
    vendor.display.use_smooth_motion=0 \\
    debug.sf.prime_shader_cache.shadow_layers=0 \\
    debug.sf.prime_shader_cache.clipped_layers=0 \\
    debug.sf.prime_shader_cache.clipped_dimmed_image_layers=0 \\
    debug.sf.prime_shader_cache.hole_punch=0 \\
    debug.sf.prime_shader_cache.image_dimmed_layers=0 \\
    debug.sf.prime_shader_cache.image_layers=0 \\
    debug.sf.prime_shader_cache.pip_image_layers=0 \\
    debug.sf.prime_shader_cache.solid_dimmed_layers=0 \\
    debug.sf.prime_shader_cache.solid_layers=0 \\
    debug.sf.prime_shader_cache.transparent_image_dimmed_layers=0
""")
open(f"{D}/onyx-sf.mk", "w").write("\n".join(mk))
print(f"Android.bp: {len(libs)} shared libs + 1 binary")
print(f"onyx-sf.mk: PRODUCT_PACKAGES with {len(libs)+1} modules")
