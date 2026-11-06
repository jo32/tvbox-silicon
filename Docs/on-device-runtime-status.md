# On-device runtime status

Updated October 15, 2026. How the iPhone, iPad and Apple TV apps run plugin JARs, what has
been verified, and the measurements behind the design.

## How it works

The iOS and tvOS apps embed a JVM and run the same Java host as the Mac (`Runtime/JavaHost/`)
in-process: no server, no child process and no JIT.

- **JVM:** OpenJDK Zero, a C++ interpreter that generates no machine code, built from the
  `openjdk/mobile` repository (JDK 28-internal, pinned at `c1ed06aaef34c8dccf71e236d1ffa20918a77cfb`
  in `Scripts/build-apple-jvm.sh`). Local patches remove process creation, avoid an executable
  code cache, and handle Mach APIs tvOS lacks. The JVM, static JNI bindings, libffi 3.4.8 and
  the native libraries are linked into the main executable, so never enable
  `ENABLE_DEBUG_DYLIB`. Since `61d929e` the JDK classes ship as one jimage (the 1.6.4 tvOS IPA
  holds 190 files instead of about 11,000).
- **Native guards:** plugins' Android ARM64 libraries (FishGuard, ftyguard) are emulated by
  unidbg on Unicorn built with QEMU's TCI interpreter (pinned at
  `e3f075a62742913bb734a55a474aec65c9e5745e` in `Scripts/build-apple-interpreter.sh`), never
  mapped as executable code. Each guest's translation buffer is capped at 32 MB
  (`Runtime/AppleRuntime/patches/unidbg-unicorn-jni.patch`): QEMU's default reserves 1 GiB per
  guest and calls `exit(1)` when it can't, which iPads with 3 GB of memory couldn't spare (#563).
- **The Mac** runs the same host in one long-lived desktop JVM with a JIT (`PluginProcess`,
  `tvbox.runtime.ProcessHost`), under the spider sandbox. `EmbeddedJarHost` is the Swift side
  on all three platforms.
- **Runtimes:** one runtime per plugin archive SHA-256, so DEX loading, the plugin's `Init` and
  native guards run once per archive; each source gets its own spider (up to 24 per archive,
  least recently used first). Archives with an FTY guard keep one runtime per source. At most
  two runtimes stay open, fewer while the heap is short.
- **Memory:** the Java heap is a third of what the process may still use, between 384 MB and
  1 GB (`os_proc_available_memory`). Each `classes*.dex` is memory-mapped rather than read
  into the heap. A memory warning or a short heap closes idle spiders and runtimes; after an
  `OutOfMemoryError` the host releases everything idle and retries once.
- **Requests:** `SerializedPluginWorker` runs up to five searches plus two interactive slots
  (home, detail, playback), holds at most two pending requests, and has a 15-minute watchdog.
  Each request carries a deadline (play 90 s, search 60 s, others 150 s) and a stop time that
  the host's HTTP and sleep calls check. See "Plugin requests that never end" in the
  [developer guide](DEVELOPMENT.md).
- **Conversion:** DEX is converted to JVM classes on demand and cached per archive hash and
  host version. Completed classes survive the app being killed; a class interrupted
  mid-conversion starts over. iOS and macOS keep the cache in Application Support (excluded
  from backup); tvOS only allows Caches, so a purge there means preparing the plugin again.

## What has been verified

- Simulators (October 6): Guazi browse, search, detail and playback on iOS 26.5 and tvOS 27.
- A physical Apple TV 4K on tvOS 27 (the living-room TV): FTY's 4K Quark episodes played in
  real time from the CDN (October 13), and a Baidu QR sign-in returned the playback link 24 s
  after the scan (October 14). These are single runs on one network and account.
- Not measured: all-source parity with the Mac, sustained multi-source memory on older
  devices, and first-use timings on physical hardware. Plugins that need Android UI or a Go
  subprocess still fail on Apple platforms; compatibility is source by source.

## Measurements (October 6, 2026)

These predate the heap sizing, the jimage, request deadlines and other later changes, and come
from simulators on a development Mac, not from devices. Raw evidence stayed in the ignored
`build/` directory.

| Measurement | Result |
| --- | --- |
| Fresh Guazi home request, iOS simulator, original 4.38 MB JAR, no cache | 243.4 s, of which 217.1 s converting 178 classes; 114 items; max sampled RSS 778 MiB |
| Warm `homeVideoContent` (five-request mean) | 1.10 s: 0.41 s until HTTP headers, 0.48 s reading the body, 0.21 s other plugin work |
| First request after relaunching with converted classes cached | 29.9 s, of which 28.8 s runtime and session start-up, mostly the emulated guard |
| Mac, four requests over three sources of one archive (JIT) | 34.95 s with a runtime per source, 18.10 s with a shared runtime |
| Converting the slowest class (`com.github.catvod.spider.merge.a.i1`) | 84.6 s before, 58.5 s after compacting instructions and sparse frame checks |
| Killed after 47 classes, then relaunched | All 47 reused unchanged; the resumed request returned 114 items |

The feasibility spikes before integration measured: Zero plus HTTPS worked on both simulators; full dex2jar of the
11.4 MB DEX inside Zero exceeded a 180-second budget (which led to on-demand conversion); and
FishGuard's `JNI_OnLoad` under Unicorn TCI took 15.9 s on the Mac.

Mac baseline the same day: 13 of the 97 sources in `http://xn--ihqu10cn4c.xn--v4q818bf34b.top`
returned verified media through the local Java host, trying home, search and categories, up to
four titles and three lines per source, without cloud-drive accounts. Sources change daily;
rerun before comparing:

```sh
printf 'Baseline|http://xn--ihqu10cn4c.xn--v4q818bf34b.top\n' > build/on-device-subscription.txt
python3 Scripts/audit-subscription-playback.py --inputs build/on-device-subscription.txt --output build/on-device-baseline --all-sources --source-workers 3
```

## Build and reproduce

Simulator apps, from the repository root:

```sh
Scripts/build-java-host.sh
Scripts/package-apple-runtime.sh ios-simulator
Scripts/package-apple-runtime.sh tvos-simulator
xcodegen generate
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project TVBox.xcodeproj -scheme TVBox-tvOS -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

For devices, package with `ios` or `tvos` and build with your own signing team.

Xcode links the packaged runtime as it is. When a change needs it packaged again, raise
`Runtime/AppleRuntime/runtime-version`: `Scripts/check-apple-runtime.sh` then stops Release builds
(and warns in Debug builds) until `Scripts/package-apple-runtime.sh` has run for that platform.

The JVM spike app (`Runtime/AppleRuntime/Spike/`) checks a bare JVM, HTTPS, and optionally
conversion of a plugin JAR passed as the second argument:

```sh
Scripts/build-apple-jvm.sh ios-simulator
Scripts/test-apple-jvm.sh ios-simulator
xcrun simctl install booted build/apple-runtime/RuntimeSpike-ios-simulator.app
xcrun simctl launch booted com.tvbox.yingxia.RuntimeSpike
# Results: Library/Caches/result.txt and jvm.log in the app's data container.
xcrun simctl terminate booted com.tvbox.yingxia.RuntimeSpike
```

Guard emulation on the Mac JVM: `Scripts/build-apple-interpreter.sh macos`, then
`Scripts/test-interpreter-guard.sh build/apple-runtime/FishGuard-v8.so`.
