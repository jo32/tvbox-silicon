# Historical source audit — before the October 4 fixes

Plugin validation date: October 3, 2026. Localization and build validation date: October 4, 2026.

The Mac app executes the subscription's JAR locally. Compatibility remains experimental and source-specific. Full plugin execution on iOS and tvOS is not implemented.

## Mac implementation

The app bundles a trimmed OpenJDK runtime and runs each plugin request in a separate local process. unidbg/Unicorn2 executes the package's original AArch64 Android ELF library and calls `JNI_OnLoad`, `getLoader`, and `getSpider`. The plugin's own loader reads the guard payload. dex2jar converts the dynamically produced DEX into JVM bytecode.

The host implements Context, preferences, Handler, the CatVod Spider contract, and a subset of Android APIs. No external Android device or remote parsing service is required.

The tested package was `jar/fan.txt` from the subscription at `https://raw.githubusercontent.com/qist/tvbox/master/fty.json`.

- SHA-256: `d9e77852563eb609bff49158e698fbf895764d78ce176bab1cac06b6148f7840`
- MD5: `2cc088afa757ba8bafffcfbab4b73ccc`
- Package contents: one outer DEX with 75 classes, ARM and AArch64 Android native libraries, and a guard payload.

The plugin is downloaded from the subscription URL, not distributed with the app. The [static audit](fantaiying-plugin-audit.json) describes the inspected package.

## Latest source audit (October 4, 2026)

All **47 configured entries** were checked. **14 reached a returned media URL successfully; 33 stopped or require unsupported features.** This tests a sample item per source, not every title. A pass means an HTTP response with media/playlist bytes, not verified AVPlayer decoding or every HLS segment. Three entries are JavaScript sources that cannot execute in the current host. Several others are configuration, ranking, push, or informational entries rather than ordinary video catalogs.

The baseline used four workers and the same host JAR as the built Mac app (SHA-256 `2793c03efe063958a9cf1c755f0b2ac5c2353fdd2ccc56ca638568e41cb5bcab`). The downloaded plugin SHA-256 matches the package above. The active app subscription is the same `fty.json` URL. Targeted retests used search when home/category returned nothing; all six drive-search providers returned search results, correcting the earlier audit's claim that their searches were empty.

### Screenshot: 峡谷 on 厂长 / NewCz

The app's captured request log identifies `com.github.catvod.spider.NewCz`. Searching that source finds **峡谷**, ID `movie/20294.html`. Instrumenting a separate diagnostic copy of the converted plugin exposed the exception that its normal detail method catches silently:

1. `www.4kcz.com/movie/20294.html` returns HTTP **403** with a cookie.
2. A retry can return another **403 without Set-Cookie**.
3. NewCz tries to save that missing cookie. `merge.M4.i` throws `NullPointerException: Cannot invoke "String.getBytes()" because "<parameter2>" is null`.
4. `NewCz.detailContent` catches the exception and returns `""`. `LocalJarHost` consequently shows “The plugin returned no content. Try another source.”

The exact detail request succeeded once initially; three further identical detail requests produced **empty, empty, success**. The successful result contains the movie synopsis and two 1080P episodes. Testing its first episode's player request hit the same 403/missing-cookie failure. This establishes an intermittent source rejection plus a plugin error-handling defect, not a permanently missing movie. The screenshot log alone did not contain the hidden exception; the repeated exact-item requests establish this reproducible failure path.

NewCz uses an HTTP client outside the host's shared request logger, explaining why the original app log omitted its remote requests. Common SQLite stub and loopback shutdown warnings also appear in successful sources and do not by themselves explain this failure. Processes are fresh per request, so cookie/session state is discarded; preserving state may help, but was not tested as a fix. Diagnostic instrumentation was kept separate from the app runtime.

Evidence: [captured app log](../build/source-diagnostics/screenshot-request.log), [first failed exact-item replay](../build/source-diagnostics/gorge-repeat-1.log), [second failure](../build/source-diagnostics/gorge-repeat-2.log), [successful replay](../build/source-diagnostics/gorge-repeat-3.json), and [episode-resolution failure](../build/source-diagnostics/gorge-play.log).

### Confirmed app lifecycle defect: 热播 / AppTT

