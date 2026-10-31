import Foundation
import Testing
@testable import TVCore

/// Converted plugin classes are cached under `BytecodeCompatibility.VERSION`, and dex2jar's output for each
/// class under `BytecodeCompatibility.DEX2JAR_VERSION`. A change to the converter that keeps the version
/// leaves every device on classes from the old converter, and the failures look like broken plugins. This
/// records what the converter's sources were for the current versions: line 1 is VERSION and every input,
/// line 2 is DEX2JAR_VERSION and the inputs of dex2jar's own output.
@Test func javaHostVersionChangesWithTheConverter() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let java = root.appending(path: "Runtime/JavaHost/src/main/java")
    let manager = FileManager.default
    let vendored = try #require(manager.enumerator(atPath: java.appending(path: "com/googlecode").path))
    let dex2jar = ["tvbox/runtime/LazyDexArchive.java"] + vendored.compactMap { $0 as? String }.filter { $0.hasSuffix(".java") }.map { "com/googlecode/" + $0 }
    let all = dex2jar + ["tvbox/runtime/BytecodeCompatibility.java", "tvbox/runtime/ConstructorRepair.java"]
    let pom = try String(contentsOf: root.appending(path: "Runtime/JavaHost/pom.xml"), encoding: .utf8)
    func hash(_ inputs: [String]) throws -> String {
        var text = ""
        for path in inputs.sorted() {
            // Comments and the versions themselves don't change what the converter produces.
            let lines = try String(contentsOf: java.appending(path: path), encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("/*") && !$0.hasPrefix("*") && !$0.contains("String VERSION = ") && !$0.contains("String DEX2JAR_VERSION = ") }
            text += path + "\n" + lines.joined(separator: "\n") + "\n"
        }
        text += pom.split(separator: "\n").filter { $0.contains("dex2jar") }.joined(separator: "\n")
        return PluginChecksum.sha256(Data(text.utf8))
    }
    let source = try String(contentsOf: java.appending(path: "tvbox/runtime/BytecodeCompatibility.java"), encoding: .utf8)
    let version = try #require(source.firstMatch(of: /String VERSION = "([^"]+)"/)?.1).description
    let dexVersion = try #require(source.firstMatch(of: /String DEX2JAR_VERSION = "([^"]+)"/)?.1).description
    let current = [(version, try hash(all)), (dexVersion, try hash(dex2jar))]
    let file = root.appending(path: "Runtime/JavaHost/conversion-inputs.txt")
    let recorded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    let expected = current.map { "\($0.0) \($0.1)" }.joined(separator: "\n")
    guard recorded.count == 2, recorded.allSatisfy({ $0.count == 2 }) else {
        Issue.record("Runtime/JavaHost/conversion-inputs.txt should have two lines. Set it to:\n\(expected)")
        return
    }
    // dex2jar's kept output is reused under a new VERSION, so a change to it needs both versions bumped.
    if recorded[1][0] == dexVersion {
        #expect(recorded[1][1] == current[1].1, "dex2jar's output may change but BytecodeCompatibility.DEX2JAR_VERSION is still \(dexVersion). Bump DEX2JAR_VERSION and VERSION so devices convert plugins again, then set Runtime/JavaHost/conversion-inputs.txt to the lines this test prints. If the change can't alter dex2jar's output, keep the versions and record:\n\(expected)")
    } else if recorded[0][0] == version {
        Issue.record("DEX2JAR_VERSION changed to \(dexVersion) but VERSION is still \(version): classes converted by the old dex2jar would stay in use. Bump VERSION too.")
    }
    if recorded[0][0] == version {
        #expect(recorded[0][1] == current[0].1, "The DEX converter changed but BytecodeCompatibility.VERSION is still \(version). Bump VERSION so devices convert plugins again (a change outside dex2jar's own output re-runs only the rewrite), then set Runtime/JavaHost/conversion-inputs.txt to the lines this test prints. If the change can't alter converted classes, keep the version and record:\n\(expected)")
    }
    if recorded[0][0] != version || recorded[1][0] != dexVersion {
        Issue.record("Runtime/JavaHost/conversion-inputs.txt is for \(recorded[0][0]) and \(recorded[1][0]). Set it to:\n\(expected)")
    }
}
