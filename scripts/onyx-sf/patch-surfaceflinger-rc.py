F="/aosp/frameworks/native/services/surfaceflinger/surfaceflinger.rc"
new = """# onyx-sf branch: run Onyx's stock SurfaceFlinger instead of the one we build.
#
# Their binary needs their own library closure, which cannot be mixed with ours,
# so it lives in /system/lib64/onyxsf and is reached via LD_LIBRARY_PATH.
# libbinder/libbinder_ndk are deliberately NOT in that directory -- theirs speak
# a different IServiceManager revision and addService fails silently.
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
