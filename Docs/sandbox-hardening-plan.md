# Plan: sandbox hardening against malicious subscription spiders

Status: core implemented and shipped (`00bc735`, in releases since 1.6); Phases 6-7 deferred · Updated: October 15, 2026

## Progress

- **Done & committed (`00bc735`):** Decision 1 (curl -> in-process synchronous `fetch`)
  and Phase 1 (the Seatbelt sandbox: `Runtime/sandbox/spider.sb`, `SpiderSandbox.swift`,
  routing in `LocalJarProcess.init` / `PluginProcess.start`, profile bundled by the three
  `build-*-host.sh`). Verified on Node, Python, and Java under the live profile: DNS/HTTPS
  and cache writes work; reading/stat'ing/listing `$HOME` and executing any binary are
  denied. The macOS app builds with it all bundled and linked.
- **Follow-up fixes:** `7518474` let JAR sources load again under the profile: it grants
  `Application Support/com.tvbox.yingxia/EmbeddedPlugins` (where JAR sessions live) and lets
  every spider read the saved cloud-drive sign-ins file, read only (Phase 7 would narrow
  that); and `76b1911` fixed the profile when the
  app runs from a `/private` path (App Translocation, `/private/tmp`): Foundation's
  `resolvingSymlinksInPath()` strips a leading `/private`, so `SpiderSandbox` resolves paths
  with `realpath(3)`. Test a release build from such a path before shipping.
- **Partially covered by Phase 1:** Phases 3 and 4 — the sandbox already confines Python
  and Java and temp dirs are redirected into the session (`-Djava.io.tmpdir`, `TMPDIR`);
  the runtime-specific extras below (Python `sys.path`/`-S`, the Java `System.load` guard
  and reflection audit) are not yet done.
- **Not implemented (deferred by request):** Phases 6 and 7.
- **Not committed as a harness:** the Phase 0 fixtures. The Phase 0 gate was instead
  validated ad hoc with per-runtime probes and `Scripts/test-sources.py`; adding the
  committed `Tests/Security/` fixtures + runner remains worthwhile.

## Objective and threat model

Treat the subscription configuration, the `plugin.jar` / `.js` / `.py`, and the native
`.so` guards as fully attacker-controlled. Goal: even with **arbitrary code execution
inside a spider runtime**, the code cannot (a) read user files outside the app's own
caches, (b) execute system commands, or (c) exfiltrate local secrets beyond what a
source inherently needs. Functionality to preserve: outbound HTTP/HTTPS, each session's
cache/profile directories, and the loopback proxy.

**Where the gap is: macOS only.** iOS and tvOS are already contained by the OS app
sandbox; the in-process QuickJS lite ports are already a capability sandbox; and
subscription JavaScript/Python run *only* on macOS (the `node`/`python3` hosts are
macOS-only bundles, and `LocalJarHost` is `#if os(macOS)`). So the effort targets the
macOS `java` / `node` / `python3` child processes.

## Verified facts this plan rests on

- macOS 27.0.1; `/usr/bin/sandbox-exec` is present.
- Bundled Node is v25.2.1 with native `fetch`/`Headers`, so curl can be dropped
  (single call site, `Runtime/ScriptHost/host.mjs`).
- The main macOS target has **no entitlements / no App Sandbox**; `Config/macOS/Hosts.entitlements`
  is applied only to the nested host binaries during release signing. Distribution is
  Developer ID + notarization, so Apple never forces a sandbox.
- `WebAddress.resolve` already restricts spider/module URLs to http/https (`file://` blocked).
- The children are spawned at two chokepoints: `PluginProcess.start` and
  `LocalJarProcess.init` in `Sources/TVCore/LocalJarHost.swift`.

## Design decisions (locked)

1. **curl → native `fetch`** in `host.mjs`, so the sandbox can deny all `process-exec`.
2. **Containment = kernel Seatbelt profile via `sandbox-exec`.** Chosen for performance:
   Seatbelt is enforced by in-kernel MAC hooks, so steady-state CPU cost is ~zero. The
   Node Permission Model was rejected because it does per-call checks in userspace
   (measurable CPU on every fs/net operation) and covers only Node. A custom
   `sandbox_init` helper was rejected because runtime cost is identical while adding a
   Mach-O to build, sign, and notarize.
3. **No HTTPS enforcement.** The transport-hardening phase is dropped.

## Phase 0 — Baseline and red-team fixtures (measure first) — validated ad hoc; committed harness pending

- Add one hostile-spider fixture per runtime (JS, Python, JAR) under `Tests/Security/`,
  shaped so each host loads it (JS: `export default () => ({ home, … })`; Python:
  `class Spider(base.spider.Spider)` with `homeContent`; JAR: a `csp_` class). Each
  performs **benign, local-only probes** — report whether a resource is reachable and
  its byte size, never its contents, and never send anything off-device:
  - list the home-directory entry count,
  - stat a private file (for example `~/.zsh_history`) and report size only,
  - write then unlink a marker in the home directory,
  - run `/usr/bin/id -un`.
- A small runner invokes each host in non-serve mode against its fixture and asserts the
  findings.
- Capture the functional baseline: macOS source sweep (`Scripts/test-sources.py`) plus the
  on-device QA sweep.

