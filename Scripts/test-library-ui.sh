#!/bin/bash
# Unified acceptance in a separate simulator bundle. Never installs a stub
# runtime into the user's device app. Deterministic local danmaku and fixture playback.
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR_ID="${1:?Usage: Scripts/test-library-ui.sh <iPad simulator UUID>}"
shift
OUT=build/LibraryUI
mkdir -p "$OUT"
# A simulator can reuse a stale XCTest runner after an incremental rebuild.
# Its own bundle contains no app history or subscription data.
xcrun simctl terminate "$SIMULATOR_ID" com.tvbox.yingxia.qa.library-tests.xctrunner 2>/dev/null || true
xcrun simctl uninstall "$SIMULATOR_ID" com.tvbox.yingxia.qa.library-tests.xctrunner 2>/dev/null || true
if lsof -tiTCP:8776 -sTCP:LISTEN >/dev/null; then
  echo 'Port 8776 is occupied; stop the previous QA server first.' >&2
  exit 1
fi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=2' \
  -f lavfi -i 'anullsrc=r=44100:cl=stereo' -t 300 -c:v libx264 -preset ultrafast \
  -g 2 -c:a aac -movflags +faststart "$OUT/clip.mp4"
python3 Scripts/qa-server.py --port 8776 --media "$OUT/clip.mp4" > "$OUT/server.log" 2>&1 &
QA_SERVER_PID=$!
trap 'kill "$QA_SERVER_PID" 2>/dev/null || true' EXIT
cat > "$OUT/RuntimeUnavailable.c" <<'C'
#include <stdlib.h>
#include <string.h>
char *TVAppleRuntimeRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"JAR runtime excluded from isolated UI acceptance\"}");
}
C
cat > "$OUT/project.yml" <<'YAML'
name: LibraryUI
options:
  deploymentTarget:
    iOS: '26.0'
packages:
  TVCore:
    path: ../..
targets:
  LibraryUI:
    type: application
    platform: iOS
    sources:
      - path: ../../App
      - path: ../../Config/iOS/Assets.xcassets
      - path: ../../Runtime/AppleRuntime/Native/ApplePython.c
      - path: RuntimeUnavailable.c
    dependencies:
      - package: TVCore
    settings:
      SWIFT_VERSION: '6.0'
      # Match the production app's SwiftUI actor-check setting (project.yml).
      OTHER_SWIFT_FLAGS: $(inherited) -Xfrontend -disable-dynamic-actor-isolation
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.library
      TARGETED_DEVICE_FAMILY: '1,2'
      ENABLE_DEBUG_DYLIB: NO
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Playback UI QA
        UILaunchScreen: {}
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
  LibraryUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: ../../UITests
    dependencies:
      - target: LibraryUI
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.library-tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  LibraryAcceptance:
    build:
      targets:
        LibraryUI: all
        LibraryUITests: [test]
    test:
      targets: [LibraryUITests]
YAML
xcodegen generate --spec "$OUT/project.yml"
xcodebuild -project "$OUT/LibraryUI.xcodeproj" -scheme LibraryAcceptance \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never test "$@"
