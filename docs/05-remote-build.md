# Remote build: driving a borrowed machine over SSH

`docs/04-build-env.md` measured why the 16 GB dev Mac cannot do soong's analysis
pass. This is what replaced it.

## The machine

Borrowed, not owned -- which drove every design decision here. Apple Silicon Mac,
Docker Desktop, containers run `linux/amd64` under Rosetta.

```
cores 16      RAM 46 GiB      /aosp 1 TB (909 GB free)
java  openjdk 17.0.19         python 3.10.12       repo launcher 2.65
```

For contrast, the numbers that mattered: `soong_build` peaked at **23 GB** and
`ckati` at **13.5 GB**. Either one alone exceeds the 13 GB VM we were fighting.

## Layout

| Path | Purpose |
|---|---|
| `build/ssh/Dockerfile` | AOSP toolchain + sshd, self-contained |
| `build/ssh/sshd_config` | key-only, no forwarding, no root |
| `build/ssh/entrypoint.sh` | validates, then starts sshd; fails closed |
| `build/ssh/builder.env` | host/port/key/tree/lunch + env overrides |
| `build/ssh/known_hosts` | pinned host key |
| `scripts/builder.sh` | the only thing you invoke |
| `scripts/sync-to-builder.sh` | pushes our work (not the AOSP tree) |

The bootstrap set is copied to the external SSD as `aosp-builder/` with
`start-builder.sh`, `stop-builder.sh` and a `README.txt` written for the
machine's owner. They run one command; `stop-builder.sh --purge` leaves no trace.

## Usage

```sh
scripts/builder.sh pin SHA256:...   # once, against the fingerprint it printed
scripts/builder.sh push             # device tree over
scripts/builder.sh build nothing    # detached
scripts/builder.sh logs -f
scripts/builder.sh status
scripts/builder.sh env              # what the build actually sees
```

## Security model, and where it is weaker than it looks

Real controls: a **dedicated** key (`~/.ssh/palma2pro-builder`, revoked by
deleting the container), key-only auth, no TCP/agent/X11/tunnel forwarding, an
unprivileged user, no sudo, and a container that refuses to start without both a
key and an explicit allow-list.

Not a real control: **the source-host allow-list.** Docker publishes ports
through a NAT, so every connection arrives as the Docker Desktop gateway
(`192.168.65.1`) rather than the client's address. `AllowUsers builder@<client>`
therefore cannot distinguish clients -- it is syntactic. Genuine source
restriction would need the host's own firewall, or binding to loopback and
tunnelling; neither is worth imposing on a borrowed machine.

Host keys live in a named volume so the fingerprint is stable and pinning works.
`StrictHostKeyChecking=yes` with a repo-local `known_hosts` makes a changed key
an error rather than a prompt.

## Four things that cost real time

**The build account was locked.** `useradd` with no password writes `!` to
`/etc/shadow`, and sshd with `UsePAM no` rejects that *before* looking at the
key, logging `User builder not allowed because account is locked`. A valid key
reads as `Permission denied (publickey)`. Fixed with `useradd -p '*'` -- no
password can ever match, but the account is not locked. Regression-tested.

**Docker `ENV` never reaches SSH sessions.** It populates PID 1 only; sshd builds
a fresh environment per session and with `UsePAM no` does not read
`/etc/environment`. Verified: `LANG` and `USE_CCACHE` were unset in both login
and non-login shells despite the Dockerfile setting them -- so **ccache was
silently inactive**. Fixed twice over: `BUILDER_SET_ENV` in `builder.env` (fixes a
running container, no rebuild) and `/etc/profile.d/aosp-build.sh` in the image,
which a login shell does source. `builder.sh env` prints both columns so this is
checked rather than assumed.

**`pgrep -f` cannot detect the sync.** The remote command line *contains* the
words being searched for -- both the echoed label and, in `resync`, the literal
`repo sync -c -j4`. The bracket trick (`[r]epo sync`) does not help, because it
only stops a pattern matching itself, not other text on the same line. Replaced
with a PID file we write ourselves.

**`repo sync -j12` hit HTTP 429.** Rate limiting from
`android.googlesource.com` failed four projects, and `repo` still wrote
`.repo/project.list`, so the tree *looked* complete:

```
error: Unable to fully sync the tree
  platform/external/google-fruit, google-smali, kotlinx.metadata, system/dmesgd
```

`project.list` is not a success marker. `builder.sh sync` now reports repo's own
verdict, suppressed while a sync is live because `resync` truncates the log.
`resync` uses `-j4`, which recovered all four with no further 429s.

## Manifest

```
repo init -u https://gitlab.e.foundation/e/os/android.git -b v4.2-a15
```

Verified rather than assumed: `v4.2-a15` sets `<default revision="refs/heads/lineage-22.2">`,
and `LineageOS/android_build` `lineage-22.2` declares `BUILD_ID=BP1A.250505.005`
-- which is what the local build reported, and which is where the `bp1a` release
name in the lunch target comes from.

