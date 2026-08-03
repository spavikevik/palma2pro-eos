#!/usr/bin/env bash
# One entry point for the remote AOSP builder.
#
#   scripts/builder.sh <command> [args]
#
#   pin <fingerprint>   verify and pin the container's SSH host key
#   ssh [cmd...]        run a command (no args = interactive shell)
#   push                copy the device tree over (scripts/sync-to-builder.sh)
#   sync                repo sync progress
#   resync              restart an interrupted repo sync
#   build [target]      start a detached build (default: the lunch config check)
#   env                 show the build environment, before and after overrides
#   logs [-f]           show the build log
#   status              what is running, plus memory and disk
#   stop                stop a running build
#
# Every command pins the host key. StrictHostKeyChecking=yes with a
# repo-local known_hosts means a changed key is an error, not a prompt -- which
# matters because the container regenerates its keys if its volume is recreated.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Local overrides, sourced FIRST so builder.env's ${VAR:-default} pattern picks
# them up. Gitignored: it holds your builder's address, which is machine
# specific and deliberately not committed. Copy builder.env.local.example.
#
# Precedence is  exported var > builder.env.local > builder.env, but only
# because every one of those files assigns with ${VAR:-default}. A plain
# assignment anywhere in the chain silently wins over the environment.
if [ -f "$HERE/build/ssh/builder.env.local" ]; then
    # shellcheck disable=SC1091
    . "$HERE/build/ssh/builder.env.local"
fi
# shellcheck source=../build/ssh/builder.env
. "$HERE/build/ssh/builder.env"
KNOWN_HOSTS="$HERE/build/ssh/known_hosts"
BUILD_LOG="$BUILDER_TREE/build.log"
SYNC_LOG="$BUILDER_TREE/sync.log"
# `pgrep -f` cannot detect the sync reliably: the command line we send CONTAINS
# the words being searched for -- both the echoed labels and, in resync, the
# literal "repo sync -c -j4". The bracket trick only stops a pattern matching
# itself, not other text on the same line. A PID file we write ourselves is
# deterministic and immune to how the command happens to be spelled.
SYNC_PID="$BUILDER_TREE/.sync.pid"

# IdentitiesOnly stops ssh-agent offering other keys first and tripping the
# container's MaxAuthTries 3.
ssh_opts=(-p "$BUILDER_PORT"
          -i "$BUILDER_KEY"
          -o IdentitiesOnly=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS"
          -o StrictHostKeyChecking=yes
          -o PasswordAuthentication=no
          -o ServerAliveInterval=30)

TARGET="$BUILDER_USER@$BUILDER_HOST"

die() { printf 'builder: %s\n' "$*" >&2; exit 1; }

need_pin() {
    [ -s "$KNOWN_HOSTS" ] || die "host key not pinned yet. Run:
  scripts/builder.sh pin <fingerprint-from-the-container-log>"
}

# Build the `env` prefix from builder.env. See BUILDER_UNSET_ENV / BUILDER_SET_ENV
# there for why the image's baked-in caps are removed rather than raised.
#
# Assembled as a string because it is interpolated into a remote shell command;
# the values are our own config, not user input.
ENV_PREFIX="env"
for v in ${BUILDER_UNSET_ENV:-}; do ENV_PREFIX="$ENV_PREFIX -u $v"; done
for a in ${BUILDER_SET_ENV:-}; do ENV_PREFIX="$ENV_PREFIX $a"; done

cmd=${1:-status}
shift || true

case "$cmd" in

pin)
    expected=${1:-}
    [ -n "$expected" ] || die "usage: builder.sh pin SHA256:..."
    scanned=$(ssh-keyscan -p "$BUILDER_PORT" -t ed25519 "$BUILDER_HOST" 2>/dev/null || true)
    [ -n "$scanned" ] || die "no response from $BUILDER_HOST:$BUILDER_PORT"
    got=$(printf '%s\n' "$scanned" | ssh-keygen -lf - | awk '{print $2}')
    printf 'expected: %s\noffered : %s\n' "$expected" "$got"
    [ "$got" = "$expected" ] || die "MISMATCH -- not pinning. Do not proceed."
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    printf '%s\n' "$scanned" > "$KNOWN_HOSTS"
    echo "match -> pinned to $KNOWN_HOSTS"
    ;;

