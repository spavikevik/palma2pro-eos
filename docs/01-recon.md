# Recon: what we're looking for and why

Run `scripts/palma-recon.sh` on the stock device. It is entirely read-only — no root
needed for most of it, nothing is written, nothing is flashed.

```
bash scripts/palma-recon.sh > palma-recon.txt 2>&1
```

The output decides the shape of the whole project. Three questions matter.

## Q1 — Which GSI variant do we flash?

From `getprop`:

| Property | What it decides |
|---|---|
| `ro.treble.enabled` | Whether a GSI can boot at all. Should be `true` on an Android 15 launch device. |
| `ro.vndk.version` | Must be ≤ the GSI's VNDK. Expect `35` for Android 15. |
| `ro.build.system_root_image`, `ro.boot.dynamic_partitions` | Confirms dynamic partitions / `super`. |
| `ro.boot.slot_suffix` | Confirms A/B. Guides already show `boot_a`/`boot_b`, so expect `_a`. |
| `ro.product.first_api_level` | Launch API level — affects which GSI images are legal. |

Whether we need the **vndklite** variant depends on whether `/system` is read-only-verity
enforced and whether the vendor is full-VNDK. `arm64_bgN` (b=A/B, g=GApps... we want the
microG /e/OS build) — the choice is between the standard A/B image and the vndklite one.
Recon plus a first boot attempt settles it.

## Q2 — Where does e-ink refresh control live? (the important one)

This is the question the project hinges on. We're looking for the interface Onyx's
userspace uses to tell the EPD controller *how* to refresh.

**Good outcome — a kernel-exposed control surface.** Look for hits under:

- `/sys/class/graphics/fb0/` — legacy-style EPD drivers expose things like
  `epd_update_mode`, `waveform_mode`, `epd_refresh`, `temperature` as plain sysfs files.
- `/sys/class/drm/` — a modern DRM driver would expose refresh mode as a DRM property on
  the connector or plane.
- Anything matching `*eink*`, `*epd*`, `*onyx*` under `/sys`, `/proc`, `/dev`.

If refresh modes are settable by writing to a file, we can write our own controller and
task #6 is weeks of work, not months.

**Bad outcome — a proprietary binder HAL.** If `lshal` shows something like
`vendor.onyx.hardware.eink@1.0` and there's a matching `/vendor/lib64/vendor.onyx.*.so`,
but sysfs shows nothing useful, then refresh control is a closed interface driven by
patched framework code in `/system` — exactly what the GSI throws away. That means
reverse-engineering blobs.

**Also note:** anything in `/system/framework/` matching `onyx` tells us how much of the
stack is framework-side. A large `onyx-framework.jar` or similar is a bad sign for GSI —
it means the refresh logic we're losing was never in `vendor` at all.

## Q3 — What is actually phoning home?

The package list filtered for `onyx|boox|umeng|baidu|tencent|jpush|getui` gives the
telemetry surface. Useful two ways: it's the debloat target if we ever fall back to
staying on stock, and it's the list of things that must *not* reappear on /e/OS.

`umeng`, `jpush` and `getui` in particular are Chinese analytics/push SDKs — if they show
up as separate packages rather than bundled inside the Onyx apps, they're independently
removable.

## Recording findings

Put the answers in `docs/findings.md` as they come in, especially the Q2 result. The
go/no-go on the whole /e/OS plan reads off that one section.
