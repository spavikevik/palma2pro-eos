#
# odm partition for the Onyx Boox Palma 2 Pro.
# SPDX-License-Identifier: Apache-2.0
#
# WHY WE BUILD odm AT ALL
# -----------------------
# Exactly one reason: fs_mgr resolves the fstab in this order --
#
#     /odm/etc/fstab.<suffix>      <- first
#     /vendor/etc/fstab.<suffix>
#     /odm/fstab.  /vendor/fstab.  /first_stage_ramdisk/...  /fstab.<suffix>
#
# and vold (second stage) is what mounts /data. Onyx's /vendor/etc/fstab.default
# carries `dirsync`, which this A15 fs_mgr does not consume, so it reaches f2fs
# as filesystem data and is rejected:
#
#     F2FS-fs (dm-39): Unrecognized mount option "dirsync" or missing value
#     vold: Cannot mount filesystem on /dev/block/mapper/userdata at /data
#
# /data never mounts and the device offers a factory reset. Nothing under
# /system can override that -- no /system path appears before /vendor in the
# search order. An odm copy is the only clean override point, since we do not
# build vendor. See docs/09-vendor-fstab-patch.md for the device-local 7-byte
# patch this replaces.
#
# EVERYTHING ELSE HERE IS ONYX'S, PRESERVED
# -----------------------------------------
# Building odm replaces Onyx's odm wholesale, so its payload has to be carried
# forward or things break quietly:
#
#   * 42 vendor.audio.feature.* properties, read by the vendor audio HAL.
#     Losing these breaks audio in ways that do not announce themselves.
#   * etc/vintf/manifest.xml -- declares the DRM/wfdhdcp, ANT, DPM, BT audio,
#     btconfigstore, data.latency, FM and wifidisplay HALs.
#   * etc/media_profiles_V1_0.xml
#
# NOT carried forward: etc/selinux/precompiled_sepolicy and its three .sha256
# pairing files. Those only let init skip compiling policy at boot, and they are
# keyed to the hashes of the plat/product/system_ext policy they shipped with.
# Ours differ, so init would recompile regardless -- shipping them would be
# dead weight, not a saving.
#
# Extracted from the stock odm_b image with debugfs; see docs/10-odm.md.
#

DEVICE_PATH := device/onyx/Palma2_Pro_C

PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/rootdir/etc/fstab.default:$(TARGET_COPY_OUT_ODM)/etc/fstab.default \
    $(DEVICE_PATH)/odm/etc/media_profiles_V1_0.xml:$(TARGET_COPY_OUT_ODM)/etc/media_profiles_V1_0.xml

# The odm VINTF manifest must NOT go through PRODUCT_COPY_FILES -- the build
# rejects that outright:
#     error: VINTF metadata found in PRODUCT_COPY_FILES: .../odm/etc/vintf/manifest.xml,
#            use ODM_MANIFEST_FILES / vintf_fragments instead!
# ODM_MANIFEST_FILES is the supported path; the build assembles and validates it
# rather than copying it blindly.
ODM_MANIFEST_FILES += $(DEVICE_PATH)/odm/etc/vintf/manifest.xml

# Verbatim from stock odm/etc/build.prop.
PRODUCT_ODM_PROPERTIES += \
    vendor.audio.feature.a2dp_offload.enable=true \
    vendor.audio.feature.afe_proxy.enable=true \
    vendor.audio.feature.anc_headset.enable=true \
    vendor.audio.feature.battery_listener.enable=true \
    vendor.audio.feature.compr_cap.enable=false \
    vendor.audio.feature.compress_in.enable=true \
    vendor.audio.feature.compress_meta_data.enable=true \
    vendor.audio.feature.compr_voip.enable=false \
    vendor.audio.feature.concurrent_capture.enable=true \
    vendor.audio.feature.custom_stereo.enable=true \
    vendor.audio.feature.display_port.enable=true \
    vendor.audio.feature.dsm_feedback.enable=false \
    vendor.audio.feature.dynamic_ecns.enable=true \
    vendor.audio.feature.ext_hw_plugin.enable=false \
    vendor.audio.feature.external_dsp.enable=false \
    vendor.audio.feature.external_speaker.enable=false \
    vendor.audio.feature.external_speaker_tfa.enable=false \
    vendor.audio.feature.fluence.enable=true \
    vendor.audio.feature.fm.enable=true \
    vendor.audio.feature.hdmi_edid.enable=true \
    vendor.audio.feature.hdmi_passthrough.enable=true \
    vendor.audio.feature.hfp.enable=true \
    vendor.audio.feature.hifi_audio.enable=false \
    vendor.audio.feature.hwdep_cal.enable=false \
    vendor.audio.feature.incall_music.enable=true \
    vendor.audio.feature.multi_voice_session.enable=true \
    vendor.audio.feature.keep_alive.enable=true \
    vendor.audio.feature.kpi_optimize.enable=true \
    vendor.audio.feature.maxx_audio.enable=false \
    vendor.audio.feature.ras.enable=true \
    vendor.audio.feature.record_play_concurency.enable=false \
    vendor.audio.feature.src_trkn.enable=true \
    vendor.audio.feature.spkr_prot.enable=true \
    vendor.audio.feature.ssrec.enable=true \
    vendor.audio.feature.usb_offload.enable=true \
    vendor.audio.feature.usb_offload_burst_mode.enable=true \
    vendor.audio.feature.usb_offload_sidetone_volume.enable=false \
    vendor.audio.feature.deepbuffer_as_primary.enable=false \
    vendor.audio.feature.vbat.enable=true \
    vendor.audio.feature.wsa.enable=false \
    vendor.audio.feature.audiozoom.enable=false \
    vendor.audio.feature.snd_mon.enable=true \
    ro.vendor.qti.va_odm.support=1
