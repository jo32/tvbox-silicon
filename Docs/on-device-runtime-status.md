# On-device runtime status

Measured October 6, 2026. Guazi catalog, search, detail, and actual video playback are verified in both main apps on arm64 simulators. Physical-device playback and all-source parity are not verified.

## Recommendation HTTP versus plugin time (October 6, 2026)

Test-only instrumented copies of `HttpDiagnostics` and `PluginSession` measured
`homeContent`, `homeVideoContent`, synchronous OkHttp execution until headers,
and response-body reads/close separately. The original plugin and converted
artifacts were unchanged. Instrumentation was packaged only into the dedicated
benchmark app, not the product Java host. Every response contained 114 items;
every measured recommendation performed an actual `/App/IndexList/index` request.
No class conversions occurred, and no scene background transitions occurred
during either measurement session.

Two sessions each performed one initialization request followed by five warm
requests, separated by two seconds. The first session averaged 1.290 s for
`homeVideoContent`: HTTP spans 1.070 s (83.0%), other plugin work 0.220 s (17.0%).
The second added native `CLOCK_THREAD_CPUTIME_ID` measurements around the JNI
entry point and produced:

| Warm recommendation stage (five-request mean) | Seconds | Share |
| --- | ---: | ---: |
| HTTP execution until headers | 0.406 | 36.9% |
| HTTP response-body reads and close | 0.482 | 43.8% |
| Other work inside `homeVideoContent` | 0.213 | 19.3% |
| Total `homeVideoContent` | 1.101 | 100% |

HTTP spans include local client/TLS work as well as network/server waits; they
are not server-only timing. As a separate CPU cross-check, the complete warm
JNI home request averaged 1.143 s elapsed and 0.300 s on its calling thread
(26.2% CPU, 73.8% off-CPU elapsed time). Off-CPU time includes scheduling and
other waits and is not independently a server-latency measurement. Other JVM
threads' CPU is outside this thread measurement.

The first request after launching the process took 29.873 s despite no new
conversion: 28.823 s was outside the home method (runtime/session initialization),
whereas the actual recommendation method took 0.985 s. The first entry consumed
26.776 s of calling-thread CPU. Thus a roughly 30-second restart delay in this
sample was overwhelmingly before recommendation fetching, not a 30-second
recommendation API call.

Evidence: `build/recommendation-timing/summary.json`, `embedded-jvm.log`,
`recommendation-runs.json`, and `lifecycle.log`; the first session is preserved
in `first-pass/`. Test-only sources, builder and analysis script are alongside
these files. These are iOS 26.5 simulator observations for Guazi in one network
window, not physical-device or all-source benchmarks.

## Shared runtime per plugin archive (October 6, 2026)

A Mac profile of the Guazi cold start (classes already converted) showed that session
startup, not the home request, dominates: 8.24 s to start versus 0.84 s per home request.
About 71% of startup main-thread samples were `FishNative.load`, the FishGuard library
load inside the CPU emulator. The embedded host previously keyed runtimes by source, so
every source from the same 97-source archive repeated plugin `Init` and the guard load,
and the two-runtime limit repeated them again when returning to a source.

The embedded host now shares one runtime per archive SHA-256, as Android TVBox clients
do: DEX loading, `Init` and native guards load once; each source creates only its own
spider and cloud bridge (up to 24 sources per archive, least recently used first, never
evicting a source with recent proxy traffic). Archives with an FTY guard keep one runtime
per source because of their loader protocol. The two-runtime limit now counts archives.
The shared runtime's Android profile is `Runtimes/<archive SHA-256>/profile`.

Mac in-process measurement (`InProcessHost`, JDK 19 JIT, identical pre-populated
conversion cache for both modes, same response item counts):

| Request order | Per-source runtimes | Shared runtime |
| --- | ---: | ---: |
| Guazi | 9.85 s | 9.34 s |
| Libvio | 10.70 s | 5.45 s |
| Jianpian | 7.31 s | 2.59 s |
| Guazi again | 7.09 s | 0.72 s |
| Total | 34.95 s | 18.10 s |

This is a Mac JIT measurement; the guard runs under Unicorn's interpreter on Apple
mobile platforms, so the per-switch saving there is expected to be larger but is not
yet measured. The Mac app's per-source child processes are unchanged.

