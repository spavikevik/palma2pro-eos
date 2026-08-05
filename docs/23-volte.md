# VoLTE on a device that was never meant to make calls

Signalling works: calls connect, both ways. There is no audio in either
direction. This is the record of why.

## What Onyx shipped

The Palma 2 Pro is a reader with a modem. It does data and SMS. The stock
firmware has no dialer, no ImsService, and — the subject of this document — no
bridge between the radio and the audio HAL.

What it *does* have is a complete vendor radio stack: `qcrild`,
`vendor.qti.hardware.radio.ims@1.0` through `1.7`, the QMI daemons, and a modem
that advertises every service a phone needs. `qrtr-lookup` on the running
device:

    9   Voice service
    33  IMS application service
    18  IMS settings service
    29  Circuit switched videotelephony service

So the modem is a phone modem. The gap is above it.

## Getting signalling up

Covered by `scripts/install-ims.sh` and its header: an ImsService from an /e/OS
Fairphone 4 build (same SoC, same Android version, `org.codeaurora.ims` built
from CAF source), plus a privapp allowlist, 20 framework jars, the real native
libraries rather than the symlinks, and
`android.hardware.telephony.calling` — Android 14 gates voice calling on that
sub-feature, and without it the framework will not hold `MODE_IN_CALL`.

Six things, each hiding the next. After all six, calls connect.

## Where the audio stops

On a QTI stack the audio HAL does not learn about calls from the framework. It
learns from `qcrild`, over a HIDL interface:

    vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1

`qcrild` is the **server**. Its own strings say so:

    QcRilAudioImpl::setCallback
    QcRilAudioImpl::setParameters
    registerService: starting QcRilAudioImpl as '%s'. Status: %d
    mQcRilAudioCallback == NULL

The interface is two halves. The stub's transport symbols give the exact shape:

    IQcRilAudio          setCallback, setError
    IQcRilAudioCallback  getParameters, setParameters

A client implements `IQcRilAudioCallback` and registers it via
`IQcRilAudio::setCallback`. When a call goes active, `qcrild` invokes the
callback with

    vsid=0x10C02000;call_state=2

which travels `adev_set_parameters` → `voice_set_parameters` →
`voice_extn_set_parameters` → `update_call_states` → `start_call`, and only
there does the HAL open the `VoiceMMode` PCMs.

**There is no such client on this device.** Scanning `/system`, `/system_ext`,
`/product`, `/vendor` and `/apex` for `IQcRilAudio` returns exactly two files:

    /vendor/lib64/libril-qc-hal-qmi.so                    qcrild's own server
    /vendor/lib64/vendor.qti.hardware.radio.am@1.0.so     the HIDL stub

Stock Onyx firmware is the same. Its `/system` mentions the interface once, in
`/system/etc/vintf/compatibility_matrix.device.xml` — the framework *declares*
it requires the HAL — and ships nothing that ever binds to it. So this was not
lost in the port. The bridge was never built, which is consistent with a device
that was never meant to place calls.

Every voice session therefore stays `INACTIVE` for the whole call, the voice
PCMs are never opened, and there is no audio.

## Everything else checks out

Worth stating, because each of these was a candidate and each is now excluded:

- **Voice PCM front-ends exist.** `/proc/asound/pcm` lists `VoiceMMode1`,
  `VoiceMMode2`, `VoIP`.
- **Mixer paths exist**, including two Onyx additions, `onyx-voice-speaker` and
  `onyx-voice-speaker-stereo`.
- **The audio HAL has the whole voice path compiled in**: `voice_start_call`,
  `voice_extn_start_call`, `voice_extn_set_parameters`, `update_call_states`.
- **Telephony routing is in the audio policy**: `Telephony Tx` / `Telephony Rx`
  device ports and the `voice_rx` / `voice_tx` mix ports.
- **ADSP is healthy.** `apr_adsp_up: Q6 is Up`, `audio_pd` up.

## Proving it

`IAudioFlingerService::setParameters` is reachable from a root shell, so the
notification can be injected by hand. Transaction 20 is
`TRANSACTION_setParameters = FIRST_CALL_TRANSACTION + 19`, read from the
generated `BnAudioFlingerService.h` in the tree rather than counted off the
AIDL:

    service call media.audio_flinger 20 i32 0 s16 "vsid=0x10C02000;call_state=2"

Injected with no call in progress, the HAL logs:

    adev_set_parameters: enter: call_state=2;vsid=0x10C02000
    voice_extn: update_call_states is_call_active:0 in_call:0, mode:3

The parameters arrive and `0x10C02000` is accepted — an unknown vsid logs
`invalid vsid` instead. But nothing starts, because `update_call_states` only
proceeds when a session is already active **or** `adev->voice.in_call` is set,
and that flag is set by `voice_start_call`, which the HAL reaches only when the
framework opens a voice output stream. Forcing `AUDIO_MODE_IN_CALL` by hand is
not enough; the voice PCMs stay `closed`.

So the decisive experiment requires a real call. `scripts/volte-audio-probe.sh`
waits for the framework to enter `IN_CALL` and injects then.

**This step has not been run yet.** Until it has, the diagnosis above rests on
the absence of a client plus the HAL's control flow, which is strong but is not
the same as having seen audio appear.

## The fix, if the probe confirms it

A small daemon that does what the missing QTI component does: get
`IQcRilAudio/slot1`, register an `IQcRilAudioCallback`, and forward
`setParameters` / `getParameters` to the audio HAL.

The obstacle is the interface definition. `IQcRilAudio.hal` is not in our tree.
Options, best first:

1. Add the CodeLinaro `vendor/qcom/opensource/interfaces` repo to the manifest.
   BSD-3-Clause, and the provenance is clean and citable.
2. Reconstruct the four-line `.hal` from the stub's symbols. The signatures are
   known exactly. Method order is not — but HIDL assigns transaction codes in
   declaration order, and with two methods of different signatures a wrong guess
   fails the transaction rather than doing damage, so it is empirically
   resolvable.

Prefer 1. Reconstructing an interface is a licensing question as much as a
technical one, and the repo that legitimately publishes it is available.

Do not build any of this before the probe reports. The point of the probe is to
find out whether the notification is the *only* missing piece.

## Wrong turns, recorded

Five root causes were asserted before this one and each collapsed:

1. `qcrild` lacks IMS — a 16KB stub was mistaken for the implementation.
2. The service is not registered — `lshal` printing `N/A` for the Server and
   Clients columns is not evidence of anything; it means `lshal` could not read
   the process, not that nobody is there.
3. SELinux — the build is permissive.
4. The Treble matrix does not list the HAL — it does.
5. "The HAL is not available" — a startup race, not a missing HAL.

The sixth, "it is modem side, and there is no Android-side lever", was written
into issue #20. It is wrong in its conclusion: the modem advertises the Voice
service, and the missing piece is an Android-side component that was never
built. The reasoning behind it — that the VSIDs never leave `INACTIVE` — was
correct, and is what led here.
