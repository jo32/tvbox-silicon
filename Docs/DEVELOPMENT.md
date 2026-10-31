# Developer guide

Build steps, runtime architecture, verification tools, and implementation notes for Yingxia. For an overview of the app, see the [README](../README.md).

Yingxia bundles a JVM, an Android ELF/JNI compatibility layer, and a DEX converter so it can run plugin sources locally. The Mac runs JAR sources in a bundled desktop JVM, and JavaScript and Python sources in bundled Node and CPython. iOS and tvOS run JAR sources in-process through an embedded interpreter-only JVM and JavaScript sources on QuickJS; they have no Python. The embedded runtime plays real subscriptions on a physical Apple TV; all-source parity with the Mac is not measured. See the [on-device runtime status](on-device-runtime-status.md) for the design, measurements and limitations.

## Build and run

### Requirements

- Xcode with the SDKs for the platforms you want to build.
- XcodeGen to regenerate `TVBox.xcodeproj` from `project.yml`.
- JDK 19 and Maven to build the bundled Mac plugin runtime.
- A standalone macOS Node.js binary and its distributed LICENSE for the JavaScript host (`NODE_BIN` and `NODE_LICENSE` can select them).
- [uv](https://docs.astral.sh/uv/) for the Python host. It installs a relocatable python-build-standalone CPython; `PYTHON_HOME` can select another relocatable prefix.
- Python 3 for localization checks and plugin inspection scripts.
- Git and network access once, to fetch FFmpeg's and dav1d's sources and dav1d's build tools (Meson and Ninja, from PyPI into the FFmpeg cache) for `Scripts/build-apple-ffmpeg.sh`.

The Mac app uses its bundled Java runtime; users do not need a separate Java installation. Physical iOS and tvOS devices require your own development team and signing configuration in Xcode. No account, certificate, or development team is preset.

### Prepare the project

Run these commands from the repository root:

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 19)"
Scripts/build-java-host.sh
Scripts/build-script-host.sh
Scripts/build-python-host.sh
Scripts/build-apple-ffmpeg.sh
xcodegen generate
```

`Scripts/build-apple-ffmpeg.sh` builds the small FFmpeg (LGPL, demuxers, the MP4 muxer, and the decoders the conversion path needs, with dav1d for AV1) that plays MKV, AVI, FLV, WMV and RMVB files; see [MKV playback](mkv-playback-plan.md). The first run takes about five minutes (more on a busy Mac). Builds are kept in `~/Library/Caches/tvbox-ffmpeg`, so other checkouts and worktrees of the same recipe only link `build/FFmpeg/FFmpeg.xcframework` to it; `Vendor/FFmpeg` points there. `Scripts/verify.sh` and the release scripts run it first.

The runtime script uses `MAVEN_BIN` if set, otherwise the local Maven binary under `build/tools/` when available, then `mvn` from `PATH`. It writes the Mac runtime to `build/JavaHost/`, which the Mac target includes as a folder resource. This generated directory is not committed, so prepare it before building a fresh checkout.

Open `TVBox.xcodeproj` and select a scheme:

| Scheme | Destination |
| --- | --- |
| `TVBox-macOS` | My Mac |
| `TVBox-iOS` | iPhone or iPad simulator/device |
| `TVBox-tvOS` | Apple TV simulator/device |

Each platform uses a separate bundle identifier. Generated app property lists are stored in `Config/`. Regenerate the project after changing `project.yml` or adding app source files or resources. Rebuild the Java host after changing `Runtime/JavaHost/`, the script host after changing `Runtime/ScriptHost/`, and the Python host after changing `Runtime/PythonHost/`. The script build copies Node and its license into `build/ScriptHost/`, and the Python build assembles CPython, the pinned spider libraries, and the host into `build/PythonHost/`; both are required Mac folder resources.

### Build the Mac app from the command line

```sh
xcodebuild -project TVBox.xcodeproj -scheme TVBox-macOS \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-mac \
  CODE_SIGNING_ALLOWED=NO build
