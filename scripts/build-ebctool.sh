#!/usr/bin/env bash
# Cross-compile ebctool for the Palma 2 Pro (aarch64 Android).
#
# Needs the Android NDK. Install one of:
#   brew install --cask android-ndk
#   or via Android Studio -> SDK Manager -> NDK (Side by side)
#
# API level: the device's vendor is API 30, but the tool only uses open/ioctl,
# so anything from 21 up is fine. 30 keeps it consistent with the platform.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/src/ebctool.c"
OUT="${REPO_ROOT}/out/ebctool"
API=30

find_ndk() {
  [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]] && { echo "$ANDROID_NDK_HOME"; return; }
  [[ -n "${ANDROID_NDK_ROOT:-}" && -d "${ANDROID_NDK_ROOT}" ]] && { echo "$ANDROID_NDK_ROOT"; return; }
  local c
  for c in "$HOME"/Library/Android/sdk/ndk/* \
           /opt/homebrew/share/android-ndk \
           /usr/local/share/android-ndk \
           /opt/android-ndk; do
    [[ -d "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

mkdir -p "${REPO_ROOT}/out"

# Preferred: zig. ebctool only calls open/ioctl/printf, so a statically linked
# musl aarch64 binary runs on Android without bionic -- it is just Linux
# syscalls. Zig's toolchain is ~100 MB against the NDK's ~2 GB.
if command -v zig >/dev/null; then
  echo ">>> Building with zig (static aarch64 musl)"
  zig cc -target aarch64-linux-musl -static \
      -Wall -Wextra -O2 -o "$OUT" "$SRC"
  echo ">>> Built: $OUT"
  file "$OUT" 2>/dev/null || true
  cat <<EOF

>>> Deploy (needs root on the device):

    adb push ${OUT} /data/local/tmp/ebctool
    adb shell chmod 755 /data/local/tmp/ebctool
    adb shell su -c '/data/local/tmp/ebctool info'
    adb shell su -c '/data/local/tmp/ebctool ident'
EOF
  exit 0
fi

NDK="$(find_ndk)" || {
  cat <<'EOF' >&2
No compiler found for aarch64 Android.

Easiest (~100 MB) -- zig cross-compiles C out of the box:
    brew install zig

Or the full Android NDK (~2 GB):
    brew install --cask android-ndk
    # or Android Studio -> SDK Manager -> SDK Tools -> NDK (Side by side)

Then re-run, or point at an NDK explicitly:
    ANDROID_NDK_HOME=/path/to/ndk scripts/build-ebctool.sh
EOF
  exit 1
}
echo ">>> NDK: $NDK"

HOST_TAG="darwin-x86_64"   # correct even on Apple Silicon; the NDK ships x86_64
                           # binaries that run under Rosetta, and newer NDKs
                           # provide universal ones under the same path.
[[ "$(uname -s)" == "Linux" ]] && HOST_TAG="linux-x86_64"

TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/${HOST_TAG}"
CC="${TOOLCHAIN}/bin/aarch64-linux-android${API}-clang"

[[ -x "$CC" ]] || {
  echo "Expected compiler not found: $CC" >&2
  echo "Available:" >&2
  ls "${TOOLCHAIN}/bin/" 2>/dev/null | grep 'aarch64.*clang$' | head >&2
  exit 1
}

mkdir -p "${REPO_ROOT}/out"
echo ">>> Building"
"$CC" -Wall -Wextra -O2 -static -o "$OUT" "$SRC"

echo ">>> Built: $OUT"
file "$OUT" 2>/dev/null || true

cat <<EOF

>>> Deploy (needs root on the device):

    adb push ${OUT} /data/local/tmp/ebctool
    adb shell chmod 755 /data/local/tmp/ebctool
    adb shell su -c '/data/local/tmp/ebctool info'
    adb shell su -c '/data/local/tmp/ebctool ident'

Both commands are read-only. If they fail with EACCES, check the SELinux label:

    adb shell ls -lZ /dev/ebc
    adb shell 'dmesg | grep avc | tail'
EOF
