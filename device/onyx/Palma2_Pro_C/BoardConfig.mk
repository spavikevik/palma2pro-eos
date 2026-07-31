#
# Board configuration for the Onyx Boox Palma 2 Pro (Palma2_Pro_C).
#
# Derived from LineageOS' Fairphone 4 tree (android_device_fairphone_FP4).
# Both are Qualcomm SM7225 ("lito"/bitra) and -- verified against this device's
# own GPT -- share an identical partition layout, so the sizes below are not
# guesses:
#
#     boot      100663296     dtbo      25165824      super      6442450944
#     recovery  100663296     metadata  16777216      group      6438256640
#
# WHERE THIS DEVICE DIFFERS FROM FP4
#
#   * No kernel source. Onyx has never published theirs (long-standing GPL2
#     violation), so this tree uses a PREBUILT kernel extracted from the stock
#     boot image rather than building from source.
#   * E-ink panel, 824x1648, driven by an Onyx EPD controller behind the
#     Qualcomm display pipeline. See docs/03-ebc-api.md -- refresh is delivered
#     through the DRM plane properties EPDC_UPDATE_PARMS_ADDR / EPDC_UPDATE_CNT
#     during atomic commit, and the vendor composer performs it.
#   * fstab uses emmc_optimized where FP4 uses inlinecrypt_optimized, despite
#     this device being UFS. That is Onyx's own configuration; keep it, since
#     the vendor and kernel are built around it.
#

DEVICE_PATH := device/onyx/Palma2_Pro_C

# --- Platform --------------------------------------------------------------
TARGET_BOARD_PLATFORM := lito
TARGET_BOOTLOADER_BOARD_NAME := lito

TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
# SM7225 is 2x Cortex-A77 + 6x Cortex-A55 (marketed as Kryo 570). Soong has no
# kryo570/A77 variant -- supported list is cortex-a53/55/72/73/75/76, kryo,
# kryo385, exynos-m1/m2, oryon. cortex-a76 is the closest and is what LineageOS'
# Fairphone 4 tree uses for this exact SoC.
TARGET_CPU_VARIANT := cortex-a76
TARGET_CPU_VARIANT_RUNTIME := cortex-a76

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := cortex-a76
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a76

# Device shipped as API 30 (Android 11 vendor) even though the stock system is
# Android 15 qssi. The vendor interface is frozen at 30.
BOARD_SHIPPING_API_LEVEL := 30
# BOARD_API_LEVEL is derived by the build system (board_config.mk errors if set
# manually) -- do not assign it.

# --- Kernel (PREBUILT -- no source exists) ---------------------------------
# Extracted from the stock boot image (boot_b).
#
# vendor/lineage/build/tasks/kernel.mk: with no kernel source present, setting
# TARGET_PREBUILT_KERNEL makes it take the FULL_KERNEL_BUILD := false path and
# use the binary directly. It emits a "prebuilt kernel is deprecated" warning,
# which is expected and harmless here -- Onyx publishes no kernel source, so
# there is nothing to build from.
#
# Deliberately NOT setting TARGET_FORCE_PREBUILT_KERNEL: per kernel.mk that flag
# only means "use the prebuilt EVEN IF kernel sources are present", and it hard
# errors on RELEASE/NIGHTLY/SNAPSHOT/EXPERIMENTAL build types. With no sources
# it is both unnecessary and a liability.
TARGET_NO_KERNEL := false
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/Image

# DTB: the real variable is BOARD_PREBUILT_DTBIMAGE_DIR and it expects a
# DIRECTORY of .dtb files, not a single image. (TARGET_PREBUILT_DTB does not
# exist -- zero references in build/make or vendor/lineage.) The stock boot
# image's DTB region holds two concatenated device trees; the bootloader picks
# by board id.
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

# --- Kernel cmdline (BRING-UP: permissive) ---------------------------------
# Reproduced BYTE-EXACTLY from the stock boot_b header (364 chars), then
# `androidboot.selinux=permissive` appended. Dropping any of the stock arguments
# would very likely mean no boot -- console, androidboot.hardware, the vfb video
# line and the usbcontroller are all load-bearing.
#
# Permissive is here so the bring-up log service can write to the raw logdump
# partition without shipping sepolicy for a throwaway debug domain. Our build is
# userdebug, so init honours the flag (ALLOW_PERMISSIVE_SELINUX is compiled in
# only for userdebug/eng).
#
# REMOVE THIS BLOCK once the port boots and logging is no longer needed.
BOARD_KERNEL_CMDLINE := console=ttyMSM0,115200,n8 earlycon=msm_geni_serial,0x888000 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 cgroup.memory=nokmem,nosocket loop.max_part=7 buildvariant=user androidboot.selinux=permissive

BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_INCLUDE_DTB_IN_BOOTIMG := true

# DTBO: prebuilt, for the same reason as the kernel.
#
# BOARD_KERNEL_SEPARATED_DTBO was set here initially and broke the build:
#     FAILED: ninja: '.../obj/DTBO_OBJ/arch/arm64/boot/dtbo.img',
#             needed by '.../dtbo.img', missing and no known rule to make it
# That flag means "assemble dtbo.img from the kernel's DTBO objects", which only
# exists when the kernel is built from source. With a prebuilt kernel there is no
# DTBO_OBJ and no rule to make one. BOARD_PREBUILT_DTBOIMAGE is the right knob --
# build/make/core/Makefile:1098 simply copies it.
#
# WHICH SLOT'S DTBO: dtbo_b, matching the kernel. The two slots carry different
# firmware versions on this device -- boot_a's kernel is 56,541,200 bytes and
# boot_b's is 60,735,504 -- and prebuilt/Image is boot_b's. Pairing a kernel with
# the other slot's overlays risks exactly the panel/board mismatch this device can
# least afford. dtbo_a is 213391 bytes vs dtbo_b's 213484, i.e. genuinely
# different, not padding.
# NOTE: this is the raw DTBO image (213,484 bytes -- exactly total_size from its
# own header), NOT the 25 MiB partition dump it came from. The dump is padded to
# the full partition and carries stock's own AVB footer at 0x35000, so handing it
# over unmodified fails:
#     avbtool: Adding hash_footer failed: Image size of 25165824 exceeds maximum
#     image size of 25096192 in order to fit in a partition size of 25165824.
# The build adds its own hash footer, and needs the ~68 KiB of headroom.
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/dtbo.img
BOARD_BOOT_HEADER_VERSION := 2
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)

# --- Partitions (verified against this device's GPT) -----------------------
BOARD_FLASH_BLOCK_SIZE := 262144
BOARD_BOOTIMAGE_PARTITION_SIZE := 100663296
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 100663296
BOARD_DTBOIMG_PARTITION_SIZE := 25165824
# BOARD_METADATAIMAGE_PARTITION_SIZE is unused by the build system (FP4 sets
# it too, equally pointlessly). Kept as documentation of the real size.
# BOARD_METADATAIMAGE_PARTITION_SIZE := 16777216
BOARD_USES_METADATA_PARTITION := true

# --- Dynamic partitions / Virtual A/B --------------------------------------
BOARD_SUPER_PARTITION_SIZE := 6442450944
BOARD_SUPER_PARTITION_GROUPS := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := odm product system system_ext vendor
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE := 6438256640

AB_OTA_UPDATER := true
# Stock ro.product.ab_ota_partitions lists only these -- vendor and odm are NOT
# OTA-updated on this device.
AB_OTA_PARTITIONS += product system system_ext vbmeta_system

BOARD_USES_RECOVERY_AS_BOOT := false

# The device IS a Virtual A/B device (lpdump reports the `virtual_ab_device`
# header flag; compression is not enabled -- ro.virtual_ab.compression.enabled
# is unset on stock). But PRODUCT_VIRTUAL_AB_OTA is a readonly PRODUCT_ variable
# set by inheriting build/make/target/product/virtual_ab_ota/launch.mk from a
# PRODUCT makefile -- it cannot be assigned in BoardConfig.
#
# Not inherited here on purpose: we flash system images directly over EDL rather
# than generating OTA packages, and the stock boot/vendor already implement
# Virtual A/B. Note FP4 does not inherit it either. Revisit if OTA packages are
# ever wanted.

# --- Filesystems -----------------------------------------------------------
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Each TARGET_COPY_OUT_<part> needs a matching filesystem type, or
# board_config.mk errors. ext4 confirmed for system and vendor by reading the
# stock images directly with debugfs; the rest of the logical partitions follow
# the same convention.
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_ODM := odm

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4

