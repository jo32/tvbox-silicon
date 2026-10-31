# Third-Party Dependencies

Yingxia's original code is licensed under GPL-3.0-only; see the root [LICENSE](../LICENSE). This project license does not replace or relicense third-party components. Their existing license texts, copyright notices, and redistribution requirements continue to apply.

## Shared DEX interpreter

[DexLoom](https://github.com/speedyfriend433/DexLoom) is distributed under the MIT License. The vendored license and version record are retained in `Vendor/DexRuntime/`. The app includes its license text in `App/Resources/ThirdPartyNotices.txt`.

## Plugin runtime (Java host, all platforms)

| Dependency | License | Notes |
| --- | --- | --- |
| [unidbg](https://github.com/zhkl0228/unidbg) | Apache-2.0 | Android native library and JNI compatibility |
| [Unicorn](https://github.com/unicorn-engine/unicorn) | GPL-2.0 | CPU emulation, distributed through the `unidbg-unicorn2` Maven dependency |
| [dex2jar](https://github.com/ThexXTURBOXx/dex2jar) | Apache-2.0 | DEX-to-JVM bytecode conversion |
| [Eclipse Temurin OpenJDK](https://adoptium.net/) | GPL-2.0 with Classpath Exception | Mac only; the bundled runtime retains its `legal` directory |
| OkHttp | Apache-2.0 | HTTP client |
| Gson | Apache-2.0 | JSON serialization |
| Android JSON implementation | Apache-2.0 | Android-compatible JSON behavior |
| jsoup | MIT | HTML parsing |

Direct Maven dependency versions are recorded in `Runtime/JavaHost/pom.xml`. Refer to each dependency's own license and notices for its complete terms and transitive components.

Third-party source plugins are loaded from the configured subscription URL and are not bundled with the app. The controlled test JAR is maintained by this project.

## iPhone, iPad and Apple TV plugin runtime

The iOS and tvOS apps link the JVM and the native emulation stack statically. Their license texts are bundled from `App/Resources/RuntimeLicenses/`.

| Dependency | License | Notes |
| --- | --- | --- |
| [OpenJDK mobile](https://github.com/openjdk/mobile) | GPL-2.0 with Classpath Exception | Zero interpreter, commit pinned in `Scripts/build-apple-jvm.sh`, with local patches under `Runtime/AppleRuntime/patches/` |
| [Unicorn](https://github.com/unicorn-engine/unicorn) | GPL-2.0 (some parts LGPL-2.0) | Built with the TCI interpreter, commit pinned in `Scripts/build-apple-interpreter.sh` |
| [Capstone](https://github.com/capstone-engine/capstone) | BSD-3-Clause (LLVM-derived parts under the LLVM license) | Disassembler used by unidbg |
| [Keystone](https://github.com/keystone-engine/keystone) | GPL-2.0 (LLVM-derived parts under the LLVM license) | Assembler used by unidbg |
| [libffi](https://github.com/libffi/libffi) 3.4.8 | MIT | Foreign calls for the JVM |
| [JNA](https://github.com/java-native-access/jna) | Apache-2.0 | Native bindings used by unidbg |

How Unicorn's and Keystone's GPL-2.0 terms apply to apps that embed this runtime is still an open question (see the [runtime extraction plan](runtime-extraction-plan.md)).

## JavaScript engine

[QuickJS-ng](https://github.com/quickjs-ng/quickjs) v0.17.0 (MIT) runs the bundled lightweight source ports on every platform and JavaScript sources on iPhone, iPad and Apple TV. Its engine sources are vendored unmodified in `Vendor/QuickJS/`, with the license and an upstream record (`UPSTREAM.md`).

## Media repackaging

[FFmpeg](https://ffmpeg.org) n8.1.3 (LGPL-2.1-or-later) reads MKV, AVI, FLV, WMV, RMVB and MPEG files so AVPlayer can play them. `Scripts/build-apple-ffmpeg.sh` builds it from unmodified upstream sources with only LGPL parts enabled and links it statically; `Vendor/FFmpeg/` keeps the license and an upstream record (`UPSTREAM.md`). The complete source of the app, including that script, is available under the GPL, so the library can be rebuilt and relinked.

[dav1d](https://code.videolan.org/videolan/dav1d) 1.5.4 (BSD-2-Clause, `Vendor/FFmpeg/LICENSE.dav1d`) decodes AV1 for that library on devices without an AV1 hardware decoder. The same script builds it from unmodified upstream sources into the static library.

## Reference implementation

The built-in Hongguo source uses the catalog and player response formats from
[jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama), commit
`2d2314213c2457c63f84055518d38a27210c7ad1` (GPL-3.0). Its `src/native/app-source.js`
and `sm3.js` are adapted as ES modules under `Sources/TVCore/ScriptAssets/sites/hongguo/`.
The signing algorithms' earlier drpys/hongguoTV attribution, modification record,
and full GPL license are retained there and bundled with the app. Changes dated
2026-10-12 replace Node/Electron dependencies with QuickJS and native Apple crypto.
The built-in Xifan and Hema sources (`Xifan.js`, `Hema.js`) follow its `src/native/xifan.js` and
`src/native/hema.js` at commit `f210689c4adbf0986e3412cdb12a1c710c5dd611` (v4.1); the record is in the same
`NOTICE.txt`.
The catalog adapter and native sample-by-sample CENC media preparation are implemented
for Yingxia. No Electron, FFmpeg, captured user cookies, or fixed device IDs are bundled
for this source.

[FongMi/TV](https://github.com/FongMi/TV) is a GPL-3.0 reference implementation. The local reference checkout, when present, retains its own Git history and license. It is not included as an app build target. Its `quickjs/src/main/assets/js/lib/cheerio.min.js` and `crypto-js.js` assets (commit `c616c0aa3613e87529791587a9f71b78c278c991`) are copied unmodified into `Runtime/ScriptHost/assets/js/lib/` and bundled with the script host. Its `cat.js`, `gbk.js`, and `similarity.js` assets are copied unmodified from commit `4a11089cb6a1377cbf437ebccd24468296357132` into the same directory. The upstream license is retained as `Runtime/ScriptHost/LICENSE.assets` and `ScriptHost/LICENSE.assets` in the app. Embedded library copyright notices are preserved.

## Node.js (Mac)

The bundled standalone Node.js binary retains its complete distributed license and third-party notices in `ScriptHost/LICENSE.node`. `Scripts/build-script-host.sh` copies that file from the selected Node distribution. The Mac release (`Scripts/build-universal-hosts.sh`) joins the official nodejs.org arm64 and x64 builds of the same version into one universal binary and ships their LICENSE. The development validation used Node 25.0.0 on macOS arm64. Subscription scripts and remote modules are downloaded on demand and are not bundled.

## Python runtime (Mac)

`Scripts/build-python-host.sh` bundles a relocatable CPython from [python-build-standalone](https://github.com/astral-sh/python-build-standalone), installed by uv. CPython is distributed under the PSF License; its license and the notices for its bundled components remain at `PythonHost/python/lib/python3.12/LICENSE.txt`. The validation used CPython 3.12.11 on macOS arm64.

The spider libraries are pinned in `Runtime/PythonHost/requirements.txt`. Each one keeps its license in its `*.dist-info` directory under `PythonHost/site-packages`.

| Dependency | License |
| --- | --- |
| requests, cryptography | Apache-2.0 (cryptography is also available under BSD-3-Clause) |
| urllib3, charset-normalizer, beautifulsoup4, soupsieve, cffi | MIT |
| idna, lxml (bundles libxml2 and libxslt under MIT), pyquery, cssselect, pycparser | BSD |
| pycryptodome | BSD-2-Clause and public domain |
| certifi | MPL-2.0 |
| typing-extensions | PSF-2.0 |

`Runtime/PythonHost/base/spider.py` is an original implementation of the CatVod Python spider interface. It contains no TVBox source code. Subscription spiders are downloaded on demand and are not bundled.
