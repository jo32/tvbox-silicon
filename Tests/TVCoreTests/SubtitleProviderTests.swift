import Foundation
import Testing
@testable import TVCore

// #576 M2: the subtitle-source contract, the script sandbox, and the search across sources.

private func fixtureScript() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "subtitle-source", withExtension: "js", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func hint(_ title: String, episode: Int? = 3, languages: [String] = ["zh-Hans", "en"], file: String? = nil) -> SubtitleHint {
    SubtitleHint(title: title, season: episode == nil ? nil : 1, episode: episode, fileName: file, languages: languages)
}

private func expectError(_ expected: SubtitleProviderError, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("expected \(expected)") }
    catch let error as SubtitleProviderError { #expect(error == expected) }
    catch { Issue.record("unexpected \(error)") }
}

private func expectKind(_ kind: String, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("expected \(kind)") }
    catch let error as SubtitleProviderError { #expect(error.kind == kind) }
    catch { Issue.record("unexpected \(error)") }
}

@Suite struct SubtitleContractTests {
    @Test func manifestValidation() throws {
        try SubtitleProviderManifest(id: "ok.source", name: "OK", domains: ["api.example.com"]).validate()
        let refused = [
            SubtitleProviderManifest(schema: 2, id: "a", name: "A", domains: ["example.com"]),
            SubtitleProviderManifest(id: "a", name: "A", minimumHost: SubtitleProtocol.version + 1, domains: ["example.com"]),
            SubtitleProviderManifest(id: "Bad Id", name: "A", domains: ["example.com"]),
            SubtitleProviderManifest(id: "a", name: "A", domains: []),
            SubtitleProviderManifest(id: "a", name: "A", domains: ["http://example.com"]),
            SubtitleProviderManifest(id: "a", name: "A", domains: ["example.com"], credentials: [.init(key: "k", title: "K"), .init(key: "k", title: "K2")]),
        ]
        for manifest in refused {
            #expect(throws: SubtitleProviderError.self) { try manifest.validate() }
        }
    }

    @Test func domainsIncludeSubdomainsOnly() throws {
        let manifest = SubtitleProviderManifest(id: "a", name: "A", domains: ["opensubtitles.com"])
        #expect(manifest.allows(URL(string: "https://api.opensubtitles.com/api/v1/subtitles")!))
        #expect(manifest.allows(URL(string: "https://opensubtitles.com/x")!))
        #expect(!manifest.allows(URL(string: "https://evilopensubtitles.com/x")!))
        #expect(!manifest.allows(URL(string: "https://opensubtitles.com.evil.net/x")!))
        #expect(!manifest.allows(URL(string: "file:///etc/passwd")!))
    }

    @Test func hintFromCatalogNames() {
        let show = SubtitleHint(video: "庆余年 第二季 [国语]", episodeName: "第05集", year: "2024", fileName: nil, languages: ["zh-Hans"])
        #expect(show.title == "庆余年")
        #expect(show.season == 2)
        #expect(show.episode == 5)
        #expect(show.year == 2024)
        let film = SubtitleHint(video: "Inception (2010)", episodeName: "HD", year: nil, fileName: "Inception.2010.1080p.BluRay.mkv", languages: ["en"])
        #expect(film.title == "Inception")
        #expect(film.season == nil)
        #expect(film.episode == nil)
        let named = SubtitleHint(video: "The Show", episodeName: "", year: nil, fileName: "The.Show.S03E07.WEB.mkv", languages: ["en"])
        #expect(named.season == 3)
        #expect(named.episode == 7)
    }

    @Test func languagesNormalize() {
        #expect(SubtitleLanguage.normalized("chs") == "zh-Hans")
        #expect(SubtitleLanguage.normalized("zh_TW") == "zh-Hant")
        #expect(SubtitleLanguage.normalized("eng") == "en")
        #expect(SubtitleLanguage.normalized("en-US") == "en")
        #expect(SubtitleLanguage.normalized("pt-br") == "pt-BR")
        #expect(SubtitleHint.preferredLanguages(["zh-Hans-CN", "ja-JP"]) == ["zh-Hans", "ja", "en"])
    }
}