LFS is deliberately **off**: the webview `.lfsconfig` points at
`review.lineageos.org` and fails with `tls: bad record MAC`. Four APKs, not
build-blocking.

## First build result

`m nothing` reached the real failure in ~7 minutes:

```
device/onyx/Palma2_Pro_C/lineage_Palma2_Pro_C.mk includes non-existent modules
  android.hardware.boot@1.1-impl-qti
  android.hardware.boot@1.1-impl-qti.recovery
  android.hardware.graphics.allocator@4.0-service
```

Fixed by removing them -- and also `android.hardware.boot@1.1-service` and
`android.hardware.graphics.composer@2.4-service`, which **do** exist but are
equally wrong here: they are vendor HALs, and this port keeps Onyx's Android 11
vendor image. `device.mk` already said the vendor composer drives the panel, then
contradicted itself two lines later.

Proven by that run: the device tree config is valid. It passed soong analysis and
all 40 legacy `Android.mk` includes, and `kernel.mk` took the prebuilt-kernel path
with exactly the deprecation warning `BoardConfig.mk` predicted.

## Cost model: batch device-tree edits

Any change to `BoardConfig.mk` (or `device.mk`) invalidates the ninja file and
forces a full `soong` + `ckati` regeneration. On this host that is **~35 minutes**,
because `ckati` is single-threaded and runs under Rosetta.

Changes to *prebuilts* referenced by the device tree (e.g.
`prebuilt/dtbo.img`) do not trigger regeneration -- those rebuild in seconds.

So: batch all `BoardConfig.mk`/`device.mk` edits into one pass before rebuilding.
A comment-only edit costs exactly as much as a real one; this was learned by
paying for it.

Rough per-change cost:

| Change | Cost |
|---|---|
| prebuilt image swapped | seconds |
| C++ source in a module | minutes (incremental) |
| `BoardConfig.mk` / `device.mk` | ~35 min full regen |
| fresh `repo sync` tree | ~35 min + first-build compile |

## Host dex2oat does not work under Rosetta

AOT compilation on the build host fails, both binaries, same root cause:

```
dex2oatd (debug)   F obj_ptr-inl.h:58 Check failed: ref <= 0xFFFFFFFFU
                     (ref=140737302179840, 0xFFFFFFFFU=4294967295)

dex2oat (release)  Fatal signal 11 (SIGSEGV) fault addr 0xf4e73008
                   #00 art::mirror::String::Equals
                   #01 art::InternTable::Table::Find
                   rsi: 0x00000000f4e73000   r15: 0x00000000f4e73000
```

ART's compressed object references are 32-bit and assume the heap is mapped below
4 GiB. Under x86_64-on-arm64 translation `mmap` returns addresses above that, so
pointers truncate to garbage. `140737302179840` is `0x7FFF...`; `0xf4e73008` is
what is left of a real pointer after truncation.

`USE_DEX2OAT_DEBUG=false` is **not** a fix. The `ObjPtr` check is indeed debug-only,
but the assumption it guards is real -- switching to the release binary only turns
a clean abort into an unchecked segfault. Recorded because the reasoning looked
sound and was wrong.

Workaround in use: `WITH_DEXPREOPT=false` (in `BUILDER_SET_ENV`). ART then JITs at
runtime instead of shipping `.art`/`.oat`/`.vdex`.

| | effect |
|---|---|
| first boot | slower (no preopt) |
| app startup | slower until JIT warms |
| image size | smaller |
| build | works |

Acceptable for bring-up, and normal for GSI-style builds. The real fix is a native
x86_64 Linux build host; revisit once the port boots.

**Note both of these variables are tracked by soong** (`soong.environment.used.*`),
so changing either forces a full ~35 min regeneration -- same cost as a
`BoardConfig.mk` edit. Batch them.

## Go toolchain faults under Rosetta are flaky -- just retry

```
FAILED: out/host/linux-x86/bin/go/fileslist/linux_glibc_x86_64/obj/fileslist
GOROOT='prebuilts/go/linux-x86' ... link -o ...
unexpected fault address 0xeffff7d4e7e0
fatal error: fault
runtime.sigpanic()
```

Go's runtime makes address-space assumptions that x86_64-on-arm64 translation can
violate, and the resulting faults are **nondeterministic**. A plain re-run of the
same build succeeded with zero fault lines.

So: on any `fatal error: fault` / `unexpected fault address` from a Go host tool,
retry before investigating. Only if it reproduces at the same step is it worth
looking at (options then: `GOMAXPROCS=1`, or building that tool on a native host).

Retries are cheap -- `out/` and ccache persist in the Docker volume, so a retry
redoes only the failed step. Step counts visibly shrink across retries as more
lands in cache: 53142 -> 10066 -> 9315 -> 6470 -> 6443 -> 3744.
