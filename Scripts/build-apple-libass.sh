#!/bin/bash
# Builds libass, the renderer that draws ASS/SSA subtitles with their fonts, positions, outlines, drawings and
# karaoke (Docs/subtitles.md, M3), with the libraries it needs: FreeType (glyphs), HarfBuzz (shaping), FriBidi
# (right-to-left text). Fonts come from the system through CoreText (libass's own provider), so there is no
# fontconfig. Nothing else: no PNG, zlib, bzip2, brotli, glib, ICU or graphite.
# Output: build/LibASS/LibASS.xcframework (Vendor/LibASS links to it), one static library per platform holding all
# four, and libass's headers only.
# Builds are kept in a cache shared by every checkout and worktree, one per recipe (the lines between RECIPE and
# END below), so a checkout usually just links the one already built (about 3 minutes otherwise; the build tools
# need Python 3, from which Meson and Ninja are installed into the cache).
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${TVBOX_LIBASS_CACHE:-$HOME/Library/Caches/tvbox-libass}"
SIGNATURE="$(sed -n '/^# RECIPE$/,/^# END$/p' "$0" | shasum -a 256 | cut -c1-16)"
OUTPUT="$CACHE/$SIGNATURE/LibASS.xcframework"
LINK="$PWD/build/LibASS/LibASS.xcframework"
link() {
  mkdir -p "$(dirname "$LINK")"
  [ "$(readlink "$LINK" 2>/dev/null)" = "$OUTPUT" ] || { rm -rf "$LINK"; ln -s "$OUTPUT" "$LINK"; }
}
if [ -f "$OUTPUT/Info.plist" ]; then
  link
  echo "libass is up to date: $OUTPUT"
  exit 0
fi
WORK="$CACHE/work"
# Two checkouts building at once would share the work folder.
mkdir -p "$CACHE"
mkdir "$CACHE/lock" 2>/dev/null || { echo "Another libass build is running (or remove $CACHE/lock)" >&2; exit 1; }
trap 'rmdir "$CACHE/lock"' EXIT
mkdir -p "$WORK"

# RECIPE
# Each source is a tag, checked against the commit it named when it was chosen.
fetch() {
  local folder=$1 url=$2 tag=$3 commit=$4
  if [ ! -f "$WORK/$folder/meson.build" ]; then
    rm -rf "$WORK/$folder.download"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$WORK/$folder.download"
    test "$(git -C "$WORK/$folder.download" rev-parse HEAD)" = "$commit"
    rm -rf "$WORK/$folder"; mv "$WORK/$folder.download" "$WORK/$folder"
  fi
}
fetch libass-0.17.5 https://github.com/libass/libass.git 0.17.5 4a05d8127f525943ebf45fdc6497c9e665947f0d
fetch freetype-2.15.0 https://gitlab.freedesktop.org/freetype/freetype.git VER-2-15-0 37515cf56ba3349656049edbed89ffc6f6466f2d
fetch harfbuzz-15.1.0 https://github.com/harfbuzz/harfbuzz.git 15.1.0 3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372
fetch fribidi-1.0.18 https://github.com/fribidi/fribidi.git v1.0.18 15393e4937aa95bcf865d92143735746aeb654fa
# The build tools, in a folder of their own (the same versions FFmpeg's dav1d uses).
TOOLS="$WORK/meson-1.9.1-ninja-1.13.2"
if [ ! -x "$TOOLS/bin/ninja" ]; then
  rm -rf "$TOOLS"
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --quiet --disable-pip-version-check meson==1.9.1 ninja==1.13.2
fi

# Builds one library of a slice with Meson, statically, into the slice's prefix, finding the slice's earlier
# libraries (and never one installed on the Mac) through pkg-config.
meson_build() {
  local name=$1 library=$2; shift 2
  local build="$WORK/build-$name/$library" prefix="$WORK/install-$name"
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH= \
  "$TOOLS/bin/meson" setup "$build" "$WORK/$library" --cross-file "$WORK/build-$name/cross.txt" \
    --prefix "$prefix" --libdir lib --buildtype release --default-library static --wrap-mode nofallback \
    -Db_ndebug=true "$@" > "$build.setup.log" 2>&1 || { tail -40 "$build.setup.log"; exit 1; }
  PATH="$TOOLS/bin:$PATH" ninja -C "$build" install > "$build.build.log" 2>&1 || { tail -40 "$build.build.log"; exit 1; }
}

