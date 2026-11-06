#!/bin/bash
# Downloads nodejs-mobile (Node.js built for iOS and tvOS; V8 runs without a JIT there) into build/NodeMobile, which
# Scripts/embed-node-mobile.sh adds to the iPhone, iPad and Apple TV apps. CatPawOpen (猫源) bundles run in it
# (EmbeddedNodeHost). A build without it still runs and lists those sources as unsupported, so release builds of the
# iOS and tvOS apps must run this first.
# The framework is built from https://github.com/jo32/nodejs-mobile (branch tvos-node26: Node.js 26 LTS plus Apple TV
# slices; see docs/BUILDING.md there) and published as that repository's release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=26.13.0
RELEASE=v26.13.0-tvbox.1
ARCHIVE_SHA256=a84ac23e389f186dc64a78e2350b747b6e3f6cf56db12c9e1c3561db156b6440
LICENSE_SHA256=12d632aa78f637d8c899f19d4549538c477b6df3836fe86731cd821f750abac8
OUT=build/NodeMobile
if [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$RELEASE" ]; then echo "nodejs-mobile $RELEASE is in $OUT"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/jo32/nodejs-mobile/releases/download/$RELEASE"
curl -fsSL --retry 3 -o "$TMP/apple.zip" "$BASE/nodejs-mobile-v$VERSION-apple.zip"
echo "$ARCHIVE_SHA256  $TMP/apple.zip" | shasum -a 256 -c - > /dev/null
# Node.js's LICENSE covers Node.js and the dependencies built into the framework.
curl -fsSL --retry 3 -o "$TMP/LICENSE" "$BASE/LICENSE"
echo "$LICENSE_SHA256  $TMP/LICENSE" | shasum -a 256 -c - > /dev/null
unzip -q "$TMP/apple.zip" 'NodeMobile.xcframework/*' -d "$TMP"
rm -rf "$OUT"
mkdir -p "$OUT"
mv "$TMP/NodeMobile.xcframework" "$OUT/"
cp "$TMP/LICENSE" "$OUT/LICENSE.node"
echo "$RELEASE" > "$OUT/VERSION"
echo "nodejs-mobile $RELEASE is in $OUT"
