#!/bin/bash
# Stop an Apple TV build that tvOS 17 can't launch: dyld quits the app before main when a required SwiftUI symbol
# is missing (#634, and #406 before it). The tvOS 26 and later SDKs name EnvironmentValues properties that moved to
# SwiftUICore without a tvOS @_originallyDefinedIn as members of an extension (EnvironmentValuesVAAE...); tvOS 17
# exports them only under their old names. A Release build inlines SwiftUI's controlSize(_:) into such a key path,
# so the app uses appControlSize(_:) (GlassKit.swift). Weak imports are fine: dyld leaves them nil.
# Usage: Scripts/check-tvos17-symbols.sh <path to the TVBox-tvOS binary>
set -euo pipefail
bad=$(xcrun dyld_info -imports "$1" | grep -F '_$s7SwiftUI17EnvironmentValuesVAAE' | grep -vF '[weak-import]' || true)
if [ -n "$bad" ]; then
  echo "$bad" >&2
  echo "$1 needs SwiftUI symbols tvOS 17 doesn't have, so it would quit at launch there." >&2
  echo "Use appControlSize(_:) instead of controlSize(_:), and read EnvironmentValues key paths only on tvOS 18 or later." >&2
  exit 1
fi
