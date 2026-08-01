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

## Contrast, blur and animators

```sh
settings put global animator_duration_scale 0        # ripples, spinners, overscroll
settings put secure high_text_contrast_enabled 1     # crisper glyph edges
# /system/build.prop
ro.surface_flinger.supports_background_blur=0
```

`animator_duration_scale` is easy to miss: the SettingsProvider defaults carry
only `def_window_animation_scale` and `def_window_transition_scale`, so
**animators were still running** after those defaults were shipped. Ripples,
progress spinners and overscroll glow are animators, and each frame of them is a
panel refresh.

Blur is pure cost here: e-ink has no subpixel structure, so a blurred backdrop
dithers into noise and repaints a large area to do it.

## Looking like the stock ROM

Stock Boox is flat, high contrast and close to monochrome. The nearest
equivalent without replacing the launcher is Launcher3's **themed icons**, which
render app icons as single-colour monochrome glyphs instead of the colourful
adaptive icons /e/OS ships. BlissLauncher supports them
(`pref_themed_icons_title`).

The preference is not a plain boolean. Launcher3 encodes it as a suffix on the
icon shape path in `com.android.launcher3.device.prefs.xml`:

```xml
<string name="pref_icon_shape_path">M 78.9068 ... z,no-theme</string>
```

Toggle it from the launcher's own settings (long press home -> Home settings)
rather than editing that string by hand.

Caveat worth testing before committing to it: themed icons only look right for
apps that ship a monochrome layer in their adaptive icon. Apps that do not fall
back to a generated glyph, which can look worse than the original.

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

## Runtime resource overlays: enabled is not the same as effective

Three RROs are built and installed from the device tree (`device/.../rro/`):

| overlay | target | status |
|---|---|---|
| `BlissLauncherEinkOverlay` | `foundation.e.blisslauncher` | enabled, effect unverified |
| `DeskClockStaticIconOverlay` | `com.android.deskclock` | enabled, **not effective** |
| `FrameworkEinkOverlay` | `android` | enabled, **not effective** |

All three report `[x]` in `cmd overlay list` and `STATE_ENABLED` in
`cmd overlay dump`, and all three APKs demonstrably contain the right resources
(`res/drawable-nodpi-v4/default_wallpaper.png`,
`res/mipmap-anydpi-v26/ic_launcher.xml`). The wallpaper and the clock icon are
nonetheless unchanged on the device.

So on this build **an RRO reporting enabled does not mean its resources are
being substituted**, and neither `cmd overlay dump` nor logcat says otherwise --
there is no rejection logged anywhere. Two dead ends ruled out along the way:

* not caching -- clearing the launcher's `app_icons.db` and deleting
  `wallpaper_info.xml` changed nothing
* not resource qualifiers -- `mipmap-anydpi-v26` beats every density bucket and
  the override was moved there, and the wallpaper RRO applies on top of the
  finished `framework-res` so build-time overlay ordering cannot matter

The most likely remaining explanation is `overlayable` policy: since Android 10
a target can restrict which of its resources an overlay may replace, and
`default_wallpaper` is not declared overlayable in `frameworks/base`. Confirming
that, and finding whether a signature-policy or `PRODUCT_ENFORCE_RRO` change is
needed, is unfinished work -- each attempt costs a ~45 minute build cycle, so it
wants a hypothesis before the next one, not another guess.

## What is actually applied today

| setting | how | survives |
|---|---|---|
| navigation bar | `qemu.hw.mainkeys=0` in `device.mk` | reboot (needs a full image build to reach `build.prop`; appended by hand meanwhile) |
| client composition | `system/etc/init/epdc-clientcomp.rc` | reboot |
| animations off | SettingsProvider defaults overlay | wipe |
| white wallpaper | image written to `/data/system/users/0/wallpaper`, then `wallpaper_info.xml` deleted so the colour hints are recomputed | reboot, **not** a wipe |
| light theme | `cmd uimode night no` | reboot |

## Known remaining

* The Clock icon is still a live analog clock; its second hand sweeps ~30x50 px
  once a second and each tick costs a full-panel refresh. It is the entire
  reason idle sits at ~9 refreshes per 10 s instead of 0. Per-layer damage
  (`docs/15`) makes it cheap regardless of whether the icon is ever made static.
* The white wallpaper is applied at runtime, not shipped by the build.
