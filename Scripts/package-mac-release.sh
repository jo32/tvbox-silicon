#!/bin/bash
# Build, sign, notarize and package the macOS app.
#   Scripts/package-mac-release.sh [--identity "Developer ID Application: …"] [--notary-profile <name>] [--skip-build]
# Without --notary-profile the app is signed but not notarized (local testing only).
# Output: build/release-mac/<version>/Yingxia-<version>-macos-arm64.{dmg,zip} + SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application"
PROFILE=""
BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    --skip-build) BUILD=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

DERIVED=build/DerivedData-mac-release
APP_BUILT="$DERIVED/Build/Products/Release/TVBox-macOS.app"
if [ "$BUILD" = 1 ]; then
  for h in JavaHost ScriptHost PythonHost; do test -d "build/$h" || { echo "missing build/$h; run Scripts/build-*-host.sh" >&2; exit 1; }; done
  xcodegen generate >/dev/null
  xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Release -derivedDataPath "$DERIVED" \
    ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build | tail -3
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUILT/Contents/Info.plist")
OUT="build/release-mac/$VERSION"
STAGE="$OUT/stage"
rm -rf "$OUT"; mkdir -p "$STAGE"
APP="$STAGE/Yingxia.app"
ditto "$APP_BUILT" "$APP"
rm -rf "$APP/Contents/Resources/PythonHost/__pycache__"
find "$APP/Contents/Resources" -name __pycache__ -type d -prune -exec rm -rf {} +

HOST_ENT=Config/macOS/Hosts.entitlements
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Native libraries packed inside jars (JNA, unidbg, ...) must be signed too, or notarization fails.
JARTMP=$(mktemp -d)
while IFS= read -r -d '' jar; do
  entries=$(unzip -Z1 "$jar" | grep -E '\.(dylib|jnilib)$' || true)
  [ -n "$entries" ] || continue
  rm -rf "$JARTMP"/*; jar_abs=$(cd "$(dirname "$jar")" && pwd)/$(basename "$jar")
  while IFS= read -r e; do
    unzip -q -o "$jar" "$e" -d "$JARTMP"
    file -b "$JARTMP/$e" | grep -q '^Mach-O' || continue
    sign "$JARTMP/$e"
    (cd "$JARTMP" && zip -q "$jar_abs" "$e")
  done <<< "$entries"
  echo "signed natives in $(basename "$jar")"
done < <(find "$APP/Contents/Resources" -name '*.jar' -print0)
rm -rf "$JARTMP"

# Inside-out: every Mach-O in the bundle except the main executable.
MAIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
count=0
while IFS= read -r -d '' f; do
  [ "$f" = "$MAIN" ] && continue
  file -b "$f" | grep -q '^Mach-O' || continue
  if [ -x "$f" ] && file -b "$f" | grep -q executable; then sign --entitlements "$HOST_ENT" "$f"; else sign "$f"; fi
  count=$((count + 1))
done < <(find "$APP/Contents" -type f -print0)
echo "signed $count nested binaries"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

ZIP="$OUT/Yingxia-$VERSION-macos-arm64.zip"
DMG="$OUT/Yingxia-$VERSION-macos-arm64.dmg"
if [ -n "$PROFILE" ]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Yingxia $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
sign "$DMG"
if [ -n "$PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tail -2
  spctl -a -t exec -vv "$APP" 2>&1 | tail -2
fi
(cd "$OUT" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt)
rm -rf "$STAGE"
echo "$OUT"; ls -lh "$OUT"
