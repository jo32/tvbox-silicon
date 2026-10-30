#!/bin/bash
# Uploads the iPhone/iPad and Apple TV apps to TestFlight and hands them to the public testers.
# Run from the repository root as part of every release, after the release build (same tree, same Java host):
#
#   Scripts/testflight-upload.sh <build> [--no-upload]
#
# <build> is the release's CURRENT_PROJECT_VERSION (e.g. 28); each upload needs a build number App Store
# Connect hasn't seen for that version. The version stays at TESTFLIGHT_VERSION (1.7.7) whatever the release
# is called: 1.7.7's first build passed Beta App Review, and later builds of an approved version usually
# reach external testers without another full review (Apple can still ask for one). A new version number
# means a full review again. The public links belong to the "Cloud Drive Browsing" groups, so they don't change.
#
# Builds with the APPSTORE flag (no software update, What's New, or extras before a subscription is added),
# signs with Apple Distribution and the "Yingxia iOS/tvOS App Store" profiles, uploads with altool, then runs
# Scripts/testflight-publish.py: wait for processing, copy What to Test, add to the group, submit for review.
# --no-upload stops after the export (to check the archives). Output: build/testflight/<version>-<build>/.
# ICLOUD=1 signs in iCloud key-value storage (Config/iCloud.entitlements, for iCloud sync); the App IDs and the
# App Store profiles must have the iCloud capability first, or the export fails.
set -euo pipefail

TESTFLIGHT_VERSION=${TESTFLIGHT_VERSION:-1.7.7}
BUILD=${1:?usage: Scripts/testflight-upload.sh <build> [--no-upload]}
UPLOAD=1
[ "${2:-}" = "--no-upload" ] && UPLOAD=0
[[ $BUILD =~ ^[0-9]+$ ]] || { echo "build must be a number: $BUILD" >&2; exit 1; }

TEAM=WWNM49L69R
DISTRIBUTION=8871E484354649A0272A1FD042C4EBDAF5989C28 # Apple Distribution: Dailin Jiang
KEY_ID=JFADGLA7XZ
ISSUER=cc097225-575e-4c18-837b-b44d6f57024f
KEY=$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
OUT=build/testflight/$TESTFLIGHT_VERSION-$BUILD
[ -f "$KEY" ] || { echo "missing App Store Connect key $KEY" >&2; exit 1; }
# Xcode builds the working tree: refuse uncommitted changes (another session's edits) unless ALLOW_DIRTY=1.
if [ -n "$(git status --porcelain --untracked-files=no)" ] && [ "${ALLOW_DIRTY:-}" != 1 ]; then
  git status --short --untracked-files=no >&2
  echo "uncommitted changes would be uploaded; commit them or set ALLOW_DIRTY=1" >&2
  exit 1
fi
mkdir -p "$OUT"
git rev-parse HEAD >"$OUT/commit.txt"

# Xcode embeds build/AppleRuntime/<platform>/Resources/JavaHost as it is (check-java-host.sh only catches an
# older converter), so rebuild the Java host from this checkout first.
echo "== Java host"
if ! { Scripts/build-java-host.sh && Scripts/sync-apple-javahost.sh iphoneos appletvos; } >"$OUT/java-host.log" 2>&1; then
  tail -20 "$OUT/java-host.log"
  exit 1
fi

echo "== FFmpeg"
Scripts/build-apple-ffmpeg.sh

