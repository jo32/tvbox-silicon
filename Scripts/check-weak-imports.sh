#!/bin/bash
# Stop a build that crashes at launch on early OS betas. Xcode 27.2's SDK back-deploys Foundation's Date.<= and
# Date.>= (@backDeployed before 27.2): the app calls the OS copy on any system that says 27.2 or later, but early
# 27.2 betas don't have it, so the weak import is NULL and the app jumps to 0x0 (TestFlight 51/52, MediaCache.prune).
# Sources/TVCore/DateComparison.swift and its copies in App/ and Tests/ shadow them; a Swift module without that
# copy that compares dates brings the import back.
# Usage: Scripts/check-weak-imports.sh <app binary>...
set -euo pipefail
status=0
for bin in "$@"; do
  bad=$(xcrun dyld_info -imports "$bin" | grep -E '_\$s10Foundation4DateV2(le|ge)oiySbAC_ACtFZ' || true)
  if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "$bin imports Foundation's back-deployed Date <=/>=, which early 27.2 betas lack (crash at launch)." >&2
    echo "Add a copy of Sources/TVCore/DateComparison.swift to the Swift module that compares dates." >&2
    status=1
  fi
done
exit $status
