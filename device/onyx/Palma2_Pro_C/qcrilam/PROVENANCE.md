# QcRilAm — provenance

Third-party source copied into this repository. Recorded here rather than
inferred later.

| | |
|---|---|
| **upstream** | https://github.com/sonyxperiadev/QcRilAm |
| **commit** | `ef51ec65f5609e0fe9180ec3d2d054b72c0b8bee` (2020-05-27) |
| **licence** | Apache-2.0 |
| **copyright** | The Android Open Source Project, 2018–2020 |
| **Kotlin rewrite** | Pavel Dubrova `<pashadubrova@gmail.com>` |

The `.hal` interface definitions originate with
[phhusson/treble_experimentations](https://github.com/phhusson/treble_experimentations/blob/master/interfaces/vendor/qti/hardware/radio/am/1.0/IQcRilAudio.hal),
which reconstructed them for GSI use. They describe Qualcomm's interface; the
files themselves are not Qualcomm's, which is why this can be vendored at all.

Apache-2.0 is compatible with this project's Apache-2.0 OR MIT, and unlike the
`ims.apk` extracted for signalling, **this is redistributable** — it can ship in
a published image.

That matters because there is a proprietary alternative doing the same job.
Stock Onyx carries this client inside `QtiTelephonyService.apk`
(`com.qualcomm.qti.telephonyservice`, classes `QcRilAudioHidl` / `QcRilAudioAidl`),
and Fairphone 4 builds simply extract that blob. Taking it would have worked and
would have been one `adb push`. It was not taken, because a published image
containing it could not be distributed.

## What was changed

Source files are byte-identical to upstream. Only `Android.bp` differs, in two
places, both explained inline in that file:

1. `subdirs` dropped — Soong removed the property.
2. `proprietary: true` → `system_ext_specific: true` — upstream installs to
   `/vendor/app`, and we never flash vendor on this device.

## How it was verified against this device before being trusted

The interface was independently derived from `libril-qc-hal-qmi.so` and
`vendor.qti.hardware.radio.am@1.0.so` on the running device — method names from
the HIDL transport symbols, direction from qcrild's own log strings — and then
compared against upstream's `.hal`. They agree exactly, including the order of
`setCallback` and `setError`.

Separately, the effect was confirmed on a live call by injecting
`vsid=0x11C05000;call_state=2` by hand: the voice session started and audio
worked in both directions. See `docs/23-volte.md`.
