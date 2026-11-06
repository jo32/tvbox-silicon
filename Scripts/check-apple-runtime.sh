#!/bin/bash
# Stop a Release build whose packaged native runtime (build/AppleRuntime/<platform>) predates a native change in
# this checkout; a Debug build only warns. Xcode links lib/libTVAppleRuntime.a as it is, without rebuilding it,
# so a stale copy ships the old native code. Runtime/AppleRuntime/runtime-version goes up whenever a change
# needs Scripts/package-apple-runtime.sh to run again; packaging copies it next to the library.
# 2: Unicorn's translation buffer capped at 32 MB per engine (issue #563: 1 GiB each quit 3 GB iPads).
# Usage: Scripts/check-apple-runtime.sh build/AppleRuntime/<platform>
set -euo pipefail
want=$(cat "$(dirname "$0")/../Runtime/AppleRuntime/runtime-version")
got=$(cat "$1/runtime-version" 2>/dev/null || echo 1)
if [ "$got" != "$want" ]; then
  message="$1 is native runtime $got, but this checkout needs $want. Rebuild it: Scripts/package-apple-runtime.sh <ios|ios-simulator|tvos|tvos-simulator>."
  if [ "${CONFIGURATION:-Release}" = Release ]; then echo "error: $message" >&2; exit 1; fi
  echo "warning: $message"
fi
