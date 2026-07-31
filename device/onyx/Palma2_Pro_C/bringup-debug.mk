#
# Bring-up debugging aids for the Palma 2 Pro port.
#
# DELETE THIS FILE TO REVERT. device.mk pulls it in with
# `inherit-product-if-exists`, so removing the file is the entire revert -- no
# other edit needed. (It still costs one ~35 min ckati regeneration, like any
# device-tree change; see docs/05-remote-build.md.)
#
# WHY THIS EXISTS
#
# Every diagnosis during this port was done blind. On a non-stock system this
# device never brings USB up -- measured: 46 seconds of no enumeration during a
# GSI boot window -- because USB gadget setup goes through Onyx's Android 11
# vendor HAL. So there is no adb and no logcat while anything is going wrong.
# What we had instead was `/sys/fs/pstore/console-ramoops-0`, a 128 KB ring
# holding only the *tail* of the previous boot's KERNEL log, bit-rotted, and with
# no userspace logging in it at all.
#
# The one thing that would have saved days: userspace logs surviving a reboot.
#
# HOW
#
# `logcatd` is already part of logd -- an existing service with existing
# sepolicy that writes rotating logcat output to /data/misc/logd/. It is enabled
# purely by property, so this needs no new init service, no new SELinux domain
# and no sepolicy at all. That matters: a custom service writing to a raw
# partition would need a domain, and getting that wrong is another failed boot.
#
# /data/misc/logd is DE (device-encrypted) storage, readable once /data mounts
# without any user unlock. And because a flashed build shares the real userdata
# with stock, logs written by a failed boot of our image can be read back after
# rebooting into stock -- which is exactly the recovery path we kept needing.
#
# Note this does NOT help if the failure is before /data mounts. For that, pstore
# remains the only source, and `scripts/builder.sh` is not involved -- see
# docs/findings.md on reading it (use grep -a; the contents are bit-rotted).
#

# Non-persist variant is read at boot before any /data property load; the persist
# one survives across boots once /data is up. Set both deliberately.
PRODUCT_PROPERTY_OVERRIDES += \
    logd.logpersistd=logcatd \
    logd.logpersistd.size=64 \
    persist.logd.logpersistd=logcatd \
    persist.logd.logpersistd.size=64

# Bigger in-memory buffers so an early crashloop does not overwrite its own
# first failure before logcatd flushes. 64 KB of default per-buffer is not enough
# when netd/zygote are restarting in a tight loop -- observed exactly that.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.logd.size=4M \
    persist.logd.size=4M

# Keep the ring buffer across a soft reboot where the kernel allows it.
PRODUCT_PROPERTY_OVERRIDES += \
    persist.logd.kernel=true
