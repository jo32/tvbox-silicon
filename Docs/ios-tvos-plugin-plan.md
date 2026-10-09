# Plan: run plugin JARs on iPhone and Apple TV

Status: main-app Guazi playback verified on both simulators; performance and all-source parity remain open · Updated: October 6, 2026

See [measured results and reproduction commands](on-device-runtime-status.md). The previous
server implementation has been reverted. The main iOS/tvOS apps now run plugin JARs in-process; the verified Guazi path reaches actual playback on both simulators. First-use preparation is still slow, and physical-device execution and all-source parity remain unverified.

## Goal

Run TVBox Java plugin sources (`type: 3`, `csp_*` spiders) **inside the iPhone, iPad and Apple TV
app itself**: no server, no Mac and no network helper.

**Done means:** with the 97-source `csp_` subscription at
`http://xn--ihqu10cn4c.xn--v4q818bf34b.top`, the iOS and tvOS apps download the plugin JAR,
prepare it once, and then browse, search and play the same sources that work on the Mac.

## What the plugin needs (measured)

Subscription spider:
`https://qiniu.gongxueyun.com/upload/6850755/2026-10-05/report/709654417_2_1791217713839.jar`
(4.4 MB download, signed Android JAR).

| Entry | Size | Meaning |
| --- | --- | --- |
| `classes.dex` | 11.4 MB | Android (Dalvik) bytecode for all 97 spiders. Large: preparing and loading it is the main startup cost. |
| `assets/FishGuard-v8.so` | 700 KB | Android ARM64 native "guard" library. Plugins call into it (decryption or licence checks), so it must execute. |
| `assets/FishGuard-v7.so` | 581 KB | 32-bit ARM version; not needed on 64-bit devices. |

Finding: the Mac host only special-cases `assets/ftyguard_v8.so` (`NativeProbe.initialize`). For
`FishGuard-v8.so` it takes the standard path. **Confirm this subscription on the Mac first**: Phase 0.

## Apple platform rules that shape the design

1. **No JIT.** An app may not create executable memory, so every engine must be a pure interpreter.
   This includes HotSpot's normal `-Xint` mode: its "template interpreter" generates machine code at
   startup. The JVM must be OpenJDK's **Zero** variant, a C++ interpreter that generates no code.
2. **No child processes.** Everything runs in-process: one JVM inside the app. The Mac's
   one-process-per-source isolation is replaced by class-loader isolation plus watchdogs.
3. **No loading of downloaded native code.** `FishGuard-v8.so` is ARM64 like the iPhone, but it is
   unsigned downloaded code, so it must be **emulated** by an interpreter, never mapped as executable.
4. **App Store guideline 2.5.2** forbids downloading code that adds or changes features. Plugin JARs
   are exactly that, so App Store approval is unlikely. Plan for TestFlight (still reviewed),
   developer or AltStore sideloading, or an EU alternative marketplace. **This is a product decision
   to make before Phase 2.**

## Architecture

```
SwiftUI app (iOS / tvOS)
└─ TVCore
   └─ EmbeddedJarHost (Swift actor, same interface as LocalJarHost)
        │  JNI invocation API, background threads
        ▼
   YingxiaJVM.xcframework ── OpenJDK "Zero" (interpreter only) + trimmed java.base / java.xml /
        │                     java.logging / java.naming / jdk.crypto.ec / jdk.zipfs …
        ├─ JavaHost (existing Runtime/JavaHost code, in-process entry point)
        │    ├─ dex2jar + baksmali   → converts classes.dex once, cached by JAR md5
        │    ├─ Android stand-ins (android.*, dalvik.*), OkHttp, Gson, jsoup, BouncyCastle
        │    └─ PluginClassLoader per source
        └─ unidbg (Java)
             └─ interpreter-only ARM64 backend (C) ── runs FishGuard-v8.so / ftyguard_v8.so
```

- **Reuse with changes:** reuse conversion, protocol and Android stand-ins, but the host cannot
  run unchanged. `NativeCalls`, `AndroidNativeRuntime`, `CloudDriveBridge.current`,
  `DexClassLoader.current` and `Init` have global state. Isolate host/Android classes per session
  and replace per-source system properties with session configuration. Share native bindings
  deliberately and close bridges/emulators when a session is actually idle.
- **Version deviation:** the pinned `openjdk/mobile` spike is JDK 28-internal, built with JDK 26,
  not the proposed JDK 21. A supported release/runtime selection remains a Phase 2 requirement.
- **Mac stays as is:** child-process JVM with JIT. It is the fast reference implementation and the
  test oracle.
- **DexLoom** (`Vendor/DexRuntime`) is not the engine; see "Alternatives considered".

## Phases

### Phase 0: make this subscription work on the Mac (about 1 week)

