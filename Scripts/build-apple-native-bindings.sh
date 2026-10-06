#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; WORK="$ROOT/build/apple-runtime"; TARGET="${1:-ios-simulator}"
case "$TARGET" in
 ios) SDK=iphoneos; SYSTEM=iOS; TRIPLE=arm64-apple-ios17.0 ;;
 ios-simulator) SDK=iphonesimulator; SYSTEM=iOS; TRIPLE=arm64-apple-ios17.0-simulator ;;
 tvos) SDK=appletvos; SYSTEM=tvOS; TRIPLE=arm64-apple-tvos17.0 ;;
 tvos-simulator) SDK=appletvsimulator; SYSTEM=tvOS; TRIPLE=arm64-apple-tvos17.0-simulator ;;
 *) exit 2 ;;
esac
checkout() {
 local name="$1" url="$2" revision="$3"
 if [ ! -d "$WORK/$name/.git" ]; then git clone "$url" "$WORK/$name"; fi
 if [ "$(git -C "$WORK/$name" rev-parse HEAD)" != "$revision" ]; then
  git -C "$WORK/$name" fetch origin "$revision"; git -C "$WORK/$name" checkout --detach "$revision"
 fi
}
checkout jna https://github.com/java-native-access/jna.git 8230fd9c023246e331601690a2afb82f37e6d4b6
checkout capstone https://github.com/zhkl0228/capstone.git aecd7d0b2bee96643f7ed2c100399afde6d44bce
checkout keystone https://github.com/keystone-engine/keystone.git 0d9567f08c0c23e8f604b2cad3d49450c93cfb40
checkout unidbg https://github.com/zhkl0228/unidbg.git c4ced05858a7878f3c68f6df465ae02fa59f6759
FFI="$WORK/libffi-$TARGET-3.4.8/install"
if [ ! -f "$FFI/lib/libffi.a" ]; then Scripts/build-apple-libffi.sh "$TARGET"; fi
if [ ! -f "$WORK/unicorn-tci-$TARGET/libunicorn.a" ]; then Scripts/build-apple-interpreter.sh "$TARGET"; fi
# Compatibility with CMake 4; no engine behavior changes.
sed -i '' 's/SET CMP0048 OLD/SET CMP0048 NEW/' "$WORK/capstone/CMakeLists.txt"
# JNA resolves the assembler's public C API from the executable. Keep these
# symbols externally visible even though the archive itself is static.
sed -i '' 's/    KEYSTONE_STATIC/    TVBOX_STATIC_KEYSTONE/' "$WORK/keystone/llvm/keystone/CMakeLists.txt"
COMMON=(-DCMAKE_SYSTEM_NAME="$SYSTEM" -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
cmake -S "$WORK/capstone" -B "$WORK/capstone-$TARGET" "${COMMON[@]}" -DCAPSTONE_BUILD_SHARED=OFF -DCAPSTONE_BUILD_TESTS=OFF -DCAPSTONE_BUILD_CSTOOL=OFF
cmake --build "$WORK/capstone-$TARGET" -j "${JOBS:-4}"
cmake -S "$WORK/keystone" -B "$WORK/keystone-$TARGET" "${COMMON[@]}" -DBUILD_SHARED_LIBS=OFF -DBUILD_LIBS_ONLY=ON -DLLVM_TARGETS_TO_BUILD=AArch64 -DPYTHON_EXECUTABLE=/usr/bin/python3
cmake --build "$WORK/keystone-$TARGET" -j "${JOBS:-4}"
JDK="${JAVA_HOME:-$(/usr/libexec/java_home -v 19)}"
OUT="$WORK/native-$TARGET"; mkdir -p "$OUT" "$WORK/jna-headers" "$WORK/jna-classes" "$OUT/classes"
"$JDK/bin/javac" -source 8 -target 8 -h "$WORK/jna-headers" -d "$WORK/jna-classes" $(rg --files "$WORK/jna/src" | rg '\.java$')
FLAGS=(-target "$TRIPLE" -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" -O2 -I "$JDK/include" -I "$JDK/include/darwin")
JNA=(-DNO_JAWT -D_REENTRANT '-DJNA_JNI_VERSION="6.1.2"' '-DCHECKSUM="147a998f0cbc89681a1ae6c0dd121629"' -I "$WORK/jna-headers" -I "$FFI/include")
clang "${FLAGS[@]}" "${JNA[@]}" -DJNI_OnLoad=TVJNA_OnLoad -DJNI_OnUnload=TVJNA_OnUnload -c "$WORK/jna/native/dispatch.c" -o "$OUT/dispatch.o"
clang "${FLAGS[@]}" "${JNA[@]}" -c "$WORK/jna/native/callback.c" -o "$OUT/callback.o"
clang "${FLAGS[@]}" -I "$WORK/unicorn-tci/unicorn-engine-sys-tci/include" -DJNI_OnLoad=TVUnicorn_OnLoad -c "$WORK/unidbg/backend/unicorn2/src/main/native/unicorn.c" -o "$OUT/unicorn-jni.o"
for source in disassembler reg_mapping; do
 clang "${FLAGS[@]}" -I "$WORK/capstone/include" -c "$WORK/capstone/bindings/java/src/main/native/$source.c" -o "$OUT/$source.o"
done
clang "${FLAGS[@]}" -c Runtime/AppleRuntime/Native/StaticLibraries.c -o "$OUT/static-libraries.o"
xcrun ar rcs "$OUT/libapplebindings.a" "$OUT"/*.o
# Patch the Java disassembler loader to use the signed-in executable's JNI library.
mkdir -p "$OUT/java/capstone/jni"
python3 - "$WORK" "$OUT" <<'PY'
import pathlib,sys
work,out=map(pathlib.Path,sys.argv[1:])
s=(work/'capstone/bindings/java/src/main/java/capstone/jni/FastDisassembler.java').read_text()
s=s.replace('NativeLoader.loadLibrary("disassembler");','if (Boolean.getBoolean("tvbox.apple")) System.loadLibrary("disassembler");\n            else NativeLoader.loadLibrary("disassembler");')
(out/'java/capstone/jni/FastDisassembler.java').write_text(s)
PY
"$JDK/bin/javac" --release 17 -cp 'build/JavaHost/host.jar:build/JavaHost/lib/*' -d "$OUT/classes" "$OUT/java/capstone/jni/FastDisassembler.java" Runtime/AppleRuntime/Java/keystone/natives/DirectMappingKeystoneNative.java Runtime/AppleRuntime/Java/tvbox/runtime/AppleBootstrap.java
"$JDK/bin/jar" --create --file "$OUT/apple-bindings.jar" -C "$OUT/classes" .
echo "Built native bindings: $OUT"
