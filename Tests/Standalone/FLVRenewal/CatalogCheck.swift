import Foundation
func checkCatalogSource() async throws {
    func plan(_ names: [String], token: Int) -> PlaybackPlan {
        PlaybackPlan(choices: names.enumerated().map { .init(id: $0.offset, name: $0.element, address: "https://flv.fixture/\($0.element).flv?token=\(token)") }, headers: ["X-Token":"\(token)"], group: "room", requiresWebDetection: false)
    }
    let episode = Episode(address: "original-room", flag: "source-line")
    let backend = CatalogFixture([plan(["high","low"], token: 1), plan(["low","high"], token: 2)])
    let client = CatalogClient(backend: backend)
    let initial = try await client.preparePlayback(episode)
    let channel = try await client.resolvePlayback(initial, choice: initial.choices[1])
    let renewed = try await channel.flvSource!.refresh()
    precondition(renewed.url.absoluteString == "https://flv.fixture/low.flv?token=2")
    precondition(renewed.headers == ["X-Token":"2"])
    let requests = await backend.requests
    precondition(requests == [episode,episode], "renewal reused a cached CDN plan instead of the original source episode")
    let freshness = await backend.freshRequests
    precondition(freshness == [false, true], "renewal permitted a cached HTTP play answer")
    let duplicate = CatalogClient(backend: CatalogFixture([plan(["low","low"], token: 4), plan(["low","high"], token: 5)]))
    let ambiguous = try await duplicate.preparePlayback(episode)
    let ambiguousChannel = try await duplicate.resolvePlayback(ambiguous, choice: ambiguous.choices[1])
    do {
        _ = try await ambiguousChannel.flvSource!.refresh()
        throw URLError(.badServerResponse)
    } catch TVError.unsupported { }
    let download = try await CatalogClient(backend: CatalogFixture([plan(["low"], token: 6)])).preparePlayback(episode, forDownload: true)
    let downloadChannel = try await client.resolvePlayback(download, choice: download.choices[0])
    precondition(downloadChannel.flvSource == nil)
    let direct = CatalogClient(backend: CatalogFixture([plan(["low"], token: 7)]), site: CatalogSite(type: 1))
    let directPlan = try await direct.preparePlayback(episode)
    let directChannel = try await direct.resolvePlayback(directPlan, choice: directPlan.choices[0])
    precondition(directChannel.flvSource == nil)
    let high = PlaybackChoice(id: 0, name: "high", address: "unused")
    precondition(high.renewed(in: plan(["low","low"], token: 3).choices, from: initial.choices) == nil)
    precondition(high.renewed(in: plan(["high","high"], token: 3).choices, from: initial.choices) == nil)
    precondition(high.renewed(in: plan(["sole"], token: 3).choices, from: [high])?.name == "sole")
    precondition(high.renewed(in: plan(["sole"], token: 3).choices, from: initial.choices) == nil)
    print("PASS: production catalog wrappers re-resolve original episode, follow named quality after reorder and reject ambiguity")
}
