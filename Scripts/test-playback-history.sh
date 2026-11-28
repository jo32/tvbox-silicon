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
  MAC_ENTITLEMENTS=$'    entitlements:\n      path: TestApp.entitlements\n      properties:\n        com.apple.security.app-sandbox: true\n        com.apple.security.network.client: true\n        com.apple.security.network.server: true'
fi
mkdir -p "$OUT"
if [[ ! -f "$OUT/clip.mp4" ]]; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=2' \
    -f lavfi -i 'anullsrc=r=44100:cl=stereo' -t 120 -c:v libx264 -preset ultrafast \
    -g 2 -c:a aac -movflags +faststart "$OUT/clip.mp4"
fi
# Three Chinese tracks on a cropped picture, then the same renditions reordered and one episode without SRT.
FIXTURES=Tests/TVCoreTests/Fixtures
printf '1\n00:00:00,100 --> 00:00:08,000\n简体中文字幕\n' > "$OUT/simplified.srt"
ffmpeg -hide_banner -loglevel error -y -i "$OUT/clip.mp4" -i "$FIXTURES/remux-bitmap.mkv" \
  -i "$FIXTURES/remux-ass.mkv" -i "$OUT/simplified.srt" -t 20 \
  -map 0:v -map 0:a -map 1:s:0 -map 2:s:0 -map 3:s:0 -c copy -vf crop=320:132 -c:v libx264 -preset ultrafast -g 2 \
  -metadata:s:s:0 language=chi -metadata:s:s:0 title=Bilingual \
  -metadata:s:s:1 language=chi -metadata:s:s:1 title=Bilingual \
  -metadata:s:s:2 language=chi -metadata:s:s:2 title=Simplified "$OUT/subtitles.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$OUT/subtitles.mkv" -map 0:v -map 0:a -map 0:s:2 -map 0:s:1 -map 0:s:0 -c copy "$OUT/reordered.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$OUT/subtitles.mkv" -map 0:v -map 0:a -map 0:s:0 -c copy "$OUT/missing.mkv"
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
      - path: ../../AppTests/SubtitlePlaybackTests.swift
      - path: ../../AppTests/DiscoverSearchNameTests.swift
      - path: subtitles.mkv
        buildPhase: resources
      - path: reordered.mkv
        buildPhase: resources
      - path: missing.mkv
        buildPhase: resources
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
