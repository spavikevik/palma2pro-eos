F="/aosp/frameworks/native/services/surfaceflinger/surfaceflinger.rc"
new = """# onyx-sf branch: run Onyx's stock SurfaceFlinger instead of the one we build.
#
# Their binary needs their own library closure, which cannot be mixed with ours,
# so it lives in /system/lib64/onyxsf and is reached via LD_LIBRARY_PATH.
# libbinder/libbinder_ndk are deliberately NOT in that directory -- theirs speak
# a different IServiceManager revision and addService fails silently.

# vendor.display.use_smooth_motion MUST be 0 or their SF dies in
# QtiSurfaceFlingerExtension::qtiCreateSmomoInstance during processDisplayAdded.
#
# Setting it via PRODUCT_SYSTEM_PROPERTIES does NOT work: it lands in
# /system/build.prop, and Onyx's /vendor/build.prop sets it to 1 and wins. Init
# has to set it explicitly, and `on init` runs well before `class_start core`
# starts surfaceflinger, so the value is in place by the time SF reads it.
on init
    setprop vendor.display.use_smooth_motion 0

service surfaceflinger /system/bin/surfaceflinger_onyx
    class core animation
    user system
    group graphics drmrpc readproc
    capabilities SYS_NICE
    onrestart restart --only-if-running zygote
    task_profiles HighPerformance
    setenv LD_LIBRARY_PATH /system/lib64/onyxsf
"""
open(F,"w").write(new)
print(open(F).read())
