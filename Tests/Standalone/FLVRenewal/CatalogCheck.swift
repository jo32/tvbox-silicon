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
    let high = PlaybackChoice(id: 0, name: "high", address: "unused")
    precondition(high.renewed(in: plan(["low","low"], token: 3).choices, originalCount: 2) == nil)
    precondition(high.renewed(in: plan(["high","high"], token: 3).choices, originalCount: 2) == nil)
    precondition(high.renewed(in: plan(["sole"], token: 3).choices, originalCount: 1)?.name == "sole")
    precondition(high.renewed(in: plan(["sole"], token: 3).choices, originalCount: 2) == nil)
    print("PASS: production catalog wrappers re-resolve original episode, follow named quality after reorder and reject ambiguity")
}
