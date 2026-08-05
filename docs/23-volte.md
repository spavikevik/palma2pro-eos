# VoLTE on a device that was never meant to make calls

Calls connect and carry audio in both directions. Getting there took two
separate fixes and a diagnosis that was wrong twice; this is the record.

## What Onyx shipped

The Palma 2 Pro is a reader with a modem. It does data and SMS. The stock
firmware has no dialer and no ImsService, so it cannot place a call — but its
lower layers are a phone's, and it *does* carry the radio-to-audio bridge that
is the subject of most of this document. Our port dropped that bridge; stock
never lacked it.

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

**This route is probably not the best one, and the reason it was taken is a
mistake.** Onyx ships its own `org.codeaurora.ims` — the same package — at
`/system_ext/priv-app/ims/ims.apk`, 1754379 bytes, built for this device's own
vendor stack. Stock also carries `QtiDialer`, `QtiTelephony` and
`QualcommVoiceActivation` beside it. The original search for it covered stock
`system` and `product` and never looked in `system_ext`, which is where it is.

Half of the six problems above come from mixing two devices' framework jars —
the `ims-ext-common.jar` living in `product` on FP4, the rewritten library XMLs,
the symlinked native libs. Using Onyx's own APK and jars should avoid all of
that. Untried.

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

    vsid=0x11C05000;call_type=LTE;call_state=2

which travels `adev_set_parameters` → `voice_set_parameters` →
`voice_extn_set_parameters` → `update_call_states` → `start_call`, and only
there does the HAL open the `VoiceMMode` PCMs.

**There is no such client on our build.** Scanning `/system`, `/system_ext`,
`/product`, `/vendor` and `/apex` for `IQcRilAudio` returns exactly two files:

    /vendor/lib64/libril-qc-hal-qmi.so                    qcrild's own server
    /vendor/lib64/vendor.qti.hardware.radio.am@1.0.so     the HIDL stub

**Stock Onyx is not the same, and this document said for some hours that it
was.** [C] Stock ships
`/system_ext/app/QtiTelephonyService/QtiTelephonyService.apk`, package
`com.qualcomm.qti.telephonyservice`, whose dex contains

    com/qualcomm/qti/telephonyservice/QcRilAudioHidl
    com/qualcomm/qti/telephonyservice/QcRilAudioAidl
    com/qualcomm/qti/telephonyservice/BootReceiver

— the client, in both HIDL and stable-AIDL flavours, started at boot. So this is
an ordinary **missing blob**, dropped when the port replaced `system_ext` with
/e/OS's. Not something Onyx never had.

### How the wrong version survived

The scan was `grep IQcRilAudio` over every file in every partition, on the
device and in the stock images. It found nothing outside `/vendor`, and that was
read as evidence of absence.

It was evidence of nothing. **`classes.dex` is deflate-compressed inside an
APK**, so no string in any Java class is greppable from the outside. The scan
could not have found a client written in Java — which every implementation of
this thing happens to be.

The downstream reasoning was sound and the fix is unaffected, but "I searched
and found nothing" was worth exactly nothing here. Worth keeping for the shape
of it: a negative result from a tool that cannot see the thing it is looking for
is indistinguishable from a real absence, and reads far more convincingly.

### What other builds do

From a GitHub code search for `IQcRilAudioCallback`, plus the blob lists:

