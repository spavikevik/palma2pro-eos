# device/onyx/Palma2_Pro_C

Device tree for the Onyx Boox Palma 2 Pro, targeting /e/OS A15 (`v4.2-a15`).

Based on LineageOS' Fairphone 4 tree (`android_device_fairphone_FP4`) — same
Qualcomm SM7225 ("lito"/bitra). The partition layout was **verified identical**
against this device's own GPT, so the sizes in `BoardConfig.mk` are measured,
not copied on faith:

```
boot      100663296     dtbo      25165824      super       6442450944
recovery  100663296     metadata  16777216      group size  6438256640
```

## Present

| Path | Source | Status |
|---|---|---|
| `BoardConfig.mk` | FP4 + this device's GPT/props | drafted, unbuilt |
| `rootdir/etc/fstab.emmc` | pulled from stock `/vendor` | verbatim |
| `prebuilt/Image` | stock `boot_b`, 60735504 bytes | ARM64 magic verified |
| `prebuilt/dtb.img` | stock `boot_b`, 407904 bytes | `d00dfeed`, 2 concatenated DTBs |

## Why a prebuilt kernel

Onyx has never released kernel source — a long-standing GPL2 violation across
the Boox line. There is no tree to build, so the stock kernel is used as-is.
This also means the EPD driver, the `sepdc`/EBC controller support and the
`onyxdsi` panel code all come along unchanged, which is what we want: those are
the parts that make the display work at all.

## Deliberately NOT here, and why

Three things that looked necessary turned out not to be. Each was checked
against the actual images rather than assumed:

| Not included | Why |
|---|---|
| `proprietary-files.txt` / `extract-files.py` | `/vendor` is not rebuilt, so no blobs need extracting. Stock `ro.product.ab_ota_partitions` is `product system system_ext vbmeta_system` — Onyx does not update vendor either. |
| `sepolicy/` | Vendor already defines the `ebc_device` type and maps `/dev/ebc` to it in `vendor_file_contexts`. Redeclaring it in system_ext policy is a compile conflict. SurfaceFlinger also does not need the node for normal refresh — the vendor composer does that work. |
| `PRODUCT_PACKAGES += mkfifo` | `/system/bin/mkfifo` is a toybox symlink already present in **both** stock and the /e/OS GSI (verified by listing each image). `mkfifo` is not a module name, so this would have failed the build. It is therefore also not an explanation for the GSI boot failure. |
| density overlay | Vendor supplies `vendor.display.lcd_density=300`. |

## Still needed

- A build. Nothing here has been compiled; expect iteration.
- Verification that `TARGET_FORCE_PREBUILT_KERNEL` + `TARGET_PREBUILT_DTB` are
  the right knobs for this /e/OS branch — these vary between LineageOS versions.
- The SurfaceFlinger question below.

## The open question: e-ink

Refresh does **not** go through `/dev/ebc` ioctls per frame. It rides on DRM
plane properties `EPDC_UPDATE_PARMS_ADDR` + `EPDC_UPDATE_CNT`, set during atomic
commit, carrying an array of a 40-byte update struct (rect, waveform_mode,
update_mode, marker, flags, temp). Full details in `docs/03-ebc-api.md`.

The split matters for this tree:

- **vendor composer** performs the update — stays, unmodified
- **SurfaceFlinger** computes and merges the regions — replaced by any port

Onyx's SurfaceFlinger hands the region list to the composer over a
vendor-extended composer AIDL whose client stub is statically linked into their
SF binary. That interface has not been recovered, so a stock AOSP SurfaceFlinger
will not drive the panel correctly.

Three options, cheapest first:

1. Build /e/OS A15 and drop in Onyx's stock `surfaceflinger` binary. Both are
   Android 15 and the vendor side is untouched, so the private interface stays
   consistent on both ends. Try this first.
2. Reverse the SF→composer binder interface and reimplement it in a patched
   AOSP SurfaceFlinger. Correct, and considerably more work.
3. Ship without EPD optimisation — boots, display behaves poorly. Compatibility
   probe only.

## Status

Nothing here has been built or flashed. Prebuilt GSIs were tried first and are
conclusively dead on this device (see `docs/findings.md`), which is what makes
this tree the path forward rather than a shortcut around it.
