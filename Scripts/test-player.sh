#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
products="$PWD/build/Verify-mac/Build/Products/Debug"
mkdir -p build
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=24' -t 30 -c:v libx264 -pix_fmt yuv420p build/player-test.mp4
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
  -module-cache-path build/PlayerModuleCache -I "$products" \
  -Xcc "-fmodule-map-file=$PWD/build/Verify-mac/Build/Intermediates.noindex/GeneratedModuleMaps/DexRuntime.modulemap" \
  App/PlaybackView.swift App/PlayerView.swift App/HLSProxy.swift App/GlassKit.swift Scripts/PlayerSmoke.swift \
  "$products/TVCore.o" "$products/DexRuntime.o" -lz -o "$products/PlayerSmoke"
"$products/PlayerSmoke" "$PWD/build/player-test.mp4"