for platform in iOS tvOS; do
  scheme=TVBox-$platform
  case $platform in
    iOS) bundle=com.jo32.yingxia.ios; profile="Yingxia iOS App Store"; type=ios ;;
    tvOS) bundle=com.jo32.yingxia.tv; profile="Yingxia tvOS App Store"; type=appletvos ;;
  esac
  archive=$OUT/$scheme.xcarchive

  echo "== $platform: archive $TESTFLIGHT_VERSION ($BUILD)"
  rm -rf "$archive"
  if ! xcodebuild archive -scheme "$scheme" -destination "generic/platform=$platform" \
      -derivedDataPath "build/testflight/DerivedData-$platform" -archivePath "$archive" \
      -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
      DEVELOPMENT_TEAM=$TEAM MARKETING_VERSION="$TESTFLIGHT_VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
      ${ICLOUD:+ICLOUD_ENTITLEMENTS=Config/iCloud.entitlements} \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) APPSTORE' >"$OUT/$platform-archive.log" 2>&1; then
    grep -E 'error:|BUILD FAILED|ARCHIVE FAILED' "$OUT/$platform-archive.log" | tail -20
    echo "archive failed, log: $OUT/$platform-archive.log" >&2
    exit 1
  fi

  # The version, build and bundle ID App Store Connect will see.
  info=$archive/Products/Applications/$scheme.app/Info.plist
  got="$(plutil -extract CFBundleIdentifier raw "$info") $(plutil -extract CFBundleShortVersionString raw "$info") $(plutil -extract CFBundleVersion raw "$info")"
  want="$bundle $TESTFLIGHT_VERSION $BUILD"
  [ "$got" = "$want" ] || { echo "archive is \"$got\", expected \"$want\"" >&2; exit 1; }
  # The embedded JVM finds JIMAGE_Open and the JNI_OnLoad_* functions with dlsym, so a binary stripped of its
  # global symbols crashes the first time a Java source starts (TestFlight 1.7.7, builds 25-27). STRIP_STYLE in
  # project.yml keeps them. No grep -q: with pipefail, nm would die of SIGPIPE when grep quit early.
  nm -gU "$archive/Products/Applications/$scheme.app/$scheme" | grep ' _JIMAGE_Open$' >/dev/null ||
    { echo "$scheme does not export JIMAGE_Open: its global symbols were stripped" >&2; exit 1; }

  echo "== $platform: export"
  cat >"$OUT/$platform-export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key><string>export</string>
	<key>method</key><string>app-store-connect</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>$DISTRIBUTION</string>
	<key>teamID</key><string>$TEAM</string>
	<key>provisioningProfiles</key><dict><key>$bundle</key><string>$profile</string></dict>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
  rm -rf "${OUT:?}/$platform"
  if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$OUT/$platform" \
      -exportOptionsPlist "$OUT/$platform-export.plist" >"$OUT/$platform-export.log" 2>&1; then
    tail -20 "$OUT/$platform-export.log"
    exit 1
  fi
  ipa=$OUT/$platform/$scheme.ipa
  echo "   $ipa ($(du -h "$ipa" | cut -f1))"

  if [ $UPLOAD = 1 ]; then
    echo "== $platform: upload"
    # The App Store app IDs (as in testflight-publish.py): without them altool guesses the bundle ID and can
    # pick an embedded Python module framework instead of the app. With --apple-id it also needs the bundle
    # ID and versions, or it assumes 1.0 (1).
    case $platform in iOS) apple_id=6825717102 ;; tvOS) apple_id=6825717931 ;; esac
    xcrun altool --upload-app --type "$type" -f "$ipa" --apple-id "$apple_id" \
      --bundle-id "$bundle" --bundle-version "$BUILD" --bundle-short-version-string "$TESTFLIGHT_VERSION" --apiKey "$KEY_ID" --apiIssuer "$ISSUER" >"$OUT/$platform-upload.log" 2>&1 || true
    grep -q "UPLOAD SUCCEEDED" "$OUT/$platform-upload.log" || { cat "$OUT/$platform-upload.log"; exit 1; }
  fi
done

[ $UPLOAD = 1 ] || { echo "exported only (--no-upload): $OUT"; exit 0; }

# Processing takes 5-30 minutes; then the build goes to the public group and Beta App Review.
uv run --quiet --with 'pyjwt[crypto]' --with requests Scripts/testflight-publish.py "$TESTFLIGHT_VERSION" "$BUILD" | tee "$OUT/publish.log"
