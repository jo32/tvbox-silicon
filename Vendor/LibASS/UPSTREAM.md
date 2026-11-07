# libass and its text stack

Nothing of these libraries is committed. `Scripts/build-apple-libass.sh` clones each tag, checks its commit, and
builds unmodified sources with Meson into one static library per platform (macOS arm64 + x86_64, iOS, tvOS and
their simulators). `LibASS.xcframework` here is a link to the build in `build/LibASS/`; only libass's public
header (`ass/ass.h`, `ass/ass_types.h`) is exported.

| Library | Upstream | Tag | Commit | License |
| --- | --- | --- | --- | --- |
| libass | https://github.com/libass/libass | 0.17.5 | `4a05d8127f525943ebf45fdc6497c9e665947f0d` | ISC (`LICENSE.libass`) |
| FreeType | https://gitlab.freedesktop.org/freetype/freetype | VER-2-15-0 | `37515cf56ba3349656049edbed89ffc6f6466f2d` | FreeType License, chosen over GPLv2 (`LICENSE.freetype`, `FTL.freetype`) |
| HarfBuzz | https://github.com/harfbuzz/harfbuzz | 15.1.0 | `3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372` | Old MIT (`LICENSE.harfbuzz`); its Universal Shaping Engine tables MIT (`LICENSE.harfbuzz-ms-use`) |
| FriBidi | https://github.com/fribidi/fribidi | v1.0.18 | `15393e4937aa95bcf865d92143735746aeb654fa` | LGPL-2.1-or-later (`LICENSE.fribidi`) |

How they are built:

- libass: CoreText font provider (the system's fonts), no fontconfig, DirectWrite or libunibreak; its assembly
  on arm64 (x86_64 has none: no NASM).
- FreeType: no zlib, bzip2, PNG, Brotli or HarfBuzz; with Apple's `libhvf` (`-Dhvf=enabled`) so it reads the
  system's Hierarchical Variable Fonts (PingFang on iOS 27 is one). `libhvf` is in the SDKs from iOS/tvOS 18.4 and
  macOS 15.4 and is weak-linked: on older systems FreeType never calls it (those systems have no HVF fonts).
- HarfBuzz: with FreeType only (no GLib, ICU, Graphite, CoreText shaper, Cairo, subsetter or tools).
- FriBidi: the library only.

`Sources/TVMedia/TVSubtitles.c` is this project's code on top of it: it hands libass a script or a Matroska
track's events and turns its images into one premultiplied BGRA picture (#576 M3, `Docs/subtitles.md`).
