#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
Scripts/build-apple-ffmpeg.sh
Scripts/build-apple-libass.sh

# The three app builds run side by side, each with its own DerivedData. Run deadline-sensitive tests afterward
# so compilation does not starve their local servers and trigger retries or timeouts.
builds=()
stop_builds() {
  for build in "${builds[@]+"${builds[@]}"}"; do kill "${build%%|*}" 2>/dev/null || true; done
}
trap stop_builds EXIT
for entry in 'macOS|platform=macOS|mac' 'iOS|generic/platform=iOS|ios' 'tvOS|generic/platform=tvOS|tv'; do
  IFS='|' read -r platform destination folder <<< "$entry"
  xcodebuild -project TVBox.xcodeproj -scheme "TVBox-$platform" \
    -destination "$destination" -derivedDataPath "build/Verify-$folder" \
    CODE_SIGNING_ALLOWED=NO build > "build/verify-$folder.log" 2>&1 &
  builds+=("$!|$platform|$folder")
done

failed=0
for build in "${builds[@]}"; do
  IFS='|' read -r pid platform folder <<< "$build"
  if wait "$pid"; then
    echo "$platform build passed (build/verify-$folder.log)"
  else
    echo "$platform build failed (build/verify-$folder.log):"
    grep -E ': error:|\*\* BUILD FAILED' "build/verify-$folder.log" | head -20 || tail -40 "build/verify-$folder.log"
    failed=1
  fi
done
builds=()
if (( failed )); then exit "$failed"; fi

swift test --no-parallel
Scripts/test-apple-runtime-bridge.sh
# The apps embed build/JavaHost: it must be the sources' version, and its own tests must pass.
Scripts/check-java-host.sh build/JavaHost/host.jar
Scripts/test-java-host.sh > build/verify-java.log 2>&1 || { tail -40 build/verify-java.log; exit 1; }
echo "Java host tests passed (build/verify-java.log)"
