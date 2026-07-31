#!/usr/bin/env bash
# Validate the security preconditions, then hand off to sshd.
#
# Fails closed on purpose. Every check below refuses to start rather than
# falling back to something weaker -- a build box that quietly accepts any key,
# or any source address, is worse than one that does not come up.
#
# Structure matters here: ALL validation happens before ANY side effect, so a
# rejected configuration leaves nothing half-written. SELFTEST=1 runs the
# validation phase only and exits -- that is what tests/ drives, so the security
# behaviour is actually verified rather than assumed.

set -euo pipefail

KEYS_SRC=${KEYS_SRC:-/keys/authorized_keys}
HOSTKEY_DIR=${HOSTKEY_DIR:-/etc/ssh/hostkeys}
SSH_DIR=${SSH_DIR:-/home/builder/.ssh}
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
BUILDER_USER=${BUILDER_USER:-builder}

die() { printf 'entrypoint: FATAL: %s\n' "$*" >&2; exit 1; }
note() { printf 'entrypoint: %s\n' "$*" >&2; }

# ===========================================================================
# PHASE 1 -- validation. No side effects outside $TMPDIR.
# ===========================================================================

# --- authorised keys must be supplied at runtime ---------------------------
# Never baked into the image: layers are permanent and get pushed.
#
# Two ways in. AUTHORIZED_KEYS exists because this often runs on a borrowed
# machine where asking someone to place a file is friction; a PUBLIC key is not
# a secret, so passing it in the environment is fine. Private keys are rejected
# below either way.
if [ -n "${AUTHORIZED_KEYS:-}" ] && [ ! -f "$KEYS_SRC" ]; then
    KEYS_SRC="$(mktemp)"
    printf '%s\n' "$AUTHORIZED_KEYS" > "$KEYS_SRC"
    note "took authorised keys from \$AUTHORIZED_KEYS"
fi

[ -f "$KEYS_SRC" ] || die "no authorised keys supplied.
  Either:  -e AUTHORIZED_KEYS=\"\$(cat ~/.ssh/id_ed25519.pub)\"
  or:      -v \$HOME/.ssh/id_ed25519.pub:/keys/authorized_keys:ro
  Refusing to start an SSH server that nobody can authenticate to."

# Count real key lines: a file of only comments is empty for our purposes.
key_count=$(grep -cvE '^[[:space:]]*(#|$)' "$KEYS_SRC" || true)
[ "$key_count" -gt 0 ] || die "$KEYS_SRC has no key lines. Refusing to start."

# A private key here is a serious mistake worth stopping for, not warning about.
if grep -q 'PRIVATE KEY' "$KEYS_SRC"; then
    die "authorised keys input contains a PRIVATE key. Supply the .pub instead."
fi

# Every non-comment line must look like an OpenSSH public key. Anything else
# means the operator pasted the wrong thing, and guessing would be wrong.
while IFS= read -r line; do
    case "$line" in
        ''|\#*|' '*\#*) continue ;;
    esac
    [ -n "${line// /}" ] || continue
    case "$line" in
        *ssh-ed25519*|*ssh-rsa*|*ecdsa-sha2-*|*sk-ssh-ed25519*|*sk-ecdsa-*|*ssh-dss*) ;;
        *) die "unrecognised line in authorised keys (not an OpenSSH public key): ${line:0:40}..." ;;
    esac
done < "$KEYS_SRC"

# --- host allow-list is mandatory -----------------------------------------
# Second, independent layer over any from="..." already in authorized_keys.
: "${ALLOWED_FROM:?ALLOWED_FROM is required (comma-separated hosts/patterns, or the literal string any).
  Examples:  ALLOWED_FROM=192.168.1.42
             ALLOWED_FROM='192.168.1.*,10.0.0.5'
  Set it to 'any' only if you accept connections from anywhere.}"

ALLOW_LINE=""
if [ "$ALLOWED_FROM" = "any" ]; then
    note "WARNING: ALLOWED_FROM=any -- no source-host restriction. Key auth is the only gate."
    ALLOW_LINE="AllowUsers ${BUILDER_USER}"
