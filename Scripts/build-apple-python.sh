#!/bin/bash
# Assemble build/ApplePython/<platform> for the iOS and tvOS apps (Docs/python-runtime-plan.md): BeeWare's
# CPython (Python-Apple-support), a trimmed standard library, the libraries TVBox spiders import (pinned in
# Runtime/PythonHost/requirements.txt, like the Mac's host; lxml and pycryptodome are compiled by
# Scripts/build-apple-python-wheels.sh), and Runtime/PythonHost itself.
# iOS and tvOS load binary modules only from frameworks, so each extension module becomes
# Frameworks/<module>.framework with a .fwork file in its place, as Python's Apple testbed does.
# The app targets embed the result with Scripts/embed-apple-python.sh.
# Usage: Scripts/build-apple-python.sh [ios|ios-simulator|tvos|tvos-simulator]
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in
  ios) FAMILY=iOS; PLATFORM=iphoneos; SLICE=ios-arm64 ;;
  ios-simulator) FAMILY=iOS; PLATFORM=iphonesimulator; SLICE=ios-arm64_x86_64-simulator ;;
  tvos) FAMILY=tvOS; PLATFORM=appletvos; SLICE=tvos-arm64 ;;
  tvos-simulator) FAMILY=tvOS; PLATFORM=appletvsimulator; SLICE=tvos-arm64_x86_64-simulator ;;
  *) echo "Usage: $0 [ios|ios-simulator|tvos|tvos-simulator]" >&2; exit 2 ;;
esac
VERSION=3.14; SUPPORT=b13
MINIMUM_OS=17.0  # the apps' deployment target in project.yml
case "$FAMILY" in
  iOS) SHA256=ce1c68affa1cbd9c5611a0f4a013e412f14a760cf22c6bb58cfb4d893073bd45 ;;
  tvOS) SHA256=72380111fcf9362b587b30e1fdf31df4ca8d6d0f72f46054eb7e3673d61f44d1 ;;
esac
# Bytecode and the libraries' tags must match the embedded interpreter's minor version.
HOST_PYTHON="${HOST_PYTHON:-$(command -v python$VERSION || true)}"
[ -x "$HOST_PYTHON" ] || { echo "Install Python $VERSION (brew install python@$VERSION) or set HOST_PYTHON." >&2; exit 1; }
WORK="$PWD/build/apple-python"
ARCHIVE="$WORK/Python-$VERSION-$FAMILY-support.$SUPPORT.tar.gz"
mkdir -p "$WORK"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --retry 2 "https://github.com/beeware/Python-Apple-support/releases/download/$VERSION-$SUPPORT/$(basename "$ARCHIVE")" -o "$ARCHIVE.download"
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
SUPPORT_DIR="$WORK/$FAMILY-$VERSION-$SUPPORT"
if [ ! -d "$SUPPORT_DIR" ]; then
  mkdir -p "$SUPPORT_DIR.partial" && tar -xzf "$ARCHIVE" -C "$SUPPORT_DIR.partial" && mv "$SUPPORT_DIR.partial" "$SUPPORT_DIR"
fi
XCFRAMEWORK="$SUPPORT_DIR/Python.xcframework"
DEST="$PWD/build/ApplePython/$PLATFORM"
rm -rf "$DEST"
mkdir -p "$DEST/Frameworks" "$DEST/python/lib" "$DEST/PythonHost/site-packages"

# The interpreter. The apps build for arm64 only (project.yml), simulators included.
rsync -a "$XCFRAMEWORK/$SLICE/Python.framework/" "$DEST/Frameworks/Python.framework/"
if lipo -archs "$DEST/Frameworks/Python.framework/Python" | grep -q ' '; then
  lipo -thin arm64 "$DEST/Frameworks/Python.framework/Python" -output "$DEST/Frameworks/Python.framework/Python.arm64"
  mv "$DEST/Frameworks/Python.framework/Python.arm64" "$DEST/Frameworks/Python.framework/Python"
fi
rm -rf "$DEST/Frameworks/Python.framework/Headers"

# The standard library, without what an app never runs (tests, GUI, installers, the REPL's docs).
EXCLUDES=(--exclude '__pycache__' --exclude 'test/' --exclude 'idlelib/' --exclude 'tkinter/' --exclude 'turtledemo/'
  --exclude 'ensurepip/' --exclude 'pydoc_data/' --exclude 'site-packages/' --exclude 'config-*/' --exclude 'libpython*.dylib'
  --exclude '_test*' --exclude '_ctypes_test*' --exclude 'xxlimited*' --exclude 'xxsubtype*' --exclude '_xxtestfuzz*')
rsync -a "${EXCLUDES[@]}" "$XCFRAMEWORK/lib/" "$DEST/python/lib/"
rsync -a "${EXCLUDES[@]}" "$XCFRAMEWORK/$SLICE/lib-arm64/" "$DEST/python/lib/"

# Pure-Python libraries, the same versions as the Mac's host. lxml and pycryptodome are compiled below;
# cffi and cryptography are left out (pycryptodome then uses ctypes; Docs/python-runtime-plan.md).
grep -E '^[A-Za-z]' Runtime/PythonHost/requirements.txt | grep -v -E '^(cffi|cryptography|lxml|pycryptodome)==' > "$WORK/requirements-pure.txt"
"$HOST_PYTHON" -m pip install --quiet --disable-pip-version-check --target "$DEST/PythonHost/site-packages" --no-deps \
  --only-binary=:all: --platform any --implementation py --abi none --python-version "$VERSION" -r "$WORK/requirements-pure.txt"
