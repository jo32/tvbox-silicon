#!/bin/bash
# Exercise the production player with isolated local media/history, without the user's app or iCloud account.
# Usage: Scripts/test-playback-history.sh macOS
#        Scripts/test-playback-history.sh iOS <iPhone or iPad simulator UUID>
#        Scripts/test-playback-history.sh tvOS <Apple TV simulator UUID>
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:?Expected macOS, iOS or tvOS}"
case "$PLATFORM" in
  macOS) DESTINATION='platform=macOS'; DEPLOYMENT=15.0 ;;
  iOS|tvOS) DESTINATION="platform=$PLATFORM Simulator,id=${2:?Expected simulator UUID}"; DEPLOYMENT=17.0 ;;
  *) echo "Unknown platform: $PLATFORM" >&2; exit 1 ;;
esac
OUT="build/PlaybackHistory-$PLATFORM"
MAC_DEPENDENCIES=''
MAC_ENTITLEMENTS=''
if [[ "$PLATFORM" == macOS ]]; then
  MAC_DEPENDENCIES=$'      - package: Sparkle\n      - package: ColorfulX'
  MAC_ENTITLEMENTS=$'    entitlements:\n      path: TestApp.entitlements\n      properties:\n        com.apple.security.app-sandbox: true\n        com.apple.security.network.client: true'
fi
mkdir -p "$OUT"
if [[ ! -f "$OUT/clip.mp4" ]]; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=2' \
    -f lavfi -i 'anullsrc=r=44100:cl=stereo' -t 120 -c:v libx264 -preset ultrafast \
    -g 2 -c:a aac -movflags +faststart "$OUT/clip.mp4"
fi
cat > "$OUT/RuntimeUnavailable.c" <<'C'
#include <string.h>
char *TVAppleRuntimeRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"JAR runtime excluded from isolated player tests\"}");
}
char *TVPythonRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"Python runtime excluded from isolated player tests\"}");
}
C
cat > "$OUT/TestApp.swift" <<'SWIFT'
import SwiftUI
@main struct PlaybackHistoryTestApp: App {
    var body: some Scene { WindowGroup { Text("Playback history regression tests") } }
}
SWIFT
cat > "$OUT/project.yml" <<YAML
name: PlaybackHistoryQA
options:
  deploymentTarget:
    $PLATFORM: '$DEPLOYMENT'
packages:
  TVCore:
    path: ../../Packages/TVCore
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0
  ColorfulX:
    url: https://github.com/Lakr233/ColorfulX
    exactVersion: 6.2.1
targets:
  PlaybackHistoryQA:
    type: application
    platform: $PLATFORM
$MAC_ENTITLEMENTS
    sources:
      - path: ../../App
        excludes: [TVBoxApp.swift]
      - path: TestApp.swift
      - path: RuntimeUnavailable.c
    dependencies:
      - package: TVCore
$MAC_DEPENDENCIES
    settings:
      SWIFT_VERSION: '6.0'
      OTHER_SWIFT_FLAGS: \$(inherited) -Xfrontend -disable-dynamic-actor-isolation
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.history
      ENABLE_DEBUG_DYLIB: NO
      GENERATE_INFOPLIST_FILE: YES
      ASSETCATALOG_COMPILER_APPICON_NAME: ''
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Playback History QA
        UILaunchScreen: {}
  PlaybackHistoryTests:
    type: bundle.unit-test
    platform: $PLATFORM
    sources:
      - path: ../../AppTests/PlaybackHistoryTests.swift
      - path: clip.mp4
        buildPhase: resources
    dependencies:
      - target: PlaybackHistoryQA
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.history-tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  PlaybackHistory:
    build:
      targets:
        PlaybackHistoryQA: all
        PlaybackHistoryTests: [test]
    test:
      targets: [PlaybackHistoryTests]
YAML
xcodegen generate --spec "$OUT/project.yml"
# A Mac test host needs ad-hoc signing to load its XCTest bundle; simulators need no signing.
SIGNING=(CODE_SIGNING_ALLOWED=NO)
if [[ "$PLATFORM" == macOS ]]; then SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO); fi
xcodebuild -project "$OUT/PlaybackHistoryQA.xcodeproj" -scheme PlaybackHistory \
  -destination "$DESTINATION" -derivedDataPath "$OUT/DerivedData" \
  "${SIGNING[@]}" -parallel-testing-enabled NO -collect-test-diagnostics never test