@Suite struct SubtitleScriptTests {
    @Test func searchAndResolve() async throws {
        let provider = try await SubtitleScriptProvider.load(script: fixtureScript(), label: "fixture-contract")
        #expect(provider.manifest.id == "fixture")
        let found = try await provider.search(hint("Show"), credentials: ["apiKey": "secret"], within: 5)
        #expect(found.map(\.key) == ["a", "b", "c", "key"])
        #expect(found[0].language == "zh-Hans")
        #expect(found[0].format == "srt")
        #expect(found[0].providerName == "Fixture")
        #expect(found[1].language == "en" && found[1].forced && found[1].hearingImpaired)
        #expect(found[3].title == "got key")
        let text = try await provider.resolve(found[0], credentials: [:], within: 5)
        #expect(text.text?.contains("你好") == true)
        let signed = try await provider.resolve(found[1], credentials: [:], within: 5)
        #expect(signed.url?.host() == "cdn.fixture.invalid")
        #expect((signed.expires?.timeIntervalSinceNow ?? 0) > 30)
    }

    @Test func sandbox() async throws {
        let provider = try await SubtitleScriptProvider.load(script: fixtureScript(), label: "fixture-sandbox")
        let host = try await provider.search(hint("host"), credentials: [:], within: 5)
        #expect(host.first?.title == "undefined undefined undefined undefined")
        await expectError(.blocked("example.com")) { _ = try await provider.search(hint("blocked"), credentials: ["apiKey": "k"], within: 5) }
        await expectError(.blocked("notfixture.invalid")) { _ = try await provider.search(hint("lookalike"), credentials: [:], within: 5) }
        await expectKind("failed") { _ = try await provider.search(hint("import"), credentials: [:], within: 5) }
        await expectKind("failed") { _ = try await provider.search(hint("broken"), credentials: [:], within: 5) }
    }

    @Test func errorKinds() async throws {
        let provider = try await SubtitleScriptProvider.load(script: fixtureScript(), label: "fixture-errors")
        await expectError(.rateLimited(retryAfter: 30)) { _ = try await provider.search(hint("limited"), credentials: [:], within: 5) }
        await expectError(.authExpired) { _ = try await provider.search(hint("expired"), credentials: [:], within: 5) }
        await expectError(.noResults) { _ = try await provider.search(hint("nothing"), credentials: [:], within: 5) }
        let started = Date()
        await expectError(.timeout) { _ = try await provider.search(hint("slow"), credentials: [:], within: 0.5) }
        #expect(Date().timeIntervalSince(started) < 3)
        // The runtime still answers after a call ran out of time.
        let again = try await provider.search(hint("Show"), credentials: [:], within: 5)
        #expect(again.count == 4)
    }

    @Test func refusesScriptsItCantRun() async throws {
        let scripts = [
            "const subtitleSource = { manifest: { schema: 1, id: 'x', domains: ['x.invalid'], minimumHost: 99 }, search() {}, resolve() {} };",
            "const subtitleSource = { manifest: { schema: 1, id: 'x', domains: [] }, search() {}, resolve() {} };",
            "const subtitleSource = { manifest: { schema: 1, id: 'x', domains: ['x.invalid'] } };",
            "this is not javascript",
        ]
        for script in scripts {
            await expectKind("incompatible") { _ = try await SubtitleScriptProvider.load(script: script, label: "refused") }
        }
    }

