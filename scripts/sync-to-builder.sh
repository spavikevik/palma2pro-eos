#!/usr/bin/env bash
# Push this project to the remote AOSP build container and place the device tree.
#
# What is synced: our own work only -- device tree, scripts, docs. A few MB.
#
# What is NOT synced: the AOSP tree itself. It lives inside the local podman VM
# at /var/aosp (163 GB) and pushing that over a LAN takes far longer than a
# fresh `repo sync` on the target, which pulls from Google's and e-OS's mirrors
# in parallel. Firmware blobs and EDL backups are excluded too -- multi-GB, and
# the build does not read them.
#
# Host key handling: pinned to a project-local known_hosts. On first contact the
# script prints the fingerprint and stops, so you can compare it against what
# the container logged at startup. Blindly accepting a key would make the whole
# SSH hardening pointless.
#
# Usage:
#   scripts/sync-to-builder.sh <user@host> [ssh-port]
#   PIN_OK=1 scripts/sync-to-builder.sh <user@host>   # accept new host key
#
# Env:
#   AOSP_REMOTE_DIR   AOSP tree on the remote (default /aosp)
#   SYNC_FIRMWARE=1   also push firmware/ (large; only if you need it there)

set -euo pipefail

TARGET=${1:-}
PORT=${2:-${BUILDER_SSH_PORT:-2222}}
AOSP_REMOTE_DIR=${AOSP_REMOTE_DIR:-/aosp}
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN_HOSTS="$REPO_DIR/build/ssh/known_hosts"

[ -n "$TARGET" ] || { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

HOST=${TARGET#*@}
IDENTITY=${BUILDER_KEY:-$HOME/.ssh/palma2pro-builder}
[ -f "$IDENTITY" ] || { echo "ERROR: no builder key at $IDENTITY" >&2; exit 1; }

# IdentitiesOnly stops ssh-agent from offering every other key first and
# tripping the container's MaxAuthTries 3.
SSH_OPTS=(-p "$PORT"
          -i "$IDENTITY"
          -o IdentitiesOnly=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS"
          -o StrictHostKeyChecking=yes
          -o PasswordAuthentication=no
          -o PubkeyAuthentication=yes)

mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"

# --- host key pinning ------------------------------------------------------
if ! ssh-keygen -F "[$HOST]:$PORT" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    echo "Host [$HOST]:$PORT is not pinned yet. Fetching its key..."
    scanned=$(ssh-keyscan -p "$PORT" -t ed25519 "$HOST" 2>/dev/null || true)
    [ -n "$scanned" ] || { echo "ERROR: could not reach $HOST:$PORT" >&2; exit 1; }
    echo
    echo "Offered host key fingerprint:"
    printf '%s\n' "$scanned" | ssh-keygen -lf - | sed 's/^/  /'
    echo
    if [ "${PIN_OK:-0}" != "1" ]; then
        echo "Compare that against the fingerprint the container printed at startup"
        echo "  (docker logs <container> | grep -A3 'host key fingerprints')"
        echo "If it matches, re-run with:  PIN_OK=1 $0 $TARGET $PORT"
        exit 1
    fi
    printf '%s\n' "$scanned" >> "$KNOWN_HOSTS"
    echo "pinned to $KNOWN_HOSTS"
fi

echo "==> checking connectivity"
ssh "${SSH_OPTS[@]}" "$TARGET" 'echo "connected as $(id -un) on $(hostname)"'

# --- what to push ----------------------------------------------------------
# Exclude by DIRECTORY, not by extension. The extension excludes were redundant
# -- every multi-GB blob lives under firmware/ or backup/, which are excluded
# wholesale -- and they were actively harmful: they silently dropped
# device/onyx/Palma2_Pro_C/prebuilt/dtbo.img, so the build would have failed on a
# missing prebuilt with no hint that the file simply never crossed the wire.
EXCLUDES=(
    --exclude 'backup/'          # EDL partition dumps, tens of GB
    --exclude 'build/*.log'
    --exclude 'build/ssh/known_hosts'
    --exclude '.DS_Store'
)
if [ "${SYNC_FIRMWARE:-0}" != "1" ]; then
    EXCLUDES+=(--exclude 'firmware/')
fi

echo "==> syncing project to ~/palma2pro-eos"
rsync -az --info=stats1,progress2 \
      -e "ssh ${SSH_OPTS[*]}" \
      "${EXCLUDES[@]}" \
      "$REPO_DIR"/ "$TARGET:palma2pro-eos/"

# --- place the device tree -------------------------------------------------
# Copied rather than symlinked: soong follows its own globbing rules and a
# symlink out of the tree has bitten people before.
echo "==> placing device tree at $AOSP_REMOTE_DIR/device/onyx/Palma2_Pro_C"
ssh "${SSH_OPTS[@]}" "$TARGET" bash -s <<EOF
set -euo pipefail
if [ ! -d "$AOSP_REMOTE_DIR" ]; then
    echo "NOTE: $AOSP_REMOTE_DIR does not exist yet -- run repo init/sync there first."
    echo "      Device tree staged at ~/palma2pro-eos/device/onyx/Palma2_Pro_C"
    exit 0
fi
mkdir -p "$AOSP_REMOTE_DIR/device/onyx"
rsync -a --delete ~/palma2pro-eos/device/onyx/Palma2_Pro_C/ \
      "$AOSP_REMOTE_DIR/device/onyx/Palma2_Pro_C/"
echo "device tree in place: \$(find "$AOSP_REMOTE_DIR/device/onyx/Palma2_Pro_C" -type f | wc -l) files"
EOF

echo
echo "done. next on the builder:"
echo "  ssh ${SSH_OPTS[*]} $TARGET"
echo "  cd $AOSP_REMOTE_DIR && source build/envsetup.sh"
echo "  lunch lineage_Palma2_Pro_C-bp1a-userdebug && m nothing"
