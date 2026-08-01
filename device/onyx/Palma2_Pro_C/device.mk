#
# Device configuration for the Onyx Boox Palma 2 Pro (Palma2_Pro_C).
# SPDX-License-Identifier: Apache-2.0
#
# Deliberately minimal. This is a system-side port onto Onyx's existing Android
# 11 vendor image, not a full device bring-up:
#
#   * /vendor is NOT rebuilt, so there is no proprietary-files.txt and no
#     extract-files.py. Every HAL, firmware blob and the EPD composer stay on
#     the device untouched.
#   * The kernel is a prebuilt from the stock boot image -- Onyx publishes no
#     kernel source.
#
# What this file therefore has to supply is only what a generic system image
# lacks: the fstab, the pieces Onyx's vendor init expects to find in /system,
# and SELinux permission for the compositor to reach the EPD device.
#

DEVICE_PATH := device/onyx/Palma2_Pro_C

# --- Dynamic partitions ----------------------------------------------------
# BoardConfig.mk declares the super layout (BOARD_SUPER_PARTITION_SIZE, the
# qti_dynamic_partitions group), but that is only the BOARD half. Without the
# PRODUCT half the build treats system/product/system_ext as fixed-size
# partitions, and build_image.py dies looking for a size we never gave it:
#
#     File "build_image.py", line 642, in BuildImage
#     KeyError: 'partition_size'
#
# With this set, image sizes are computed from content instead.
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Do NOT assemble super.img. This port deliberately does not rebuild vendor or
# odm -- the device keeps Onyx's Android 11 vendor image -- so a super image
# could not be assembled anyway, and we flash the logical partitions
# individually over EDL (scripts/flash-logical-via-edl.py).
PRODUCT_BUILD_SUPER_PARTITION := false

# --- Platform --------------------------------------------------------------
PRODUCT_SHIPPING_API_LEVEL := 30

PRODUCT_TARGET_VNDK_VERSION := 30

# ...and actually SHIP the VNDK 30 snapshot. This is the fix for the blank-screen
# hang, traced end to end from the on-device log:
#
#   E linkerconfig: Unable to access VNDK APEX at path: /apex/com.android.vndk.v30
#   F linkerconfig: Check failed: !"undefined var" SANITIZER_DEFAULT_VENDOR is not defined
#   I linkerconfig: Fatal signal 6 (SIGABRT) in BuildVendorNamespace
#   F linker: CANNOT LINK EXECUTABLE "/system/bin/keystore2":
#             library "libandroidicu.so" not found: needed by libsqlite.so
#   servicemanager: vold waiting for android.system.keystore2.IKeystoreService ... forever
#
# PRODUCT_TARGET_VNDK_VERSION only DECLARES that vendor is VNDK 30 (which it is --
# Onyx's vendor is Android 11). It does not build the snapshot. Without the APEX,
# linkerconfig aborts building the vendor namespace, /linkerconfig/ld.config.txt
# is never written, and from then on nothing can resolve its libraries. keystore2
# dies first, vold blocks on it, /data is never set up, boot stops dead.
#
# build/make/core/main.mk:1017 turns each entry here into com.android.vndk.v<ver>,
# sourced from prebuilts/vndk/v30 which is already in the tree.
PRODUCT_EXTRA_VNDK_VERSIONS := 30

# --- A/B ------------------------------------------------------------------
PRODUCT_PACKAGES += \
    otapreopt_script \
    update_engine \
    update_engine_sideload \
    update_verifier

# NO boot HAL here, deliberately.
#
# boot control is a VENDOR HAL and this device keeps Onyx's Android 11 vendor
# image, which already provides it -- that is what makes A/B work today on stock.
# Building a system-side copy would be unused at best.
#
# The first attempt listed android.hardware.boot@1.1-impl-qti and
# .recovery, which do not exist in this tree at all (checked: no Android.bp or
# Android.mk defines them) and failed the build:
#     main.mk:1117: error: includes non-existent modules in PRODUCT_PACKAGES
# android.hardware.boot@1.1-service DOES exist
# (hardware/interfaces/boot/1.1/default) but is equally wrong to ship here.

AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=ext4 \
    POSTINSTALL_OPTIONAL_system=true

# --- fstab -----------------------------------------------------------------
# Taken verbatim from stock /vendor. Note it specifies
# fileencryption=...+emmc_optimized+wrappedkey_v0 and
# metadata_encryption=aes-256-xts:wrappedkey_v0 -- Qualcomm hardware-wrapped
# keys. AOSP vold handles these generically (the Fairphone 4 tree sets no
# special flags for the same scheme), with the vendor's KeyMint supplying the
# storage-key capability.
# Ship BOTH fstabs, under both names.
#
# The stock ramdisk carries fstab.default AND fstab.emmc, and they are NOT the
# same file:
#     fstab.default  5144 B, 16 entries
#     fstab.emmc     4985 B, 15 entries
# `default` additionally mounts /onyxconfig, and its /data line carries `dirsync`
# which `emmc` lacks.
#
# Stock evidently boots with fstab.default: the onyxconfig partition is populated
# and carries its own SELinux types (onyxconfig_file, onyxmmkv_file), and only
# fstab.default mounts it. Which file init reads is chosen by
# androidboot.fstab_suffix, supplied by the bootloader -- we cannot see it from
# here, and guessing wrong means first-stage mount finds no /data at all.
#
# So ship both. This was previously shipping ONLY fstab.emmc, which never showed
# up because we boot stock's ramdisk (it has both) and vendor is not rebuilt --
# our copies were simply never used. With our own boot.img they would be.
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/rootdir/etc/fstab.default:$(TARGET_COPY_OUT_RAMDISK)/fstab.default \
    $(DEVICE_PATH)/rootdir/etc/fstab.emmc:$(TARGET_COPY_OUT_RAMDISK)/fstab.emmc \
    $(DEVICE_PATH)/rootdir/etc/fstab.default:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.default \
    $(DEVICE_PATH)/rootdir/etc/fstab.emmc:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.emmc

