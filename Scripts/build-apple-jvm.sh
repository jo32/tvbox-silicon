#!/bin/bash
# Phase 1 build, not a claim of production readiness. See the plan's go/no-go gates.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$ROOT/build/apple-runtime"
SOURCE="$WORK/openjdk-mobile"
REVISION=c1ed06aaef34c8dccf71e236d1ffa20918a77cfb
BOOT="$WORK/boot-jdk/jdk-26.0.2.1+1/Contents/Home"
TARGET="${1:-ios}"
case "$TARGET" in
  ios) SDK=iphoneos; CONF=ios-aarch64-zero-release; MINIMUM=-miphoneos-version-min=17.0 ;;
  ios-simulator) SDK=iphonesimulator; CONF=ios-aarch64-zero-simulator; MINIMUM=-mios-simulator-version-min=17.0 ;;
  tvos) SDK=appletvos; CONF=tvos-aarch64-zero-release; MINIMUM=-mtvos-version-min=17.0 ;;
  tvos-simulator) SDK=appletvsimulator; CONF=tvos-aarch64-zero-simulator; MINIMUM=-mtvos-simulator-version-min=17.0 ;;
  *) echo "Usage: $0 [ios|ios-simulator|tvos|tvos-simulator]" >&2; exit 2 ;;
esac
mkdir -p "$WORK"
fetch() {
  local url="$1" destination="$2" digest="$3"
  if [ ! -f "$destination" ]; then
    curl -fL --retry 2 "$url" -o "$destination.download"
    mv "$destination.download" "$destination"
  fi
  echo "$digest  $destination" | shasum -a 256 -c -
}
if [ ! -x "$BOOT/bin/java" ]; then
  fetch 'https://github.com/adoptium/temurin26-binaries/releases/download/jdk-26.0.2.1%2B1/OpenJDK26U-jdk_aarch64_mac_hotspot_26.0.2.1_1.tar.gz' \
    "$WORK/boot-jdk.tar.gz" 8c77a069a150c5b1c80280269ba062463053ebb7619ddef38dcfe3921fc60bdd
  mkdir -p "$WORK/boot-jdk"
  tar -xzf "$WORK/boot-jdk.tar.gz" -C "$WORK/boot-jdk"
fi
fetch https://download2.gluonhq.com/mobile/mobile-support-20250106.zip \
  "$WORK/mobile-support.zip" 5793dd8700612fe0c5a1cbbfb280464167aea5944b3c01f32b340542976e9440
if [ ! -d "$WORK/support/support" ]; then unzip -q "$WORK/mobile-support.zip" -d "$WORK/support"; fi
if [ ! -d "$SOURCE/.git" ]; then git clone --depth 1 https://github.com/openjdk/mobile.git "$SOURCE"; fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$REVISION" ]; then
  git -C "$SOURCE" fetch origin "$REVISION"
  git -C "$SOURCE" checkout --detach "$REVISION"
fi
PATCH="$ROOT/Runtime/AppleRuntime/patches/openjdk-apple-zero.patch"
if git -C "$SOURCE" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PATCH"
else
  git -C "$SOURCE" apply --reverse --check "$PATCH"
fi
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
SUPPORT="$WORK/support/support"
# Device SDK libffi stubs are not sufficient for the static JVM. Build for the
# exact platform: arm64 device and simulator archives are not interchangeable.
"$ROOT/Scripts/build-apple-libffi.sh" "$TARGET"
FFI="$WORK/libffi-$TARGET-3.4.8/install"
cd "$SOURCE"
sh configure --with-conf-name="$CONF" --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios --with-jvm-variants=zero --with-boot-jdk="$BOOT" \
  --with-libffi-include="$FFI/include" --with-libffi-lib="$FFI/lib" \
  --with-cups-include="$SUPPORT/cups-2.3.6" --with-sysroot="$SYSROOT" \
  --with-extra-cflags="$MINIMUM" --with-extra-cxxflags="$MINIMUM" --with-extra-ldflags="$MINIMUM"
# Keep java-only targets separate: OpenJDK otherwise skips native prerequisites
# for the entire make invocation, including static-libs-image.
make CONF="$CONF" JOBS="${JOBS:-4}" hotspot-static-libs java.base-static-libs java.management-static-libs
make CONF="$CONF" JOBS="${JOBS:-4}" java.management-java java.logging-java java.naming-java java.security.sasl-java java.xml-java jdk.httpserver-java jdk.zipfs-java jdk.unsupported-java
make CONF="$CONF" static-libs-image-only
test -f "$SOURCE/build/$CONF/images/static-libs/lib/zero/libjvm.a"
echo "Zero static libraries: $SOURCE/build/$CONF/images/static-libs/lib"
echo "Exploded module classes: $SOURCE/build/$CONF/jdk/modules"
