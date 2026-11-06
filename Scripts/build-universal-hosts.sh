#!/bin/bash
# Assemble universal (arm64 + x86_64) spider hosts for the Mac release in build/universal/{JavaHost,ScriptHost,PythonHost}.
# The arm64 halves are build/{JavaHost,PythonHost} from Scripts/build-*-host.sh. The x86_64 halves use the same
# JDK and CPython versions and run under Rosetta while they are assembled. Node comes from nodejs.org for both
# architectures: Homebrew's node links to libraries in /opt/homebrew that other Macs do not have.
#   NODE_VERSION=v26.13.0 Scripts/build-universal-hosts.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TOOLS="$ROOT/build/tools"
X64="$ROOT/build/x86_64"
OUT="$ROOT/build/universal"
NODE_VERSION="${NODE_VERSION:-v26.13.0}"
arch -x86_64 /usr/bin/true 2>/dev/null || { echo 'Rosetta is required: softwareupdate --install-rosetta' >&2; exit 1; }
for h in JavaHost ScriptHost PythonHost; do test -d "build/$h" || { echo "missing build/$h; run Scripts/build-*-host.sh" >&2; exit 1; }; done
mkdir -p "$TOOLS" "$X64" "$OUT"

# fetch <url> <sha256> <file>: download once into build/tools and check it.
fetch() {
  if [ ! -f "$3" ] || [ "$(shasum -a 256 "$3" | cut -d' ' -f1)" != "$2" ]; then
    curl -fL --retry 3 -o "$3.tmp" "$1"
    [ "$(shasum -a 256 "$3.tmp" | cut -d' ' -f1)" = "$2" ] || { echo "checksum mismatch: $1" >&2; exit 1; }
    mv -f "$3.tmp" "$3"
  fi
}

# Java: jlink the same modules with the x86_64 build of the JDK that made build/JavaHost/jre.
JRE="$ROOT/build/JavaHost/jre"
JDK_BUILD=$("$JRE/bin/java" -version 2>&1 | sed -n 's/.*Temurin-\([0-9.]*+[0-9]*\).*/\1/p' | head -1)
[ -n "$JDK_BUILD" ] || { echo 'build/JavaHost/jre is not a Temurin runtime' >&2; exit 1; }
JDK_MAJOR=${JDK_BUILD%%[.+]*}
JDK_TAR="$TOOLS/OpenJDK${JDK_MAJOR}U-jdk_x64_mac_hotspot_${JDK_BUILD/+/_}.tar.gz"
JDK_URL="https://github.com/adoptium/temurin${JDK_MAJOR}-binaries/releases/download/jdk-${JDK_BUILD/+/%2B}/$(basename "$JDK_TAR")"
fetch "$JDK_URL" "$(curl -fsSL "$JDK_URL.sha256.txt" | cut -d' ' -f1)" "$JDK_TAR"
rm -rf "$X64/jdk" "$X64/jre"; mkdir -p "$X64/jdk"
tar -xzf "$JDK_TAR" -C "$X64/jdk" --strip-components 1
MODULES=$("$JRE/bin/java" --list-modules | sed 's/@.*//' | paste -sd, -)
arch -x86_64 "$X64/jdk/Contents/Home/bin/jlink" --add-modules "$MODULES" --strip-debug --no-header-files --no-man-pages --output "$X64/jre"
rm -rf "$OUT/JavaHost"
rsync -a --exclude /jre build/JavaHost/ "$OUT/JavaHost/"
# The module image differs only in the target platform its module-info classes record, which the JVM does not
# check at run time; shaders.metallib is GPU code for the Metal pipeline, the same on both.
python3 Scripts/merge-universal.py "$JRE" "$X64/jre" "$OUT/JavaHost/jre" --keep-arm64 release \
  --keep-arm64 lib/modules --keep-arm64 lib/shaders.metallib

# Node: the official builds are self-contained; join the two architectures.
SUMS=$(curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt")
for a in arm64 x64; do
  name="node-$NODE_VERSION-darwin-$a.tar.gz"
  fetch "https://nodejs.org/dist/$NODE_VERSION/$name" "$(echo "$SUMS" | awk -v n="$name" '$2 == n {print $1}')" "$TOOLS/$name"
  rm -rf "$X64/node-$a"; mkdir -p "$X64/node-$a"
  tar -xzf "$TOOLS/$name" -C "$X64/node-$a" --strip-components 1
done
rm -rf "$OUT/ScriptHost"
rsync -a --exclude /node --exclude /LICENSE.node build/ScriptHost/ "$OUT/ScriptHost/"
lipo -create "$X64/node-arm64/bin/node" "$X64/node-x64/bin/node" -output "$OUT/ScriptHost/node"
cp "$X64/node-arm64/LICENSE" "$OUT/ScriptHost/LICENSE.node"

# Python: the same CPython and requirements, built for x86_64 by build-python-host.sh.
PY_VERSION=$(build/PythonHost/python/bin/python3 -c 'import platform; print(platform.python_version())')
uv python install --managed-python "cpython-$PY_VERSION-macos-x86_64-none" >/dev/null
PY_X64=$(uv python find --managed-python "cpython-$PY_VERSION-macos-x86_64-none")
PYTHON_HOME="$(dirname "$(dirname "$PY_X64")")" PYTHON_HOST_DEST="$X64/PythonHost" Scripts/build-python-host.sh
# sysconfigdata and the wheel metadata name the architecture they were built for; the code is the same.
# Bytecode records each .py file's mtime, and the arm64 .py files are the ones kept.
python3 Scripts/merge-universal.py build/PythonHost "$X64/PythonHost" "$OUT/PythonHost" --keep-arm64 '*.pyc' \
  --keep-arm64 'python/lib/python3.*/_sysconfigdata_*' \
  --keep-arm64 'python/lib/python3.*/config-*' --keep-arm64 'python/lib/pkgconfig/*' \
  --keep-arm64 'site-packages/*.dist-info/RECORD' --keep-arm64 'site-packages/*.dist-info/WHEEL'

du -sh "$OUT"/*
