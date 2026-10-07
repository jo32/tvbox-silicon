#!/bin/bash
# Assemble build/PythonHost: a relocatable CPython (python-build-standalone, as installed by uv),
# the libraries TVBox Python spiders import, and the host in Runtime/PythonHost.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${PYTHON_VERSION:-3.12}"
DEST="$PWD/build/PythonHost"
if [ -n "${PYTHON_HOME:-}" ]; then
  PREFIX="$PYTHON_HOME"
else
  command -v uv >/dev/null || { echo 'Install uv, or set PYTHON_HOME to a relocatable python-build-standalone prefix.' >&2; exit 1; }
  # --managed-python: Homebrew and system builds link to files outside their prefix.
  uv python install --managed-python "$VERSION" >/dev/null
  PREFIX="$(dirname "$(dirname "$(uv python find --managed-python "$VERSION")")")"
fi
if otool -L "$PREFIX/bin/python3" | tail -n +2 | grep -v -E '@executable_path|/System/Library|/usr/lib/' >&2; then
  echo "$PREFIX/bin/python3 links to libraries outside the bundle." >&2
  exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a --exclude '__pycache__' --exclude 'include/' --exclude 'share/' \
  --exclude 'lib/tcl*' --exclude 'lib/tk*' --exclude 'lib/itcl*' --exclude 'lib/thread*' \
  --exclude 'lib/python3.*/test/' --exclude 'lib/python3.*/idlelib/' --exclude 'lib/python3.*/tkinter/' \
  --exclude 'lib/python3.*/turtledemo/' --exclude 'lib/python3.*/ensurepip/' --exclude 'lib/python3.*/site-packages/' \
  --exclude 'lib/python3.*/config-*/' --exclude 'lib/python3.*/lib-dynload/_tkinter*' \
  "$PREFIX/" "$DEST/python/"
PYTHON="$DEST/python/bin/python3"
uv pip install --quiet --python "$PYTHON" --target "$DEST/site-packages" --only-binary ':all:' \
  -r Runtime/PythonHost/requirements.txt
rm -rf "$DEST/site-packages/bin"
cp Runtime/PythonHost/host.py "$DEST/"
cp -R Runtime/PythonHost/base "$DEST/"
# The app bundle is read-only and signed; precompile once so -B startups still use bytecode.
"$PYTHON" -I -m compileall -q -j 0 "$DEST/python/lib" "$DEST/site-packages" "$DEST/base" "$DEST/host.py" >/dev/null
"$PYTHON" -I -B -c "import sys; sys.path[:0] = ['$DEST', '$DEST/site-packages']; import requests, lxml.etree, bs4, pyquery, Crypto.Cipher.AES, cryptography.hazmat.primitives.ciphers, base.spider; print('Python host ready:', sys.version.split()[0])"
