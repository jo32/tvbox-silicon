# Third-Party Dependencies

## Shared DEX interpreter

[DexLoom](https://github.com/speedyfriend433/DexLoom) is distributed under the MIT License. The vendored license and version record are retained in `Vendor/DexRuntime/`. The app includes its license text in `App/Resources/ThirdPartyNotices.txt`.

## Mac plugin runtime

| Dependency | License | Notes |
| --- | --- | --- |
| [unidbg](https://github.com/zhkl0228/unidbg) | Apache-2.0 | Android native library and JNI compatibility |
| [Unicorn](https://github.com/unicorn-engine/unicorn) | GPL-2.0 | CPU emulation, distributed through the `unidbg-unicorn2` Maven dependency |
| [dex2jar](https://github.com/ThexXTURBOXx/dex2jar) | Apache-2.0 | DEX-to-JVM bytecode conversion |
| [Eclipse Temurin OpenJDK](https://adoptium.net/) | GPL-2.0 with Classpath Exception | The bundled runtime retains its `legal` directory |
| OkHttp | Apache-2.0 | HTTP client |
| Gson | Apache-2.0 | JSON serialization |
| Android JSON implementation | Apache-2.0 | Android-compatible JSON behavior |
| jsoup | MIT | HTML parsing |

Direct Maven dependency versions are recorded in `Runtime/JavaHost/pom.xml`. Refer to each dependency's own license and notices for its complete terms and transitive components.

Third-party source plugins are loaded from the configured subscription URL and are not bundled with the app. The controlled test JAR is maintained by this project.

## Reference implementation

[FongMi/TV](https://github.com/FongMi/TV) is a GPL-3.0 reference implementation. The local reference checkout, when present, retains its own Git history and license. It is not included as an app build target. Its `quickjs/src/main/assets/js/lib/cheerio.min.js` and `crypto-js.js` assets (commit `c616c0aa3613e87529791587a9f71b78c278c991`) are copied unmodified into `Runtime/ScriptHost/assets/js/lib/` and bundled with the script host. Its `cat.js`, `gbk.js`, and `similarity.js` assets are copied unmodified from commit `4a11089cb6a1377cbf437ebccd24468296357132` into the same directory. The upstream license is retained as `Runtime/ScriptHost/LICENSE.assets` and `ScriptHost/LICENSE.assets` in the app. Embedded library copyright notices are preserved.

## JavaScript runtime

The bundled standalone Node.js binary retains its complete distributed license and third-party notices in `ScriptHost/LICENSE.node`. `Scripts/build-script-host.sh` copies that file from the selected Node distribution. The development validation used Node 25.0.0 on macOS arm64. Subscription scripts and remote modules are downloaded on demand and are not bundled.

## Python runtime

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