open build/DerivedData-mac/Build/Products/Debug/TVBox-macOS.app
```

## Features

- Import TVBox JSON subscriptions by URL, with a default URL prefilled. Several subscriptions merge into one source list (`SubscriptionMerge`); each source keeps its origin, and failing sources cool down and search last (`SourceHealth`).
- Save subscription snapshots, origin URLs, import dates, and favorite channels. A failed refresh preserves the last successfully imported configuration.
- Preserve plugin-specific fields such as `ext`, `spider`, and rules. Resolve relative URLs against the final response URL.
- Browse M3U and TVBox TXT live playlists, filter groups, search channels, and save favorites. Support configured User-Agent and Referer headers. Built-in Bilibili, Douyu, Huya and Douyin live rooms sit beside them.
- Browse standard type 1/type 4 JSON sources: home pages, categories, search, pagination, details, playback sources, episodes, and resolved media URLs.
- Run type 3 plugin sources (JAR, JavaScript, and Python on Mac). Bundled lightweight ports of common sources (`Sources/TVCore/ScriptAssets/sites/`) run first on QuickJS, with the original plugin as the fallback.
- Built-in Bilibili (video, live, QR sign-in, and casts from the Bilibili phone app on Apple TV and Mac) and Hongguo short dramas, appended to the displayed subscription.
- Play media with AVPlayer, display playback errors, and retry failed requests. On Mac, a private loopback HLS adapter handles supported image-prefixed MPEG-TS segments.
- Playback history, Continue Watching, intro/outro skipping, automatic next episode and automatic danmaku ([library and cache notes](LIBRARY_CACHE.md)).
- Offline downloads, resumable, played back through a loopback server (`Downloads.swift`, `DownloadTransfer.swift`, `LocalMediaServer.swift`). tvOS keeps them in Caches, which the system may purge.
- Music: search, albums, playlists, a queue, lyrics and lossless playback (see [Music](#music)).
- Run the bundled DEX test JAR and inspect subscription plugins for DEX files and Android libraries. The inspection tool can check an inline MD5 fingerprint.

Playback depends on the source, media format, device decoder, and network availability. Unsupported features include full CatVod/Android API compatibility, arbitrary desktop JVM applications, web video detection, magnet links, multiple-quality playback responses, XML collection APIs, EPG, and cloud sync. Complex playlist extensions and header requirements still need source-by-source verification.

## Built-in Hongguo source

Hongguo is appended alongside Bilibili to the displayed subscription, without changing
the imported document. It uses the bundled QuickJS runtime on macOS, iOS and tvOS.
The web catalog provides live-action, animated and AI dramas, four rankings, search,
and complete episode IDs. Search currently exposes one batch because the website
ignores its page parameter; category and ranking pagination follow the source.

Playback first requests the exact episode through the app's signed model endpoint
and its returned fallback endpoint. The adapter selects H.264/HEVC and resolves
encrypted media URLs locally. Playback registers a virtual MP4 with AVFoundation's
resource loader. Small HTTP Range requests read the MP4 sample tables (even when
the moov is at the end), then fetch and decrypt only requested samples using native
AES-CTR. Seeking reads the destination ranges without downloading the preceding
media. Responses that ignore Range or return a different range are rejected.
App media keeps the app endpoint's User-Agent. It omits Referer initially and retries
HTTP 403 once with the app Referer, retaining the successful policy for subsequent
ranges. Some CDN nodes reject the web browser headers even when another node works.

The player and resource loader use a roughly 60-second forward window. Decrypted
ranges have a 16 MB memory limit and expire as the playhead advances or seeks;
stopping playback cancels pending requests and clears those ranges. Playback creates
no complete movie on disk. Explicit offline downloads retain the complete-file
preparation path through `preparePlayback(_:forDownload:)`, with disposable files
eligible for cleanup after an hour at 512 MB, or after a day regardless of size.
If app playback is unavailable, the adapter tries the selected episode's public web
video. It does not substitute another episode or truncate the full episode list to
the web preview count. Availability and quality still depend on the upstream response.

`swift run TVBoxProbe --hongguo-check [series ID] [episode number]` checks catalog,
search, rankings, details, first-frame timing, bytes fetched before playback,
paused buffering, and forward/backward seeking. `--hongguo-play <series ID> [episode number]`
isolates playback from catalog/search availability. `HongguoTests`
cover the QuickJS signing/crypto bridge, exact episode selection, parsing and CENC
sample/subsample decryption using a NIST AES-CTR vector, middle-of-sample range reads,
tail metadata, cache reuse, cancellation, the forward window, and invalid HTTP Range
responses, app media headers, and bounded Referer retries. On tvOS, diagnostic logs
are stored under `Library/Caches/com.tvbox.yingxia/Logs` so they can be retrieved
from the app container after a device failure. Successful platform builds
do not establish playback on physical iPhone or Apple TV devices.

On 2026-10-12, the live probe returned all 69 episode IDs for series
`7686713195246930968`. Episodes 4 and 69 both played at 1080×1920 on macOS,
advanced past two seconds, and sought successfully near the end. Page 2 of all
seven catalog/ranking categories returned items. These are sampled live checks,
not a guarantee that every episode or title is available.

The subsequent streaming check on episode 69 resolved in 0.61 s and produced its
first frame in 1.93 s, after receiving 2.84 MB of the 13.28 MB, 157.5-second file.
With playback paused at 2.1 s, buffered media ended at 63.7 s and the received-byte
count stayed unchanged across consecutive checks. Seeking near the end and back
to 5 s both succeeded. These timings are one local network sample, not a latency
guarantee.

## Languages

English (`en`) is the source and fallback language. Traditional Chinese (`zh-Hant`), Simplified Chinese (`zh-Hans`), and Japanese (`ja`) are supported on all three platforms. The app follows the system's preferred languages or Apple's per-app language setting.

Subscription-provided source names, channel names, categories, and video titles retain their original text.

### Contributor conventions

- Write project documentation, source comments, and developer-facing diagnostics in English.
- Keep app-owned UI copy and user-facing errors in localization resources. Use `L10n.text("English source text")` with format arguments for dynamic values.
- Add every new key to all four `Sources/TVCore/Resources/<language>.lproj/Localizable.strings` files.
- Keep localized app names and permission text in `App/Resources/<language>.lproj/InfoPlist.strings`.
- Keep translated labels separate from persistent identifiers and plugin request values.
- Preserve upstream license text, third-party source content, and multilingual test fixtures.

## Project layout

| Path | Purpose |
| --- | --- |
| `App/` | Shared SwiftUI screens and platform-specific playback integration |
| `Sources/TVCore/` | Subscription models, networking, catalogs, built-in sources, music, downloads, localization, and runtime boundaries |
| `Sources/TVCore/ScriptAssets/` | Bundled QuickJS source ports and their shared helpers |
| `Sources/TVBoxProbe/` | Command-line plugin inspection, source checks, and basic DEX execution probes |
| `Runtime/JavaHost/` | The Java plugin host for all platforms: Android API adapters, DEX conversion, and the native plugin bridge |
| `Runtime/AppleRuntime/` | The embedded JVM for iOS and tvOS: OpenJDK and Unicorn patches, native bootstrap, and the JVM spike app |
| `Runtime/ScriptHost/`, `Runtime/PythonHost/` | The Mac's Node and CPython hosts for JavaScript and Python sources |
| `Runtime/sandbox/` | The Seatbelt profile for the Mac's plugin processes ([plan](sandbox-hardening-plan.md)) |
| `Vendor/DexRuntime/` | Vendored experimental DEX interpreter and its license |
| `Vendor/QuickJS/` | Vendored QuickJS-ng engine and this project's bridge |
| `Tests/` | Core tests and controlled Java/DEX fixtures |
| `Scripts/` | Build, verification, and inspection tools |
| `Docs/` | Install guide, runtime status, plans, and dependency notes |
| `website/` | The website at yingxia.getmegaportal.com, including `public/releases.json`, the messages to users in `public/messages.json` and the AltStore source `public/altstore.json` |
| `project.yml` | XcodeGen project definition |

## Verification

After preparing the Mac runtime:

```sh
python3 Scripts/check-localizations.py
swift test
Scripts/verify.sh
```

The localization check verifies translation coverage, format arguments, and static Swift key references. `Scripts/verify.sh` runs the Swift tests, native JNI bridge tests, Java host tests, and unsigned macOS, iOS device-SDK, and tvOS device-SDK builds. The native bridge tests (`Scripts/test-apple-runtime-bridge.sh`) use the installed JDK and controlled Java responses to exercise malformed Unicode, exceptions, and concurrent requests through the production bridge. Successful builds do not establish plugin compatibility or device playback support.

`Scripts/test-tv-ui.sh <tvOS simulator UUID>` drives the Siri Remote in a separate tvOS bundle (no JAR runtime, isolated data) against `Scripts/qa-server.py`: `TVNavigationUITests` opens a video page whose details never arrive (`-qaPage open-detail:qa-stall:1`) and checks that Back returns to the previous page instead of leaving the app. Focus starts in the tab sidebar, so the test moves right into the page.

The command-line probe supports controlled static DEX execution and live-playlist inspection:

```sh
swift run TVBoxProbe App/Resources/runtime-probe.jar 'Ltvbox/RuntimeProbe;' run
swift run TVBoxProbe --live-check
```

Its execution mode only calls a no-argument static DEX method returning an integer. It does not expose the Mac app's full CatVod plugin host. The live check uses the network and reports parsed channel counts, not playback success.

### Test every source of a subscription

```sh
Scripts/test-sources.py [subscription-url] [--workers N] [--only text] [--output directory]
```

Runs each source through home, category or search, detail, play, and a fetch of the returned media URL, using the same persistent Java, JavaScript, and Python hosts as the Mac app (build it first with `Scripts/build-java-host.sh`). It needs the network, takes several minutes for a large subscription, and writes `build/site-test/results.json`. Use `--output` to preserve separate runs and repeat `--only` to select multiple sources. The harness keeps each completed JAR request’s parameters, response, and stderr under `evidence/`, and tries search when a home or category is empty. A pass means the returned media URL responded; it does not establish AVPlayer decoding or every HLS segment’s availability. Some sources are intermittent, so rerun before concluding that one is dead.

### Inspect a subscription JAR without executing it

```sh
mkdir -p build
curl --fail -L -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
  'https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt' -o build/fan.jar