Also changed: on iOS the embedded plugin cache moved from purgeable Caches to
Application Support (excluded from backup; an existing cache is moved once). tvOS still
uses Caches. Converted classes that were fully validated get a size/time stamp, so later
launches reuse them without re-reading every entry and without waiting behind another
class's conversion lock.

## Interrupted conversion recovery (October 6, 2026)

The lazy converter retains completed class artifacts across process death. It now
also atomically checkpoints the DEX-to-JVM result before compatibility rewriting,
flushes completed artifacts before publication, validates cached entries and their
CRC/class names, and discards interrupted staging writes under the class lock.
Existing completed caches remain compatible. An interrupted DEX conversion restarts
that class; there is no checkpoint inside an individual method or conversion pass.

The real 4.38 MB Guazi JAR was tested on the iOS simulator with the new host. After
47 classes completed, the process was killed with SIGKILL during another conversion.
The app was relaunched without clearing its cache: all 47 completed artifacts had
identical hashes and modification times, and progress reported 47 reused classes.
The resumed request completed in 214.023 seconds and returned 114 home items.
Both attempts stayed active until the forced termination or successful response.
Evidence: `build/ios-resume-20261006/summary.json`, `checkpoints-before.json`,
`interrupted-embedded-jvm.log`, `embedded-jvm.log`, and `lifecycle.log`.

`ConversionResumeTest` additionally verifies recovery after forced JVM death,
reuse without rewriting completed artifacts, cleanup of partial staging files,
resumption from a completed raw conversion, and regeneration of a corrupt raw
checkpoint. The full Java host regression suite passes.

## Uninterrupted real-JAR cold run (October 6, 2026)

A fresh installation of the dedicated benchmark app ran the original 4,379,102-byte
JAR through the current embedded runtime on the iOS 26.5 arm64 iPhone 17 Pro
simulator. The app started its worker only after its scene became active; lifecycle
records show no inactive/background transition between request start and end.
Other TVBox simulator apps were stopped, and no concurrent builds were run.
No converted artifacts or source profile were seeded. The original JAR was bundled
locally, so the measurement excludes download time and Swift app navigation.

| Measurement | Result |
| --- | ---: |
| Real Guazi home request, including JVM startup and initialization | 243.365 s (4 min 3 s) |
| Sum of completed `DEX_CLASS_READY` conversion durations | 217.060 s (3 min 37 s) |
| Completed on-demand class conversions at response | 178 |
| Home items returned | 114 |
| Maximum sampled process RSS | 777.875 MiB |

This is the conversion work needed by the first home request, not conversion of
all classes in the JAR. Conversion durations are summed logged elapsed times,
not CPU time. One additional class had begun conversion without a completion
record when the response was captured; its unfinished work is excluded from the
217.060 s sum. These remain simulator measurements, not physical-device results.
The dedicated harness uses the same native entry point and current Java host as
the app; it does not measure the complete app UI loading path.

Original JAR SHA-256: `ee8afb1dcd232705de428b3a8bbe4527369348f2cde5b40b856d774e964f45e9`.
Java host SHA-256: `f4b32c73dbb432c1e0e5c4a2a9fa01faa1e00b95d9d491b97a214d880cc76e02`.
Evidence and reproducible harness: `build/ios-real-cold-20261006/`, including
`summary.json`, `metrics.json`, `lifecycle.log`, `embedded-jvm.log`, `result.txt`,
`samples.json`, and `build-benchmark.py`. The fresh app was launched without
`-prebuilt`. The older interrupted run below should not be used as its comparator.

## Performance follow-up (October 6, 2026)

A controlled arm64 iOS simulator benchmark converts the same slow class,
`com.github.catvod.spider.merge.a.i1`, from the original 4,379,102-byte plugin
archive using OpenJDK Zero. Each cold measurement starts with a fresh conversion
cache; the warm measurement reopens that cache and rebuilds its index.

| Measurement | Before | After |
| --- | --- | --- |
| Cold conversion including archive indexing | 84.582 s | 58.462 s |
| Class conversion alone | 81.917 s | 55.569 s |
| Warm cache reopen | 2.780 s | 2.704 s |

This is a 31% reduction in this cold benchmark, not an end-to-end startup claim.
The converter now compacts replaced instructions in one pass and uses sparse
frame checks and bit sets in SSA removal. The lazy class loader defines prepared
classes directly instead of repeatedly scanning previously converted archives.
An opt-in `tvbox.profileConversion` property reports slow conversion stages.

