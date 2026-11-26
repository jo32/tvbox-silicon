#!/usr/bin/env python3
"""Compile the real QuickJS C bridge and Swift session/HTTP code against a loopback fixture.

Only app catalog/resource/logging adapters are replaced. This is a narrow host harness, not a
platform app build. Requires Xcode's clang/swiftc, without SwiftPM's unrelated media dependencies.
"""
import pathlib
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
release = threading.Event()
class Origin(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '1000')
        self.end_headers()
        self.wfile.write(b'x'); self.wfile.flush()
        release.wait(4)
server = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()

with tempfile.TemporaryDirectory() as temporary:
    work = pathlib.Path(temporary)
    include = work / 'module'; include.mkdir()
    header = ROOT / 'Vendor/QuickJS/include/TVScript.h'
    (include / 'module.modulemap').write_text(f'module QuickJS {{ header "{header}" export * }}\n')
    objects = []
    for name in ('quickjs', 'libregexp', 'libunicode', 'dtoa', 'TVScript'):
        output = work / (name + '.o'); objects.append(str(output))
        subprocess.run(['xcrun', 'clang', '-O1', '-D_GNU_SOURCE', '-DQUICKJS_NG_BUILD', '-DNDEBUG',
                        '-c', str(ROOT / f'Vendor/QuickJS/{name}.c'), '-o', str(output)], check=True)
    production = (ROOT / 'Sources/TVCore/ScriptRuntime.swift').read_text()
    production = 'import Foundation\nimport CryptoKit\nimport QuickJS\n' + production[production.index('/// One QuickJS runtime pinned'):]
    (work / 'Runtime.swift').write_text(production)
    models = (ROOT / 'Sources/TVCore/Models.swift').read_text()
    models = models[models.index('public enum JSONValue:'):models.index('/// How a source runs')]
    stubs = r'''
import Foundation
import CryptoKit
import QuickJS
struct TVError: Error { static let invalidURL = TVError(); static func unsupported(_ text: String) -> TVError { TVError() } }
enum L10n { static func text(_ text: String, _ args: CVarArg...) -> String { String(format: text, arguments: args) } }
enum Diagnostics { static let shared = Logger(); struct Logger: Sendable { enum Level { case info }; func record(_ level: Level, _ name: String, _ detail: String) {} } }
enum ImportedFiles { static func data(at url: URL) throws -> Data? { nil } }
enum PluginChecksum { static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() } }
enum ScriptCrypto { static func run(_ json: String) throws -> String { throw TVError() } }
enum ScriptAssets {
    static let cache = URL(fileURLWithPath: CommandLine.arguments[2])
    static func resolve(_ name: String, from base: String) -> String? { URL(string: name, relativeTo: URL(string: base))?.absoluteString }
    static func bundled(_ name: String) -> String? {
        if name == "assets://fixture.js" { return "globalThis.fixture = true;" }
        return try? String(contentsOfFile: CommandLine.arguments[1] + "/" + name.replacingOccurrences(of: "assets://", with: ""), encoding: .utf8)
    }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { print("FAIL: " + message); exit(1) } }
@main struct Check {
    static func main() async throws {
        let session = try await ScriptSession.start(module: "assets://fixture.js", supplied: [:], profile: ScriptAssets.cache, label: "cancellation-fixture")
        let url = CommandLine.arguments[3]
        let expressions = ["(() => { while (true) {} })()", "({toJSON() { while (true) {} }})", "new Promise(resolve => setTimeout(() => resolve(1), 3000))",
            "__host('http', JSON.stringify({url:'" + url + "', timeout:3000}))",
            "(() => { __host('httpStart', JSON.stringify({url:'" + url + "', timeout:3000})); return new Promise(resolve => setTimeout(resolve, 3000)); })()"]
        for expression in expressions {
            FileHandle.standardOutput.write(Data(("RUN: " + expression + "\n").utf8))
            let started = Date()
            let task = Task { await session.evaluate(expression, within: 2) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            let answer = await task.value
            check(Date().timeIntervalSince(started) < 1.0, "cancelled VM/HTTP kept executing: " + expression)
            check(answer["error"] != nil, "cancelled evaluation succeeded")
            let next = await session.evaluate("40 + 2", within: 1)
            check(next["value"]?.int == 42, "following call inherited cancellation")
        }
        let began = Date()
        let expired = await session.evaluate("__host('http', JSON.stringify({url:'" + url + "', timeout:3000}))", within: 0.15)
        check(expired["error"] != nil && Date().timeIntervalSince(began) < 0.8, "operation deadline failed to interrupt synchronous HTTP")
        let timer = Task { await session.evaluate("globalThis.stale = 0; new Promise(resolve => setTimeout(() => { stale++; resolve(1); }, 200))", within: 2) }
        try await Task.sleep(for: .milliseconds(40)); timer.cancel(); _ = await timer.value
        let afterTimer = await session.evaluate("new Promise(resolve => setTimeout(() => resolve(globalThis.stale), 300))", within: 1)
        check(afterTimer["value"]?.int == 0, "cancelled timer ran during the next operation: \(afterTimer)")
        FileHandle.standardOutput.write(Data("RUN: init\n".utf8))
        let initializing = Task { () -> Bool in
            do {
                let value = try await ScriptSession.start(api: "https://fixture.invalid/init.js", key: "k", ext: "", profile: ScriptAssets.cache, label: "init", source: "export default { init() { while (true) {} } };")
                value.close(); return false
            } catch is CancellationError { return true } catch { return false }
        }
        try await Task.sleep(for: .milliseconds(100)); initializing.cancel()
        let initCancelled = await initializing.value
        check(initCancelled, "cancelled source initialization did not unwind")
        FileHandle.standardOutput.write(Data("RUN: pending\n".utf8))
        let pending = PendingRequests()
        let id = pending.add()
        pending.cancel(id)
        let cancelled = DispatchSemaphore(value: 0)
        pending.setCancel(id) { cancelled.signal() }
        check(cancelled.wait(timeout: .now() + 0.1) == .success, "cancel-before-attach lost HTTP cancellation")
        pending.finish(id, "late")
        check(pending.take(id) == nil, "late callback resurrected a cancelled answer")
        let done = pending.add()
        pending.finish(done, "ok")
        check(pending.take(done) == "ok", "completed answer lost")
        // The fence includes a transport callback that arrives after cancel was requested.
        let scope = ScriptRequestScope(deadline: Date().addingTimeInterval(2))
        let transfer = try scope.begin()
        let callback = DispatchSemaphore(value: 0)
        scope.attach(transfer) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { callback.signal(); scope.finish(transfer) }
        }
        let fenced = Date()
        scope.cancelAndWait()
        check(Date().timeIntervalSince(fenced) >= 0.1 && callback.wait(timeout: .now()) == .success,
              "scope released before its cancellation callback finished")
        FileHandle.standardOutput.write(Data("RUN: close\n".utf8))
        let running = Task { await session.evaluate("(() => { while (true) {} })()", within: 2) }
        try await Task.sleep(for: .milliseconds(50))
        let queued = Task { await session.evaluate("42", within: 1) }
        session.close()
        let closedRunning = await running.value
        let closedQueued = await queued.value
        check(closedRunning["error"] != nil && closedQueued["error"] != nil, "close lost a running or queued operation")
        let afterClose = await session.evaluate("42", within: 1)
        check(afterClose["error"] != nil, "closed session accepted new work")
        print("QuickJS cancellation checks passed: loop, promise, synchronous/async HTTP, deadlines, timers, init, next operation, pending/callback fences, running/queued close")
    }
}
'''
    (work / 'Check.swift').write_text(stubs + '\n' + models)
    executable = work / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(include),
                    str(work / 'Runtime.swift'), str(work / 'Check.swift'), *objects, '-o', str(executable)], check=True)
    try:
        subprocess.run([str(executable), str(ROOT / 'Sources/TVCore/ScriptAssets'), str(work),
                        f'http://127.0.0.1:{server.server_port}/hold'], check=True, timeout=30)
    finally:
        release.set()
        server.shutdown(); server.server_close()