| build | where the client comes from |
|---|---|
| stock QTI / QSSI, including stock Onyx | `QtiTelephonyService.apk`, `com.qualcomm.qti.telephonyservice` — proprietary |
| LineageOS / /e/OS **Fairphone 4** | the same blob — `proprietary-files.txt` line 815, `system_ext/app/QtiTelephonyService/QtiTelephonyService.apk` |
| Sony devices, OmniROM | [`QcRilAm`](https://github.com/sonyxperiadev/QcRilAm), Apache-2.0 reimplementation |
| phh GSIs, some device trees | `QtiAudio`, `me.phh.qti.audio.Service` |
| Sailfish / Droidian | [`audiosystem-passthrough`](https://github.com/mer-hybris/audiosystem-passthrough), native C |

The server side is Qualcomm's `qcril_qmi_audio_service.cc` in `qcril-hal`, which
matches the `QcRilAudioImpl` strings in our `libril-qc-hal-qmi.so`.

So FP4 uses the blob. The earlier question here — "how does FP4 manage without
one" — was an artefact of the same bad scan and is withdrawn.

Without a client, every voice session stays `INACTIVE` for the whole call, the
voice PCMs are never opened, and there is no audio.

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

### The probe, on a live call

Ran it. The diagnosis holds.

First, the negative result, which is the stronger half. Across an entire call
the only `update_calls` the HAL performs on its own is this one, at call start,
when the framework opens the voice output stream and `voice_start_call` sets
`voice.in_call`:

    update_calls: cur_state=1 new_state=1 vsid=10c01000
    ... seven sessions, every one INACTIVE -> INACTIVE

and one more at teardown when the mode drops back to `NORMAL`. Nothing else,
ever. No component sends `vsid`/`call_state`, exactly as predicted.

Then the injection, mid-call:

    adev_set_parameters: enter: call_state=2;vsid=0x11C05000
    update_call_states is_call_active:0 in_call:1, mode:2
    update_calls: cur_state=1 new_state=2 vsid=11c05000
    update_calls: INACTIVE -> ACTIVE vsid:11c05000
    voice_start_usecase: enter usecase:voicemmode1-call
    ACDB -> send_voice_cal, acdb_rx = 7, acdb_tx = 41
    voice_config.rate 8000
    voice_set_sidetone: enable, out_snd_device: 25
    voice_start_usecase: exit: status(0)

`/proc/asound/card0/pcm2p/sub0/status` went from `closed` to `RUNNING`.
Calibration loaded, sidetone on, handset device selected, status 0. The voice
path comes up completely, and the *only* thing it was waiting for is a
notification nothing on this device sends.

### Which vsid

`0x11C05000`, VOICEMMODE1. Not the legacy VoLTE `0x10C02000`, which is the
obvious guess and is wrong: the HAL accepts it and `update_calls` does take it
`INACTIVE -> ACTIVE`, but `voice_start_usecase()` then fails for usecase 38.

Worth stating plainly, because it nearly became a sixth wrong root cause: a vsid
being accepted means only that the HAL knows the constant. It says nothing about
whether the modem has a session behind it.

## The fix

Put the stock client back. `scripts/extract-qti-telephony.sh` pulls
`QtiTelephonyService.apk` out of `firmware/super.img`, installs it, and installs
the allowlist it needs on our build.

Verified on a live call with no manual injection anywhere:

    19:07:34.466  adev_set_mode: mode 2 , prev_mode 0
    19:07:34.736  update_calls: INACTIVE -> ACTIVE vsid:11c05000
    19:07:34.736  voice_start_usecase: enter usecase:voicemmode1-call
    19:07:34.737  ACDB -> send_voice_cal, acdb_rx = 7, acdb_tx = 41
    19:07:56.157  voice_stop_usecase: enter usecase:voicemmode1-call
    19:07:57.136  adev_set_mode: mode 0

270 ms from mode change to session start. Audio works in both directions, and
teardown is clean — `pcm2` returns to `closed`, unlike the hand injection, which
left a session running after hangup because nothing sent `call_state=1`.

The parameters it sends are `vsid=0x11C05000;call_type=LTE;call_state=2`. The
vsid is exactly the one derived by hand; `call_type` is extra and the manual
probe never sent it.

### It must be privileged here, though stock runs it unprivileged

The app wants `MODIFY_AUDIO_ROUTING`, which is `signature|privileged`. Stock
satisfies the signature half — the APK is signed with Onyx's platform key — so
it sits unprivileged in `/system_ext/app` and works.

Our build has a different platform key, so that half can never match and the
permission has to come from the privileged half instead: `/system_ext/priv-app`
plus `device/onyx/Palma2_Pro_C/telephony/privapp-permissions-qtitelephony.xml`.

Installed stock-style, it fails in a way that reads like a code bug rather than
a permissions problem:

    SecurityException: Not allowed to monitor audioserver state
    NullPointerException ... AudioController.updateAudioCallbacks
        at QtiTelephonyService.onCreate(QtiTelephonyService.java:109)

`AudioController` never constructs, the field stays null, and since the app is
`android:persistent` the framework restarts it forever. Worth remembering
generally: a signature-guarded blob that "works on stock" may be relying on a
key you do not have, and the failure surfaces well downstream of the cause.

### Why not the free implementation

[sonyxperiadev/QcRilAm](https://github.com/sonyxperiadev/QcRilAm) is Apache-2.0,
about 70 lines of Kotlin, and does exactly this job:

```kotlin
val qcRilAudio = IQcRilAudio.getService("slot$simSlotNo", true /*retry*/)
qcRilAudio.setCallback(object : IQcRilAudioCallback.Stub() {
    override fun getParameters(keys: String?)         = audioManager.getParameters(keys)
    override fun setParameters(keyValuePairs: String?): Int {
        audioManager.setParameters(keyValuePairs)
        return 0
    }
})
```

It was vendored here and then removed. The argument for it was that a published
image could ship it. That argument does not survive contact with the rest of the
stack: **VoLTE signalling already requires the proprietary `ims.apk`**, so no
published image can place a call regardless, and anyone building this extracts
blobs anyway. The redistributability bought nothing real.

Against that, the stock APK is what Onyx shipped and tested on this exact vendor
stack, and it demonstrably handles teardown and `call_type` correctly. It is in
git history if the reasoning ever changes.

Do not install both. qcrild keeps a single `mQcRilAudioCallback`, so whichever
registers last silently wins.

### Still owed

**sepolicy.** A `system_ext` priv-app reaching a vendor HIDL service needs a
rule. This build is permissive, so it works without one and will break the day
it stops being permissive.

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