else
    terms=""
    old_ifs=$IFS
    IFS=','
    for h in $ALLOWED_FROM; do
        h="$(printf '%s' "$h" | tr -d '[:space:]')"
        [ -n "$h" ] || continue
        terms="$terms ${BUILDER_USER}@$h"
    done
    IFS=$old_ifs
    [ -n "$terms" ] || die "ALLOWED_FROM parsed to nothing: '$ALLOWED_FROM'"
    ALLOW_LINE="AllowUsers${terms}"
fi

# --- the build account must not be locked ---------------------------------
# sshd with `UsePAM no` refuses a login whose /etc/shadow password field starts
# with '!', with the easily-misread message "account is locked" -- it happens
# BEFORE key checking, so a perfectly good key looks like it was rejected. The
# Dockerfile creates the user with -p '*' to avoid this; this check catches image
# drift rather than trusting it. Repaired in place when we have the privilege,
# since refusing to boot over something fixable would be unhelpful.
SHADOW_FILE=${SHADOW_FILE:-/etc/shadow}
if [ -r "$SHADOW_FILE" ]; then
    pw_field=$(awk -F: -v u="$BUILDER_USER" '$1==u {print $2}' "$SHADOW_FILE")
    case "$pw_field" in
        '!'*)
            note "WARNING: account '$BUILDER_USER' is LOCKED ('${pw_field}') -- sshd would"
            note "         reject every key with 'account is locked'."
            if [ "${SELFTEST:-0}" = "1" ]; then
                printf 'SELFTEST_LOCKED %s\n' "$BUILDER_USER"
            elif command -v usermod >/dev/null 2>&1 && usermod -p '*' "$BUILDER_USER" 2>/dev/null; then
                note "         unlocked it (password auth remains impossible: field is now '*')."
            else
                die "could not unlock '$BUILDER_USER'. Rebuild the image: the useradd
  line needs -p '*' (see build/ssh/Dockerfile)."
            fi
            ;;
    esac
fi

note "validated: ${key_count} authorised key(s); ${ALLOW_LINE}"

if [ "${SELFTEST:-0}" = "1" ]; then
    # Machine-readable lines for tests/ to assert on.
    printf 'SELFTEST_OK key_count=%s\n' "$key_count"
    printf 'SELFTEST_ALLOW %s\n' "$ALLOW_LINE"
    exit 0
fi

# ===========================================================================
# PHASE 2 -- side effects. Everything above has already passed.
# ===========================================================================

install -d -m 700 -o "$BUILDER_USER" -g "$BUILDER_USER" "$SSH_DIR"
install -m 600 -o "$BUILDER_USER" -g "$BUILDER_USER" "$KEYS_SRC" "$SSH_DIR/authorized_keys"
printf '\n%s\n' "$ALLOW_LINE" >> "$SSHD_CONFIG"

# --- persistent host keys -------------------------------------------------
# Regenerating these on every start makes the fingerprint useless for pinning
# and trains you to ignore MITM warnings. Mount HOSTKEY_DIR as a volume.
install -d -m 700 "$HOSTKEY_DIR"
if [ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]; then
    note "generating host keys in $HOSTKEY_DIR (mount it as a volume to persist)"
    ssh-keygen -q -t ed25519 -N '' -f "$HOSTKEY_DIR/ssh_host_ed25519_key"
    ssh-keygen -q -t rsa -b 4096 -N '' -f "$HOSTKEY_DIR/ssh_host_rsa_key"
fi
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key
chmod 644 "$HOSTKEY_DIR"/ssh_host_*_key.pub

note "host key fingerprints -- pin these on the client:"
for k in "$HOSTKEY_DIR"/ssh_host_*_key.pub; do
    ssh-keygen -lf "$k" | sed 's/^/entrypoint:   /' >&2
done

# --- tree ownership sanity ------------------------------------------------
# A UID mismatch on a bind-mounted tree makes it unwritable, which surfaces
# much later as a confusing build error.
if [ -d /aosp ] && ! su "$BUILDER_USER" -s /bin/sh -c 'test -w /aosp'; then
    note "WARNING: /aosp is not writable by $BUILDER_USER (uid $(id -u "$BUILDER_USER"))."
    note "         Rebuild with --build-arg BUILDER_UID=<owner uid of the host dir>."
fi

mkdir -p /run/sshd
/usr/sbin/sshd -t -f "$SSHD_CONFIG" || die "sshd config rejected"
note "starting sshd"
exec /usr/sbin/sshd -D -e -f "$SSHD_CONFIG"
