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

[FongMi/TV](https://github.com/FongMi/TV) is a GPL-3.0 reference implementation. The local reference checkout, when present, retains its own Git history and license. It is not included as an app build target. Its `quickjs/src/main/assets/js/lib/cheerio.min.js` and `crypto-js.js` assets (commit `c616c0aa3613e87529791587a9f71b78c278c991`) are copied unmodified into `Runtime/ScriptHost/assets/js/lib/` and bundled with the script host. The upstream license is retained as `Runtime/ScriptHost/LICENSE.assets` and `ScriptHost/LICENSE.assets` in the app. Embedded library copyright notices are preserved.

## JavaScript runtime

The bundled standalone Node.js binary retains its complete distributed license and third-party notices in `ScriptHost/LICENSE.node`. `Scripts/build-script-host.sh` copies that file from the selected Node distribution. The development validation used Node 25.0.0 on macOS arm64. Subscription scripts and remote modules are downloaded on demand and are not bundled.
