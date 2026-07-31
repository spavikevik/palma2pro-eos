# Build environment: why this host cannot do soong's analysis pass

Five attempts to run `m nothing` (config-only, no compilation) on a 16 GB Apple
Silicon Mac. None completed. This records what was measured, so the next attempt
starts from evidence rather than repeating it.

## The host

| | |
|---|---|
| Host | Apple Silicon Mac, **16 GB** RAM |
| VM | podman machine, Fedora CoreOS, x86_64 via Rosetta |
| VM RAM | 12 GB, later 13 GB |
| VM disk | 400 GB (238 GB free) |
| Tree | /e/OS `v4.2-a15`, 13,527 `Android.bp`, 57 GB prebuilts |

x86_64-under-Rosetta is *not* the problem: benchmarked at 17.9 s vs 17.8 s
native. The problem is memory, and only memory.

## What soong actually needs

Measured working set of the single `soong_build` process during glob + analysis:

```
run 1  no limit          grew to ~36 GB   OOM-killed at 11.7 GB anon-rss
run 2  GOMEMLIMIT=7GiB   RSS pinned 7.6 GB + 5.7 GB swap    GC spiral
run 3  GOMEMLIMIT=10GiB  reached analysis, then Killed
run 4  GOMEMLIMIT=11GiB  broke on pruned tree (see below)
run 5  no limit + zram   ~35 GB at 2h15m, still in globs, thrashing
```

**~36 GB of working set for the analysis pass.** That is the number that matters.
13 GB of RAM cannot back it, and no arrangement of swap changes that -- it only
changes whether you die quickly or slowly.

## Every lever tried

| Lever | Result |
|---|---|
| `vm.swappiness=100` | **Necessary.** At 20 the kernel OOM-killed with 15 GB of swap untouched. |
| `--oom-score-adj=-500` | Necessary. Podman defaults soong to `+200`, i.e. preferred kill target. |
| `GOMEMLIMIT` 7/10/11 GiB | Harmful below the live heap: Go GCs continuously against a ceiling it cannot reach. Only useful if set *above* the live set. |
| VM 12 -> 13 GB | Marginal. Host has 16 GB total; more would starve macOS. |
| Prune `cts` + `platform_testing` | **Broke the build.** See below. |
| zram (zstd) | Best single lever. Bought survival past the previous death point, not completion. |
| `_JAVA_OPTIONS=-Xmx4g`, `NINJA_HIGHMEM_NUM_JOBS=2` | Already set; irrelevant to this phase. |

### Pruning the tree does not work

`cts/` is 2,055 of 13,527 modules and contributes nothing to a device image, so
removing it looks free. It is not. Soong analyses **every** `Android.bp` in the
tree regardless of what the product builds, so any dangling reference is fatal:

```
error: test/cts-root/tests/bugreport/Android.bp:19:1:
  "CtsRootBugreportTestCases" depends on undefined module "cts_defaults".
error: packages/modules/HealthFitness/tests/cts/Android.bp:20:1:
  "CtsHealthFitnessDeviceTestCases" depends on undefined module "cts_defaults".
```

`platform_testing/` fails the same way via `tradefed_errorprone_defaults`, which
non-test modules under `packages/modules/AdServices` depend on. Test suites are
not leaf nodes -- they publish `defaults` consumed across the tree. Chasing every
referrer would mean deleting dozens of unrelated directories.

Both were restored. `.repo/local_manifests/prune-tests.xml` was removed.

### zram is worth keeping regardless

Not persistent across VM restart; re-apply before a build:

```sh
sudo modprobe zram num_devices=1
echo zstd > /sys/block/zram0/comp_algorithm   # MUST precede disksize
echo 20G  > /sys/block/zram0/disksize         # uncompressed capacity
echo 5G   > /sys/block/zram0/mem_limit        # ceiling on real RAM consumed
mkswap /dev/zram0 && swapon -p 100 /dev/zram0 # priority above disk swapfiles
```

Compression on soong's Go heap, measured:

```
early   3.2 GB data -> 228 MB   (14:1)
later  19.8 GB data -> 3.1 GB   (7:1, as more varied pages spill in)
```

Excellent, and still not enough. When zram filled at 19.8/20 GB, overflow went
to disk swap and the process shifted from compute-bound to I/O-bound -- CPU fell
488% -> 328%, load 4.36 -> 2.87. Raising `disksize` to 40 G is the one untried
knob.

## Conclusion

AOSP's own guidance for this era is 64 GB RAM. A 16 GB host is far enough below
that the analysis pass is not merely slow but non-viable: 2h15m produced no
milestone, with `glob_results` still 0 bytes.

The build belongs on a machine with 32-64 GB. Everything else in this repo --
the device tree, the EBC work, the EDL tooling -- is unaffected and stays valid.

Worth noting what *did* get proven: the device tree config parses clean. Every
`TARGET_*` variable resolves, `lunch lineage_Palma2_Pro_C-bp1a-userdebug`
succeeds, and blueprint bootstraps. The blocker is host capacity, not our
configuration.