build_slice() {
  local name=$1 sdk=$2 arch=$3 triple=$4
  local prefix="$WORK/install-$name" sysroot cc cxx asm=enabled
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  cxx="$(xcrun --sdk "$sdk" --find clang++)"
  # No nasm on the build Mac: Intel Macs draw subtitles without libass's x86 assembly. Arm's needs none.
  [ "$arch" = x86_64 ] && asm=disabled
  rm -rf "$WORK/build-$name" "$prefix"; mkdir -p "$WORK/build-$name"
  cat > "$WORK/build-$name/cross.txt" <<CROSS
[binaries]
c = '$cc'
cpp = '$cxx'
objc = '$cc'
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'
pkg-config = '$(command -v pkg-config)'
[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sysroot', '-fno-common']
cpp_args = ['-target', '$triple', '-isysroot', '$sysroot', '-fno-common']
objc_args = ['-target', '$triple', '-isysroot', '$sysroot']
c_link_args = ['-target', '$triple', '-isysroot', '$sysroot']
cpp_link_args = ['-target', '$triple', '-isysroot', '$sysroot']
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
CROSS
  # HVF: Apple's Hierarchical Variable Fonts, which iOS, tvOS and macOS 26 and later use for some system fonts
  # (PingFang, the Chinese fallback, among them). FreeType draws them through the SDK's libhvf (iOS and tvOS 18.4,
  # macOS 15.4), checking at run time; the app links it weakly, so older systems start without it.
  meson_build "$name" freetype-2.15.0 -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled \
    -Dbrotli=disabled -Dhvf=enabled -Dmmap=enabled
  meson_build "$name" fribidi-1.0.18 -Ddocs=false -Dbin=false -Dtests=false -Dfuzzer_ldflags=
  meson_build "$name" harfbuzz-15.1.0 -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dchafa=disabled -Dicu=disabled -Dgraphite2=disabled -Dcoretext=disabled -Dtests=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dintrospection=disabled -Dbenchmark=disabled -Dsubset=disabled
  meson_build "$name" libass-0.17.5 -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled \
    -Dlibunibreak=disabled -Dasm=$asm -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled \
    -Dcheckasm=disabled -Drequire-system-font-provider=true
  # One archive per slice, so the xcframework names a single library.
  libtool -static -no_warning_for_no_symbols -o "$prefix/libASS.a" \
    "$prefix"/lib/libass.a "$prefix"/lib/libharfbuzz.a "$prefix"/lib/libfreetype.a "$prefix"/lib/libfribidi.a
  rm -rf "$prefix/headers"; mkdir -p "$prefix/headers"; cp -R "$prefix/include/ass" "$prefix/headers/ass"
  echo "libass $name built"
}

build_slice macos-arm64 macosx aarch64 arm64-apple-macos14.0
build_slice macos-x86_64 macosx x86_64 x86_64-apple-macos14.0
build_slice ios iphoneos aarch64 arm64-apple-ios17.0
build_slice ios-simulator iphonesimulator aarch64 arm64-apple-ios17.0-simulator
build_slice tvos appletvos aarch64 arm64-apple-tvos17.0
build_slice tvos-simulator appletvsimulator aarch64 arm64-apple-tvos17.0-simulator
# END

mkdir -p "$WORK/install-macos"
lipo -create "$WORK/install-macos-arm64/libASS.a" "$WORK/install-macos-x86_64/libASS.a" -output "$WORK/install-macos/libASS.a"
rm -rf "$WORK/install-macos/headers"; cp -R "$WORK/install-macos-arm64/headers" "$WORK/install-macos/headers"
PARTIAL="$CACHE/$SIGNATURE.partial"
rm -rf "$OUTPUT" "$PARTIAL"; mkdir -p "$PARTIAL"
arguments=()
for slice in macos ios ios-simulator tvos tvos-simulator; do
  arguments+=(-library "$WORK/install-$slice/libASS.a" -headers "$WORK/install-$slice/headers")
done
xcodebuild -create-xcframework "${arguments[@]}" -output "$PARTIAL/LibASS.xcframework" > /dev/null
rm -rf "$(dirname "$OUTPUT")"; mv "$PARTIAL" "$(dirname "$OUTPUT")"
link
echo "libass 0.17.5: $OUTPUT"
