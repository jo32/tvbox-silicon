#!/bin/bash
# Siri Remote acceptance on a tvOS simulator, in a separate bundle (com.tvbox.yingxia.qa.tv) with
# no JAR runtime and isolated data, against Scripts/qa-server.py. The user's app is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR_ID="${1:?Usage: Scripts/test-tv-ui.sh <tvOS simulator UUID> [xcodebuild args]}"
shift
OUT=build/TVUI
mkdir -p "$OUT"
xcrun simctl terminate "$SIMULATOR_ID" com.tvbox.yingxia.qa.tv-tests.xctrunner 2>/dev/null || true
# Downloads live outside -qaIsolatedData; start each run without the last run's.
xcrun simctl uninstall "$SIMULATOR_ID" com.tvbox.yingxia.qa.tv 2>/dev/null || true
if lsof -tiTCP:8776 -sTCP:LISTEN >/dev/null; then
  echo 'Port 8776 is occupied; stop the previous QA server first.' >&2
  exit 1
fi
python3 Scripts/qa-server.py --port 8776 --media "$OUT/clip.mp4" > "$OUT/server.log" 2>&1 &
QA_SERVER_PID=$!
trap 'kill "$QA_SERVER_PID" 2>/dev/null || true' EXIT
cat > "$OUT/RuntimeUnavailable.c" <<'C'
#include <stdlib.h>
#include <string.h>
char *TVAppleRuntimeRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"JAR runtime excluded from isolated UI acceptance\"}");
}
char *TVPythonRequest(const char *resources, const char *request) {
    return strdup("{\"error\":\"Python runtime excluded from isolated UI acceptance\"}");
}
C
cat > "$OUT/project.yml" <<'YAML'
name: TVUI
options:
  deploymentTarget:
    tvOS: '26.0'
packages:
  TVCore:
    path: ../../Packages/TVCore
targets:
  TVUI:
    type: application
    platform: tvOS
    sources:
      - path: ../../App
      - path: ../../Config/tvOS/Assets.xcassets
      - path: RuntimeUnavailable.c
    dependencies:
      - package: TVCore
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.tv
      ENABLE_DEBUG_DYLIB: NO
      ASSETCATALOG_COMPILER_APPICON_NAME: App Icon & Top Shelf Image
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Remote UI QA
        UILaunchScreen: {}
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
  TVUITests:
    type: bundle.ui-testing
    platform: tvOS
    sources:
      - path: ../../UITests/TVNavigationUITests.swift
    dependencies:
      - target: TVUI
    settings:
      SWIFT_VERSION: '6.0'
      PRODUCT_BUNDLE_IDENTIFIER: com.tvbox.yingxia.qa.tv-tests
      GENERATE_INFOPLIST_FILE: YES
schemes:
  TVAcceptance:
    build:
      targets:
        TVUI: all
        TVUITests: [test]
    test:
      targets: [TVUITests]
YAML
xcodegen generate --spec "$OUT/project.yml"
xcodebuild -project "$OUT/TVUI.xcodeproj" -scheme TVAcceptance \
  -destination "platform=tvOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never test "$@"