The Mac is where plugin bugs are fastest to find, so fix them there first.

1. Run `Scripts/audit-subscription-playback.py` against the new subscription; record per-source
   results in `Docs/on-device-runtime-status.md`.
2. Generalize native-guard loading in `NativeProbe.initialize`: detect any
   `assets/*-v8.so` / `*_v8.so` guard (`FishGuard`, `ftyguard`) and its `.md5` file instead of
   one hard-coded name. Map its JNI entry points through `NativeProbe` / `AndroidNativeRuntime`.
3. Output: a Mac baseline ("N of 97 sources fetch media") that the iPhone build must match.

### Phase 1: feasibility spikes and go/no-go (2–3 weeks)

The biggest unknown is speed. Build throwaway prototypes and measure on real hardware: an older
supported iPhone and an Apple TV 4K.

| Spike | Work | Pass criterion |
| --- | --- | --- |
| A. JVM on device | Cross-compile OpenJDK 21 Zero for `ios-arm64`, `ios-arm64-simulator`, `tvos-arm64`, `tvos-arm64-simulator`. Static libraries plus a trimmed module image in an xcframework; start it from Swift through `JNI_CreateJavaVM`. Prior art: PojavLauncher iOS runs OpenJDK on iOS but relies on JIT; the Zero build is new work. | Hello-world plus `java.net` HTTPS request works on device and simulator. |
| B. Conversion | Run dex2jar on the 11.4 MB `classes.dex` inside the Zero JVM. | One-time preparation under about 3 minutes on device, with progress; result cached. |
| C. Spider run | Load converted classes; `init` + `homeContent` + `categoryContent` + `detailContent` + `playerContent` for 3 sources. | Cold home under 30 s, warm under 5 s; peak memory under 600 MB. |
| D. Native guard | unidbg with an interpreter-only ARM64 backend: build unicorn with QEMU's TCI (TCG interpreter), or write a small ARM64 interpreter backend. Run `FishGuard-v8.so` init + one guarded call. | Guard init under 10 s, later calls under 1 s. |

**Go/no-go:** if A–D pass, continue. If C or D is several times too slow, stop and reconsider: the
alternatives below are slower or much larger, and there is no faster legal engine on a stock
iPhone.

### Phase 2: production runtime framework (2–3 weeks)

1. `Scripts/build-apple-jvm.sh`: reproducible build of the Zero JVM and module image for all four
   targets; outputs `Vendor/YingxiaJVM.xcframework`, wired into `project.yml` for the iOS and tvOS
   targets.
2. Size budget: aim for under 80 MB added to the app. Include only the JDK modules the host needs
   (match the Mac's jlink list minus `java.desktop`, `java.management` and `jdk.httpserver` where
   possible).
3. Licences: OpenJDK is GPLv2 with the Classpath Exception; add its notices, plus dex2jar, smali,
   unidbg, unicorn (GPLv2) and the others, to `ThirdPartyNotices.txt`. Unicorn's GPL needs a
   decision on how the app is distributed and whether source must be offered.

### Phase 3: in-process plugin host (2 weeks)

1. **Java:** add `tvbox.runtime.InProcessHost` alongside `NativeProbe`:
   - `open(requestJson) -> sessionId` (same fields `LocalJarHost` writes to `request.json`).
   - `request(sessionId, paramsJson) -> envelopeJson` (same envelope: `result`, `error`,
     `errorCode`, `host`, `status`).
   - `close(sessionId)`.
   The Mac's `--serve` mode stays and calls the same code.
2. **Swift:** `EmbeddedJarHost` actor in TVCore (iOS/tvOS) with `LocalJarHost.request`'s signature,
   so `CatalogClient.request` gains one platform branch.
   - One JVM per app launch, created lazily on first plugin use.
   - Each source runs on its own serial queue. JNI calls run on JVM-attached background threads,
     never the main thread.
   - Watchdog: 60 s per request (180 s for first load). Java threads can't be killed, so a
     timed-out source is marked broken and new work is refused. Dropping a class-loader
     reference does not stop its thread or free reachable state. Bound outstanding workers and
     quarantine the runtime when a worker will not stop; app restart may be required.
   - Memory: JVM heap cap (for example `-Xmx512m`). Evict idle sessions on memory warnings and after
     5 idle minutes.
3. `Site.canBrowse(jarURL:)`: on iOS/tvOS return `true` for `csp_` sources when the embedded
   runtime loaded.
4. Cloud-drive accounts (`CloudDriveAccounts`, the Quark/UC sign-in) on iOS: port
   `CloudLoginView` (macOS-only WebKit sheet today) to iOS. tvOS has no web views, so use a QR code
   scanned with the phone or pasting a cookie.
5. Cloud-drive playback proxy: `CloudDriveBridge` starts a `127.0.0.1` HTTP server. This works
   in-process on iOS (listening on loopback is allowed). Keep it and check that AVPlayer can reach it.

