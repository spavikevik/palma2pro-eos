# tests

```sh
tests/run-all.sh
```

No dependencies beyond `bash` and `python3` — no bats, no pip (neither is
available on this host, and a suite that cannot be run is worse than none). No
device and no container engine required: everything here exercises pure logic.

| Suite | Covers |
|---|---|
| `test-entrypoint.sh` | `build/ssh/entrypoint.sh` — SSH server fails closed |
| `test-boot-patchers.sh` | the three boot-image patchers |
| `test-edl-scripts.sh` | `flash-logical-via-edl.py`, `sync-to-builder.sh`, syntax of every script |

## Why these three

They are the places where a mistake is expensive and silent.

**The entrypoint** is the only thing between a borrowed machine and an open SSH
server. Every case asserts it *refuses* rather than degrading: no key, empty
key, comments-only key, a private key pasted by accident, malformed key
material, a missing host allow-list, an allow-list of only separators. It is
driven with `SELFTEST=1`, which runs the validation phase and exits without
touching `/home/builder`, `sshd_config` or host keys — so it runs on macOS, and
one test asserts that the success path really does leave `sshd_config` untouched.

**The boot patchers** produced a device that hung with no diagnostic, twice.
`tests/mkbootfixture.py` builds small synthetic images that reproduce the
structural details that actually caused it: header v2, `recovery_dtbo_offset` as
an *absolute* offset, and an AVB vbmeta blob starting immediately after the DTB
with zero slack. The invariants asserted are total image size, ramdisk page
count, byte-identical kernel/DTB, and that recovery images are refused outright.

**`flash-logical-via-edl.py`** writes raw sectors into a live `super`. A wrong
extent offset overwrites a neighbouring partition. The suite checks the computed
absolute sectors, how the image is split across extents, and the refusals; a
fake `edl` on `PATH` acts as a tripwire proving nothing is ever invoked without
`--go`.

## Two real bugs these found

Both in the ramdisk rebuild, both of the same kind, and neither would have shown
up until a device failed to boot.

`patch-boot-overlayrc.py` refused outright when the ramdisk *shrank* a page
(which it does — it drops the AVB keys). On the real device it happened to stay
322 → 322 pages, so this never surfaced.

The underlying issue was worse. Padding the ramdisk *section* back to its
original span while leaving `ramdisk_size` smaller in the header breaks the DTB:
the bootloader locates later sections arithmetically, as

```
page + align(kernel_size) + align(ramdisk_size) + align(second_size) + ...
```

so it would read the DTB a page early. `patch-recovery-adb.py` had the identical
latent bug. Both now declare the padded length, keeping every absolute offset
after the ramdisk exactly where it was.

## Adding a test

`tests/lib.sh` provides `assert_eq`, `assert_contains`, `assert_not_contains`,
`assert_fails`, `assert_succeeds`, `section`, `summary`. Name files
`tests/test-*.sh` and `run-all.sh` picks them up.
