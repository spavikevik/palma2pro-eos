# E-ink device tuning

Settings that make the device usable rather than merely working. Each one was
arrived at by measurement; the reasoning is worth keeping because most of them
are counter-intuitive on a normal display and obvious only here.

The rule underneath all of them: **refresh cost is proportional to area, not to
how much of that area changed.** Anything that repaints the panel for a small
visual difference is expensive.

---

## Animations off

```sh
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
```

Measured on the launcher, idle, no input:

| | EPD updates / 10 s |
|---|---|
| animations on | 10-13 |
| animations off | **0** (and zero changed pixels between frames 2 s apart) |

An animation is a sequence of small visual differences, and each one currently
costs a whole-panel refresh. This is the single largest win available.

`config_disableTransitionAnimation` is already true in the device overlay; these
three settings cover what it does not. They are `global` settings and survive a
reboot, but they belong in the product configuration.

## Wallpaper: white, and not disabled

`config_enableWallpaperService` is **true** in the device overlay, with a white
`drawable-nodpi/default_wallpaper.png`.

It was originally false here, on the reasoning "a static image forces
full-screen refreshes". That was wrong. A static wallpaper is drawn once like
any other layer and costs nothing to hold on screen; only *live* wallpapers
refresh continuously. What disabling it actually produced was
`SystemServer: Wallpaper service disabled by config`, no wallpaper settable at
all, and a **black** background -- the worst case here, because black is the
most ink and the least contrast.

Upstream ships `default_wallpaper.png` only for `sw600dp`/`sw720dp`, so on this
device no variant matched, `BuiltInWallpaperAsset` got a null drawable and
`com.android.wallpaper` crashed on every launch. A `drawable-nodpi` variant
fixes that without shifting resource IDs, since the resource name already exists
in the package.

/e/OS ships its own default wallpaper, which outranks ours, so the shipped
default is still their colourful one. To force white on a running device:

```sh
adb push white.png /data/local/tmp/white.png
adb shell 'cp /data/local/tmp/white.png /data/system/users/0/wallpaper
           chown system:system /data/system/users/0/wallpaper
           chmod 600 /data/system/users/0/wallpaper
           rm -f /data/system/users/0/wallpaper_info.xml'      # <- see below
adb reboot
```

**Deleting `wallpaper_info.xml` is the part that matters.** Writing the image
file directly bypasses `WallpaperManager`, so the cached `colorHints` still
describe the *previous* wallpaper. SystemUI and the launcher pick text colour
from those hints, so a white background arrives with white text on it --
invisible labels and an invisible status bar. Removing the file makes the
service recompute the hints from the actual image and everything flips to
dark-on-light.

This lives in `/data`, so it survives reboots but not a wipe. Shipping it
properly means outranking /e/OS's default in the build.

## Light theme

```sh
cmd uimode night no
```

Dark theme means the panel is mostly black: maximum ink, minimum contrast, and
the opposite of what e-ink is good at.

## Navigation bar

The bar does not exist at all unless:

```
qemu.hw.mainkeys=0
```

is set before WindowManager starts (`config_showNavigationBar` is false for this
device). Belongs in a build.prop; a runtime `setprop` needs a framework restart
and does not survive a reboot.

Note that gesture navigation is a poor fit here regardless: gestures imply
animation, and animation is what costs refreshes.

## Client composition is mandatory

```sh
service call SurfaceFlinger 1008 i32 1
```

Not a preference. `__sde_plane_atomic_update_epdc` accepts only planes exactly
the size of the panel, so any layer the composer promotes to its own hardware
plane -- nav bar (53 px), status bar (90 px), IME, popups -- is dropped and
never reaches the e-ink buffer. It is drawn, it is clickable, and it is
invisible. `system/etc/init/epdc-clientcomp.rc` re-applies this on every
SurfaceFlinger restart. See `docs/11`.

## Refresh policy

Live, no restart (`docs/11` for the full list):

```sh
setprop persist.epdcshim.upd 0          # 1 flashes the whole panel on every change
setprop persist.epdcshim.wf 2           # 2=GC16 quality, 8=PART_GL16, 12=A2 fast
setprop persist.epdcshim.interval 120   # ms floor between refreshes
setprop persist.epdcshim.fullevery 12   # periodic full-flash clean, clears ghosting
```

`upd` is the difference between unusable and pleasant.

## Known remaining

* The Clock icon is drawn as a live analog clock; its second hand sweeps ~30x50
  px once a second and currently costs a full-panel refresh. Fixing this
  properly is the per-layer damage task (`docs/15`).
* /e/OS's colourful default wallpaper still ships; white is applied at runtime.
