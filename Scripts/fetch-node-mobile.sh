#!/bin/bash
# Downloads nodejs-mobile (Node.js built for iOS; V8 runs without a JIT there) into build/NodeMobile, which
# Scripts/embed-node-mobile.sh adds to the iPhone and iPad app. CatPawOpen (猫源) bundles run in it
# (EmbeddedNodeHost). A build without it still runs and lists those sources as unsupported, so release
# builds of the iOS app must run this first.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=18.20.4
ARCHIVE_SHA256=8c5ca3a0d1e38de7f182a5642593e82593b820efd375a14b3ecafc4bcfee620e
LICENSE_SHA256=66233b87054d6bca9b0c2f23b027bb2caf1ebd961a6f981616d098dade33af34
OUT=build/NodeMobile
if [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION" ]; then echo "nodejs-mobile $VERSION is in $OUT"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/ios.zip" "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v$VERSION/nodejs-mobile-v$VERSION-ios.zip"
echo "$ARCHIVE_SHA256  $TMP/ios.zip" | shasum -a 256 -c - > /dev/null
# The release archive has no license; the same tag's LICENSE covers Node.js and its dependencies.
curl -fsSL --retry 3 -o "$TMP/LICENSE" "https://raw.githubusercontent.com/nodejs-mobile/nodejs-mobile/v$VERSION/LICENSE"
echo "$LICENSE_SHA256  $TMP/LICENSE" | shasum -a 256 -c - > /dev/null
unzip -q "$TMP/ios.zip" 'NodeMobile.xcframework/*' -d "$TMP"
rm -rf "$OUT"
mkdir -p "$OUT"
mv "$TMP/NodeMobile.xcframework" "$OUT/"
cp "$TMP/LICENSE" "$OUT/LICENSE.node"
echo "$VERSION" > "$OUT/VERSION"
echo "nodejs-mobile $VERSION is in $OUT"
