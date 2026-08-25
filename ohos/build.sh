#!/usr/bin/env bash
# Cross-compile OpenSSL static libs for OpenHarmony/HarmonyOS (CrossPaste
# harmony pairing v3 SPAKE2 backend): ohos-arm64 (devices) + ohos-x64
# (emulator). Runs on a Linux host.
#
# OpenSSL has no ohos Configure target, so this drives the asm-enabled generic
# linux-aarch64 / linux-x86_64 targets with the OpenHarmony NDK clang
# (--target=<arch>-linux-ohos + NDK sysroot). NEVER use linux-generic64: it
# silently drops all assembly, including the ecp_nistz256 constant-time P-256
# implementation this supply chain exists to provide (the exact defect the
# pinned conan-center-index fork fixes for Android/iOS). Every build therefore
# hard-fails unless ecp_nistz256 + OPENSSL_armcap/ia32cap markers are present
# in the produced libcrypto.a.
#
# Output layout matches the conan jobs so the aggregate job merges it as-is:
#   build/openssl3/ohos-arm64/{lib,include}
#   build/openssl3/ohos-x64/{lib,include}
set -euo pipefail

VERSION="${1:?usage: ohos/build.sh <openssl-version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/ohos-work"
OUT="$ROOT/build/openssl3"
mkdir -p "$WORK" "$OUT"

# --- OpenHarmony SDK (public Linux tarball from the official mirror, pinned) --
# 6.1-Release ships native-linux-x64-6.1.0.31-Release.zip — a Release-stamped
# NDK (6.0-Release actually contains a Beta1-stamped build; never build this
# supply chain with a beta toolchain) and the public equivalent of the
# HarmonyOS 6.1.1 NDK the consuming app's spike verified on device. The sha256
# is pinned here (not fetched from the mirror's sidecar file) so a mirror-side
# change can never go unnoticed.
OHOS_SDK_RELEASE="6.1-Release"
OHOS_SDK_URL="https://repo.huaweicloud.com/openharmony/os/${OHOS_SDK_RELEASE}/ohos-sdk-windows_linux-public.tar.gz"
OHOS_SDK_SHA256="b833b75a64ee46bbd7880921abbb49b733ec5c8171b6684c9b524d57f624cee0"

if [ ! -d "$WORK/ndk" ]; then
  echo "== downloading OpenHarmony SDK ${OHOS_SDK_RELEASE} =="
  curl -fL --retry 3 -o "$WORK/ohos-sdk.tar.gz" "$OHOS_SDK_URL"
  echo "${OHOS_SDK_SHA256}  $WORK/ohos-sdk.tar.gz" | sha256sum --check
  # Only the Linux native (NDK) zip is needed out of the combined archive.
  # Archive layout varies by release (6.0 has linux/ at the top level, others
  # wrap it in ohos-sdk/), so match the member by wildcard and locate the zip.
  mkdir -p "$WORK/sdk-tar"
  tar -xzf "$WORK/ohos-sdk.tar.gz" -C "$WORK/sdk-tar" --wildcards '*linux/native-*.zip'
  unzip -q "$(find "$WORK/sdk-tar" -name 'native-*.zip' | head -1)" -d "$WORK/ndk-extract"
  mv "$(dirname "$(find "$WORK/ndk-extract" -maxdepth 3 -type d -name llvm | head -1)")" "$WORK/ndk"
  rm -rf "$WORK/ohos-sdk.tar.gz" "$WORK/sdk-tar" "$WORK/ndk-extract"
fi
NDK="$WORK/ndk"
"$NDK/llvm/bin/clang" --version

# --- OpenSSL sources: same pin as every conan platform (vendored conandata) --
read -r SRC_URL SRC_SHA256 < <(python3 - "$VERSION" "$ROOT/conan-center-index/recipes/openssl/3.x.x/conandata.yml" <<'PY'
import re, sys
version, path = sys.argv[1], sys.argv[2]
text = open(path).read()
# conandata.yml sources block: `  "3.6.3":` or `  3.6.3:` followed by url/sha256.
pattern = (r'^  "?' + re.escape(version) + r'"?:.*?'
           r'url:\s*"?([^"\s]+)"?.*?sha256:\s*"?([0-9a-f]{64})"?')
m = re.search(pattern, text, re.S | re.M)
if not m:
    sys.exit(f"no sources entry for {version} in {path}")
print(m.group(1), m.group(2))
PY
)
echo "== OpenSSL $VERSION source: $SRC_URL =="
curl -fL --retry 3 -o "$WORK/openssl-$VERSION.tar.gz" "$SRC_URL"
echo "$SRC_SHA256  $WORK/openssl-$VERSION.tar.gz" | sha256sum --check
tar -xzf "$WORK/openssl-$VERSION.tar.gz" -C "$WORK"
SRC="$WORK/openssl-$VERSION"

build_one() { # $1 = profile name, $2 = ohos triple, $3 = openssl target
  local profile="$1" triple="$2" target="$3"
  local bld="$WORK/build-$profile" stage="$OUT/$profile"
  echo "== building $profile ($target, $triple) =="
  rm -rf "$bld" && mkdir -p "$bld"
  (
    cd "$bld"
    export CC="$NDK/llvm/bin/clang --target=$triple --sysroot=$NDK/sysroot"
    export AR="$NDK/llvm/bin/llvm-ar"
    export RANLIB="$NDK/llvm/bin/llvm-ranlib"
    perl "$SRC/Configure" "$target" no-shared no-tests no-apps no-docs \
      -ffunction-sections -fdata-sections --prefix=/ --libdir=lib
    make -s build_generated
    make -s -j"$(nproc)" build_libs
    make -s DESTDIR="$stage" install_dev
  )
}

verify_asm() { # $1 = profile name, $2 = cap symbol (OPENSSL_armcap|OPENSSL_ia32cap)
  local lib="$OUT/$1/lib/libcrypto.a" nm="$NDK/llvm/bin/llvm-nm"
  local nistz cap
  nistz=$("$nm" "$lib" 2>/dev/null | grep -c ecp_nistz256 || true)
  cap=$("$nm" "$lib" 2>/dev/null | grep -c "$2" || true)
  echo "== asm markers $1: ecp_nistz256=$nistz $2=$cap =="
  if [ "$nistz" -eq 0 ] || [ "$cap" -eq 0 ]; then
    echo "FATAL: $1 libcrypto.a has no constant-time P-256 assembly markers" >&2
    echo "(a linux-generic target or broken asm probe produced a no-asm build)" >&2
    exit 1
  fi
  grep -q "OpenSSL $VERSION" "$lib" ||
    { echo "FATAL: $1 libcrypto.a lacks the OpenSSL $VERSION version string" >&2; exit 1; }
}

build_one ohos-arm64 aarch64-linux-ohos linux-aarch64
build_one ohos-x64 x86_64-linux-ohos linux-x86_64
verify_asm ohos-arm64 OPENSSL_armcap
verify_asm ohos-x64 OPENSSL_ia32cap

echo "== done =="
ls -l "$OUT"/ohos-*/lib
