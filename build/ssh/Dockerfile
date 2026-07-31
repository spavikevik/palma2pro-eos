# AOSP build environment, reachable over SSH.
#
# Purpose: soong's analysis pass needs ~36 GB of working set (measured -- see
# docs/04-build-env.md). The 16 GB dev Mac cannot back that, so the build moves
# to a bigger machine and we drive it over SSH.
#
# Deliberately self-contained rather than `FROM aosp-build`: it gets built on a
# host that has never seen this project, so it cannot depend on a local base
# image. The toolchain half below intentionally mirrors ../Containerfile -- keep
# them in step.
#
# SECURITY MODEL
#
#   * No secrets in the image. Authorised keys are bind-mounted read-only at
#     runtime. Anything baked in would persist in the layer history and leak on
#     any registry push.
#   * Fails closed. The entrypoint refuses to start sshd unless it has a
#     non-empty authorized_keys AND an explicit host allow-list.
#   * Keys only. Passwords, empty passwords, keyboard-interactive and root login
#     are all disabled.
#   * Host restriction is enforced twice, independently: sshd's `AllowUsers
#     builder@<pattern>` and `from="..."` in authorized_keys. Neither is a single
#     point of failure.
#   * No forwarding. TCP/agent/X11/tunnel forwarding are off, so a stolen key
#     cannot be used to pivot into the build host's network.
#   * Unprivileged. Builds run as `builder`; no sudo is installed.
#
# BUILD
#   docker build -t aosp-ssh --build-arg BUILDER_UID=$(id -u) build/ssh
#
# RUN -- see docs/05-remote-build.md for the full invocation.

FROM --platform=linux/amd64 docker.io/library/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# --- AOSP toolchain (mirrors ../Containerfile) ------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs gnupg flex bison build-essential zip curl zlib1g-dev \
      libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
      libxml2-utils xsltproc unzip fontconfig python3 python3-pip python-is-python3 \
      openjdk-17-jdk ccache rsync lzop bc kmod cpio libssl-dev \
      ca-certificates procps file less nano \
      openssh-server tini \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
    && chmod +x /usr/local/bin/repo

# --- Build tuning ----------------------------------------------------------
# NO memory caps here, deliberately.
#
# The 16 GB laptop needed NINJA_HIGHMEM_NUM_JOBS=2 and _JAVA_OPTIONS=-Xmx4g to
# survive at all. This host has 46 GB and 16 cores, where both are actively
# harmful: NINJA_HIGHMEM_NUM_JOBS serialises the linker/R8/D8 pool that could
# now run wide, and a global _JAVA_OPTIONS imposes the same ceiling on every JVM
# the build spawns (javac, turbine, d8, r8, metalava) regardless of what each
# actually needs. Soong sizes those pools from available RAM on its own, and its
# defaults are right when the RAM is genuinely there.
#
# If this image is ever run on a small machine again, cap it at runtime:
#   -e NINJA_HIGHMEM_NUM_JOBS=2 -e _JAVA_OPTIONS=-Xmx4g
#
# ccache stays: it costs disk, not RAM, and repeat builds are inevitable.
ENV USE_CCACHE=1 \
    CCACHE_DIR=/aosp/.ccache \
    CCACHE_EXEC=/usr/bin/ccache \
    CCACHE_MAXSIZE=50G \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# Docker ENV above is NOT enough on its own: it populates PID 1's environment,
# and sshd constructs a fresh environment for each session (and with UsePAM no it
# does not read /etc/environment). Verified: LANG and USE_CCACHE were unset in
# both login and non-login SSH shells, so ccache was silently inactive. A
# profile.d snippet is what actually reaches a login shell, which is what
# `bash -lc` in scripts/builder.sh uses.
RUN printf '%s\n' \
      'export USE_CCACHE=1' \
      'export CCACHE_DIR=/aosp/.ccache' \
      'export CCACHE_EXEC=/usr/bin/ccache' \
      'export CCACHE_MAXSIZE=50G' \
      'export LC_ALL=C.UTF-8' \
      'export LANG=C.UTF-8' \
    > /etc/profile.d/aosp-build.sh \
    && chmod 644 /etc/profile.d/aosp-build.sh

# --- Unprivileged build user ----------------------------------------------
# UID/GID are build args so they can match the host owner of the bind-mounted
# tree; a mismatch means every file in /aosp is unwritable.
ARG BUILDER_UID=1000
ARG BUILDER_GID=1000
#
# `-p '*'` is load-bearing. useradd with no password writes `!` into
# /etc/shadow, and sshd with `UsePAM no` treats `!` as a LOCKED account and
# rejects the login before it ever looks at the key:
#     User builder not allowed because account is locked
# `*` means "no password can ever match" without marking the account locked, so
# public-key auth works and password auth remains impossible.
RUN groupadd -g "${BUILDER_GID}" builder \
    && useradd -m -u "${BUILDER_UID}" -g "${BUILDER_GID}" -s /bin/bash -p '*' builder \
    && mkdir -p /aosp /keys /etc/ssh/hostkeys \
    && chown builder:builder /aosp \
    && chmod 700 /etc/ssh/hostkeys

# --- sshd ------------------------------------------------------------------
# Written as a file rather than sed-patched so the effective policy is
# reviewable in one place.
RUN rm -f /etc/ssh/ssh_host_*_key* /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
COPY sshd_config /etc/ssh/sshd_config
RUN chmod 644 /etc/ssh/sshd_config && mkdir -p /run/sshd && chmod 755 /run/sshd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22
WORKDIR /aosp

# tini reaps zombies -- soong leaves them behind, and we spent real time on a
# zombie soong_build holding 25 GB of swap on the previous host.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