The Swift native worker coalesces identical in-flight requests, permits at most
two distinct queued requests, and removes cancelled work before it reaches Java.
A superseded catalog load cancels its fetch. Running Java calls remain serialized
and are never forcibly interrupted. The worker thread retires after an idle
minute. Identical downloaded archives share one file by content hash. Existing
limits retain at most two plugin sessions and a 512 MiB Java heap; that heap limit
is **not** a total process memory limit.

Completed Android Handler callbacks now release their tracking entries, cancelled
callbacks leave the scheduler queue, and closing a source shuts down its host
Looper. Regression tests cover completed and cancelled callback batches, source
shutdown, duplicate requests, queue cancellation, retries, and timeout behavior.
All 65 Swift tests and the Java host suite pass. Both simulator targets and both
unsigned device-SDK targets build. The updated tvOS app browses Guazi, opens a
detail, resolves a player URL, and displays actual video. Its cached home request
was 31.326 s, detail 1.428 s, and player resolution 0.665 s in this run.

The full iOS cold verification completed and displayed the real catalog from a
fresh on-device conversion cache, then played the test video and paused at 00:18.
The first detail request took 23.569 s and player resolution took 3.684 s.
The cold run was backgrounded during another simulator
task, so its wall time is not comparable with the earlier uninterrupted run. First-use
conversion still takes minutes and needs substantial memory: this iOS run sampled
a maximum RSS of 883.5 MiB (not a guaranteed peak or a hardware measurement).
Physical-device
latency, memory pressure, and sustained multi-source use remain unverified.
Benchmark records are in `build/performance-zero-{before,after}-result.txt`;
regression logs are `build/performance-{swift,java}-tests.log`.

## Main app integration (current work)

The iOS and tvOS main targets now link an embedded OpenJDK Zero runtime, static
JNI bindings, and the Unicorn TCI interpreter. `CatalogClient` routes CSP JAR
requests into that runtime on a dedicated thread. No server or child JVM is used.
Both simulator apps build, install, browse the real Guazi catalog, open details,
resolve the episode and play it in AVPlayer. The test title was
`舒马赫1994：传奇诞生`: iOS rendered video and advanced to 00:29; tvOS rendered
video and advanced to 04:25. Pause worked on both. The source was loaded from the
original subscription inside each app; no Mac conversion cache was installed.
The older spike results below are retained as historical measurements.

| Measurement | iOS 26.5 / iPhone 17 Pro simulator | tvOS 27 / Apple TV 4K simulator |
| --- | --- | --- |
| Guazi home response | 21,405 bytes; 374.3 s cold | 21,405 bytes; 60.5 s after restarting with the on-device class cache |
| Detail response | 1,307 bytes; 33.7 s | 1,307 bytes; 38.1 s |
| Player resolution | 306 bytes; 0.80 s | 306 bytes; 1.06 s |
| Actual playback | Visible video, 00:29, pause | Visible video, 04:25, remote pause |
| Search `舒马赫` after reinstall | 4,334-byte response; matching titles visible | 4,334-byte response; matching titles visible |

These are development-machine measurements, not hardware benchmarks. The TV cold
run was interrupted for diagnostics, so there is no completed TV cold timing.
Sampled iOS RSS during preparation was about 576 MiB and fell to about 88 MiB
when idle; these samples are not a peak-memory guarantee. Source initialization
still attempts optional Android UI and Go subprocess services; those cannot run
on Apple, while this Guazi path succeeds without them. Compatibility is source-specific.
Saved logs: `build/apple-runtime/evidence/{ios,tvos}-main-{jvm.log,diagnostics.jsonl}`.

DEX conversion is now demand-driven and cached per original JAR hash and host
version. A quadratic phi-analysis memory problem in dex2jar was fixed. The full
Mac conversion and the lazy Mac reference both returned the real Libvio catalog;
the mobile playback check above uses the same converter. The first mobile source
load remains slow. Warm starts reuse the on-device converted classes.

Rebuild the embedded main apps from the repository root:

