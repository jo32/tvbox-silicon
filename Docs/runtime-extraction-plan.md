# Plan: extract the Android runtime as a reusable library

Status: future work, not started · Updated: October 6, 2026

## Summary

The Apple-platform Android compatibility layer (patched OpenJDK Zero, ARM64 native
emulation, DEX-to-JVM conversion and Android API stubs) is not specific to TVBox. It
could serve any app that needs to run Android JAR/DEX code, including native libraries,
on macOS, iOS and tvOS without JIT or child processes.

Decision: separate it **inside this repository first**, and move it to its own repository
only after its API and performance have settled. Splitting now would slow iteration and
produce an API shaped by a single consumer.

## Why not a separate repository yet

- **The boundary is not clean.** `tvbox.runtime` mixes the general runtime with CatVod,
  cloud-drive and FTY/FishGuard behavior. Thirteen Java files under `Runtime/` reference
  CatVod concepts (`Spider`, `vod_`).
- **The runtime is still changing.** iOS/tvOS playback is verified on simulators for one
  source only. A cold start takes about 30 seconds, mostly runtime initialization and guard
  emulation (see [on-device runtime status](on-device-runtime-status.md)). Performance work
  is likely to change the API.
- **There is one consumer.** A general API designed against one app is usually wrong.

## Proposed component split

### Generic runtime (future library)

| Area | Current location |
| --- | --- |
| OpenJDK Zero and Unicorn patches for Apple platforms | `Runtime/AppleRuntime/patches/` |
| In-process bootstrap and native bridge | `Runtime/AppleRuntime/Native/`, `AppleBootstrap.java`, `DirectMappingKeystoneNative.java`, `AppleInterpreterFactory.java` |
| ARM64 Android native-library emulation | `AndroidNativeRuntime`, `HeadlessAndroidEmulator`, `NativeLibraries`, `NativeCalls` |
| Lazy DEX-to-JVM conversion and checkpointed caching | `LazyDexArchive`, `PreparationProgress`, vendored dex2jar sources (`com/googlecode/...`) |
| Bytecode compatibility rewriting | `BytecodeCompatibility` (generic parts only) |
| Android API stubs | `android/**`, `dalvik/system/**` |
| Support utilities | `FilePreferences`, `HierarchyProxyFactory`, `ReflectionDiagnostics`, `HostEnvironment` |
| Swift embedding and preparation | generic parts of `EmbeddedJarHost`, `PluginPreparation`, `SerializedPluginWorker` |
| Basic DEX interpreter | `Vendor/DexRuntime/` (or keep as a TVBox test tool) |

### TVBox adapter (stays in this app)

| Area | Current location |
| --- | --- |
| CatVod contract | `com/github/catvod/**` (`Spider`, `SpiderDebug`, `Init`, `DexNative`) |
| Plugin sessions and per-archive sharing | `PluginSession`, `SharedPluginRuntime`, `InProcessHost` |
| Plugin-family special cases | `NativeProbe` (FTY/FishGuard), CatVod parts of `PluginClassLoader`, `BytecodeCompatibility` |
| Cloud-drive and proxy contracts | `CloudDriveBridge` |
| Source HTTP diagnostics | `HttpDiagnostics` |
| Mac process host | `LocalJarHost`, `Runtime/ScriptHost/` (JavaScript spiders are TVBox-specific) |

The CatVod-specific code in `android/app/ActivityThread.java` and
`android/content/pm/PackageManager.java` must move behind an adapter hook.

## Phases

### Phase 1: module boundary inside this repository

1. Create a separate Maven module for the generic Java runtime and a local Swift package
   (working name `Packages/AndroidRuntimeKit`).
2. Move generic code into a neutral package (for example `apple.android.runtime`) and
   leave TVBox code in `tvbox.runtime`.
3. Rule: the runtime module must not reference `catvod`, `tvbox` or `vod_`. Add a
   `Scripts/verify.sh` check that fails on such references.
4. Keep `Scripts/test-java-host.sh`, the Swift tests and the Guazi simulator playback path
   passing after each move.

### Phase 2: public API

Define the library API with general concepts only:

- Load an archive (JAR/DEX/assets) and get a class loader.
- Call methods on loaded classes, with deadlines and a watchdog.
- Register native-library emulation and JNI bindings.
- Configure cache, checkpoint and preferences directories.
- Report preparation progress and diagnostics.

TVBox should then use only this API plus its adapter.

### Phase 3: separate repository

Split with `git subtree split` (preserving history) when one of these is true:

- The Phase 2 API has gone several weeks without breaking changes.
- First-use and cold-start performance on physical iPhone and Apple TV devices is acceptable.
- A second app needs the runtime.

## Open questions before publishing

- **Licensing.** OpenJDK is GPLv2 with the Classpath Exception, Unicorn is GPLv2, and
  unidbg and dex2jar are Apache-2.0. Confirm how Unicorn is linked in the Apple build and
  what that requires of apps that embed the library. Record conclusions in
  [third-party notices](THIRD_PARTY_NOTICES.md).
- **App Store review.** Guideline 2.5.2 restricts downloading and executing code. A library
  presented as "run downloaded Android code on iOS" draws that scrutiny to every app that
  uses it. Decide how the library is described and which use cases it documents.
- **Name and scope.** Decide whether the JavaScript host and the DexLoom interpreter belong
  to the library or stay with TVBox.
