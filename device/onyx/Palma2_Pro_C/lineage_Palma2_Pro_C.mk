#
# Product configuration for the Onyx Boox Palma 2 Pro.
# SPDX-License-Identifier: Apache-2.0
#
# NOTE: this builds system / system_ext / product ONLY. The device keeps Onyx's
# stock Android 11 vendor image -- stock `ro.product.ab_ota_partitions` is
# "product system system_ext vbmeta_system", i.e. Onyx never updates vendor
# either. Keeping it is also what preserves the EPD display stack, since
# vendor.qti.hardware.display.composer-service is the binary that actually
# performs panel updates.
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

$(call inherit-product, device/onyx/Palma2_Pro_C/device.mk)

# Common Lineage/e-OS bits.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# E-ink panel.
TARGET_SCREEN_WIDTH := 824
TARGET_SCREEN_HEIGHT := 1648

# Device identifier. Must come after all inclusions.
PRODUCT_NAME := lineage_Palma2_Pro_C
PRODUCT_DEVICE := Palma2_Pro_C
PRODUCT_BRAND := Onyx
PRODUCT_MODEL := Palma 2 Pro
PRODUCT_MANUFACTURER := ONYX

# NO PRODUCT_BUILD_PROP_OVERRIDES.
#
# This file started from LineageOS' Fairphone 4 tree, which carries the old idiom
#
#     PRODUCT_BUILD_PROP_OVERRIDES += TARGET_DEVICE=<codename> PRODUCT_NAME=<codename>
#
# to make ro.product.name report the codename instead of "lineage_<codename>".
# That idiom is dead in A15. build/soong/scripts/gen_build_prop.py validates each
# key against the soong product config:
#
#     if key not in config:
#         print(f"Key \"{key}\" isn't a valid prop override")
#
# and that config is keyed in CamelCase (DeviceProduct, DefaultAppCertificate,
# SanitizeDevice ...), not with make variable names. So BOTH keys fail, one build
# at a time:
#     Key "TARGET_DEVICE" isn't a valid prop override
#     Key "PRODUCT_NAME" isn't a valid prop override
#
# Dropped entirely rather than guessing at CamelCase equivalents: the effect is
# purely cosmetic (ro.product.name reads lineage_Palma2_Pro_C), and each guess
# costs a ~35 minute regeneration. Revisit only if something actually depends on
# the codename appearing there.
