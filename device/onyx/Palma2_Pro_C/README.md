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
