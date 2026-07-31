#!/usr/bin/env bash
# Make a GSI system image tolerate BPF loader failure, the way Onyx stock does.
#
#   bash gsi-bpf-tolerant.sh <in.img> <out.img>
#
# WHY
# ---
# Onyx stock Android 15 boots on its 4.19.157 kernel while every GSI reboots at
# 16-20s. Measured difference (docs/findings.md): stock's loader prints the same
# "Unsupported kernel version" complaint and carries on; its init.rc has no
# `trigger bpf-progs-loaded`; `bpf.progs_loaded` is never set. Newer mainline
# modules turn the same condition into a hard failure.
#
# This reproduces stock's tolerance with text edits only -- no binary patching.
# Commenting out reboot_on_failure is exactly what AOSP's own comment inside
# netbpfload.rc instructs for debugging these bootloops.
#
# WORKS ON BOTH LAYOUTS
#
# The two /e/OS GSIs differ, so nothing here is hardcoded to one of them:
#
#   A15: service bpfloader /system/bin/false   (overridden by the tethering APEX)
#        reboot_on_failure reboot,netbpfload-missing
#        init.rc: trigger load-bpf-programs  +  trigger bpf-progs-loaded
#
#   A14: service bpfloader /system/bin/netbpfload   (real binary on /system)
#        reboot_on_failure reboot,bpfloader-failed
#        init.rc: trigger load_bpf_programs  (underscores, like stock)
#                 and NO bpf-progs-loaded trigger -- already stock-like
#
# So: match any reboot_on_failure line whatever its reason string, and treat the
# bpf-progs-loaded trigger as optional.
#
# All three of mode 0644, root:root and security.selinux
# "u:object_r:system_file:s0\0" are restored after each write -- debugfs does not
# preserve them, and init/apexd reject mislabelled files.

set -euo pipefail

IN=${1:?usage: gsi-bpf-tolerant.sh <in.img> <out.img>}
OUT=${2:?usage: gsi-bpf-tolerant.sh <in.img> <out.img>}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LABEL="$WORK/selabel.bin"
printf 'u:object_r:system_file:s0\000' > "$LABEL"

echo "==> copying $IN -> $OUT"
cp "$IN" "$OUT"

changed=0

# write_back <path-in-image> <local-file>
write_back() {
    local path=$1 local_file=$2 base
    base=$(basename "$path")
    cp "$local_file" "$WORK/$base.stage"
    debugfs -w "$OUT" >/dev/null 2>&1 <<EOF
rm $path
cd $(dirname "$path")
write $WORK/$base.stage $base
sif $path mode 0100644
sif $path uid 0
sif $path gid 0
ea_set -f $LABEL $path security.selinux
quit
EOF
}

# comment_out <path-in-image> <grep-pattern> <sed-expr> <label> <required:yes|no>
comment_out() {
    local path=$1 pat=$2 expr=$3 label=$4 required=$5 base
    base=$(basename "$path")
    debugfs -R "dump $path $WORK/$base" "$OUT" 2>/dev/null || true
    if [ ! -s "$WORK/$base" ]; then
        if [ "$required" = yes ]; then
            echo "ERROR: $path not present in image" >&2; exit 1
        fi
        echo "    skip: $path not present"
        return 0
    fi
    if ! grep -qE "$pat" "$WORK/$base"; then
        if [ "$required" = yes ]; then
            echo "ERROR: $label -- no active line matching /$pat/ in $path" >&2; exit 1
        fi
        echo "    skip: $label already absent in $path"
        return 0
    fi
    local before after
    before=$(wc -c < "$WORK/$base")
    sed -i "$expr" "$WORK/$base"
    after=$(wc -c < "$WORK/$base")
    [ "$before" = "$after" ] && { echo "ERROR: $label -- sed changed nothing" >&2; exit 1; }
    write_back "$path" "$WORK/$base"
    echo "    $label: $before -> $after bytes"
    changed=$((changed + 1))
}

echo "==> disabling reboot_on_failure (any reason string)"
comment_out /system/etc/init/netbpfload.rc \
    '^[[:space:]]*reboot_on_failure' \
    's|^\( *\)\(reboot_on_failure .*\)$|\1# PALMA2PRO disabled: \2|' \
    "reboot_on_failure" yes

echo "==> removing the bpf-progs-loaded wait, if this image has one"
comment_out /system/etc/init/hw/init.rc \
    '^[[:space:]]*trigger bpf-progs-loaded' \
    's|^\( *\)\(trigger bpf-progs-loaded\)$|\1# PALMA2PRO disabled: \2|' \
    "bpf-progs-loaded trigger" no

echo "==> verifying"
debugfs -R "dump /system/etc/init/netbpfload.rc $WORK/v1" "$OUT" 2>/dev/null
if grep -qE '^[[:space:]]*reboot_on_failure' "$WORK/v1"; then
    echo "    FAIL: an active reboot_on_failure remains" >&2; exit 1
fi
echo "    ok: no active reboot_on_failure"
debugfs -R "dump /system/etc/init/hw/init.rc $WORK/v2" "$OUT" 2>/dev/null
if grep -qE '^[[:space:]]*trigger bpf-progs-loaded' "$WORK/v2"; then
    echo "    FAIL: bpf-progs-loaded trigger still active" >&2; exit 1
fi
echo "    ok: no active bpf-progs-loaded trigger"
for p in /system/etc/init/netbpfload.rc /system/etc/init/hw/init.rc; do
    debugfs -R "ea_list $p" "$OUT" 2>/dev/null | grep -q 'u:object_r:system_file:s0' \
        && echo "    ok: label intact on $p" \
        || { echo "    FAIL: label lost on $p" >&2; exit 1; }
done
e2fsck -fn "$OUT" 2>&1 | tail -1
echo "==> done: $OUT ($(wc -c < "$OUT") bytes, $changed file(s) edited)"
