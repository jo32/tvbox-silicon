import Foundation
import Testing
@testable import TVCore

// The pure parts of the assistant's app tools (App/Agent/Tools): arguments, ids, caps, scripts' lines and diffs.

@Test func agentArgumentsReadLenientlyButCheck() throws {
    let args = AgentArguments(["n": .string(" 12 "), "x": .number(3), "f": .string("on"), "s": .string("  hi "),
                               "empty": .string("  "), "list": .string("one"), "bad": .object([:]), "half": .number(1.5)])
    #expect(try args.int("n") == 12)
    #expect(try args.int("x") == 3)
    #expect(try args.bool("f") == true)
    #expect(try args.string("s") == "hi")
    #expect(try args.string("empty") == nil)
    #expect(try args.strings("list") == ["one"])
    #expect(try args.string("missing") == nil)
    #expect(throws: AgentToolError.self) { try args.string("bad") }
    #expect(throws: AgentToolError.self) { try args.int("half") }
    #expect(throws: AgentToolError("Missing required argument `missing`.")) { try args.requiredString("missing") }
    #expect(throws: AgentToolError("`n` must be between 1 and 10.")) { try args.int("n", in: 1...10, default: 5) }
    #expect(try args.int("missing", in: 1...10, default: 5) == 5)
    #expect(try args.choice("s", ["HI", "there"]) == "HI")
    #expect(throws: AgentToolError.self) { try args.choice("f", ["a", "b"]) }
    #expect(args.unknownKeys(["n", "x", "f", "s", "empty", "list", "half"]) == ["bad"])
}

@Test func agentArgumentsReadTimes() {
    #expect(AgentArguments.seconds("90") == 90)
    #expect(AgentArguments.seconds("1:30") == 90)
    #expect(AgentArguments.seconds("1:02:03") == 3723)
    #expect(AgentArguments.seconds("-10") == -10)
    #expect(AgentArguments.seconds("1:75") == nil)
    #expect(AgentArguments.seconds("abc") == nil)
    #expect(AgentArguments.seconds("1:2:3:4") == nil)
}

@Test func agentIDsRoundTripAndRefuseOthers() throws {
    let id = AgentToolKit.encodeID("v", ["abc", "src_1", "/vod/42?x=一"])
    #expect(id.hasPrefix("v_"))
    #expect(!id.contains("=") && !id.contains("+") && !id.contains("/"))
    #expect(try AgentToolKit.decodeID(id, prefix: "v", count: 3) == ["abc", "src_1", "/vod/42?x=一"])
    #expect(throws: AgentToolError.self) { try AgentToolKit.decodeID(id, prefix: "s", count: 3) }
    #expect(throws: AgentToolError.self) { try AgentToolKit.decodeID(id, prefix: "v", count: 2) }
    #expect(throws: AgentToolError.self) { try AgentToolKit.decodeID("v_!!!", prefix: "v", count: 3) }
    // A digest is stable and never shows its input.
    #expect(AgentToolKit.digest("https://a.example/x?token=secret") == AgentToolKit.digest("https://a.example/x?token=secret"))
    #expect(AgentToolKit.digest("a").count == 16)
    #expect(AgentToolKit.digest("a") != AgentToolKit.digest("b"))
    #expect(AgentToolKit.digest("") == "cbf29ce484222325")
}

@Test func agentResultsAreCapped() {
    let (items, more) = AgentToolKit.capped(Array(1...45), limit: 30)
    #expect(items == Array(1...30) && more == 15)
    #expect(AgentToolKit.capped([1, 2], limit: 30).more == 0)
    #expect(AgentToolKit.capped([1, 2], limit: -1).items.isEmpty)
    #expect(AgentToolKit.clip("  abcdef  ", 4) == "abc…")
    #expect(AgentToolKit.clip("abc", 4) == "abc")
}

@Test func scriptExcerptNumbersAndCapsLines() throws {
    let text = (1...250).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let first = try AgentScriptText.excerpt(text, from: nil, to: nil)
    #expect(first.total == 250 && first.first == 1 && first.last == 200 && first.truncated)
    #expect(first.text.hasPrefix("  1| line 1\n  2| line 2"))
    let rest = try AgentScriptText.excerpt(text, from: 201, to: nil)
    #expect(rest.last == 250 && !rest.truncated)
    let range = try AgentScriptText.excerpt(text, from: 10, to: 12)
    #expect(range.text == " 10| line 10\n 11| line 11\n 12| line 12")
    #expect(throws: AgentToolError.self) { try AgentScriptText.excerpt(text, from: 300, to: nil) }
    #expect(throws: AgentToolError.self) { try AgentScriptText.excerpt(text, from: 20, to: 10) }
    // The byte cap cuts long lines' excerpts short.
    let wide = (1...50).map { _ in String(repeating: "x", count: 300) }.joined(separator: "\n")
    let capped = try AgentScriptText.excerpt(wide, from: nil, to: nil, maxBytes: 2_000)
    #expect(capped.last < 10 && capped.truncated)
    #expect(try AgentScriptText.excerpt("", from: nil, to: nil).total == 0)
}

