#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The Mac's JavaScript host. Node is the official nodejs.org build pinned here (the same version the Mac release
# ships, Scripts/build-universal-hosts.sh), downloaded once per Mac into ~/Library/Caches/tvbox-node, so nobody needs
# their own Node: Homebrew's links to libraries in /opt/homebrew that other Macs do not have.
# NODE_BIN (with NODE_LICENSE, the LICENSE distributed with it) selects another standalone binary.
NODE_VERSION=v26.13.0
DEST="$PWD/build/ScriptHost"
if [ -z "${NODE_BIN:-}" ]; then
  case "$(uname -m)" in
    arm64) ARCH=arm64 SHA256=d38bd5e5a2ddce6bbb5ce45e46e208337da4d51fffe611e567fd32073d6439f6 ;;
    *) ARCH=x64 SHA256=525c9b29bb0263d687de60a4cec0e2a6db876a8eb032369e5795eca71e7c358e ;;
  esac
  NAME="node-$NODE_VERSION-darwin-$ARCH"
  CACHE="${TVBOX_CACHE:-$HOME/Library/Caches}/tvbox-node"
  if [ ! -x "$CACHE/$NAME/bin/node" ]; then
    echo "Downloading Node.js $NODE_VERSION for the Mac (once per Mac)"
    mkdir -p "$CACHE"
    TMP=$(mktemp -d "$CACHE/.download.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL --retry 3 -o "$TMP/node.tar.gz" "https://nodejs.org/dist/$NODE_VERSION/$NAME.tar.gz"
    echo "$SHA256  $TMP/node.tar.gz" | shasum -a 256 -c - > /dev/null
    tar -xzf "$TMP/node.tar.gz" -C "$TMP"
    rm -rf "$CACHE/$NAME"
    mv "$TMP/$NAME" "$CACHE/$NAME"
  fi
  NODE_BIN="$CACHE/$NAME/bin/node"
  NODE_LICENSE="$CACHE/$NAME/LICENSE"
fi
NODE="$NODE_BIN"
LICENSE="${NODE_LICENSE:-$(dirname "$(dirname "$NODE")")/LICENSE}"
if [ ! -f "$LICENSE" ]; then
  echo 'Set NODE_LICENSE to the LICENSE distributed with the Node binary.' >&2
  exit 1
fi
mkdir -p "$DEST"
cp "$NODE" "$DEST/node"
cp "$LICENSE" "$DEST/LICENSE.node"
cp Runtime/ScriptHost/host.mjs Runtime/ScriptHost/LICENSE.assets "$DEST/"
cp Runtime/sandbox/spider.sb "$DEST/"
mkdir -p "$DEST/assets"
cp -R Sources/TVCore/ScriptAssets/js "$DEST/assets/"