ssh|sh)
    need_pin
    if [ $# -eq 0 ]; then exec ssh -t "${ssh_opts[@]}" "$TARGET"; fi
    exec ssh "${ssh_opts[@]}" "$TARGET" "$@"
    ;;

push)
    need_pin
    exec "$HERE/scripts/sync-to-builder.sh" "$TARGET" "$BUILDER_PORT"
    ;;

sync)
    need_pin
    ssh "${ssh_opts[@]}" "$TARGET" "
        if [ -f $SYNC_PID ] && kill -0 \$(cat $SYNC_PID) 2>/dev/null; then
            echo \"repo-sync: RUNNING (pid \$(cat $SYNC_PID))\"
        else
            echo 'repo-sync: idle'
        fi
        echo \"tree size: \$(du -sh $BUILDER_TREE 2>/dev/null | cut -f1)\"
        # repo writes NOTHING to a non-tty, so sync.log stays empty unless
        # something fails. Progress therefore comes from the tree: .repo/projects
        # gains a directory per fetched project, and project.list is the total.
        # project.list is only written once sync COMPLETES, so count the manifest
        # (plus any local manifests) while it is still in flight.
        total=\$( { cat $BUILDER_TREE/.repo/manifests/default.xml \
                        $BUILDER_TREE/.repo/local_manifests/*.xml 2>/dev/null; } \
                  | grep -c '<project' || echo 0)
        done_n=\$(find $BUILDER_TREE/.repo/projects -maxdepth 3 -name '*.git' 2>/dev/null | wc -l)
        echo \"projects fetched: \$done_n / \$total\"
        if [ -s $SYNC_LOG ]; then
            echo '--- log (only written on errors) ---'
            tail -c 4000 $SYNC_LOG | tr '\r' '\n' | grep -vE '^[[:space:]]*\$' | tail -5
        else
            echo 'log empty (expected: repo is silent when not on a tty)'
        fi
        # project.list is written even when the sync PARTIALLY failed, so it is
        # not a success marker. repo's own verdict in the log is -- but only once
        # the sync has actually exited, since resync truncates the log on start
        # and a stale project.list would otherwise read as success.
        if [ -f $SYNC_PID ] && kill -0 \$(cat $SYNC_PID) 2>/dev/null; then
            echo 'VERDICT: sync in progress -- no verdict until it exits'
        elif grep -q 'Unable to fully sync the tree' $SYNC_LOG 2>/dev/null; then
            echo 'VERDICT: last sync FAILED for some projects:'
            grep -oE \"on [a-zA-Z0-9_./+-]+ failed\" $SYNC_LOG | sort -u | sed 's/^/    /'
            echo '    -> run: scripts/builder.sh resync'
        elif [ -f $BUILDER_TREE/.repo/project.list ]; then
            echo \"VERDICT: sync complete (\$(wc -l < $BUILDER_TREE/.repo/project.list) projects)\"
        else
            echo 'VERDICT: sync still in progress'
        fi
    "
    ;;

resync)
    need_pin
    ssh "${ssh_opts[@]}" "$TARGET" "
        cd $BUILDER_TREE
        if [ -f $SYNC_PID ] && kill -0 \$(cat $SYNC_PID) 2>/dev/null; then
            echo \"a sync is already running (pid \$(cat $SYNC_PID))\"; exit 0
        fi
        : > $SYNC_LOG
        # -j4, not -j12: the first pass hit HTTP 429 (rate limiting) from
        # android.googlesource.com on four projects. Gentler parallelism avoids it.
        nohup repo sync -c -j4 --no-clone-bundle --no-tags --force-sync >> $SYNC_LOG 2>&1 &
        echo \$! > $SYNC_PID
        echo \"resync started, pid \$(cat $SYNC_PID)\"
    "
    ;;

build)
    need_pin
    target=${1:-nothing}
    # Detached via nohup: a full build outlives any SSH session.
    ssh "${ssh_opts[@]}" "$TARGET" "
        set -e
        cd $BUILDER_TREE
        # ckati MUST be in this list. It is a whole phase of the build (~35 min
        # regeneration on this host), and omitting it let a second build start
        # mid-regen and die on out/.lock:
        #   Tried to lock out/.lock, but timed out ... no other Soong process
        for _p in soong_build ninja ckati soong_ui; do
            if pgrep -x \$_p >/dev/null; then
                echo \"a build is already running (\$_p) -- use: builder.sh stop\"; exit 1
            fi
        done
        if [ ! -f build/envsetup.sh ]; then
            echo 'no build/envsetup.sh -- the repo sync has not finished'; exit 1
        fi
        nohup $ENV_PREFIX bash -lc '
            cd $BUILDER_TREE
            source build/envsetup.sh >/dev/null
            lunch $BUILDER_LUNCH
            m $target
        ' > $BUILD_LOG 2>&1 &
        echo \"build '$target' started, pid \$!\"
        echo \"log: $BUILD_LOG\"
    "
    ;;

env)
    need_pin
    echo "prefix: $ENV_PREFIX"
    echo
    echo "--- as the CONTAINER has it (image ENV, what sshd inherits) ---"
    ssh "${ssh_opts[@]}" "$TARGET" \
        'for v in NINJA_HIGHMEM_NUM_JOBS _JAVA_OPTIONS USE_CCACHE CCACHE_DIR CCACHE_MAXSIZE LC_ALL LANG; do
             printf "  %-24s %s\n" "$v" "${!v-<unset>}"
         done'
    echo "--- as the BUILD will see it (after overrides) ---"
    ssh "${ssh_opts[@]}" "$TARGET" \
        "$ENV_PREFIX bash -lc 'for v in NINJA_HIGHMEM_NUM_JOBS _JAVA_OPTIONS USE_CCACHE CCACHE_DIR CCACHE_MAXSIZE LC_ALL LANG; do
             printf \"  %-24s %s\\n\" \"\$v\" \"\${!v-<unset>}\"
         done'"
    ;;

logs)
    need_pin
    if [ "${1:-}" = "-f" ]; then
        exec ssh "${ssh_opts[@]}" "$TARGET" "tail -f $BUILD_LOG"
    fi
    ssh "${ssh_opts[@]}" "$TARGET" \
        "tail -c 3000 $BUILD_LOG 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -25 || echo 'no build log yet'"
    ;;

status)
    need_pin
    ssh "${ssh_opts[@]}" "$TARGET" "
        echo '--- processes ---'
        { [ -f $SYNC_PID ] && kill -0 \$(cat $SYNC_PID) 2>/dev/null; } && echo '  repo-sync: RUNNING' || echo '  repo-sync: -'
        # ckati and soong_ui belong here as much as the other two. Without them
        # 'status' reported nothing running during the ~35 min kati regen, whose
        # final step ('finishing legacy Make module parsing') also writes no log
        # lines -- so a healthy build looked dead for half an hour.
        for _p in soong_ui soong_build ckati ninja; do
            if pgrep -x \$_p >/dev/null; then
                echo \"  \$_p: RUNNING (\$(ps -o etime= -C \$_p | head -1 | tr -d ' '))\"
            else
                echo \"  \$_p: -\"
            fi
        done
        echo '--- memory ---'; free -h | sed -n 2,3p
        echo '--- disk ---'; df -h $BUILDER_TREE | tail -1
        echo '--- top rss ---'; ps -eo rss,etime,comm --sort=-rss | head -4
    "
    ;;

stop)
    need_pin
    ssh "${ssh_opts[@]}" "$TARGET" "
        pkill -f soong_ui  2>/dev/null || true
        pkill -x soong_build 2>/dev/null || true
        pkill -x ninja 2>/dev/null || true
        sleep 2
        pgrep -x soong_build >/dev/null && echo 'still running' || echo 'build stopped'
    "
    ;;

*)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
