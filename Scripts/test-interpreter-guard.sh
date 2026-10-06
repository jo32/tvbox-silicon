#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ "$#" != 1 ]; then echo "Usage: $0 /path/to/FishGuard-v8.so" >&2; exit 2; fi
GUARD="$1"
WORK="$ROOT/build/apple-runtime"
SOURCE="$WORK/unidbg"
REVISION=c4ced05858a7878f3c68f6df465ae02fa59f6759
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 19)}"
bash Scripts/build-apple-interpreter.sh macos
if [ ! -d "$SOURCE/.git" ]; then
  git clone --depth 1 --branch v0.9.8 https://github.com/zhkl0228/unidbg.git "$SOURCE"
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$REVISION"
NATIVE="$SOURCE/backend/unicorn2/src/main/native"
OUTPUT="$WORK/unicorn-tci-macos"
clang -shared -O2 -I "$WORK/unicorn-tci/unicorn-engine-sys-tci/include" \
  -I "$JDK/include" -I "$JDK/include/darwin" "$NATIVE/unicorn.c" \
  "$OUTPUT/libunicorn.a" -o "$OUTPUT/libunicorn-jni.dylib"
mkdir -p build/host-tests
"$JDK/bin/javac" -cp 'build/JavaHost/host.jar:build/JavaHost/lib/*' -d build/host-tests Tests/Java/InterpreterGuardProbe.java
"$JDK/bin/java" -cp 'build/host-tests:build/JavaHost/host.jar:build/JavaHost/lib/*' \
  com.github.unidbg.arm.backend.InterpreterGuardProbe "$OUTPUT/libunicorn-jni.dylib" "$GUARD"
