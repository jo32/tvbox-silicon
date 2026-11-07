#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
Scripts/build-apple-ffmpeg.sh
Scripts/build-apple-libass.sh
swift test
Scripts/test-apple-runtime-bridge.sh
# The apps embed build/JavaHost: it must be the sources' version, and its own tests must pass.
Scripts/check-java-host.sh build/JavaHost/host.jar
Scripts/test-java-host.sh > build/verify-java.log 2>&1 || { tail -40 build/verify-java.log; exit 1; }
echo "Java host tests passed (build/verify-java.log)"
for entry in 'macOS|platform=macOS|mac' 'iOS|generic/platform=iOS|ios' 'tvOS|generic/platform=tvOS|tv'; do
  IFS='|' read -r platform destination folder <<< "$entry"
  xcodebuild -project TVBox.xcodeproj -scheme "TVBox-$platform" \
    -destination "$destination" -derivedDataPath "build/Verify-$folder" \
    CODE_SIGNING_ALLOWED=NO build > "build/verify-$folder.log" 2>&1
  echo "$platform build passed (build/verify-$folder.log)"
done
