# Resizing a logical partition without a booting system

## Why

The first source build that got past the VNDK blocker produced a `product.img`
that does not fit:

```
product_b capacity   1,435,648 sectors = 735,051,776 B
product.img                              809,660,416 B     over by 74,608,640
system_b                3,761,692,672 B  vs 1,545,478,144   ok
system_ext_b              697,573,376 B  vs   545,255,424   ok
```

`scripts/flash-logical-via-edl.py` refuses an oversized image rather than
truncating one, so this surfaced as a clean error instead of a corrupt
filesystem.

Two ways out: drop the 285 MB `Browser.apk` and rebuild (~45 min), or grow
`product_b`. Super has unallocated space, so growing it keeps the build intact.

## Why not fastbootd

The supported route is:

```sh
adb reboot fastboot
fastboot resize-logical-partition product_b 943718400
```

and this device's fastbootd does accept resize (it rejects *flashing* logical
partitions, which is why `flash-logical-via-edl.py` exists at all). But
`adb reboot fastboot` needs a system that boots, and during bring-up there isn't
one -- the device holds a non-booting build, so the only channel is EDL.

So the same edit is made offline on a dump of super's head, then written back.

## The tool

```sh
scripts/lp-resize-partition.py <super-head.bin> <partition> <bytes> \
                               --slot N -o <out.bin>
```

It appends a LINEAR extent from unallocated space at the tail, rebuilds the
extents table, and recomputes both SHA256 checksums.

The extents table is rebuilt rather than patched: partitions reference a
*contiguous run* of extents via `first_extent_index`/`num_extents`, so inserting
one extent in the middle shifts every later partition's indices. Regenerating
the whole table in partition order and recomputing the indices is harder to get
subtly wrong.

### Only one slot, named explicitly

`--slot` is required. The metadata slot tracks the boot slot -- booting `_b`
uses metadata slot 1 -- and on this device the three slots do **not** agree:

| slot | contents |
|---|---|
| 0 | original 10-partition A/B layout (`odm_a`, `product_a`, ...), 5 extents |
| 1 | the live layout |
| 2 | same as slot 0 |

Patching all three would grow `product_b` inside layouts that are not in use.

### Struct layouts (both got this wrong once)

liblp's structs carry **natural alignment padding** and are not packed:

```
LpMetadataBlockDevice    first_logical_sector(0,u64) alignment(8,u32)
                         alignment_offset(12,u32) size(16,u64)
                         partition_name[36](24) flags(60,u32)      -- 64 B
LpMetadataPartitionGroup name[36] + 4 PAD + maximum_size(40,u64)   -- 48 B
LpMetadataPartition      name[36] attributes(36) first_extent(40)
                         num_extents(44) group_index(48)           -- 52 B
```

Reading `size` at 20 gave `7309471332004003841`; reading `maximum_size` at 36
gave `9205357638345293824`. At 16 and 40 they read `6442450944` and
`6438256640`, matching `lpdump`. Always sanity-check a parsed size against a
known value.

## Verification before touching the device

The transform was validated against the real `lpdump` host binary, not only our
own parser -- `lpdump` goes through liblp, which is the same code the device's
init uses, and it rejects bad checksums:

```sh
m lpdump                                  # 30 s on the builder
truncate -s 6442450944 /tmp/super-test.img
dd if=patched.bin of=/tmp/super-test.img bs=1M count=1 conv=notrunc
out/host/linux-x86/bin/lpdump --slot 0 /tmp/super-test.img
```

Result on a slot-0 dry run (`product_b` 0 -> 900 MiB):

```
  Name: product_b
  Group: qti_dynamic_partitions_b
  Extents:
    0 .. 1843199 linear super 10326880
```

Every other partition unchanged, metadata size 1036 -> 1128 bytes.

## The stale-dump trap

`firmware/super.img` (dumped 2026-07-29) is **not** a valid patch source. Its
slot 1 still contains Virtual A/B snapshot partitions:

```
odm_b-cow   product_b-cow   system_b-cow
```

which occupy the entire tail -- the tool correctly refuses with
`need 407552 sectors, only 0 free at tail`. `lpdump-a15.txt` shows slot 1 with
5 partitions and no cow, i.e. after the VABC clear. The two disagree, so the
metadata **must be re-dumped from the device** immediately before patching, and
the snapshot state re-checked. Patching a stale layout would place an extent on
top of live data.

## Procedure

Device in EDL.

```sh
# 1. dump the head (geometry + all metadata slots live in the first ~400 KB)
edl rs 45576 256 firmware/analysis/super-head-now.bin \
    --loader=firmware/palma2pro-firehose.bin --memory=ufs --lun=0

# 2. inspect: which slot is live, and are there *-cow partitions?
python3 scripts/lpdump-from-super.py firmware/analysis/super-head-now.bin --slot 1

# 3. patch
python3 scripts/lp-resize-partition.py \
    firmware/analysis/super-head-now.bin product_b 943718400 \
    --slot 1 -o firmware/analysis/super-head-resized.bin

# 4. verify with the real lpdump (see above) BEFORE writing

# 5. write back
edl ws 45576 firmware/analysis/super-head-resized.bin \
    --loader=firmware/palma2pro-firehose.bin --memory=ufs --lun=0

# 6. re-read and confirm
edl rs 45576 256 /tmp/verify.bin --loader=... --memory=ufs --lun=0
cmp /tmp/verify.bin firmware/analysis/super-head-resized.bin
```

`45576 = 0x0b208000 / 4096`, the super partition start from the GPT in device
sectors. Note `0x0b208000 = 186,679,296`, not 186,646,528 -- misreading that
hex once produced 45568, and the resulting dump had geometry at `0x9000` instead
of `0x1000`, i.e. shifted by exactly 32,768 bytes (8 device sectors). Harmless
on a read, and it fails the geometry-magic check immediately, but the same
mistake on the `ws` in step 5 would write metadata 32 KB below super and destroy
whatever precedes it. Verify the offset with a read before every write.

Step 6 matters: a half-written metadata region is worse than an unpatched one,
since liblp falls back to the backup copy and the two would disagree.

## Recovery

`firmware/analysis/super-head-now.bin` from step 1 is the undo. Writing it back
to sector 45576 restores the previous layout exactly. The full EDL backup
remains the fallback beyond that.