swift run TVBoxProbe build/fan.jar
python3 Scripts/inspect-plugin.py build/fan.jar
```

### Regenerate the DEX test fixture

The fixture source is `Tests/Java/RuntimeProbe.java`. Compiled fixtures are included, so ordinary test runs do not need the fixture toolchain. Regeneration requires JDK 17+ and Google D8:

```sh
mkdir -p build/tools
curl --fail -L 'https://storage.googleapis.com/r8-releases/raw/8.3.37/r8lib.jar' -o build/tools/r8lib.jar
Scripts/build-runtime-probe.sh
```

## Plugin architecture and references

CatVod plugins may contain DEX, JVM classes, Android native libraries, or a guarded payload. The Mac host loads ordinary plugins without requiring `ftyguard_v8.so`; the FTY-specific path is selected only when that library is present. Ordinary DEX (including multidex) is converted with JVM stack frames, while original assets remain accessible. Plugin Init/helpers remain isolated from the host contract, and each source's `jar` override and relative extension path are respected.

Plugin JNI calls and native-library loads can run through the Android ARM64 guest rather than macOS `dlopen`. This does not supply a complete Android device: Android UI, unsupported native operations, private guards, login requirements, and unavailable servers can still prevent a source from loading. A successful subscription import or empty home response does not establish successful search or playback.

Each type 3 source is routed like TVBox: a `.js` api is a JavaScript spider, a `.py` api (or a legacy `py_` key whose `ext` is the script) is a Python spider, and any other api is a JAR class. On Mac, JavaScript runs in bundled Node and Python in bundled CPython, one reusable child process per source (at most three; idle ones stop after five minutes; requests have a 60-second deadline), and JAR sources share one long-lived desktop JVM (`PluginProcess`) that serves the same requests as the embedded JVM on iOS and tvOS. All of these children run under the spider sandbox. On iOS and tvOS, JavaScript runs on QuickJS and JAR sources in the embedded JVM. JavaScript spiders get HTTP, HTML parsing, module loading, and preference adapters. Python spiders get the CatVod `base.spider` API, `requests`, `lxml`, `bs4`, `pyquery`, `pycryptodome`, and `cryptography`, and their `localProxy` responses are served from a loopback port. Sources follow one strategy (`SourceStrategy`): only sources this platform can run are listed, in runtime order JSON API, Python, JavaScript, then JAR. Sources whose names normalize to the same site (for example `低端影视`, `影视 | 低端影视[js]`, and `🛣┃低端┃影视`) form one channel. Channels are ordered by their best runtime, and a channel's sources by runtime and then subscription order (JSON a, JSON b, Python a, Python b, and so on). The Sources list, the Watch Now source picker and default, and Global Search all use this order; search also runs each runtime in its own lane so slow JVM searches never delay the others. Web video detection remains unsupported. The Mac host supports CatVod stream proxy responses and the FTY cloud-drive proxy contract; other plugin-specific proxy implementations may still require adapters.

The basic DexLoom interpreter remains available for controlled tests on all platforms. It does not provide complete Android plugin compatibility.

- [On-device runtime status](on-device-runtime-status.md)
- [Third-party dependency notes](THIRD_PARTY_NOTICES.md)
- [FongMi/TV reference implementation](https://github.com/FongMi/TV), reference commit `c616c0aa3613e87529791587a9f71b78c278c991`, GPL-3.0. An unmodified local reference checkout may exist at `reference/FongMi-TV/`; that directory is ignored by this project.
- [DexLoom](https://github.com/speedyfriend433/DexLoom), MIT. Its license and version record are retained under `Vendor/DexRuntime/`.

Third-party subscription plugin binaries are downloaded on demand and are not bundled with the app. The test JAR is a project-owned fixture. The current ATS configuration permits HTTP subscriptions and local-network media; TLS certificate validation remains enabled.

### Desktop player

On macOS, playback opens in an independent, resizable window with remembered window geometry, standard minimize/close controls, fullscreen, and Picture in Picture. The library stays usable while a video plays. AVKit provides the timeline, volume, AirPlay, embedded audio/subtitle selection when available, and 0.5–2× playback speed. The bottom options menu adds looping, fit/fill, floating above other windows, and retry. Closing the player releases the stream and its local HLS proxy; selecting another item reuses the player window.

Keyboard shortcuts apply in the player window: Space plays/pauses, Left/Right seeks 10 seconds (Shift: 60 seconds), Up/Down adjusts volume, M toggles mute, F toggles fullscreen, and Escape exits fullscreen. Seeking is limited to the stream's available seekable range; live channels without DVR cannot rewind. Standard Command-W closes the window.

The player uses Apple's AVKit inside SwiftUI. KSPlayer (https://github.com/kingslay/KSPlayer) and IINA (https://github.com/iina/iina) were evaluated as references; no code or dependencies were imported from them. This upgrade does not extend AVFoundation's supported codecs or add external subtitle files.

After building the macOS target into `build/Verify-mac`, `bash Scripts/test-player.sh` generates a local test clip with FFmpeg and runs a native window/playback smoke check. It requires Apple silicon, Xcode, FFmpeg, and a logged-in desktop session.

Host regression checks: `Scripts/test-java-host.sh` and `python3 Scripts/test-script-host.py`. Run these after preparing the corresponding runtimes.

### Runtime diagnostic logs

Open Settings → Diagnostic Logs, or choose View Logs on the JAR runtime page. The log viewer filters by level and keyword, can pause live refresh, refreshes manually, and exports; on Mac it can also open the log folder directly. The page shows the latest 1,000 entries from the current run; exports include the history retained on disk.

Logs are stored as JSON Lines under `com.tvbox.yingxia/Logs/` in the app's Application Support directory. They record JAR downloads, DEX inspection, source/session/request correlation, request durations, retries, timeouts, process exits, and plugin stdout/stderr. Full request parameters and results are not logged. Common credentials and URL query strings are redacted, but plugin-specific output should still be checked before sharing.

A background utility queue writes logs in 250 ms batches; producers only append to a bounded in-memory queue and never wait for the disk. Each entry is capped at 2,048 characters and the queue at 512 entries; under overload, warnings and errors are kept first and the number of dropped entries is recorded. Each log file holds up to about 2 MB, and 4 files are retained; an exported copy holds up to about 8 MB. Plugin output is reassembled into lines, overlong lines are truncated, and pipes are drained continuously so that log writes to disk never block a plugin. The viewer refreshes every 2 seconds and only while it is visible.

A disk write failure does not make parsing fail: the page shows the error, keeps recent logs in memory, and retries after 30 seconds when new logs arrive. An abrupt exit may lose the last batch that has not reached the disk; entries are not synced to disk one by one. These logs provide evidence for locating problems; they do not mean that every plugin compatibility issue or upstream source failure has been fixed.

### tvOS channel guide

The channel page follows [YouTube TV’s published live-guide design](https://blog.youtube/news-and-events/youtube-tv-live-guide-and-library/): focused-channel details above compact full-width rows, neutral category pills, and high-contrast remote focus. Search opens on demand from the header; refresh is a compact icon. Hold Select on a channel for the favorite action. Playlists supply channel names, groups, and logos, so the guide does not invent programme schedules or preview imagery. iOS and macOS retain their existing channel layout.

### tvOS playback recovery

Playback failures use a flat full-screen layout with a prominent heading, channel/video name, and wide focusable Retry, Go back, and Show details controls. Show details expands the server message beneath the controls, and Hide details collapses it. The remote’s Back button returns to the previous screen. The visual reference is a [YouTube TV playback-error screenshot published in its support community](https://support.google.com/youtubetv/thread/342048636/playback-error?hl=en), rather than YouTube’s proprietary source code. This app retains local retry and diagnostics instead of imitating a feedback service.

### Global search and recommendations

Watch Now displays the selected source's home recommendations and remembers the source choice. JAR home responses merge `homeContent(true)` with a nonempty `homeVideoContent()` list; JavaScript sources may supply `homeVod()`. Index sources (`indexs: 1`) and name-only ranking entries are displayed as recommendations and open Global Search by title; entries with real video IDs from ordinary sources open their own details. An empty recommendation list stays empty instead of substituting a category. The latest four source recommendation lists are cached in memory for ten minutes, with explicit refresh and subscription invalidation. TVBox artwork header suffixes are parsed into actual HTTP headers; posters are downsampled and held in a bounded decoded-image cache.

Global Search queries supported sources with `searchable` omitted or set to `1`, with at most four concurrent requests. Results append to a stable poster grid and retain their source for details/playback. Source chips filter the grid; select a source and use its “More” link to browse subsequent search pages. Failed sources appear in a separate sheet and can be retried independently. Search state survives opening details and switching app sections. Search history stores the latest 20 keywords locally and can be cleared. The latest six completed searches are cached in memory for five minutes; subscription changes invalidate them. Already-started sources are searched first. Stopping or replacing a search prevents stale results from being displayed; an already running plugin call may still finish in its host process. iOS and tvOS search every source they can run.

On tvOS, Global Search uses SwiftUI’s native `.searchable` and `.searchSuggestions` interface: the keyboard, recent-search suggestions, and results share the screen and native focus navigation. Searches start after a 650 ms typing pause; suggestions complete the query through the same search field. Explicit submissions and opened results add the query to history, avoiding partial queries in history during typing. Source filters, progress, stop/resume, and failure retry remain in the results area. Details and source pagination preserve search state on return. macOS and iOS keep their existing search controls.

Simulator verification: recent-search completion returned 24 fixture results, and opening a result and returning preserved the results. Individual character selection through Device Hub’s simulated remote was inconsistent on tvOS 27; physical Siri Remote typing and dictation remain unverified.

Search design references: [YouTube's TV search guide](https://www.fetchtv.com.au/pdf/Fetch_YouTube_UserGuide.pdf) for keyboard/suggestions/results layout, and [Apple's SwiftUI media catalog sample](https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui) for native implementation. These describe public interaction patterns; YouTube's proprietary tvOS implementation was not inspected.

Plugin downloads are shared across source sessions, with a five-minute, four-entry/40 MB memory cache. A verified SHA-256 disk cache survives app restarts (up to 16 URL records and 80 MB of downloaded artifacts). After five minutes, HTTP ETag/Last-Modified revalidation checks for changes; without validators the plugin is downloaded and hashed again. For JAR sources, a changed payload at the same URL starts a new plugin session while preserving the source profile. Source and detail loading show download progress when a byte total is available, then preparation stages and converted/reused component counts. Demand-driven conversion does not have a fixed total, so it uses an activity indicator instead of an estimated percentage. JAR conversion artifacts are shared on disk, keyed by DEX SHA-256 and host transformation version. Process locks and atomic publication prevent concurrent conversion races; invalid JAR artifacts are regenerated. On iOS/tvOS, interrupted preparation resumes automatically at class boundaries: completed classes remain reusable, and a completed DEX-to-JVM stage is checkpointed before compatibility rewriting. Restarting repeats only unfinished stages, not previously completed classes. Checkpoints are validated before reuse; partial writes are discarded under the class lock. A class interrupted during DEX conversion must restart that class. Resuming requires the cache to remain available and the plugin content and transformation version to match. Each source still has its own runtime and preferences. A local startup sample measured 9.587 seconds for first conversion versus 3.928–4.749 seconds with the shared artifact; these are plugin startup measurements, not an end-to-end search latency guarantee.

Manual Mac search check: the existing query `兰香` displayed three results within the first approximately five-second UI observation, continued to 30 searched sources, retained results when switching sections, and reused the completed query without entering loading again. This is one observed run; source network latency varies.

### Audit source loading and search

Export a normalized subscription with `swift run TVBoxProbe --subscription-export URL > build/subscription.json`, then run `python3 Scripts/audit-source-loading.py build/subscription.json --output build/source-audit`. The audit tests home and search independently using the same bundled hosts, records empty results separately, respects per-source plugins, and keeps evidence under the output directory. Use `--query`, `--keys`, or `--searchable-only --limit 6` to select a bounded sample. It does not test playback or confirm every source in a sampled subscription.

For an end-to-end subscription audit, run `python3 Scripts/audit-subscription-playback.py --inputs Fixtures/subscription-audit.txt --output build/playback-audit`. It imports every listed URL with TVCore, tries sources until a media response is verified, and keeps search/detail/player responses and failure stages. HLS checks follow a playlist into a media segment; HTTP 200 HTML is rejected. It tests up to four titles and three playback lines per source, and does not claim a decoder/playback test. `--resume` keeps completed evidence. `python3 Scripts/audit-subscription-directories.py --resume` follows reachable directory roots from that audit until a child subscription passes. Playback URLs may expire.

### Cloud drive accounts (Mac)

Open Settings → Cloud Drive Accounts → Manage Cloud Accounts. Quark and UC offer an embedded official sign-in page; finish signing in and choose Save Login. Existing Quark/UC cookies, an optional UC token, and an Aliyun refresh token can also be entered manually. Credentials stay in the app's private Application Support directory (directory mode 0700, file mode 0600) and are passed to the subscription plugins the user runs. Saving restarts plugin sessions; retry the source afterward.

The host supplies `Cloud-drive` JSON (`quarkCookie`, `ucCookie`, `ucToken`, `token`) and existing `cookie`/`uc_cookie`/`token` extension references through a per-process loopback server with an unguessable URL. It preserves other source settings. CatVod proxy responses retain status, headers, range requests, and streaming bodies. FTY `ProxyOrigin.getUrl` and `getOwnProxyUrl` use the host's server, including its separate `proxyDrive` routing. Recent proxy traffic keeps the source process alive.

Validation includes controlled configuration/streaming checks, Swift tests, and a real WoGG initialization with synthetic credentials: all four cloud initializers fetched the configuration, and Quark retained credential state. This does **not** verify account authorization or end-to-end playback. Real playback still needs the user's valid account, provider access, compatible media, and a working source. Android plugin QR dialogs are not emulated; use the account settings login page.

### Cloud drive playback

A plugin's cloud-drive file (a `/drive/` address on the plugin's loopback proxy) is not played through that proxy. FTY's Quark proxy starts a set of download threads for every range AVPlayer opens; on a 4K file (1.4–2 GB) the abandoned ranges exhausted the embedded JVM's threads (`OutOfMemoryError: unable to create native thread`) and playback stalled at 0 bytes/s. Instead, the Java host's `directMedia` command asks the proxy for two bytes and records the CDN request the plugin makes to answer them (`HttpDiagnostics` sees every plugin OkHttp call): its URL, headers and file length. `CloudStreams` then serves AVPlayer from that address through a resource loader, in 2 MB chunks over up to six parallel connections (drives cap each connection), reading a bounded window ahead of each reader. A file whose audio sits far from its video is read in two places at once, so the stream tracks several readers and never cancels a chunk someone waits on. The container comes from the file's first bytes, not its name (a 4K MP4 named `.mp3`). An expired address is resolved again through the plugin; when no CDN request is revealed, playback falls back to the proxy.

Two AVFoundation rules the loader follows: answer from a copied `Data`, never a slice of a cached chunk, and never call `respond(with:)` or `finishLoading` while holding the delegate queue (AVFoundation can wait on that queue while holding its request lock, which deadlocked playback). When a newer request arrives for the same stream, deliveries to older requests pause briefly so AVFoundation's cancel lands first; bytes handed to a request it had just abandoned made it report the movie as damaged. `CloudStreamsTests` cover byte-exact reads, two distant readers, expired addresses, and, with `TVBOX_CLOUD_MEDIA=<an MP4>`, AVPlayer opening, playing and seeking a movie through the loader three times; they serve ranges from memory (`RangeServer`), not a shared port.

On the living-room Apple TV (2026-10-13), FTY's 4K Quark episodes (1.63 GB MP4, and a 1.94 GB MP4 named `.mp3`) played at 3840×2160 in real time with 2.0–3.8 MB/s from the CDN, where the proxy had managed 0.4–0.6 MB/s and then stalled. One network and one account; not a guarantee for every drive or file.

The same lookup covers every drive whose proxy fetches the file with ranged requests, whatever the plugin calls its route: `/drive/` addresses and the plugin's own `/media` proxy (Fish's drives answer `/proxy?do=…`, which the bridge routes to `/media`). Fish downloads ranges over `HttpURLConnection` on its own threads, not OkHttp, so the converted plugin's `getResponseCode()`/`getInputStream()` calls are rewritten to `HttpDiagnostics` as well (conversion `host-v13`; a version bump converts each plugin class again once). A proxy that does not answer the probe with a byte range (a playlist, a page) is left to the proxy at once. Downloads of drive episodes use the same direct address (`Store.resolveDownload`), and take their file type from the first bytes. Playback that still streams through a plugin logs `plugin proxy stream drive|media do=<x>` in Diagnostics.

`TVBoxProbe --drive-check <subscription> <source> [search]` opens a source's first video and, for each drive it offers, prints DIRECT (CDN host, size, lookup time, read speed) or PROXY. Run it with `TVBOX_DISABLE_SANDBOX=1` from a remote shell, where `sandbox-exec` cannot start the JVM. Drives that need an account read it from `CloudDrive/accounts.json`, as the app does. On 2026-10-13 Fish's 玩偶 Quark episodes (原画 and 无限) went DIRECT with a 0.3–0.6 s lookup; 夸克智 failed inside the plugin (HTTP 404 from Quark), Baidu hung without an account, and 123/光鸭 need accounts.

### Plugin requests that never end

Android plugins wait for a QR sign-in by showing a dialog and polling until someone scans it. This host shows no dialog, so without a host check the request never returns, and because a source takes one request at a time, every later request for that source waits behind it. FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC, 嘟嘟 is Baidu, 阿狸 is Aliyun. On 2026-10-13 its Baidu and Aliyun lines without an account still hung after 120 s.

- `HttpDiagnostics.qrLoginDrive` recognizes the QR endpoints of Quark, UC, Baidu (`passport.baidu.com` getqrcode/unicast) and Aliyun (`passport.aliyundrive.com/newlogin/qrcode/…` and the open-API variants). Quark and UC throw `CloudLoginRequired` and the app offers its own sign-in. Baidu and Aliyun keep the plugin's sign-in: `LoginPrompt` reads the code from the plugin's own code-creating response (Baidu's `imgurl`, Aliyun's `codeContent`), writes it to `login-prompt.json` in the source's session folder (`_folder`), and moves the request's deadline out by 180 s. `PluginSignIn` (Swift) watches that file while a non-search request runs and `PluginSignInView` shows the code; once it is scanned the plugin saves the account itself (Baidu `files/mybd_cookie`, Aliyun `files/ali_*`) and the playback request continues. A code-creating response without a code still hands the sign-in back. The detail page doesn't start a title on a Baidu or Aliyun line.
- FTY saves the account after the scan but only its Android dialog code tells the waiting request, so that request would wait out its deadline. `LoginPrompt.confirms` spots the confirmation (Baidu's `qrbdusslogin` setting `BDUSS`, Aliyun's `qrCodeStatus: CONFIRMED`), the request ends with `SignedIn` 1.5 s (Baidu) or 4 s (Aliyun) later, and `InProcessHost` retires that runtime and serves the request again from a fresh one with a fresh deadline. The fresh spider reads the saved account. `login-prompt.json` gets `signedIn: true`, and the app closes the code. On the living-room Apple TV (2026-10-14) a Baidu scan returned the playback link 24 s after confirming, including the restart.
- Settings → Cloud Drive Accounts also signs in to Baidu Netdisk and Aliyun Drive with a code to scan (`CloudDriveQRLogin`: Baidu's passport QR login sets `BDUSS`/`STOKEN`/`PTOKEN`, kept as `baiduCookie`; Aliyun's `bizExt` carries the refresh token, kept as `token`), on the Mac too. FTY keeps its own copies as guard-encrypted JSON (`files/mybd_cookie`: `bduss`, `stoken`, `ptoken`, `devuid`; `files/ali_user`: `refresh_token`). `CloudDriveBridge.syncFtyAccounts` writes the app's Baidu account into `mybd_cookie` (`DexNative.encrypt`) before the spider starts, and offers a sign-in only the plugin has back through `plugin-accounts.json`, which `EmbeddedJarHost` adopts into the app's accounts. A sign-in through the plugin's code is adopted too (its `signedIn` notice carries the account), so one scan serves every source. Signing out also removes the plugin's copies.
- Every request carries a stop time (`stopAt`): the app's `cancel` (going back, choosing another title, the worker's 15-minute limit) sets it to now, and the spider's deadline (`EmbeddedJarHost.deadline`: play 90 s, search 60 s, others 150 s, from when the spider starts on it) sets it ahead. `SystemClock.sleep`, OkHttp calls and the rewritten `HttpURLConnection` calls check it and throw `RequestStopped`, an `Error`, so plugin `catch (Exception)` loops can't swallow it. The app reports it as `source_timeout`.
- A request still running 15 s after its stop time (`OpeningGate.STUCK_GRACE_MILLIS`; it waits somewhere the host can't reach) gets its spider retired: the next request opens a fresh one, and the old runtime closes when that request returns.
- Host commands (`directMedia`, `recoverProxy`) bypass the plugin request slots (`SerializedPluginWorker.immediate`), so starting a working video never waits behind a stuck line.
- `embedded-jvm.log` logs `PLUGIN_REQUEST <time> <kind> [flag=…]`, `PLUGIN_STOPPED`, `PLUGIN_RUNTIME_RETIRED`; past 2 MB at launch it moves to `embedded-jvm.previous.log`.

### Music

Music searches four catalogs (QQ Music, NetEase Cloud Music, Migu and Kuwo) and plays each song from a temporary audio address that a resolver service returns. It needs no account and no server of ours. Code: `Sources/TVCore/Music*.swift` and `App/Music*.swift`.

- **Channels.** A catalog plus a resolver is a channel. `MusicResolver.order` tries the primaries first (Migu through Migu's own servers, Kuwo through Nianxin, QQ through VKeys, NetEase through GD Studio), then the fallbacks (Kuwo through Xinghai, NetEase through Nianxin, QQ through HYW, NetEase through Xinghai). At most two resolve at once, within 15 seconds per song. When every channel fails, the song is looked up in the catalogs it was not found in. Addresses are reused only within one playback.
- **Service limits.** GD Studio allows 50 requests per 5 minutes, is for personal non-commercial use, and asks to be credited; Xinghai is held to 30 per 5 minutes. The player credits both. `MusicSourceHealth` keeps these budgets and cools a failing service down (1 minute, doubling up to 30; 10 minutes after upstream risk control). HYW stays off until the user enters its key in Music settings; the key is never committed or logged.
- **Matching.** Results merge across catalogs by title, artists and duration. Version tags (live, instrumental, remix, cover, re-recorded, acoustic, demo, and other versions such as a Cantonese one) keep different recordings apart. A query that names one song, with or without its artist, plays it directly only when the original is unambiguous.
- **Quality is measured, not trusted.** `MusicProber` reads at most 256 KiB by Range, parses the header (FLAC STREAMINFO, MP3/ADTS, MP4) and asks the platform decoder when the header leaves something open. Extensions, Content-Type and providers' quality labels are never evidence: CDNs sent FLAC as `audio/x-ogg` or `audio/mpeg`, a request for high quality returned 48 kbps AAC, and an old VKeys endpoint returned 60-second previews. A stream clearly shorter than the recording (beyond max(3 s, 2%)) is a preview and is rejected; with either length unknown it stays unknown. "Lossless first" (the default) plays the first complete, playable lossless stream, else the best lossy one, marked; "Lossless only" fails with a clear message instead.
- **Player.** Albums and playlists, a queue with shuffle, repeat, Play Next and Add to Up Next, synced lyrics with translation, Recently Played and Continue Playing. Unplayable songs are skipped while a queue plays. iPhone and iPad publish Now Playing for the Lock Screen and Control Center (`MusicRemoteControl`). The Mac has a floating bar on every page and a full-window Now Playing; Apple TV has a full-screen player and a now-playing card atop the sidebar (tvOS 27; a sidebar item before that).
- **QQ keyword search** uses the mobile method (`DoSearchForQQMusicMobile`), which still returns code 2001 at times; the other catalogs then carry the results.

Tests: `MusicTests`, `MusicLibraryTests` and `MusicMiguKuwoTests` run offline. `TVBOX_MUSIC_LIVE=1 swift test --filter MusicLiveTests` resolves real sample songs and prints what each one got; run it by hand, not in CI. Debug launch arguments: `-qaSection music -qaQuery <text>`, plus `-qaMusicKind albums`, `-qaMusicOpen 1`, `-qaMusicPlay 1`, `-qaMusicLyrics 1`, `-qaNowPlaying artwork|lyrics|queue`, and `-musicVolume 0` to keep test runs silent.

### Software update and What's New

Release notes live in `website/public/releases.json`, which the website serves at `https://yingxia.getmegaportal.com/releases.json` and every app target also bundles. Each release has a `version`, its `build` number (CURRENT_PROJECT_VERSION; `ReleaseFeedTests` checks that the newest one matches `project.yml`), a `date`, `links` keyed by platform (`macos`, `ios`, `tvos`; a platform without a link did not get the release, so its users are not told about it), and `features` with an SF Symbol, a `title` and a `detail` in `en`, `zh-Hans`, `zh-Hant` and `ja` (an optional `platforms` list limits a feature). `ReleaseFeedTests` checks that the file parses and that every feature is translated.