rm -rf "$DEST/PythonHost/site-packages/bin"

# lxml and pycryptodome, compiled for this platform.
Scripts/build-apple-python-wheels.sh "$TARGET"
for name in lxml pycryptodome; do
  version="$(grep -E "^$name==" Runtime/PythonHost/requirements.txt | cut -d= -f3)"
  unzip -qo "$WORK/wheels/$PLATFORM/$name-$version-"*.whl -d "$DEST/PythonHost/site-packages"
done
# Cython sources, C headers and type stubs only matter when building against them.
rm -rf "$DEST/PythonHost/site-packages/lxml/includes"
find "$DEST/PythonHost/site-packages/lxml" "$DEST/PythonHost/site-packages/Crypto" \
  \( -name '*.pyx' -o -name '*.pxd' -o -name '*.pxi' -o -name '*.h' -o -name '*.c' -o -name '*.pyi' \) -delete
# pycryptodome opens its C code with ctypes from .so files beside its modules. Those become frameworks
# below, so it follows the .fwork file instead, as importlib does for extension modules.
"$HOST_PYTHON" -I - "$DEST/PythonHost/site-packages/Crypto/Util/_raw_api.py" <<'PATCH'
import sys
path = sys.argv[1]
source = open(path, encoding='utf-8').read()
anchor = '''            full_name = pycryptodome_filename(dir_comps, filename)
'''
assert source.count(anchor) == 1, 'pycryptodome changed: update the .fwork patch'
open(path, 'w', encoding='utf-8').write(source.replace(anchor, anchor + '''            fwork = full_name[:-len(".so")] + ".fwork"
            if full_name.endswith(".so") and os.path.isfile(fwork):
                with open(fwork) as stream:
                    full_name = os.path.join(os.path.dirname(sys.executable), stream.read().strip())
'''))
PATCH
cp Runtime/PythonHost/host.py Runtime/PythonHost/cancellation.py "$DEST/PythonHost/"
cp -R Runtime/PythonHost/base "$DEST/PythonHost/"

# The bundle is read-only and signed, and installing may change file times: precompile with hashes
# that are never checked against the sources.
"$HOST_PYTHON" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$DEST/python/lib" "$DEST/PythonHost" >/dev/null

# Extension modules into frameworks: Frameworks/<module>.framework/<module>, and <module>.fwork naming
# it (relative to the app) where the .so was. The .origin file points back for importlib.
find "$DEST/python" "$DEST/PythonHost" -name '*.so' | sort | while read -r library; do
  relative="${library#$DEST/}"
  case "$relative" in
    python/lib/python$VERSION/lib-dynload/*) module_path="${relative#python/lib/python$VERSION/lib-dynload/}" ;;
    PythonHost/site-packages/*) module_path="${relative#PythonHost/site-packages/}" ;;
    *) echo "Unexpected extension module $relative" >&2; exit 1 ;;
  esac
  module="$(echo "${module_path%%.*}" | tr / .)"
  framework="Frameworks/$module.framework"
  mkdir -p "$DEST/$framework"
  cp "$XCFRAMEWORK/build/$FAMILY-dylib-Info-template.plist" "$DEST/$framework/Info.plist"
  plutil -replace CFBundleExecutable -string "$module" "$DEST/$framework/Info.plist"
  plutil -replace CFBundleIdentifier -string "com.tvbox.yingxia.python.$(echo "$module" | tr _ -)" "$DEST/$framework/Info.plist"
  mv "$library" "$DEST/$framework/$module"
  if lipo -archs "$DEST/$framework/$module" | grep -q ' '; then
    lipo -thin arm64 "$DEST/$framework/$module" -output "$DEST/$framework/$module.arm64"
    mv "$DEST/$framework/$module.arm64" "$DEST/$framework/$module"
  fi
  echo "$framework/$module" > "${library%.so}.fwork"
  echo "${relative%.so}.fwork" > "$DEST/$framework/$module.origin"
done
# BeeWare's templates say iOS 13 / tvOS 9, but our wheels target 17.0, some tvOS modules 12.0 and the simulator's
# Python.framework 14.0. App Store processing rejects a framework whose binary needs a newer OS than its
# MinimumOSVersion (ITMS-90208), so declare the app's deployment target, which covers them all.
# _ssl and _hashlib link OpenSSL, which Apple lists as a commonly used third-party SDK: TestFlight review rejects
# a framework holding it without a privacy manifest (ITMS-91061). Every module framework gets one (no tracking,
# no data collected, no required-reason APIs), so a module flagged later is covered too.
for framework in "$DEST/Frameworks/"*.framework; do
  plutil -replace MinimumOSVersion -string "$MINIMUM_OS" "$framework/Info.plist"
  cp Config/Python/PrivacyInfo.xcprivacy "$framework/"
  binary="$framework/$(plutil -extract CFBundleExecutable raw "$framework/Info.plist")"
  declared="$(plutil -extract MinimumOSVersion raw "$framework/Info.plist")"
  needed="$(vtool -show-build "$binary" | awk '/minos/ {print $2; exit}')"
  [ "$(printf '%s\n%s\n' "$needed" "$declared" | sort -V | tail -1)" = "$declared" ] ||
    { echo "$(basename "$framework") needs $FAMILY $needed but declares $declared" >&2; exit 1; }
done
echo "Embedded Python $VERSION ($FAMILY $SUPPORT) for $PLATFORM: $DEST ($(du -sh "$DEST" | cut -f1))"