# Bring-up boot logger (see rootdir/etc/init/palma-bootlog.rc).
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/rootdir/etc/init/palma-bootlog.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/palma-bootlog.rc

# --- Onyx system-side dependencies ----------------------------------------
# /vendor/etc/init/hw/init.onyx.rc (imported by init.qcom.rc) runs
#     exec - system system -- /system/bin/mkfifo /dev/onyx/listener
# and chmods a list of /sys/onyx_misc/* nodes.
#
# /system/bin/mkfifo itself is a toybox symlink present in stock AND in the /e/OS
# GSI (verified by listing both), so that one comes for free.
#
# But vendor init references 17 binaries under /system, and comparing stock
# against the GSI shows five Onyx scripts that only stock has:
#
#     init.onyx.sh  init.onyxconfig.sh  TouchMisc.sh  sndTinycap.sh  tpCalibrate.sh
#
# (init.onyx.misc.sh is included too -- called by init.onyx.sh.)
#
# None are declared `critical` -- in fact vendor init declares no critical
# services at all -- so their absence is NOT boot-fatal, and this is not an
# explanation for the GSI failure. It does mean touch calibration, sound setup
# and the /onyxconfig preparation silently never run. Ship them.
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/rootdir/bin/init.onyx.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/init.onyx.sh \
    $(DEVICE_PATH)/rootdir/bin/init.onyx.misc.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/init.onyx.misc.sh \
    $(DEVICE_PATH)/rootdir/bin/init.onyxconfig.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/init.onyxconfig.sh \
    $(DEVICE_PATH)/rootdir/bin/TouchMisc.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/TouchMisc.sh \
    $(DEVICE_PATH)/rootdir/bin/sndTinycap.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/sndTinycap.sh \
    $(DEVICE_PATH)/rootdir/bin/tpCalibrate.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/tpCalibrate.sh

# --- Display / e-ink -------------------------------------------------------
# The panel is driven by the vendor composer through DRM plane properties
# EPDC_UPDATE_PARMS_ADDR / EPDC_UPDATE_CNT during atomic commit; see
# docs/03-ebc-api.md. Nothing to add here for the transport itself -- that lives
# in /vendor. What IS still open is SurfaceFlinger: Onyx's computes and merges
# the update regions and hands them over on a private composer AIDL. A stock
# AOSP SurfaceFlinger does not, so refresh quality will be poor until that is
# resolved.
# NO graphics HALs here either, for the same reason -- and this file already said
# so two paragraphs up before contradicting itself.
#
# android.hardware.graphics.allocator@4.0-service does not exist in this tree
# (A15 moved allocator to AIDL), and composer@2.4-service, which does exist,
# belongs to vendor. Onyx's vendor.qti.hardware.display.composer-service is what
# actually drives the panel; a system-side HIDL composer would either sit unused
# or fight it for the display.

# SELinux policy lives in BoardConfig.mk (SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS);
# see sepolicy/private for the /dev/ebc rules.

# --- odm -------------------------------------------------------------------
# Built solely so /odm/etc/fstab.default can override Onyx's
# /vendor/etc/fstab.default, which is the copy vold actually reads. See odm.mk.
# Disabled with BOARD_USES_ODMIMAGE -- building odm breaks the boot, see BoardConfig.mk
# $(call inherit-product, $(DEVICE_PATH)/odm.mk)

# --- Overlays --------------------------------------------------------------
DEVICE_PACKAGE_OVERLAYS += $(DEVICE_PATH)/overlay

# --- Bring-up debugging (REMOVE bringup-debug.mk TO REVERT) -----------------
# inherit-product-if-exists, not inherit-product: deleting bringup-debug.mk is
# the whole revert, with no edit needed here.
$(call inherit-product-if-exists, $(DEVICE_PATH)/bringup-debug.mk)

# --- e-ink tuning ----------------------------------------------------------
#
# Runtime resource overlays. Both targets are prebuilt APKs whose source is not
# in this tree, so an RRO is the only way to change their resources without
# modifying or redistributing the APK itself. See docs/17.
PRODUCT_PACKAGES += \
    BlissLauncherEinkOverlay \
    FrameworkEinkOverlay

# The navigation bar does not exist AT ALL without this: config_showNavigationBar
# is false for this device, and PhoneWindowManager treats "0" here as an explicit
# override that forces the bar on. It is read once, before WindowManager starts,
# so a runtime setprop needs a framework restart and does not survive a reboot.
#
# Gesture navigation is a poor fit on e-ink regardless -- gestures imply
# animation, and animation is what costs panel refreshes.
PRODUCT_PROPERTY_OVERRIDES += \
    qemu.hw.mainkeys=0
