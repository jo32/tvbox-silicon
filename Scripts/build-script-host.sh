#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
NODE="${NODE_BIN:-$(command -v node)}"
DEST="$PWD/build/ScriptHost"
LICENSE="${NODE_LICENSE:-$(dirname "$(dirname "$NODE")")/LICENSE}"
if [ ! -f "$LICENSE" ]; then
  echo 'Set NODE_LICENSE to the LICENSE distributed with the Node binary.' >&2
  exit 1
fi
mkdir -p "$DEST"
cp "$NODE" "$DEST/node"
cp "$LICENSE" "$DEST/LICENSE.node"
cp Runtime/ScriptHost/host.mjs Runtime/ScriptHost/LICENSE.assets "$DEST/"
mkdir -p "$DEST/assets"
cp -R Sources/TVCore/ScriptAssets/js "$DEST/assets/"
