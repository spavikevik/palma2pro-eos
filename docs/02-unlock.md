# Unlocking the Palma 2 Pro bootloader

> **Credit.** The Fairphone 4 ABL swap is not our discovery. It was published by
> [`Kisuke-CZE/Palma_2_Pro-tips`](https://github.com/Kisuke-CZE/Palma_2_Pro-tips),
> and the Palma 2 (non-Pro) rooting method it builds on is
> [`jdkruzr/BooxPalma2RootGuide`](https://github.com/jdkruzr/BooxPalma2RootGuide)
> (CC0-1.0), which in turn credits
> [Renate at MobileRead](https://www.temblast.com/edl.htm) for the EDL material.
> What is ours is the host-side `devinfo` finish described under "How it really
> went" — needed because this panel cannot display the confirmation prompt the
> published procedure expects you to press. See `THIRD_PARTY.md`.

**STATUS: DONE.** `flash.locked=0`, `verifiedbootstate=orange`.

Not via the fastboot route this document originally described — via a direct `devinfo`
patch. What actually happened is recorded in "How it really went" at the bottom; read that
before trusting the procedure above it.

This is the highest-risk step in the project. Read the whole document before running
anything from it.

## Why it isn't just `fastboot flashing unlock`

Onyx ships an ABL (Android Bootloader) with the unlock commands stripped out. On a stock
Palma 2 Pro, fastboot has neither `flashing unlock` nor `oem unlock`, and it refuses to
write or boot even the device's own original `boot.img`. People who tried the published
Boox Palma 2 rooting method on a Pro hit bootloops that restoring `boot_a`/`boot_b` did
not fix.

The known way around it exploits the SoC coincidence: **SM7225 is the Fairphone 4's SoC**.
The Fairphone 4 ABL is signed for this platform, is GPL-licensed and publicly distributed,
and has working unlock commands. You temporarily run the device on FP4's bootloader, unlock,
then put Onyx's bootloader back.

`fastboot oem device-info` on stock reports `Verity mode: true` — verified boot is active.
Once unlocked, modified boot images and a patched vbmeta will be accepted.

## Hard gates

Do not proceed past a gate that hasn't passed.

**Gate 1 — EDL is reachable on your specific unit.**
`adb reboot edl`, then confirm the device enumerates as Qualcomm 9008:
```
system_profiler SPUSBDataType | grep -i -A4 qualcomm
```
If it does not appear, stop. Without EDL there is no recovery from a bad ABL write, and
Onyx sells no unbrick service for this device.

**Gate 2 — a full backup exists, off this machine.**
```
scripts/edl-backup.sh
```
Then copy the resulting `backup/<timestamp>/` directory somewhere that is not this laptop.
`modemst1`, `modemst2`, `fsg` and `persist` carry your IMEI, modem calibration and sensor
calibration. Those are not reconstructible from any download. Losing them means a device
that never connects to a network again.

**Gate 3 — the restore path is proven, not assumed.**
```
scripts/edl-verify-restore.sh backup/<timestamp>
```
This rewrites one inactive-slot partition from the backup and reads it back. A backup you
have never restored from is not a backup. If this fails, the ABL swap would be a one-way
trip.

## Procedure

Automated, with every gate re-checked in code:

```
scripts/fetch-fp4-abl.sh <FP4-build.zip>       # -> firmware/abl-fp4.img
scripts/unlock-bootloader.sh backup/<stamp>
```

`unlock-bootloader.sh` refuses to run unless all four gates pass — it verifies the backup's
checksums and requires the `GATE3-PASS` receipt that `edl-verify-restore.sh` writes. The
gates are checks in code rather than warnings in prose so the procedure can only be skipped
by deciding to, not by forgetting.

What it does:

1. **Enable OEM unlocking** in Developer Options first (manual). If the toggle is greyed
   out, resolve that before starting, not mid-flash.
2. Writes the **Fairphone 4 ABL** to `abl_a` and `abl_b` via EDL.
3. `setactiveslot b` (this device's active slot) and reset.
4. `fastboot flashing unlock`, reboot to bootloader, `fastboot flashing unlock_critical`.
   Each wipes userdata and needs a physical Vol Up + Power confirmation.
5. Restores **Onyx's ABL** to both slots. The unlock state lives in `devinfo`, independent
   of which ABL is installed, so it survives the restore.
6. Leaves you to verify the device still boots stock — do this before layering anything on
   top, while the backup and proven restore path are fresh.

### Notes from the known-good procedure

- **No Fairphone unlock code is needed.** Fairphone's own unlock flow requires an
  IMEI-bound code from their site, which was the obvious way this plan could have failed.
  It doesn't apply here: the FP4 ABL honours `flashing unlock` when the OEM-unlocking flag
  is set in `devinfo`, and there is no `get_unlock_ability` step.
- **`--memory=ufs` is required on every `edl` invocation.** This device is UFS with six
  LUNs (`lun0..lun5`, matching `sda..sdf`). All scripts here pass it.
- The ABL donor's Android version does not need to match this device. It only has to be
  signed for SM7225, which every FP4 build is.

## Failure modes worth knowing


- **Bootloop after ABL swap.** Restore `abl_a`/`abl_b` and `devinfo` from backup via EDL.
- **`unlock_critical` refused.** Some ABL builds gate it behind `flashing unlock` having
  completed and the device having rebooted once. Reboot between the two stages.
- **Device no longer sees SIM / no IMEI after all this.** `modemst1`, `modemst2`, `fsg`
  restore from backup. This is exactly the scenario Gate 2 exists for.
- **Fastboot writes rejected while "unlocked".** Check `devinfo` actually persisted the
  unlock; some Qualcomm ABLs read unlock state from a partition the swap can clobber.

## Note on the Onyx ABL

Redistributing Onyx's ABL is not something this repo does — it's proprietary and pulled
from your own device. The Fairphone ABL is GPL-2.0 and separately licensed; using it to
unlock hardware you own is fine, shipping a Boox image containing it is not.

---

## How it really went

The FP4 ABL swap worked exactly as intended — `fastboot getvar product` returned `FP4`,
and `fastboot oem device-info` responded, which stock Onyx ABL never does. But
`fastboot flashing unlock` could not be completed.

### The blocker: the confirmation menu is invisible

The unlock prompt is drawn by the bootloader to a standard DSI framebuffer. This device's
panel is an EPD driven through the `sepdc`/EBC controller, which the Fairphone bootloader
knows nothing about — so the screen stays blank. The prompt was there, being answered
blind, with the default selection on "do not unlock". Pressing Power alone declines it.

Two of my own bugs hid this:

- The script claimed the device would "land in fastboot" after `edl reset`. It does not —
  `edl reset` is a normal boot. The flow desynced.
- The script never verified the unlock afterwards. `fastboot flashing unlock` returns
  success even when the on-device prompt is declined, so it proceeded to restore Onyx's
  ABL as though it had worked.

Detected by three independent signals, all agreeing the unlock had not happened:

```
devinfo offset 13 (is_unlocked)   0x00, identical to the pre-unlock backup
ro.boot.verifiedbootstate          green   (unlocked would be orange)
userdata                           NOT wiped -- adb auth survived, settings intact
```

That last one is the strongest: `fastboot flashing unlock` always wipes. Nothing was
wiped, so it never ran.

### What worked: patching `devinfo` directly

`scripts/patch-devinfo-unlock.sh`. Qualcomm's `device_info` struct, confirmed against this
device's own dumps rather than assumed:

```
offset 0..12   "ANDROID-BOOT!"              magic
offset 13      is_unlocked                  0x00 -> 0x01
offset 14      is_unlock_critical           0x00 -> 0x01
offset 15      is_charger_screen_enabled    0x01   <- sanity check
```

Offset 15 reading `0x01` cross-checks against `fastboot oem device-info` reporting
*charger screen enabled: true* while both unlock fields read false. All three agree, so
the layout is established.

Two bytes changed. Read back and verified by sha256.

### The wipe happened anyway — and that was predictable

I told the user this route would preserve userdata. **That was wrong.** On reboot the
device dropped to Android Recovery with "Can't load Android system".

Userdata encryption keys are bound by Keymaster/TEE to the verified boot state. Flipping
locked -> unlocked invalidates them, so `/data` becomes undecryptable. `fastboot flashing
unlock` wipes for exactly this reason — the wipe is a *consequence* of the lock-state
transition, not something the command chooses to do. Any route to unlocked costs the data.

A factory reset from recovery resolved it. Final state:

```
flash.locked      = 0
verifiedbootstate = orange
user apps         = 0
```

### Lessons for the rest of this project

- **Verify state, never trust a command's exit code.** Three of the tools here return
  success on failure: `fastboot flashing unlock` when declined, and `cmp` in two separate
  ways (BSD `-n` EOF quirk, and `-l` exiting 1 under `pipefail`).
- **The bootloader cannot draw to this panel.** Any future step needing on-device
  confirmation at bootloader level will be invisible. Prefer host-driven operations.
  This also forecloses ever seeing fastboot menus, recovery-from-bootloader UI, etc.
- **Assume any lock-state change wipes `/data`.** Including a future re-lock.