**Gate established:** every probe SUCCEEDS on the current unsandboxed host ("before");
after Phase 1 every probe must be DENIED ("after"), with the source sweep unchanged (no
functional loss).

## Phase 1 — macOS: Seatbelt sandbox for the spider children (the core fix) — DONE (`00bc735`)

Confine only the child host processes, not the GUI app (sandboxing the app would conflict
with the JIT / `disable-library-validation` entitlements and the Developer ID model).

- New bundled profile `Runtime/sandbox/spider.sb` (SBPL, `(deny default)`), with dynamic
  paths injected as `-D` parameters:
  - **read:** app Resources (host dir), the per-session job/cache root, the profile dir,
    system frameworks/dylibs, `/dev/urandom`, certs, tzdata — and the `cloudAccounts` file
    *only for cloud sessions* (see Phase 7).
  - **write:** only under `~/Library/Caches/com.tvbox.yingxia/…`, the session job dir, and
    the profile dir.
  - **network:** outbound tcp to any port (80/443 only until 2026-10-28, which broke sources on
    ports like :16968) plus loopback bind (for `CloudDriveBridge` / the py proxy).
  - **exec/fork:** allow exec of the interpreter only; **deny process-fork**, which
    neutralizes Java `Runtime.exec`, Node `child_process`, and Python `subprocess`.
- New `Sources/TVCore/SpiderSandbox.swift` builds the `sandbox-exec -f … -D … <interp> <args>`
  argv; `PluginProcess.start` and `LocalJarProcess.init` route through it on macOS.
- **Prerequisite (Decision 1):** rewrite `host.mjs` `request()` from `spawnSync('/usr/bin/curl', …)`
  to native `fetch`, preserving current behavior (redirect control, header/method
  validation, 20 MB cap, timeouts, binary `bodyBase64`, buffer modes).
- **Feature-flagged, default-on**, with a logged fallback to current behavior if the
  wrapper fails.
- **Expect iteration:** getting the JVM, Node, and Python to run under a deny-default
  profile is fiddly (shared cache, sysctls, mach services); budget build/run cycles
  against the live runtimes, validated by the Phase 0 sweep.

Files: add `Runtime/sandbox/spider.sb` and `Sources/TVCore/SpiderSandbox.swift`; edit
`PluginProcess.swift`, `LocalJarHost.swift`, and `host.mjs`.

## Phase 3 — Python child tightening (defense-in-depth) — base containment DONE; extras pending

Already `-I -B`. Containment is the Phase 1 sandbox (Python has no permission model).
Verify `sys.path` never includes the writable `profile/modules` directory; consider `-S`
if it does not break `requests`/`certifi`.

## Phase 4 — Java child and native guards — base containment DONE; native guards pending

- No `SecurityManager` exists in modern Java, so rely on Phase 1. Launch with a minimal
  environment and `-Djava.io.tmpdir=<session>`.
- Native guards are unidbg-**emulated**, never `dlopen`'d. Add an explicit guard that
  `System.load`/`loadLibrary` can only reach an ARM64-validated library resolved by
  `NativeLibraries` through unidbg, and reject any real `dlopen` of a jar-dropped Mach-O.
  Converted plugin classes already have their direct `System.load`/`loadLibrary` calls
  rewritten to `AndroidNativeRuntime` (`BytecodeCompatibility`); still open is an audit of
  reflective and `Runtime`-level calls that would bypass that rewrite
  (`ReflectionDiagnostics`).

## Phase 6 — Integrity and consent (app-side, low risk) — NOT IMPLEMENTED (deferred)

- `PluginChecksum` is a cache key only today; add trust-on-first-use: record each spider's
  hash on first fetch and warn/log when the hash changes for the same source.
- A one-time, per-subscription-origin consent prompt: "This subscription runs custom code
  (N sources)."

## Phase 7 — Secret scoping (app-side, low risk) — NOT IMPLEMENTED (deferred)

- Stop giving spiders filesystem access to secrets: do not include the `cloudAccounts`
  *path* in child-visible input or in the sandbox read-list for non-cloud sessions. The
  trusted host reads the file and injects token *values* only into verified
  `com.github.catvod.spider.Cloud` spiders (as `cloudExtension` already does), which makes
  that class check actually load-bearing once filesystem access is gone.
- Bilibili `SESSDATA` stays app-side and is never passed to spiders.

## Testing and rollout

- **Security gate:** the Phase 0 fixtures flip from "succeeds" to "denied" on all three
  runtimes after Phase 1.
- **Regression gate:** the macOS source sweep plus the on-device QA sweep match the Phase 0
  baseline after each phase.
- **Sequence (each independently shippable):** Phase 0 → Phase 1 (default-on + fallback)
  → Phases 6 and 7 → Phases 3 and 4.

## Risks and watch-items

- `sandbox-exec` is formally deprecated (still shipping on macOS 27); keep a `sandbox_init`
  spawn-helper as a documented fallback if Apple removes it.
- Denying fork could surprise a runtime that spawns a helper at startup — caught by the
  Phase 0 sweep; relax narrowly if needed.
- The loopback proxy must remain reachable under the profile (bind plus connect on localhost).
- Other Claude sessions edit this repository; this plan touches `Runtime/` and
  `Sources/TVCore/{PluginProcess,LocalJarHost}.swift` plus `host.mjs`, none in `App/`, so
  collision risk is low, but confirm before any commit.