# DISABLED -- building odm breaks the boot. See below before re-enabling.
#
# The intent was sound: /odm/etc/fstab.default overrides /vendor/etc/fstab.default,
# and vold reads the vendor copy when mounting /data. Onyx's has `dirsync`, which
# this A15 fs_mgr passes through to f2fs, which rejects it. No /system path
# precedes /vendor in fs_mgr's search order, so odm is the only clean override
# point on a port that does not rebuild vendor.
#
# But flashing our odm.img (995,328 B, with Onyx's payload preserved -- 42
# vendor.audio.feature.* props, the vintf manifest, media_profiles) left the
# device unable to boot: no adb, and `rawdump` still held the PREVIOUS boot's
# kernel log, meaning init never got as far as starting system services. Earlier
# than any other failure this port has hit, and earlier than our on-device
# logger can capture.
#
# Restoring the stock odm_b (firmware/stock-extract/odm_b-stock.img) with the
# same new system.img boots fine, so odm is conclusively the cause.
#
# Untested suspicions, in order:
#   * our build generates fresh odm_file_contexts / odm_service_contexts rather
#     than carrying Onyx's precompiled_sepolicy; the log shows ours ARE loaded,
#     and a mislabel here would bite vendor init immediately;
#   * shipping /odm/etc/fstab.default makes fs_mgr use OUR fstab for every
#     first-stage mount (system, vendor, product, odm), not just /data;
#   * ro.odm.build.* is regenerated, so any vendor code comparing odm and vendor
#     fingerprints now sees a mismatch.
#
# Diagnosing it needs boot logging earlier than we currently have. Until then the
# `dirsync` fix stays as the documented device-local vendor patch
# (docs/09-vendor-fstab-patch.md), which works.
# BOARD_USES_ODMIMAGE := true

# /data is f2fs on this device (see rootdir/etc/fstab.emmc).
TARGET_USERIMAGES_USE_F2FS := true

# --- AVB -------------------------------------------------------------------
# Same pattern as the FP4 tree: use a custom key if one is supplied via the
# environment, otherwise fall back to AOSP's in-tree test key. A chained AVB
# partition (vbmeta_system) MUST have a key or soong fails with
# "No key found for chained avb partition".
#
# The test key is fine here: we flash with verification disabled anyway
# (vbmeta patched to flags 0x3), and the bootloader is unlocked.
BOARD_AVB_ENABLE := true

ifneq (,$(AVB_CUSTOM_KEY_PATH))
BOARD_AVB_ALGORITHM := $(AVB_CUSTOM_ALGORITHM)
BOARD_AVB_KEY_PATH := $(AVB_CUSTOM_KEY_PATH)
else
AVB_CUSTOM_ALGORITHM := SHA256_RSA2048
AVB_CUSTOM_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
endif

# flags 3 = HASHTREE_DISABLED | VERIFICATION_DISABLED, matching how we flash.
ifneq ($(WITH_AVB),true)
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
endif

# Stock's vbmeta_system covers system + system_ext (product is separate on this
# device -- see ro.product.ab_ota_partitions).
BOARD_AVB_VBMETA_SYSTEM := system system_ext
BOARD_AVB_VBMETA_SYSTEM_ALGORITHM := $(AVB_CUSTOM_ALGORITHM)
BOARD_AVB_VBMETA_SYSTEM_KEY_PATH := $(AVB_CUSTOM_KEY_PATH)
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX_LOCATION := 2

# --- Vendor ----------------------------------------------------------------
# Vendor is NOT rebuilt: this device keeps Onyx's Android 11 vendor image, which
# carries the EPD composer (vendor.qti.hardware.display.composer-service) that
# actually drives the panel.
# No sepolicy is shipped here. Vendor already defines the ebc_device type and
# maps /dev/ebc to it in vendor_file_contexts, and vendor is not rebuilt --
# redeclaring the type in system_ext policy is a compile conflict, and the
# mapping would be a duplicate. SurfaceFlinger does not need /dev/ebc for
# normal refresh either: the vendor composer performs EPD updates via DRM plane
# properties. Revisit only if a replacement refresh controller needs the node.

# --- VINTF -----------------------------------------------------------------
# Framework compatibility matrix contributed by the device: taken verbatim from
# stock /system/etc/vintf/compatibility_matrix.device.xml (208 HAL entries,
# mostly QTI). Supplying it makes our built system declare the same vendor
# requirements the stock system does.
#
# NOTE: this is NOT why prebuilt GSIs failed to boot. Checked directly -- the
# stock and /e/OS GSI framework manifests provide an identical set of HALs, and
# the vendor's own compatibility_matrix.xml requires only 7 framework HALs which
# both satisfy equally. That hypothesis was tested and rejected.
#
# The vendor manifest is NOT supplied here (no DEVICE_MANIFEST_FILE): vendor is
# not rebuilt, so the device keeps its own.
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE += $(DEVICE_PATH)/compatibility_matrix.xml

# --- Recovery --------------------------------------------------------------
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/rootdir/etc/fstab.emmc

# --- Display ---------------------------------------------------------------
# E-ink, 824x1648. Density is a starting guess and should be checked against
# stock (ro.sf.lcd_density).
TARGET_SCREEN_WIDTH := 824
TARGET_SCREEN_HEIGHT := 1648