@Test func scriptPatchReplacesExactlyWhereMeant() throws {
    let text = "a = 1\nb = 2\na = 1\n"
    #expect(throws: AgentToolError.self) { try AgentScriptText.replacing("a = 1", with: "a = 3", in: text) }
    let both = try AgentScriptText.replacing("a = 1", with: "a = 3", in: text, expected: 2)
    #expect(both.text == "a = 3\nb = 2\na = 3\n" && both.count == 2)
    #expect(throws: AgentToolError("`find` occurs 2 times, not 3.")) { try AgentScriptText.replacing("a = 1", with: "", in: text, expected: 3) }
    #expect(try AgentScriptText.replacing("b = 2\n", with: "", in: text).text == "a = 1\na = 1\n")
    #expect(throws: AgentToolError.self) { try AgentScriptText.replacing("zzz", with: "", in: text) }
    #expect(throws: AgentToolError.self) { try AgentScriptText.replacing("", with: "x", in: text) }
}

@Test func scriptDiffIsUnified() {
    let old = (1...20).map { "l\($0)" }.joined(separator: "\n")
    var lines = (1...20).map { "l\($0)" }
    lines[9] = "changed"
    lines.insert("added", at: 15)
    let diff = AgentScriptText.unifiedDiff(old: old, new: lines.joined(separator: "\n"), name: "s.py")
    #expect(diff == """
        --- s.py
        +++ s.py
        @@ -7,12 +7,13 @@
         l7
         l8
         l9
        -l10
        +changed
         l11
         l12
         l13
         l14
         l15
        +added
         l16
         l17
         l18
        """)
    #expect(AgentScriptText.unifiedDiff(old: old, new: old, name: "s.py").isEmpty)
    // Far-apart changes make two hunks; a new file is all additions.
    var far = (1...40).map { "l\($0)" }
    far[1] = "x"; far[35] = "y"
    let two = AgentScriptText.unifiedDiff(old: (1...40).map { "l\($0)" }.joined(separator: "\n"), new: far.joined(separator: "\n"), name: "f")
    #expect(two.components(separatedBy: "\n@@ ").count == 3)
    #expect(AgentScriptText.unifiedDiff(old: "", new: "a\nb", name: "n") == "--- n\n+++ n\n@@ -0,0 +1,2 @@\n+a\n+b")
    let long = AgentScriptText.unifiedDiff(old: "", new: (1...500).map(String.init).joined(separator: "\n"), name: "n", maxLines: 20)
    #expect(long.hasSuffix("more lines") && long.split(separator: "\n").count == 21)
}

@Test func timeoutAnswersEvenWhenTheWorkIgnoresCancellation() async throws {
    let start = ContinuousClock.now
    await #expect(throws: AgentToolError.self) {
        try await AgentToolKit.withTimeout(0.2, "Slow") {
            // Work that doesn't stop when cancelled, as a plugin call may not.
            let end = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < end { _ = try? await Task.sleep(for: .milliseconds(50)) }
            return 1
        }
    }
    #expect(ContinuousClock.now - start < .seconds(1.5))
    #expect(try await AgentToolKit.withTimeout(2) { 7 } == 7)
    await #expect(throws: CancellationError.self) { try await AgentToolKit.withTimeout(2) { () -> Int in throw CancellationError() } }
}

/// Every switch and picker key on the Settings pages is in the assistant's settings catalog, or listed below as one
/// it leaves alone on purpose, so a new setting can't be missed.
@Test func agentSettingsCatalogCoversSettingsPages() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let catalog = try String(contentsOf: root.appending(path: "App/Agent/Tools/SettingsCatalog.swift"), encoding: .utf8)
    let pages = ["App/SettingsView.swift", "App/DanmakuSettingsView.swift", "App/SubtitleSourcesView.swift"]
    // Not values the assistant sets: pages' own state, servers and addresses, and choices made in the player's menus.
    let leftAlone: Set<String> = ["DanmakuService.preferredSourceKey", "DanmakuService.serverKey", "DanmakuService.serversKey",
                                  "PlaybackSpeed.key", "ColorThemes.key", "ColorThemes.customKey"]
    let storage = try NSRegularExpression(pattern: #"@AppStorage\(([A-Za-z."_]+)"#)
    var missing: [String] = []
    for page in pages {
        let text = try String(contentsOf: root.appending(path: page), encoding: .utf8)
        for match in storage.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[range])
            if leftAlone.contains(key) || catalog.contains(key) { continue }
            // A literal key: the catalog spells it the same.
            if key.hasPrefix("\""), catalog.contains(key) { continue }
            if !missing.contains(key) { missing.append(key) }
        }
    }
    #expect(missing.isEmpty, "Settings keys the assistant's catalog doesn't know: \(missing)")
    // And every literal key the catalog names is one the app reads.
    let literal = try NSRegularExpression(pattern: #"key: "([^"]+)""#)
    let app = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "App").path).filter { $0.hasSuffix(".swift") }
        .map { try String(contentsOf: root.appending(path: "App/" + $0), encoding: .utf8) }.joined()
    for match in literal.matches(in: catalog, range: NSRange(catalog.startIndex..., in: catalog)) {
        guard let range = Range(match.range(at: 1), in: catalog) else { continue }
        #expect(app.contains("\"\(catalog[range])\""), "The catalog names a key the app doesn't use: \(catalog[range])")
    }
}