    @Test func builtInSourcesLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SubtitleSourceLibrary(folder: folder, credentials: MemorySubtitleCredentials())
        let items = await library.items()
        #expect(items.map(\.id) == ["opensubtitles", "assrt"])
        #expect(items.allSatisfy { $0.builtIn && !$0.enabled })
        #expect(items[0].credentials.map(\.key) == ["apiKey", "username", "password"])
        await library.setEnabled("assrt", true)
        // Enabled without its token: listed for the search, which says a key is needed without asking it.
        let sources = await library.searchSources()
        #expect(sources.map(\.provider.manifest.id) == ["assrt"])
        let search = SubtitleSearch(files: SubtitleResourceCache(folder: folder.appendingPathComponent("cache")))
        let progress = await search.results(hint("Show"), sources: sources)
        #expect(progress.statuses["assrt"] == .failed(.authRequired))
        #expect(progress.finished)
        // Added scripts can't take a built-in's name.
        await expectKind("incompatible") {
            try await library.add(script: "const subtitleSource = { manifest: { schema: 1, id: 'assrt', domains: ['x.invalid'] }, search() {}, resolve() {} };", origin: nil)
        }
        let added = try await library.add(script: fixtureScript(), origin: URL(string: "https://fixture.invalid/s.js"))
        #expect(added.enabled && !added.builtIn)
        let reopened = SubtitleSourceLibrary(folder: folder, credentials: MemorySubtitleCredentials())
        #expect(await reopened.items().map(\.id) == ["opensubtitles", "assrt", "fixture"])
        await reopened.remove("fixture")
        #expect(await reopened.items().count == 2)
    }
}

/// A source in Swift whose answers and timing a test sets.
private final class StubProvider: SubtitleProvider, @unchecked Sendable {
    let manifest: SubtitleProviderManifest
    let delay: Double
    /// Ignores cancellation, like a script that is still running.
    let stubborn: Bool
    let answer: Result<[SubtitleCandidate], SubtitleProviderError>
    var resources: [SubtitleResource]
    let meter: Meter

    init(_ id: String, delay: Double = 0, stubborn: Bool = false, answer: Result<[SubtitleCandidate], SubtitleProviderError> = .success([]),
         resources: [SubtitleResource] = [], credentials: [SubtitleProviderManifest.Credential] = [], meter: Meter = Meter()) {
        manifest = SubtitleProviderManifest(id: id, name: id.uppercased(), domains: ["\(id).invalid"], credentials: credentials)
        self.delay = delay; self.stubborn = stubborn; self.answer = answer; self.resources = resources; self.meter = meter
    }

    func search(_ hint: SubtitleHint, credentials: [String: String], within seconds: Double) async throws -> [SubtitleCandidate] {
        await meter.begin()
        if stubborn {
            await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() } }
        } else if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        await meter.end()
        return try answer.get()
    }

    func resolve(_ candidate: SubtitleCandidate, credentials: [String: String], within seconds: Double) async throws -> SubtitleResource {
        await meter.resolved()
        return resources.isEmpty ? SubtitleResource() : resources.removeFirst()
    }
}

private actor Meter {
    var searches = 0, resolves = 0, running = 0, peak = 0
    func begin() { searches += 1; running += 1; peak = max(peak, running) }
    func end() { running -= 1 }
    func resolved() { resolves += 1 }
}

private func candidate(_ provider: String, _ key: String, title: String = "Show.S01E03.WEB", language: String = "zh-Hans", episode: Int? = nil,
                       url: String? = nil, forced: Bool = false, fileMatch: Bool = false, downloads: Int? = nil) -> SubtitleCandidate {
    SubtitleCandidate(provider: provider, key: key, title: title, language: language, forced: forced, episode: episode, fileMatch: fileMatch,
                      downloads: downloads, url: url.flatMap(URL.init(string:)))
}

private func temporaryCache() -> SubtitleResourceCache {
    SubtitleResourceCache(folder: FileManager.default.temporaryDirectory.appendingPathComponent("subs-" + UUID().uuidString))
}

@Suite struct SubtitleSearchTests {
    @Test func asksThreeAtATimeAndReportsAsTheyAnswer() async throws {
        let meter = Meter()
        let sources = (0..<5).map { index in
            SubtitleSearchSource(StubProvider("s\(index)", delay: 0.2, answer: .success([candidate("s\(index)", "k\(index)", title: "Show.S01E03.r\(index)")]), meter: meter))
        }
        let search = SubtitleSearch(files: temporaryCache())
        var updates: [SubtitleSearchProgress] = []
        for await progress in search.search(hint("Show"), sources: sources) { updates.append(progress) }
        #expect(await meter.peak == 3)
        #expect(await meter.searches == 5)
        #expect(updates.count >= 3)
        #expect(updates.first?.candidates.isEmpty == true)
        #expect(updates.first?.statuses.values.allSatisfy { $0 == .searching } == true)
        #expect(updates.last?.finished == true)
        #expect(updates.last?.candidates.count == 5)
    }

