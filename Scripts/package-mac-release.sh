#!/bin/bash
# Build, sign, notarize and package the macOS app.
#   Scripts/package-mac-release.sh [--identity "Developer ID Application: …"] [--notary-profile <name>] [--skip-build]
#   Scripts/package-mac-release.sh ... --notary-key <AuthKey_ID.p8> --notary-key-id <ID> --notary-issuer <issuer UUID>
#   Scripts/package-mac-release.sh ... --profile <Developer ID .provisionprofile>
# --profile turns on iCloud sync (Sources/TVCore/CloudSync.swift): it embeds the profile and gives the app the key-value
# store of Config/iCloud.entitlements, the one the iPhone, iPad and Apple TV apps use. The profile must be a Developer
# ID profile for com.jo32.yingxia.mac with iCloud. Without it the app has no entitlements and sync stays on this Mac.
# Without a notary profile or key the app is signed but not notarized (local testing only). A keychain
# profile only works while the screen is unlocked (data-protection keychain); an App Store Connect API
# key is a file, so it also works with the screen locked.
# Output: build/release-mac/<version>/Yingxia-<version>-macos-{arm64,x86_64}.dmg + SHA256SUMS.txt (DMG only since
# 1.7.4; the app inside is notarized and stapled too, so it also passes Gatekeeper once copied out)
# Then Scripts/make-appcast.sh <version> adds the DMGs to the appcasts the app updates itself from.
# One universal build (spider hosts from Scripts/build-universal-hosts.sh) is thinned into an Apple silicon and an
# Intel package, so each download carries only its own architecture.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application"
NOTARY=()
BUILD=1
PROFILE=
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) NOTARY+=(--keychain-profile "$2"); shift 2 ;;
    --notary-key) NOTARY+=(--key "$2"); shift 2 ;;
    --notary-key-id) NOTARY+=(--key-id "$2"); shift 2 ;;
    --notary-issuer) NOTARY+=(--issuer "$2"); shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --skip-build) BUILD=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

DERIVED=build/DerivedData-mac-release
APP_BUILT="$DERIVED/Build/Products/Release/TVBox-macOS.app"
if [ "$BUILD" = 1 ]; then
  for h in JavaHost ScriptHost PythonHost; do test -d "build/$h" || { echo "missing build/$h; run Scripts/build-*-host.sh" >&2; exit 1; }; done
  Scripts/build-universal-hosts.sh
  Scripts/build-apple-ffmpeg.sh
  xcodegen generate >/dev/null
  xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS -configuration Release -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build | tail -3
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUILT/Contents/Info.plist")
OUT="build/release-mac/$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT"
# Kept (not uploaded) to turn crash reports' binary offsets into code lines: Scripts/error-reports.py.
# The dSYM holds both architectures.
mkdir -p "$OUT/dSYMs"; ditto "$APP_BUILT.dSYM" "$OUT/dSYMs/$(basename "$APP_BUILT").dSYM"
UNIVERSAL="$OUT/universal/Yingxia.app"
ditto "$APP_BUILT" "$UNIVERSAL"
# Xcode copied the build machine's arm64 hosts; swap in the universal ones.
for h in JavaHost ScriptHost PythonHost; do
  test -d "build/universal/$h" || { echo "missing build/universal/$h; run Scripts/build-universal-hosts.sh" >&2; exit 1; }
  rm -rf "$UNIVERSAL/Contents/Resources/$h"; ditto "build/universal/$h" "$UNIVERSAL/Contents/Resources/$h"
done
find "$UNIVERSAL/Contents/Resources" -name __pycache__ -type d -prune -exec rm -rf {} +

HOST_ENT=Config/macOS/Hosts.entitlements
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$UNIVERSAL/Contents/Info.plist")

