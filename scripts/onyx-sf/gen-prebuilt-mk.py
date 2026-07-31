import os
D="/aosp/device/onyx/Palma2_Pro_C"
LD=f"{D}/onyx-sf/lib64"
for f in os.listdir(LD):
    if f.startswith("._"): os.unlink(os.path.join(LD,f))
libs=sorted(os.listdir(LD))
hdr = """#
# onyx-sf: run Onyx's stock SurfaceFlinger instead of ours.
#
# NOT FOR main. These are proprietary Onyx/Qualcomm binaries extracted from the
# device we own -- fine for that device, NOT redistributable.
#
# Their SF needs their own library closure; ours and theirs cannot be mixed
# (their SF needs their libgui for the android::JankData vtable, while our
# libcamera_client/libmedia need ours). So the libs install to a private
# directory and the service gets LD_LIBRARY_PATH, rather than overwriting
# /system/lib64.
#
# DELIBERATELY EXCLUDED: libbinder.so and libbinder_ndk.so. Onyx's copies speak
# a different IServiceManager AIDL revision than our servicemanager, so every
# addService fails SILENTLY -- SF ignores the return value -- and SurfaceFlinger
# never registers. Using the system's binder libraries is what makes it work.
#
DEVICE_PATH := device/onyx/Palma2_Pro_C

PRODUCT_COPY_FILES += \\
    $(DEVICE_PATH)/onyx-sf/surfaceflinger_onyx:$(TARGET_COPY_OUT_SYSTEM)/bin/surfaceflinger_onyx"""
lines=[hdr]
for l in libs:
    lines[-1]+=" \\"
    lines.append(f"    $(DEVICE_PATH)/onyx-sf/lib64/{l}:$(TARGET_COPY_OUT_SYSTEM)/lib64/onyxsf/{l}")
props = """

# Both are required or their SF SIGSEGVs during startup:
#   use_smooth_motion=0        -> else QtiSurfaceFlingerExtension::qtiCreateSmomoInstance
#   prime_shader_cache.*=0     -> else Skia shadow-layer priming (drawShadowLayers)
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
"""
open(f"{D}/onyx-sf.mk","w").write("\n".join(lines)+props)
print(f"onyx-sf.mk: {len(libs)} libs")