    @Test func endsByTheDeadlineWhateverIsOut() async throws {
        var policy = SubtitleSearchPolicy()
        policy.total = 0.5; policy.perSource = 0.5
        let sources = [
            SubtitleSearchSource(StubProvider("fast", answer: .success([candidate("fast", "1")]))),
            SubtitleSearchSource(StubProvider("stuck", delay: 5, stubborn: true)),
            SubtitleSearchSource(StubProvider("failing", answer: .failure(.rateLimited(retryAfter: 9)))),
        ]
        let started = Date()
        let progress = await SubtitleSearch(policy: policy, files: temporaryCache()).results(hint("Show"), sources: sources)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(progress.finished)
        #expect(progress.statuses["fast"] == .found(1))
        #expect(progress.statuses["stuck"] == .failed(.timeout))
        #expect(progress.statuses["failing"] == .failed(.rateLimited(retryAfter: 9)))
        #expect(progress.candidates.map(\.key) == ["1"])
    }

    @Test func ranksDedupesAndFilters() async throws {
        let a = [
            candidate("a", "wrong-episode", title: "Show.S01E04.WEB"),
            candidate("a", "english", title: "Show.S01E03.WEB", language: "en", episode: 3),
            candidate("a", "shared", title: "Show.S01E03.WEB", episode: 3, url: "https://a.invalid/f.srt?token=1"),
            candidate("a", "forced", title: "Show.S01E03.WEB", episode: 3, url: "https://a.invalid/f.srt?token=1", forced: true),
            candidate("a", "hash", title: "x", fileMatch: true),
        ] + (0..<30).map { candidate("a", "filler\($0)", title: "filler", language: "de") }
        let b = [
            candidate("b", "same-file", title: "Show.S01E03.WEB", episode: 3, url: "https://A.invalid/f.srt?token=2", downloads: 5000),
            candidate("b", "traditional", title: "Show.S01E03.WEB", language: "zh-Hant", episode: 3, url: "https://a.invalid/f.srt"),
        ]
        let sources = [SubtitleSearchSource(StubProvider("a", answer: .success(a))), SubtitleSearchSource(StubProvider("b", answer: .success(b)))]
        let progress = await SubtitleSearch(files: temporaryCache()).results(hint("Show", file: "Show.S01E03.WEB.mkv"), sources: sources)
        let keys = progress.candidates.map(\.key)
        #expect(progress.statuses["a"] == .found(20))
        #expect(!keys.contains("wrong-episode"))
        #expect(keys.first == "hash")
        #expect(progress.candidates.first?.reasons.first == .file)
        // The same file from two sources is one result: the better scored.
        #expect(keys.contains("same-file") && !keys.contains("shared"))
        // Forced, another language: kept apart even at the same address.
        #expect(keys.contains("forced") && keys.contains("traditional"))
        #expect(keys.firstIndex(of: "same-file")! < keys.firstIndex(of: "english")!)
        let best = try #require(progress.candidates.first { $0.key == "same-file" })
        #expect(best.reasons == [.episode, .language, .release, .popular])
    }