The app checks the feed at launch and when it becomes active again, at most every six hours. A newer release for the platform is presented once as a "Something New Is Here" sheet (Mac: Install and Relaunch, below; iPhone and iPad: Get the Update opens the link; Apple TV: a QR code of the link); afterwards it stays as a New badge on Settings (sidebar on Mac, tab or More on iPhone/iPad) and a Software Update row at the top of Settings. After an update, the first launch shows What's New for every release since the previous version that has features for the platform; Settings → What's New in Version x.y reopens it. Fresh installs skip What's New. The Mac app menu has Check for Updates…. Sheets wait while a video plays.

TestFlight builds read the same feed. They are all called 1.7.7 and carry the build number of the release they were archived from (see `Scripts/testflight-upload.sh`), so they compare builds instead of versions: a TestFlight build announces the releases whose `build` is above its own, up to the build in the feed's `testflight` section, which says per platform what testers can install now and where (the group's public link):

```json
"testflight": {
  "ios": { "build": 29, "link": "https://testflight.apple.com/join/dU6UNbzp" },
  "tvos": { "build": 29, "link": "https://testflight.apple.com/join/SSgWEwSr" }
}
```

It sits after `releases` and changes only once a build is live on the public link, which can be hours or days after the release (adding the build to the group submits it for Beta App Review). Publishing the release entry alone tells testers nothing, so they are never sent to a TestFlight that has no new build yet. When both builds are live, run `uv run --with 'pyjwt[crypto]' --with requests Scripts/testflight-publish.py 1.7.7 <build> --announce`: it checks with App Store Connect that the build is in the public group and live, writes the section, and leaves a platform whose build isn't live at its previous build. Then commit and deploy the website. The sheet says "Yingxia 1.7.7 (30) is ready in TestFlight" with Open TestFlight (the public link, which opens the app's page in TestFlight) on iPhone and iPad, and tells Apple TV users to update in TestFlight on the TV, without a QR code. What's New after a TestFlight update covers the releases between the previous build (`updates.lastBuild`) and this one. TestFlight is told apart from the App Store by the sandbox receipt (`Distribution.isTestFlight`), so a build promoted to the App Store announces nothing. TestFlight builds up to 1.7.7 (29) predate this and never read the feed; reach them with a message (below).

