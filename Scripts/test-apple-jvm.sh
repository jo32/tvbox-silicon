#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TARGET="${1:-ios-simulator}"
case "$TARGET" in
  ios-simulator) SDK=iphonesimulator; CONF=ios-aarch64-zero-simulator; TRIPLE=arm64-apple-ios17.0-simulator; FAMILY=1 ;;
  tvos-simulator) SDK=appletvsimulator; CONF=tvos-aarch64-zero-simulator; TRIPLE=arm64-apple-tvos17.0-simulator; FAMILY=3 ;;
  *) echo "Usage: $0 [ios-simulator|tvos-simulator]" >&2; exit 2 ;;
esac
JDK="$ROOT/build/apple-runtime/openjdk-mobile/build/$CONF"
BOOT="$ROOT/build/apple-runtime/boot-jdk/jdk-26.0.2.1+1/Contents/Home"
LIB="$JDK/images/static-libs/lib"
APP="$ROOT/build/apple-runtime/RuntimeSpike-$TARGET.app"
test -f "$LIB/zero/libjvm.a"
FFI="$ROOT/build/apple-runtime/libffi-$TARGET-3.4.8/install/lib/libffi.a"
if [ ! -f "$FFI" ]; then "$ROOT/Scripts/build-apple-libffi.sh" "$TARGET"; fi
mkdir -p "$APP/lib/modules" "$APP/lib/lib/security" "$APP/lib/conf/security" "$APP/spike"
# Optional third argument: comma-separated classes for isolated cold/warm timing.
if [ "$#" -ge 3 ]; then
  printf '%s' "$3" > "$APP/spike/benchmark-classes.txt"
else
  rm -f "$APP/spike/benchmark-classes.txt"
fi
if [ "$#" -ge 2 ]; then
  mkdir -p "$APP/host"
  cp "$2" "$APP/plugin.jar"
  cp build/JavaHost/host.jar build/JavaHost/lib/*.jar "$APP/host/"
else
  rm -f "$APP/plugin.jar"
fi
for module in java.base java.logging java.naming java.security.sasl java.xml jdk.zipfs jdk.httpserver jdk.unsupported; do
  test -d "$JDK/jdk/modules/$module"
  rsync -a --delete "$JDK/jdk/modules/$module/" "$APP/lib/modules/$module/"
done
# The build's static-libs target does not assemble a runtime image. Supply the
# ordinary JDK configuration and trust store for this exploded-image spike.
cp "$BOOT/conf/security/java.security" "$APP/lib/conf/security/java.security"
rsync -a --delete "$BOOT/conf/security/policy/" "$APP/lib/conf/security/policy/"
cp "$BOOT/lib/security/cacerts" "$APP/lib/lib/security/cacerts"
cp "$BOOT/lib/tzdb.dat" "$APP/lib/lib/tzdb.dat"
"$BOOT/bin/javac" --release 17 -d "$APP/spike" Runtime/AppleRuntime/Spike/RuntimeSpike.java
LINK=(-Wl,-force_load,"$LIB/zero/libjvm.a")
for library in java net nio zip jimage verify; do LINK+=(-Wl,-force_load,"$LIB/lib$library.a"); done
xcrun --sdk "$SDK" clang++ -target "$TRIPLE" -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" \
  -fobjc-arc -I "$BOOT/include" -I "$BOOT/include/darwin" Runtime/AppleRuntime/Spike/main.m \
  "${LINK[@]}" "$FFI" -lz -liconv -framework UIKit -framework Foundation -framework Security -framework CoreGraphics \
  -Wl,-export_dynamic -o "$APP/RuntimeSpike"
python3 - "$APP" "$FAMILY" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = dict(CFBundleIdentifier='com.tvbox.yingxia.RuntimeSpike', CFBundleExecutable='RuntimeSpike',
            CFBundleName='Runtime Spike', CFBundleVersion='1', CFBundleShortVersionString='1.0',
            CFBundlePackageType='APPL', MinimumOSVersion='17.0', UIDeviceFamily=[int(sys.argv[2])],
            UILaunchScreen={}, UIApplicationSceneManifest={
                'UIApplicationSupportsMultipleScenes': False,
                'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                    'UISceneConfigurationName': 'Runtime', 'UISceneDelegateClassName': 'SpikeSceneDelegate'
                }]}
            })
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
echo "Built spike app: $APP"
echo 'Install with simctl on the corresponding simulator; inspect Library/Caches/jvm.log and result.txt.'