`AppTT.detailContent` initializes an instance JSON field containing playback parser configuration. Its player method returns `{}` when that field is null. The app runs each request in a new process, losing this configuration before play. A controlled replay logged `PARSER_STATE_BEFORE=null` and `PARSER_STATE_AFTER_KEYS=1`; detail followed by play on the same instance returned an HLS URL. This establishes an app runtime defect. That URL was not decoder-tested, and the app's lifecycle was not changed during this audit.

Evidence: [fresh-process empty result](../build/source-diagnostics/apptt-traced.json), [same-process state log](../build/source-diagnostics/apptt-warm.log), and [same-process playback result](../build/source-diagnostics/apptt-warm.json).

### Every configured source

“Media fetched” describes the baseline sample. Other rows incorporate targeted retests where available.

| Source | Result / diagnosed cause |
| --- | --- |
| 豆豆┃片单 | Home was intermittently empty. Retry returned 20 ranking entries without video IDs; these cannot be opened as videos. |
| 🗂我的云盘┃配置 | Configuration/login actions, not playable videos; category/search did not produce an openable video. |
| 👽玩偶哥哥┃4K弹幕 | Search/catalog and detail work; playback returns no media URL and says: 未扫码登录无法观看 ("cannot watch without signing in by QR code"). |
| 🚀叨观荐影┃预告片 | Media fetched successfully. |
| 🎙️易听音乐┃带歌词 | Host bytecode incompatibility: Comparator.comparingLong must use an InterfaceMethodref constant (IncompatibleClassChangeError). |
| 💡聚剧┃四盘 | Detail parser expects JSON but gets non-JSON input (JSONException); plugin swallows the error and returns empty content. |
| 🌞光影┃不卡 | Media fetched successfully. |
| 👒原创┃不卡 | Sampled details returned zero playable episodes. Underlying site/parser cause remains unisolated. |
| 📔厂长┃不卡 | Intermittent upstream HTTP 403; absent Set-Cookie causes a swallowed null-pointer exception. Exact 峡谷 reproduction below. |
| 🌟立播┃不卡 | Media fetched successfully. |
| 👀瓜子┃不卡 | Media fetched successfully. |
| 🍄比特┃不卡 | Media fetched successfully. |
| 🍓糯米┃秒播 | Media fetched successfully. |
| 💮文采┃秒播 | Source www.ghw9zwp5.com returned HTTP 403; its response cannot be parsed as the expected JSON. |
| 🧀奶酪┃秒播 | Media fetched successfully. |
| 📺热播┃多线 | Confirmed host lifecycle defect: detail initializes the plugin playback configuration, but a fresh player process loses it and returns {}. Keeping detail and play in one process returns an HLS URL. |
| 🌸茉莉┃多线 | Resolved media URL returned HTTP 403. |
| 🐻剧圈┃多线 | Resolved media host closed the connection without an HTTP response. |
| 🥝荐片┃多线 | Media fetched successfully. |
| 🏝奥特┃多线 | Media fetched successfully. |
| 🧲新6V┃磁力 | Returns a magnet link; the app has no torrent playback engine. |
| 🦉咕咕┃动漫 | Media fetched successfully. |
| 🚌巴士┃动漫 | Returns parse=1; requires web video detection/additional parsing. |
| ⚽八八┃看球 | Resolved media URL returned HTTP 404 this run (previously also required web parsing). |
| 🏀多多┃回放 | Media fetched successfully. |
| 🏐吃瓜┃看球 | Media fetched successfully. |
| 🎮一直播┃直播 | Room-detail response lacks an object the plugin expects; Alllive.detailContent dereferences null after HTTP 200. |
| 🎶明星┃MV | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 🎧有声┃小说 | Media fetched successfully. |
| 🚑急救┃教学 | Media fetched successfully. |
| 🐯虎牙┃直播 | JavaScript/drpy2 source; the app has no JavaScript spider runtime. |
| 🐟斗鱼┃直播 | JavaScript/drpy2 source; the app has no JavaScript spider runtime. |
| 🎈盘搜┃四盘 | Search works; four sampled detail requests returned empty content. Logs repeatedly report missing android.app.ActivityThread; exact causal link remains unisolated. |
| 🦋易搜┃四盘 | Search works; four sampled detail requests returned empty content. Logs repeatedly report missing android.app.ActivityThread; exact causal link remains unisolated. |
| 🐌盘她┃夸父 | Search/catalog and detail work; playback returns no media URL and says: 未扫码登录无法观看 ("cannot watch without signing in by QR code"). |
| 🐞盘他┃嘟嘟 | Search/catalog and detail work; playback returns no media URL and says: 超时扫码请点刷新,未扫码授权无法观看 ("QR scan timed out, tap refresh; cannot watch without QR authorization"). |
| 🍄抠抠┃搜搜 | Search/catalog and detail work; playback returns no media URL and says: 未扫码登录无法观看 ("cannot watch without signing in by QR code"). |
| 🌈优汐┃搜搜 | Search/catalog and detail work; playback returns no media URL and says: 未扫码登录无法观看 ("cannot watch without signing in by QR code"). |
| 🅱哔哔合集┃弹幕 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 🅱哔哔演唱会┃弹幕 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 📚儿童┃启蒙 | JavaScript/drpy2 source; the app has no JavaScript spider runtime. |
| 📚少儿┃教育 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 📚小学┃课堂 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 📚初中┃课堂 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 📚高中┃课堂 | Search/detail resolve, but play returns a quality array with /proxy?do=bili URLs; quality selection and the plugin media proxy are unsupported. |
| 🛴手机┃推送 | Push-input utility; empty home without a pushed item does not establish an upstream failure. |
| 请勿信视频中任何广告 | Informational subscription entry configured as XPath; the host cannot instantiate its spider. |

