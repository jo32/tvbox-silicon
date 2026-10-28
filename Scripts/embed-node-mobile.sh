#!/bin/bash
# Xcode build phase of the iOS app: embeds nodejs-mobile from build/NodeMobile (Scripts/fetch-node-mobile.sh)
# and the CatPawOpen runner (Runtime/NodeHost), and signs the framework before Xcode signs the app. A build
# without it still works: EmbeddedNodeHost then reports Node as missing and CatPawOpen sources stay unsupported.
set -euo pipefail
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
case "$PLATFORM_NAME" in
  iphoneos) SLICE=ios-arm64 ;;
  *) SLICE=ios-arm64_x86_64-simulator ;;
esac
FRAMEWORK="$SRCROOT/build/NodeMobile/NodeMobile.xcframework/$SLICE/NodeMobile.framework"
# Signing changes the 55 MB binary, so rsync would copy it again on every build. Skip copying and signing
# while the source, the signing and the embedded copy are unchanged.
STAMP="${DERIVED_FILE_DIR:-$TARGET_TEMP_DIR}/embed-node-mobile.stamp"
if [ ! -d "$FRAMEWORK" ]; then
  echo "warning: This build has no Node.js runtime, so CatPawOpen sources won't run. Run Scripts/fetch-node-mobile.sh first."
  rm -rf "$APP/Frameworks/NodeMobile.framework" "$APP/NodeHost" "$STAMP"
  exit 0
fi
rsync -a --delete "$SRCROOT/Runtime/NodeHost/" "$APP/NodeHost/"
cp "$SRCROOT/build/NodeMobile/LICENSE.node" "$APP/NodeHost/LICENSE.node"
SIGN=
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then SIGN=yes; fi
KEY=$({
  echo "$APP|$SIGN|${EXPANDED_CODE_SIGN_IDENTITY:-}|${OTHER_CODE_SIGN_FLAGS:-}"
  find "$FRAMEWORK" -exec stat -f '%m %z %N' {} +
} | md5 -q)
COPY="$APP/Frameworks/NodeMobile.framework"
if [ "$(cat "$STAMP" 2>/dev/null)" = "$KEY" ] && [ -f "$COPY/NodeMobile" ] && [ -f "$COPY/PrivacyInfo.xcprivacy" ] && { [ -z "$SIGN" ] || [ -d "$COPY/_CodeSignature" ]; }; then
  echo "Node.js runtime already embedded"
  exit 0
fi
rm -f "$STAMP"
mkdir -p "$APP/Frameworks"
# The app opens the framework with dlopen and never compiles against it, so its headers stay out.
rsync -a --delete --exclude Headers --exclude Modules "$FRAMEWORK/" "$COPY/"
# Node links OpenSSL, a commonly used SDK: without a privacy manifest TestFlight review marks the build invalid
# (ITMS-91061), as it did the Python frameworks.
cp "$SRCROOT/Config/Python/PrivacyInfo.xcprivacy" "$COPY/"
if [ -n "$SIGN" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$COPY"
fi
mkdir -p "$(dirname "$STAMP")"
echo "$KEY" > "$STAMP"