```sh
Scripts/build-java-host.sh
Scripts/package-apple-runtime.sh ios-simulator
Scripts/package-apple-runtime.sh tvos-simulator
xcodegen generate
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Both simulator builds and both unsigned device-SDK builds succeeded. All 60
Swift tests and the Java host regression suite passed. Installed debug simulator
app sizes are approximately 134 MiB (iOS) and 137 MiB (tvOS).

For device SDKs, use `ios` or `tvos` with the packaging script and build the
corresponding target with your signing team. Device execution has not yet been
verified. Do not enable `ENABLE_DEBUG_DYLIB`: the JVM's statically linked JNI
entry points must reside in the main executable. Dependencies and source patches
are pinned by the build scripts; bundled notices are in `App/Resources`.

The worker serializes calls, limits pending requests, and rejects further work
after a 15-minute watchdog expires. It cannot safely terminate a Java thread;
restarting the app is required after that timeout. Up to two source sessions are
retained, with recent proxy activity preventing eviction. This is development
integration, not an App Store release assessment.

## Historical Phase 1 findings

| Gate | Evidence | Status |
| --- | --- | --- |
| A: embedded Zero + HTTPS | iOS 26.5 arm64 simulator and tvOS 27 arm64 simulator both returned `Hello from OpenJDK 64-Bit Zero VM 28-internal; HTTPS 200`. Static JVM, no child JVM, non-executable Zero code cache. | Simulator proof only; physical-device execution and xcframework packaging outstanding. |
| B: real subscription conversion | 4,379,102-byte original JAR, dex2jar inside iOS simulator Zero: `CONVERSION_NO_GO: exceeded 180 seconds`. RSS sample at 151 s was 589,552 KiB (~576 MiB); this is not a peak measurement. Worker still ran after cancellation; test app was terminated. | Failed simulator time budget; physical-device timing unknown. |
| C: complete spider requests | No complete in-process Apple spider run yet. | Not passed. |
| D: native guard | Pinned Unicorn TCI on Mac: FishGuard `JNI_OnLoad`, `register()V`, `svN()I` returned 36; initialization 15.921 s, subsequent call below displayed millisecond precision. ARM64 instruction probe returned 43. | Functional Mac interpreter proof, exceeds 10 s target; Apple JNI/JNA integration and timings outstanding. |

Do not advance to production integration on the strength of these results. The simulator
conversion timeout is evidence of a problem, not a physical-device benchmark. No supported
Apple-device playback or 97-source parity claim can be made yet. The 600 MB total-memory
budget also needs a real peak measurement, including native emulator allocations.

The runtime source is pinned at OpenJDK mobile `c1ed06aaef34c8dccf71e236d1ffa20918a77cfb`
(JDK 28-internal), not JDK 21. Local patches remove unsupported process creation, avoid
executable Zero cache allocation, and handle unavailable tvOS Mach APIs. Unicorn TCI is
pinned at `e3f075a62742913bb734a55a474aec65c9e5745e`; the build checks interpreter mode.
The iOS device static JVM build also completes with platform-specific libffi 3.4.8
(`build/apple-jvm-ios-final.log`); this does not verify physical-device execution.
Static archives are development outputs, not a distributable framework. Licensing notices,
release selection, signing and size validation remain outstanding.

Reproduce the simulator spike (requires Xcode, downloaded build dependencies and a booted
arm64 simulator; commands run from the repository root):

```sh
Scripts/build-apple-jvm.sh ios-simulator
Scripts/test-apple-jvm.sh ios-simulator
xcrun simctl install booted build/apple-runtime/RuntimeSpike-ios-simulator.app
xcrun simctl launch booted com.tvbox.yingxia.RuntimeSpike
# Repeat with tvos-simulator and the corresponding booted Apple TV simulator.
# Pass an original plugin JAR as test-apple-jvm.sh's second argument for conversion;
# first build the Java host with Scripts/build-java-host.sh.
# Inspect the app data container's Library/Caches/result.txt and jvm.log.
# On CONVERSION_NO_GO, terminate the spike: cancellation cannot stop dex2jar.
xcrun simctl terminate booted com.tvbox.yingxia.RuntimeSpike
```

The iOS hello/HTTPS test also passed after switching to the separately built static libffi;
that result is saved as `ios-static-ffi-result.txt`.

Saved local results: `build/apple-runtime/evidence/{ios,tvos}-{jvm.log,result.txt}`.
Native interpreter reproduction: `Scripts/build-apple-interpreter.sh macos`, then
`Scripts/test-interpreter-guard.sh build/apple-runtime/FishGuard-v8.so`.
The latter runs on the Mac JVM; it is not an Apple embedded guard test.

## Plan review corrections

The no-server architecture matches the requested product direction. Three assumptions needed
correction: the host has process-global state beyond its entry point; class-loader disposal
cannot stop an infinite Java worker; and the available mobile JVM spike is a newer development
JDK. The plan now records these explicitly. Native guard discovery accepts arbitrary ARM64
asset names, but support for an unknown library's JNI protocol is not automatic.

The former gateway UI, runtime and scripts were removed, with a recovery copy under
`build/previous-server-implementation`. Existing user UI edits were preserved. Regression
checks passed: 60 Swift tests, Java host tests, and both main-app simulator builds. These
checks validate the existing app and host, not embedded plugin playback.

## Mac reference baseline

Subscription: `http://xn--ihqu10cn4c.xn--v4q818bf34b.top`. **13 / 97 sources returned verified media** through the local Java host.