    @Test func keepsResultsPerAccount() async throws {
        let meter = Meter()
        let provider = StubProvider("c", answer: .success([candidate("c", "1")]), credentials: [.init(key: "key", title: "Key")], meter: meter)
        let search = SubtitleSearch(files: temporaryCache())
        _ = await search.results(hint("Show"), sources: [SubtitleSearchSource(provider, credentials: ["key": "one"])])
        let cached = await search.results(hint("Show"), sources: [SubtitleSearchSource(provider, credentials: ["key": "one"])])
        #expect(cached.candidates.count == 1)
        #expect(await meter.searches == 1)
        _ = await search.results(hint("Show"), sources: [SubtitleSearchSource(provider, credentials: ["key": "two"])])
        #expect(await meter.searches == 2)
        await search.forget("c")
        _ = await search.results(hint("Show"), sources: [SubtitleSearchSource(provider, credentials: ["key": "one"])])
        #expect(await meter.searches == 3)
        // No key: not asked at all.
        let missing = await search.results(hint("Other"), sources: [SubtitleSearchSource(provider)])
        #expect(missing.statuses["c"] == .failed(.authRequired))
        #expect(await meter.searches == 3)
    }

    @Test func downloadsOnceAndResolvesExpiredAddressesAgain() async throws {
        let meter = Meter()
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        let provider = StubProvider("d", resources: [SubtitleResource(url: URL(string: "https://d.invalid/x.srt"), expires: Date(timeIntervalSinceNow: -5)),
                                                     SubtitleResource(text: srt, name: "x.srt", format: "srt")], meter: meter)
        let search = SubtitleSearch(files: temporaryCache())
        let source = SubtitleSearchSource(provider)
        let document = try await search.download(candidate("d", "1", language: "en"), from: source)
        #expect(document.cues.first?.text == "Hello")
        #expect(document.language == "en")
        #expect(await meter.resolves == 2)
        let cached = try await search.download(candidate("d", "1", language: "en"), from: source)
        #expect(cached.cues.count == 1)
        #expect(await meter.resolves == 2)
        // Another account's copy is its own.
        await expectKind("downloadFailed") { _ = try await search.download(candidate("d", "1"), from: SubtitleSearchSource(provider, credentials: ["k": "v"])) }
    }

    @Test func refusesAddressesOutsideTheManifest() async throws {
        let provider = StubProvider("e", resources: [SubtitleResource(url: URL(string: "https://example.com/x.srt"))])
        await expectError(.blocked("example.com")) { _ = try await SubtitleSearch(files: temporaryCache()).download(candidate("e", "1"), from: SubtitleSearchSource(provider)) }
    }

    @Test func resourceCacheDropsLeastRecentlyUsed() async throws {
        let cache = SubtitleResourceCache(folder: FileManager.default.temporaryDirectory.appendingPathComponent("subs-" + UUID().uuidString), limit: 12)
        await cache.store(Data("aaaaaa".utf8), key: "p/1", name: "1", format: nil)
        await cache.store(Data("bbbbbb".utf8), key: "p/2", name: "2", format: nil)
        _ = await cache.data(for: "p/1")
        await cache.store(Data("cccccc".utf8), key: "q/3", name: "3", format: nil)
        #expect(await cache.data(for: "p/1") != nil)
        #expect(await cache.data(for: "p/2") == nil)
        #expect(await cache.data(for: "q/3") != nil)
        #expect(await cache.size == 12)
    }

    @Test func signedAddressesNormalize() {
        let one = SubtitleSearch.normalized(URL(string: "http://CDN.example.com/a.srt?Expires=1&b=2&X-Amz-Signature=z#t")!)
        let two = SubtitleSearch.normalized(URL(string: "https://cdn.example.com/a.srt?b=2&expires=9")!)
        #expect(one == two)
    }
}

/// The built-in sources against their real APIs, without a valid key: each must reach its API through the sandbox
/// and turn the refusal into the right kind. Off by default (network); run with SUBTITLE_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBTITLE_LIVE"] != nil)) struct SubtitleLiveTests {
    @Test func builtInsReachTheirAPIs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SubtitleSourceLibrary(folder: folder, credentials: MemorySubtitleCredentials())
        let assrt = try await library.provider("assrt")
        await expectError(.authExpired) { _ = try await assrt.search(hint("Inception", episode: nil), credentials: ["token": "not-a-token"], within: 10) }
        let opensubtitles = try await library.provider("opensubtitles")
        await expectError(.authRequired) { _ = try await opensubtitles.search(hint("Inception", episode: nil), credentials: ["apiKey": "not-a-key"], within: 10) }
    }
}
