import Foundation
import Testing
@testable import TVCore

enum CatPawDanmaku {
    static func comments(_ context: PlaybackHistoryContext) async -> AutomaticDanmakuResult? { nil }
}

@propertyWrapper final class FixtureState<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

@MainActor struct PickerFixture {
    @FixtureState var busy = false
    @FixtureState var error: String? = nil
    @FixtureState var work: Task<Void, Never>? = nil
    @FixtureState var workGeneration = UUID()
    let episodes: [CatalogDanmakuEpisode] = [], searchServer = "https://fixture.invalid", link = "https://fixture.invalid/page"
    @FixtureState var dismissals = 0
    let model = PickerReply()
    func dismiss() { dismissals += 1 }
}

@MainActor final class PickerReply {
    enum Outcome { case loaded, empty, cancelled, urlCancelled }
    var outcome = Outcome.loaded
    func load(_ episode: CatalogDanmakuEpisode, anime: CatalogDanmakuAnime, client: CatalogDanmakuClient, siblings: [CatalogDanmakuEpisode]) async throws {
        try finish()
    }
    func load(page: String, server: String) async throws { try finish() }
    private func finish() throws {
        switch outcome {
        case .loaded: break
        case .empty: throw TVError.unsupported("No comments")
        case .cancelled: withUnsafeCurrentTask { $0?.cancel() }
        case .urlCancelled: throw URLError(.cancelled)
        }
    }
}

@MainActor @Test(arguments: [false, true]) func pickerDismissesOnlyItsCurrentNonemptySuccess(link: Bool) async {
    let picker = PickerFixture()
    for reply in [PickerReply.Outcome.empty, .cancelled, .urlCancelled, .loaded] {
        picker.model.outcome = reply
        if link { picker.loadLink() }
        else { picker.load(.init(id: "one", title: "Episode 1"), anime: .init(id: "show", title: "Show")) }
        await picker.work?.value
        #expect(picker.dismissals == (reply == .loaded ? 1 : 0))
        #expect(!picker.busy && picker.work == nil)
        #expect((picker.error != nil) == (reply == .empty))
    }
}

@MainActor @Test func emptyManualSelectionKeepsPreviousTrackAndDoesNotCompleteThePickerAction() async throws {
    let model = CatalogDanmakuModel()
    let anime = CatalogDanmakuAnime(id: "show", title: "Show", source: "iqiyi")
    let pick = CatalogDanmakuEpisode(id: "first", title: "Episode 1")
    let client = try CatalogDanmakuClient(address: "https://fixture.invalid", transport: .init { request in
        Data((request.url?.lastPathComponent == "first"
            ? #"{"comments":[{"p":"1,1,16777215,user","m":"existing"}]}"#
            : #"{"comments":[]}"#).utf8)
    })
    try await model.load(pick, anime: anime, client: client)
    let track = model.track, revision = model.revision
    var dismissals = 0
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(#"{"comments":[]}"#.utf8).write(to: file)
    for fromFile in [false, true] {
        do {
            if fromFile { try model.importFile(file) }
            else { try await model.load(.init(id: "empty", title: "Episode 2"), anime: anime, client: client) }
            dismissals += 1
        } catch TVError.unsupported { }
        #expect(model.comments.map(\.text) == ["existing"])
        #expect(model.track == track && model.revision == revision)
        #expect(model.automaticState == "loaded")
    }
    #expect(dismissals == 0)
}