### Phase 4: native guard in production (1–2 weeks)

Harden the Spike D backend:
- Supported JNI surface for `FishGuard` and `ftyguard`.
- Cache guard state per JAR md5.
- Clear error code `unsupported_native_library` with the library name when a different guard
  appears.

### Phase 5: preparation, storage and UI (1 week)

1. First use of a subscription: "Preparing plugins…" with progress (download, then convert, then
   load). Cache converted classes by JAR md5:
   - iOS: `Application Support` (persistent).
   - tvOS: only `Caches` is writable and the system may purge it, so be ready to convert again;
     show progress instead of failing.
2. Sources show states: preparing · ready · unsupported (with reason).
3. Settings → JAR Runtime page (`RuntimeView`): replace the DexLoom probe with embedded-JVM status
   (version, heap, sessions, cache size, "Clear prepared plugins").

### Phase 6: JavaScript sources (optional, 1 week)

Run drpy JavaScript sources in **JavaScriptCore** (system framework, interpreter on device, allowed
without JIT). Port `Runtime/ScriptHost/host.mjs` and replace Node's `require`/`fs`/`http` with Swift
bridges. Not needed for the `csp_`-only subscription above.

### Phase 7: verification (ongoing)

- Parity audit: run the Phase 0 audit through a test harness on the iOS simulator and on devices;
  compare with the Mac baseline source for source.
- Performance dashboard in Diagnostic Logs: conversion time, cold and warm request latency, heap.
- Crash safety: fuzz bad JARs, a plugin that never returns, a plugin that allocates without limit.
- UI capture with the existing `-qaSection` / `-qaPage` launch hooks.

## Alternatives considered

| Option | Verdict |
| --- | --- |
| **Extend DexLoom** (already in repo, runs DEX directly, small). | Rejected as the main engine. It runs only parameterless static `int` methods today. It would need a Java class library written in C (reflection, threads, `java.net`, regex, collections), plus OkHttp, Gson, jsoup and BouncyCastle. That's months, with no reuse of the Mac host. Keep it for the runtime self-test. |
| **Port Android's ART runtime and libcore** (runs DEX natively, includes Android APIs). | Rejected: it is built on bionic/Linux system interfaces; porting is far larger than OpenJDK Zero. |
| **HotSpot `-Xint`** | Not allowed: its template interpreter generates machine code at startup. Zero is the compliant variant. |
| **Plugin server / Mac on LAN** | Rejected by product decision: everything must run on the device. |
| **JIT via debugger tricks (as PojavLauncher uses)** | Not usable for a normal user install; fragile across iOS versions; excluded on tvOS. |

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Interpreter speed (Zero is many times slower than the Mac's JIT; the guard is emulated on top). | Could make sources unusably slow. | Phase 1 measures before committing; cache conversions; keep warm sessions; parse lazily. |
| Memory: 11 MB DEX → large class metadata; tvOS and older iPhones are tighter. | Jetsam kills the app. | Heap cap, session eviction, memory-warning handling; spike C measures peak. |
| In-process plugin bugs (native emulator crash, infinite loop). | Whole app crashes or stalls. | Watchdogs, bounded workers, refuse new work after poisoning, emulator memory limits, crash-safe caches. A watchdog cannot reclaim a hung Java thread. |
| App Store rejection (2.5.2), also for TestFlight. | No App Store distribution. | Decide distribution channel up front. |
| GPL obligations (unicorn, possibly others). | Licensing exposure. | Licence review in Phase 2. |
| Guard libraries change (new names, anti-emulation checks). | Sources stop working. | Generic guard loading (Phase 0) and clear error codes. Mac shares the same code, so a fix lands everywhere. |
| tvOS cache purge. | Repeat multi-minute preparation. | Progress UI; small cache footprint; prepare in background when possible. |

## Effort summary (rough)

| Phase | Estimate |
| --- | --- |
| 0. Mac baseline for this subscription | about 1 week |
| 1. Feasibility spikes (go/no-go) | 2–3 weeks |
| 2. Runtime framework | 2–3 weeks |
| 3. In-process host | 2 weeks |
| 4. Native guard | 1–2 weeks |
| 5. Preparation, storage, UI | 1 week |
| 6. JavaScript sources (optional) | 1 week |
| 7. Verification | ongoing |

Roughly **2–3 months** to a usable build, **gated by the Phase 1 go/no-go after about a month**.

## Decisions needed now

1. Distribution channel (App Store is unlikely to accept this; TestFlight, sideload or EU
   marketplace?).
2. Minimum devices to support (older iPhones and Apple TV HD may be too slow or memory-limited).
3. Acceptable first-use preparation time and cold start per source (sets the Phase 1 pass bar).
