#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A full verify is heavy (three app builds, then every test), and many sessions share one Mac. At most two run at a
# time, one while the Mac is already loaded, and the rest wait in line, all at low priority. A slot is a lock that
# lockf holds for the run, so it is freed however the run ends. VERIFY_DIRECT=1 skips the line.
if [[ -z "${VERIFY_SLOT:-}" && "${VERIFY_DIRECT:-}" != 1 ]]; then
  locks="${VERIFY_LOCK_DIR:-$HOME/Library/Caches/tvbox-verify}"
  mkdir -p "$locks"
  started="$locks/started.$$"
  run=
  trap '[[ -z "$run" ]] || kill "$run" 2>/dev/null || true; rm -f "$started"' EXIT
  trap 'exit 143' TERM INT HUP
  cores=$(sysctl -n hw.ncpu)
  queued=$SECONDS
  note=0
  while :; do
    slots="${VERIFY_SLOTS:-2}"
    if (( $(sysctl -n vm.loadavg | awk '{print int($2)}') >= cores )); then slots=1; fi
    for (( slot = 1; slot <= slots; slot++ )); do
      waited=$(( SECONDS - queued ))
      VERIFY_SLOT=$slot VERIFY_STARTED="$started" \
        lockf -k -s -t 0 "$locks/slot-$slot" nice -n 10 "$PWD/Scripts/verify.sh" "$@" &
      run=$!
      status=0
      wait "$run" || status=$?
      run=
      if [[ -e "$started" ]]; then
        echo "$(date '+%F %T') $PWD waited ${waited}s ran $(( SECONDS - queued - waited ))s exit $status" \
          >> "$locks/runs.log"
        exit "$status"
      fi
    done
    if (( SECONDS >= note )); then
      echo "Waiting for a verify slot ($slots at a time on this Mac, waited $(( SECONDS - queued ))s)"
      note=$(( SECONDS + 60 ))
    fi
    sleep 5
  done
fi
if [[ -n "${VERIFY_STARTED:-}" ]]; then : > "$VERIFY_STARTED"; fi

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