Each source was tried with home, search, category fallback, up to four titles and three playback lines. A pass requires an HTTP media response (including an HLS segment), not just a playback URL. No cloud-drive credentials were supplied. A failure here is a result of these samples, not proof that every title in the source fails.

Reproduce:

```sh
printf 'Baseline|http://xn--ihqu10cn4c.xn--v4q818bf34b.top\n' > build/on-device-subscription.txt
python3 Scripts/audit-subscription-playback.py --inputs build/on-device-subscription.txt --output build/on-device-baseline --all-sources --source-workers 3
```

Local raw evidence: `build/on-device-baseline/results.json` and `01/source-*/result.json`, including request/response logs. The first 11 source results preceded the generic guard-discovery change; the rest used that change. The engine and subscription are the same; fresh parity runs must use one pinned build.

| Source | Verified media | Time (s) | Outcome |
| --- | --- | ---: | --- |
| zhiqiu | Yes | 101.6 | 我的狗狗我的爱 |
| Libvio | Yes | 28.1 | 我的偶像总裁 |
| Guazi | Yes | 24.3 | 失控的关系 |
| Kan360 | No | 11.0 | No videos from home, search, or categories |
| GuaziTY | No | 12.1 | No videos from home, search, or categories |
| fishhxq | No | 15.7 | No videos from home, search, or categories |
| 兰芷 | No | 17.7 | No verified media from tested titles/lines |
| 疏影 | Yes | 72.4 | 法医秦明之龙番往事 |
| 枕霜 | Yes | 31.3 | 我们的新时代 |
| 观澜 | No | 53.9 | No verified media from tested titles/lines |
| 孟葭 | Yes | 27.1 | 我们的新时代 |
| 南枝 | Yes | 26.0 | 我的城 |
| 沐辞 | Yes | 27.5 | 我的名字 |
| gying | No | 29.1 | No verified media from tested titles/lines |
| wencai | No | 21.9 | No verified media from tested titles/lines |
| 双星 | Yes | 25.8 | 玩具总动员5 |
| Jianpian | Yes | 35.0 | 淑女与髯 |
| TingShijie | Yes | 22.2 | 我的老千生涯-多人有声剧 |
| TingYou | No | 13.2 | No videos from home, search, or categories |
| ShuangXing | No | 76.5 | No verified media from tested titles/lines |
| Tiu6 | No | 44.4 | No verified media from tested titles/lines |
| 少儿教育 | No | 13.8 | No videos from home, search, or categories |
| 小学课堂 | No | 12.4 | No videos from home, search, or categories |
| 初中课堂 | No | 13.2 | No videos from home, search, or categories |
| 高中教育 | No | 14.7 | No videos from home, search, or categories |
| BiliHeji | No | 15.5 | No videos from home, search, or categories |
| BiliGequ | No | 15.1 | No videos from home, search, or categories |
| Douban | No | 13.6 | No videos from home, search, or categories |
| YGP | No | 17.7 | No videos from home, search, or categories |
| FishConfig | No | 20.5 | No videos from home, search, or categories |
| Local | No | 21.1 | No videos from home, search, or categories |
| ALLLive | No | 17.9 | No videos from home, search, or categories |
| bili | No | 16.9 | No videos from home, search, or categories |
| FishPs | No | 17.1 | No videos from home, search, or categories |
| FishMuou | No | 23.8 | No videos from home, search, or categories |
| bl | Yes | 38.9 | 兰香如故 |
| KanJu | No | 22.0 | No videos from home, search, or categories |
| Luck | No | 18.3 | java.lang.NoClassDefFoundError: android/util/AtomicFile: java.lang.ClassNotFoundException: android.util.AtomicFile |
| 素笺 | No | 17.4 | No videos from home, search, or categories |
| 长泽 | Yes | 27.0 | 哦，我的宠妃大人 |
| 云岫 | No | 13.4 | No videos from home, search, or categories |
| Rebo | No | 12.6 | No videos from home, search, or categories |
| 三秋影视 | No | 12.9 | No videos from home, search, or categories |
| 马猴影视 | No | 12.7 | No videos from home, search, or categories |
| 星澜 | No | 13.9 | No videos from home, search, or categories |
| 茶寮 | No | 13.7 | No videos from home, search, or categories |
| 竹隐 | No | 13.9 | No videos from home, search, or categories |
| 玉阶 | No | 11.8 | No videos from home, search, or categories |
| 香篆 | No | 11.9 | No videos from home, search, or categories |
| 松庭 | No | 11.8 | No videos from home, search, or categories |
| 纸鸢 | No | 11.1 | No videos from home, search, or categories |
| 墨砚 | No | 11.0 | No videos from home, search, or categories |
| KZN | No | 11.2 | No videos from home, search, or categories |
| Yidong4K | No | 10.7 | No videos from home, search, or categories |
| WoNiu | No | 11.0 | No videos from home, search, or categories |
| Qiwei | No | 17.4 | No videos from home, search, or categories |
| FishDuoduo | No | 11.8 | No videos from home, search, or categories |
| Fishhuajuan | No | 11.3 | No videos from home, search, or categories |
| FishHuban | No | 11.9 | No videos from home, search, or categories |
| Fishshayang | No | 11.5 | No videos from home, search, or categories |
| Fishgege | No | 11.4 | No videos from home, search, or categories |
| DianYingYunJi | No | 10.9 | No videos from home, search, or categories |
| VideoX | No | 10.5 | No videos from home, search, or categories |
| Wwys | No | 10.6 | No videos from home, search, or categories |
| CZ | No | 15.4 | No videos from home, search, or categories |
| TvDy | No | 11.8 | No videos from home, search, or categories |
| SaoHuo | No | 11.9 | No videos from home, search, or categories |
| Duboku | No | 12.7 | No videos from home, search, or categories |
| HonHon | No | 12.6 | No videos from home, search, or categories |
| DJHub | No | 12.5 | No videos from home, search, or categories |
| XingHui | No | 12.6 | No videos from home, search, or categories |
| FanShu | No | 13.1 | No videos from home, search, or categories |
| XgAnime | No | 13.1 | No videos from home, search, or categories |
| Manbo | No | 12.3 | No videos from home, search, or categories |
| Gugu | No | 12.6 | No videos from home, search, or categories |
| Xb6v | No | 12.4 | No videos from home, search, or categories |
| JSo | No | 34.1 | No videos from home, search, or categories |
| Buguyy | No | 14.1 | No videos from home, search, or categories |
| ChuXin | No | 13.7 | No videos from home, search, or categories |
| aiting | No | 12.5 | No videos from home, search, or categories |
| Music24bit | No | 12.4 | No videos from home, search, or categories |
| TuXiaoBei | No | 12.5 | No videos from home, search, or categories |
| BeiLeHu | No | 12.6 | No videos from home, search, or categories |
| Kanqiu | No | 12.2 | No videos from home, search, or categories |
| Sir88 | No | 11.1 | No videos from home, search, or categories |
| QiutongTY | No | 11.3 | No videos from home, search, or categories |
| 919TY | No | 10.4 | No videos from home, search, or categories |
| TingBook | No | 11.0 | No videos from home, search, or categories |
| TingBookJinXia | No | 11.0 | No videos from home, search, or categories |
| Market | No | 10.4 | No videos from home, search, or categories |
| push_agent | No | 10.5 | No videos from home, search, or categories |
| Fishdrive | No | 10.1 | java.lang.NoClassDefFoundError: java/util/Object: java.lang.ClassNotFoundException: java.util.Object |
| Wallpaper | No | 12.7 | No videos from home, search, or categories |
| SeedHub | No | 73.1 | No verified media from tested titles/lines |
| PanWebShare123 | No | 15.8 | No verified media from tested titles/lines |
| PanWebShareGuangYa | No | 13.0 | No videos from home, search, or categories |
| Wogg | No | 76.3 | No verified media from tested titles/lines |