The Mac updates itself with [Sparkle](https://sparkle-project.org) 2.10 (`App/MacUpdater.swift`). The release feed still decides what to announce; Sparkle downloads, checks and installs, through a user driver of our own, so its windows never show. It reads `website/public/appcast/macos-arm64.xml` or `macos-x86_64.xml` (one appcast per package, since an entry has one download) every six hours, downloads a newer version in the background (a delta update when one fits) and installs it when the app quits. Settings → Install Updates Automatically turns the background download off. Install and Relaunch in the sheet downloads with a progress bar if needed, installs and relaunches; after a background download it reads Relaunch to Update. Sparkle only installs a DMG whose EdDSA signature matches `SUPublicEDKey` in `project.yml`, from an appcast signed with the same key, and an app signed by the same Developer ID. If the appcast lacks the announced version or the install fails, the sheet offers Download Manually. App Store builds leave Sparkle off. Builds released before Sparkle can't update themselves: their users install the first Sparkle release by hand.

To release: add the new version's entry at the top of `releases.json` before building, so the build bundles its own notes, then deploy the website after the downloads are uploaded; publishing the entry is what tells existing users. On the Mac, run `Scripts/make-appcast.sh <version>` after `Scripts/package-mac-release.sh`: it adds both DMGs to their appcasts and writes delta updates (`Yingxia<build>-<old build>-<arch>.delta`) next to them, made from the DMGs of earlier releases that it keeps in `build/appcast/`. Upload the deltas with the DMGs before deploying. For iPhone and iPad, run `Scripts/make-altstore-source.py <version>` once the iOS IPA in `build/release-apple/<version>/` is final: it adds the version to `website/public/altstore.json`, the AltStore source, with the IPA's size, SHA-256, minimum iOS and privacy usage descriptions, which AltStore checks against the download. It signs with `~/.sparkle/yingxia_ed25519.key` (mode 600, never in git), which only the release Mac has: keep a backup, since installed apps accept only updates signed with it. To pull a release, delete its `<item>` from both appcasts, sign them again with `build/sparkle-2.10.0/bin/sign_update --ed-key-file ~/.sparkle/yingxia_ed25519.key <appcast>`, and deploy; apps that already downloaded it install it on quit.

QA (Debug builds): `-qaReleaseFeed <url>` reads another feed (a `file://` path works on simulators), `-qaVersion 1.0.1` pretends to be another version, `-qaTestFlight 1 -qaBuild 29` acts as TestFlight build 29, and launch-argument defaults such as `-updates.lastVersion 1.0.1` or `-updates.announcedVersion 1.1` set the recorded state for one run. With `-qaSection`, update checks only run when `-qaReleaseFeed` is given. Debug Mac builds leave Sparkle off, so an update can't replace a build in DerivedData; `-qaAppcast <url>` turns it on against another appcast (a local `python3 -m http.server` works), and `-qaInstallUpdate 1` presses Install and Relaunch four seconds after launch. Run such a build from a copy outside DerivedData, as the update replaces it.

### Messages to users

To tell people something without a release, add a message to `website/public/messages.json` and deploy the website. Every build from the first one with this feature reads it, App Store and TestFlight builds included (`App/Announcements.swift`, model `Sources/TVCore/MessageFeed.swift`). Each message shows once per device, in an alert, after any update sheet and never over a playing video. On iPhone, More → Messages lists every live message for the device, with a count on its tile and a New badge while one is unread; opening it counts as reading them, so they no longer pop up:

```json
{
  "messages": [
    {
      "id": "2026-10-24-search-crash",
      "title": { "en": "Search crash fixed", "zh-Hans": "搜索闪退已修复" },
      "body": { "en": "Update to build 28 in TestFlight.", "zh-Hans": "请在 TestFlight 中更新到 28 版本。" },
      "link": "https://yingxia.getmegaportal.com/",
      "linkTitle": { "en": "Open Website", "zh-Hans": "打开网站" },
      "platforms": ["ios", "tvos"],
      "channels": ["appstore"],
      "maxBuild": 27,
      "end": "2026-11-30"
    }
  ]
}
```

Only `id`, `title` and `body` are required. Texts are keyed `en`, `zh-Hans`, `zh-Hant` and `ja`; a missing language shows English, and a plain string counts as English. A device remembers the IDs it showed, so a new message needs a new ID, and editing a shown message does not show it again. Optional limits: `platforms` (`macos`, `ios`, `tvos`), `channels` (`direct` for downloads and sideloading, `appstore` for App Store and TestFlight), `minVersion`/`maxVersion` and `minBuild`/`maxBuild` (inclusive; TestFlight builds all carry version 1.7.7, so use build numbers there), and `start`/`end` as ISO 8601 times or dates (a date is midnight UTC). `link` adds a button, titled Learn More unless `linkTitle` says otherwise; Apple TV can't open web pages and leaves it out. Messages show in the file's order, as alerts and on the Messages page, so keep the newest at the top. `MessageFeedTests` checks the published file, so run `swift test` before deploying: a file that doesn't decode hides every message.

The app asks at launch and whenever it becomes active, at most every 15 minutes. It sends back the `ETag` (and `Last-Modified`, if present) of the copy it saved, so an unchanged file costs a `304 Not Modified` without a body; the website serves the file with `cache-control: max-age=0, must-revalidate`, so a deploy reaches devices at their next check.

QA (Debug builds): `-qaMessageFeed <url>` reads another feed (a `file://` path works on simulators), `-qaVersion` and `-qaBuild` pretend to be another build, and `-qaAppStore 1` acts as an App Store build. With `-qaSection`, the launch check only runs when `-qaMessageFeed` is given. Shown IDs are in the defaults key `messages.seen`.