# The app's own entitlements. A restricted one (iCloud) without a matching embedded profile stops the app from
# launching, so check the profile before using it.
APP_SIGN=()
if [ -n "$PROFILE" ]; then
  PROFILE_PLIST="$OUT/profile.plist"; APP_ENT="$OUT/app.entitlements"
  security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
  pb() { /usr/libexec/PlistBuddy -c "Print $1" "$2" 2>/dev/null || true; }
  TEAM=$(pb ':TeamIdentifier:0' "$PROFILE_PLIST")
  BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$UNIVERSAL/Contents/Info.plist")
  KVS=$(pb ':com.apple.developer.ubiquity-kvstore-identifier' Config/iCloud.entitlements)
  KVS=${KVS/\$\(TeamIdentifierPrefix\)/$TEAM.}
  ALLOWED_KVS=$(pb ':Entitlements:com.apple.developer.ubiquity-kvstore-identifier' "$PROFILE_PLIST")
  problems=()
  APP_ID=$(pb ':Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")
  [ "${APP_ID:-$(pb ':Entitlements:application-identifier' "$PROFILE_PLIST")}" = "$TEAM.$BUNDLE" ] || problems+=("not for $BUNDLE")
  [ "$(pb ':ProvisionsAllDevices' "$PROFILE_PLIST")" = true ] || problems+=("not a Developer ID profile")
  [[ -n $ALLOWED_KVS && $KVS == $ALLOWED_KVS ]] || problems+=("no iCloud key-value storage for $KVS (allows '$ALLOWED_KVS')")
  EXPIRES=$(plutil -extract ExpirationDate raw "$PROFILE_PLIST" 2>/dev/null || true)
  [ "$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$EXPIRES" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ] || problems+=("expired ($EXPIRES)")
  # The signing certificate must be one of the profile's.
  CERT_SHA=$(security find-certificate -Z -c "$IDENTITY" | awk '/SHA-1/{print $3; exit}')
  in_profile=0; i=0
  while der=$(plutil -extract "DeveloperCertificates.$i" raw "$PROFILE_PLIST" 2>/dev/null); do
    sha=$(echo "$der" | base64 -D | openssl x509 -inform der -noout -fingerprint -sha1 2>/dev/null | tr -d : | cut -d= -f2)
    [ "$sha" = "$CERT_SHA" ] && in_profile=1; i=$((i + 1))
  done
  [ "$in_profile" = 1 ] || problems+=("signing certificate '$IDENTITY' is not in it")
  if [ ${#problems[@]} -gt 0 ]; then echo "profile $PROFILE:" >&2; printf '  %s\n' "${problems[@]}" >&2; exit 1; fi
  cat > "$APP_ENT" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>$TEAM.$BUNDLE</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM</string>
	<key>com.apple.developer.ubiquity-kvstore-identifier</key>
	<string>$KVS</string>
</dict>
</plist>
ENT
  cp "$PROFILE" "$UNIVERSAL/Contents/embedded.provisionprofile"
  APP_SIGN=(--entitlements "$APP_ENT")
  echo "iCloud sync on: $KVS"
fi

for ARCH in arm64 x86_64; do
  STAGE="$OUT/stage-$ARCH"
  APP="$STAGE/Yingxia.app"
  mkdir -p "$STAGE"; ditto "$UNIVERSAL" "$APP"
  # Thin every Mach-O to this architecture. arm64 drops the x86_64-only extras of the x86_64 wheels
  # (pycryptodome's AES-NI modules); anything else without the architecture is a broken merge.
  dropped=0
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q '^Mach-O' || continue
    archs=" $(lipo -archs "$f") "
    if [[ $archs != *" $ARCH "* ]]; then
      if [ "$ARCH" = x86_64 ] || [ "$archs" != " x86_64 " ] || [ "$f" = "$APP/Contents/MacOS/$EXECUTABLE" ]; then
        echo "no $ARCH slice:$archs${f#"$APP/"}" >&2; exit 1
      fi
      echo "$ARCH: dropping${archs}${f#"$APP/"}"; rm "$f"; dropped=$((dropped + 1))
    elif [ "$archs" != " $ARCH " ]; then
      lipo "$f" -thin "$ARCH" -output "$f.thin" && chmod "$(stat -f %Lp "$f")" "$f.thin" && mv -f "$f.thin" "$f"
    fi
  done < <(find "$APP/Contents" -type f -print0)
  echo "$ARCH: thinned, $dropped files dropped"

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
  done < <(find "$APP/Contents/Resources" -name '*.jar' -print0)
  rm -rf "$JARTMP"

  # Sparkle's helpers are bundles of their own: signed as Sparkle documents, after everything else and without the
  # hosts' JIT entitlements. Its XPC services are only for sandboxed apps, so they go.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

  # Inside-out: every Mach-O in the bundle except the main executable.
  count=0
  while IFS= read -r -d '' f; do
    [ "$f" = "$APP/Contents/MacOS/$EXECUTABLE" ] && continue
    [[ $f == "$SPARKLE"/* ]] && continue
    file -b "$f" | grep -q '^Mach-O' || continue
    if [ -x "$f" ] && file -b "$f" | grep -q executable; then sign --entitlements "$HOST_ENT" "$f"; else sign "$f"; fi
    count=$((count + 1))
  done < <(find "$APP/Contents" -type f -print0)
  echo "$ARCH: signed $count nested binaries"
  test -d "$SPARKLE" || { echo "missing Sparkle.framework" >&2; exit 1; }
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
  sign ${APP_SIGN[@]+"${APP_SIGN[@]}"} "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
  if [ -n "$PROFILE" ]; then
    codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "$KVS" || { echo "$ARCH: the app lacks the iCloud entitlement" >&2; exit 1; }
  fi

  DMG="$OUT/Yingxia-$VERSION-macos-$ARCH.dmg"
  if [ ${#NOTARY[@]} -gt 0 ]; then
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY[@]}" --wait
    rm "$OUT/notarize.zip"
    xcrun stapler staple "$APP"
  fi
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Yingxia $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  sign "$DMG"
  if [ ${#NOTARY[@]} -gt 0 ]; then
    xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tail -2
    spctl -a -t exec -vv "$APP" 2>&1 | tail -2
  fi
  rm -rf "$STAGE"
done
rm -rf "$OUT/universal" "$OUT/profile.plist" "$OUT/app.entitlements"
(cd "$OUT" && shasum -a 256 *.dmg > SHA256SUMS.txt)
echo "$OUT"; ls -lh "$OUT"
