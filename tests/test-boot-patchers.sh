#!/usr/bin/env bash
# The boot-image patchers. Highest-risk code in the repo: a bad ramdisk rebuild
# produced a device that hung in recovery with no diagnostic, twice.
#
# The invariants under test are the ones that were learned the hard way:
#   * total image size never changes (it is flashed to a fixed partition)
#   * the ramdisk never outgrows its original page count when anything after it
#     is addressed absolutely
#   * recovery images (recovery_dtbo_offset != 0) are refused outright
#   * kernel and DTB come through byte-identical

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/lib.sh"

MK="$REPO_ROOT/tests/mkbootfixture.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 "$MK" "$TMP/boot.img" >/dev/null
python3 "$MK" "$TMP/recovery.img" --kind recovery >/dev/null
python3 "$MK" "$TMP/tight.img" --no-avb-keys --tight >/dev/null

# field <img> <offset> -- read a little-endian u32 from the header
field() { python3 -c "
import struct,sys
print(struct.unpack_from('<I', open(sys.argv[1],'rb').read(), int(sys.argv[2]))[0])" "$1" "$2"; }
size() { wc -c < "$1" | tr -d ' '; }

section "patch-boot-cmdline.py"

CL="$REPO_ROOT/scripts/patch-boot-cmdline.py"
out=$(python3 "$CL" "$TMP/boot.img" "$TMP/cl.img" "androidboot.selinux=permissive" 2>&1)
assert_eq "exit 0 on valid image" "0" "$?"
assert_eq "size unchanged" "$(size "$TMP/boot.img")" "$(size "$TMP/cl.img")"
assert_contains "reports new cmdline" "$out" "androidboot.selinux=permissive"

# Only the cmdline field may differ.
diffrange=$(python3 -c "
a=open('$TMP/boot.img','rb').read(); b=open('$TMP/cl.img','rb').read()
d=[i for i in range(len(a)) if a[i]!=b[i]]
print(f'{min(d)}-{max(d)}' if d else 'none')")
assert_contains "only the cmdline region changed (offsets 64..575)" \
  "$(python3 -c "
lo,hi='$diffrange'.split('-'); print('inside' if int(lo)>=64 and int(hi)<576 else 'OUTSIDE '+'$diffrange')")" "inside"

assert_eq "ramdisk_size untouched" "$(field "$TMP/boot.img" 16)" "$(field "$TMP/cl.img" 16)"
assert_eq "kernel_size untouched" "$(field "$TMP/boot.img" 8)" "$(field "$TMP/cl.img" 8)"

# 512-byte field, must refuse rather than truncate into the id[32] that follows.
assert_fails "refuses a cmdline that would overflow the field" \
  python3 "$CL" "$TMP/boot.img" "$TMP/overflow.img" "$(python3 -c 'print("x"*600)')"
assert_eq "no output file written on refusal" "no" \
  "$([ -f "$TMP/overflow.img" ] && echo yes || echo no)"

printf 'NOTANDROID' > "$TMP/notboot.img"
assert_fails "refuses a non-boot image" python3 "$CL" "$TMP/notboot.img" "$TMP/x.img" "a=b"

section "patch-boot-overlayrc.py"

OV="$REPO_ROOT/scripts/patch-boot-overlayrc.py"
out=$(python3 "$OV" "$TMP/boot.img" "$TMP/ov.img" 2>&1); rc=$?
assert_eq "exit 0 on a boot image with avb keys to drop" "0" "$rc"
assert_eq "size unchanged" "$(size "$TMP/boot.img")" "$(size "$TMP/ov.img")"
assert_contains "reports dropping the avb keys" "$out" "avb/q-gsi.avbpubkey"

inspect=$(python3 -c "
import gzip,struct
b=open('$TMP/ov.img','rb').read()
g=lambda o: struct.unpack_from('<I',b,o)[0]
ks,rs,ps=g(8),g(16),g(36)
ro=((ps+ks)+ps-1)//ps*ps
c=gzip.decompress(b[ro:ro+rs])
print('rc' if b'overlay.d/bootlog.rc' in c else 'norc')
print('magisk' if b'overlay.d/sbin/magisk.xz' in c else 'nomagisk')
print('initxz' if b'.backup/init.xz' in c else 'noinitxz')
print('keys' if b'q-gsi.avbpubkey' in c else 'nokeys')
print(( (rs+ps-1)//ps ))")
assert_contains "injects overlay.d/bootlog.rc" "$inspect" "rc"
assert_contains "keeps magisk.xz" "$inspect" "magisk"
assert_contains "keeps .backup/init.xz (magiskinit execs the real init)" "$inspect" "initxz"
assert_contains "removes the avb pubkeys" "$inspect" "nokeys"

orig_pages=$(python3 -c "
import struct
b=open('$TMP/boot.img','rb').read(); g=lambda o: struct.unpack_from('<I',b,o)[0]
print((g(16)+g(36)-1)//g(36))")
new_pages=$(printf '%s\n' "$inspect" | tail -1)
assert_eq "ramdisk page count preserved" "$orig_pages" "$new_pages"

# Kernel and DTB must survive a section rebuild untouched.
same=$(python3 -c "
import struct
a=open('$TMP/boot.img','rb').read(); b=open('$TMP/ov.img','rb').read()
g=lambda i,o: struct.unpack_from('<I',i,o)[0]
ps=g(a,36); ks=g(a,8)
print('kernel-same' if a[ps:ps+ks]==b[ps:ps+ks] else 'kernel-DIFF')
print('avb-same' if a[-1040:]==b[-1040:] else 'avb-DIFF')")
assert_contains "kernel byte-identical" "$same" "kernel-same"
assert_contains "AVB blob byte-identical and in place" "$same" "avb-same"

assert_fails "refuses a recovery image (absolute recovery_dtbo_offset)" \
  python3 "$OV" "$TMP/recovery.img" "$TMP/bad.img"
out=$(python3 "$OV" "$TMP/recovery.img" "$TMP/bad.img" 2>&1 || true)
assert_contains "recovery refusal names the reason" "$out" "recovery_dtbo"
assert_eq "no output file written for recovery" "no" \
  "$([ -f "$TMP/bad.img" ] && echo yes || echo no)"

assert_fails "refuses when the ramdisk would outgrow its pages" \
  python3 "$OV" "$TMP/tight.img" "$TMP/tight-out.img"
out=$(python3 "$OV" "$TMP/tight.img" "$TMP/tight-out.img" 2>&1 || true)
assert_contains "page-overflow refusal explains the shift risk" "$out" "Refusing"

section "patch-recovery-adb.py"

RA="$REPO_ROOT/scripts/patch-recovery-adb.py"
ssh-keygen -t ed25519 -N '' -f "$TMP/fake" -q 2>/dev/null
out=$(python3 "$RA" "$TMP/recovery.img" "$TMP/ra.img" "$TMP/fake.pub" 2>&1); rc=$?
assert_eq "exit 0 on a recovery image with default.prop" "0" "$rc"
assert_eq "size unchanged (recovery_dtbo_offset stays valid)" \
  "$(size "$TMP/recovery.img")" "$(size "$TMP/ra.img")"
assert_contains "reports the ramdisk padding decision" "$out" "pages"

ra=$(python3 -c "
import gzip,struct
b=open('$TMP/ra.img','rb').read(); g=lambda o: struct.unpack_from('<I',b,o)[0]
ks,rs,ps=g(8),g(16),g(36)
ro=((ps+ks)+ps-1)//ps*ps
c=gzip.decompress(b[ro:ro+rs])
print('secure0' if b'ro.adb.secure=0' in c else 'secure1')
print('keys' if b'adb_keys' in c else 'nokeys')
print(g(1636))")
assert_contains "sets ro.adb.secure=0" "$ra" "secure0"
assert_contains "adds adb_keys" "$ra" "keys"
assert_eq "recovery_dtbo_offset unchanged" \
  "$(python3 -c "
import struct;print(struct.unpack_from('<Q',open('$TMP/recovery.img','rb').read(),1636)[0])")" \
  "$(printf '%s\n' "$ra" | tail -1)"

summary