Full machine-readable evidence: [baseline](../build/source-diagnostics/all-sources.json), [results with retests](../build/source-diagnostics/results-with-retests.json), [search-provider retests](../build/source-diagnostics/search-retry/results.json). The diagnostic script now preserves completed request envelopes, parameters, and stderr under `evidence/`, supports independent output directories, and continues to search after empty home/category responses. Syntax and controlled empty-home/empty-category fallback checks passed.

### Previously applied compatibility fixes

Earlier testing improved the sample pass count from 6 to 15 by unwrapping pass-through `m3u8` proxy URLs, registering Bouncy Castle for Android-style AES padding, and adding several Android API stubs. The latest baseline passed 14 because NewCz failed intermittently. Those changes do not implement a general plugin proxy, JavaScript runtime, cloud-drive login flow, or complete Android compatibility.

## Tests and builds

- All 24 Swift tests passed after localization was added. Coverage includes missing-ID detail responses, image-prefixed MPEG-TS normalization, subscription parsing, DEX execution limits, locale fallback, format arguments, and structured plugin errors.
- All 117 shared localization keys passed coverage and format checks for English, Traditional Chinese, Simplified Chinese, and Japanese.
- macOS, iOS simulator, and tvOS simulator builds succeeded. Compilation does not establish complete plugin support or physical-device playback.
- The running Mac interface was checked in all four supported languages.

## Limitations

- The Mac integration currently targets plugin packages containing `ftyguard_v8.so`; compatibility with other JARs is not guaranteed.
- Each request uses a separate process with a 60-second deadline. The former `last-request.log` has been replaced by rotating diagnostic files; see `runtime-status.md`.
- Session state does not persist between requests. Flows requiring login, persistent plugin proxies, CAPTCHA handling, or cloud-drive session state are not supported.
- Android API coverage is incomplete; SQLite and other APIs remain unimplemented.
- Web video detection, plugin-provided local media proxies, scrolling comments, magnet links, and proprietary player protocols are not implemented. The Mac HLS adapter only handles supported media framing; it does not implement arbitrary plugin proxies.
- iOS and tvOS retain the basic DEX interpreter without JIT. The controlled test method executes 44 instructions and returns 42. This is not full CatVod compatibility.

## Build and reproduce

Run `Scripts/build-java-host.sh`, then regenerate the Xcode project and build the Mac target. The host build requires JDK 19 and Maven; `JAVA_HOME` and `MAVEN_BIN` can select their locations. The bundled runtime is approximately 128 MB and retains the JRE's `legal` directory.

See the [README](../README.md) for complete build, localization, and inspection commands. Runtime inspection and the controlled DEX probe are separate from the real Mac plugin execution path.
