import Foundation
import Testing
@testable import TVCore

@Test func feedbackSendsTheTrimmedMessageWithTheAppsDetails() throws {
    let payload = Feedback.payload("  \n Freezes halfway \n", kind: .bug, install: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
    #expect(json["message"] == "Freezes halfway")
    #expect(json["kind"] == "bug")
    #expect(json["install"] == "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
    // The fields the server checks before it posts anything (Services/error-reports, /v1/feedback).
    #expect(["macos", "ios", "tvos"].contains(json["platform"] ?? ""))
    #expect(Set(json.keys) == ["install", "platform", "os", "model", "lang", "app", "build", "kind", "message"])
    #expect(Feedback.payload(String(repeating: "x", count: 9000), kind: .idea, install: "").message.count == Feedback.limit)
}

@Test func feedbackKindsMatchTheServersLabels() {
    #expect(Feedback.Kind.allCases.map(\.rawValue) == ["bug", "idea", "other"])
}

@Test func feedbackContextListsSubscriptionsAndRecentPlays() throws {
    let origin = try #require(URL(string: "https://example.com/tv.json"))
    let played = PlaybackHistoryContext(origin: origin, sourceKey: "lz", sourceName: "量子资源", videoID: "42",
                                        videoName: "庆余年", episodeID: "2", episodeName: "第2集", episodeFlag: "lzm3u8")
    let entry = PlaybackHistoryEntry(context: played, position: 754, duration: 3723, updatedAt: Date(timeIntervalSince1970: 1_792_843_200))
    let text = Feedback.context(subscriptions: [SubscriptionEntry(address: "https://example.com/tv.json", name: "Home"),
                                                SubscriptionEntry(address: "https://a.example/sub?token=abc&page=1", enabled: false)],
                                errors: ["https://example.com/tv.json": "Timed out"], history: [entry], timeZone: .gmt)
    #expect(text == """
    Subscriptions:
    - Home: https://example.com/tv.json
      - failed: Timed out
    - https://a.example/sub?token=***&page=1 (off)

    Recently played:
    - 庆余年 · 第2集, 量子资源 (lz), 12:34 / 1:02:03, 2026-10-24 12:00:00Z
    """)
    #expect(Feedback.context(subscriptions: [], history: []) == "Subscriptions:\n- none\n\nRecently played:\n- nothing")
}

@Test func feedbackMasksSignInsInAddresses() {
    #expect(Feedback.shareable("http://me:secret@host.example/a.json") == "http://***@host.example/a.json")
    #expect(Feedback.shareable("https://h.example/s?Key=1&sign=2&name=x") == "https://h.example/s?Key=***&sign=***&name=x")
    #expect(Feedback.shareable("file:///Users/someone/Documents/tv.json") == "file: tv.json")
    #expect(Feedback.shareable("not a url") == "not a url")
}

@Test func feedbackSendsTheMessageThenWhatIsLeftOfTheDetails() {
    #expect(Feedback.combined(" It stutters \n", context: "Subscriptions:\n- none\n") == "It stutters\n\nSubscriptions:\n- none")
    #expect(Feedback.combined("It stutters", context: " \n") == "It stutters")
}

@Test func feedbackSaysWhichLimitRefusedIt() {
    let now = Date(timeIntervalSince1970: 1_792_870_000)
    func refusal(_ body: String) -> Feedback.Failure { Feedback.refusal(Data(body.utf8), now: now) }
    #expect(refusal(#"{"limit":"install","max":5,"retryAfter":3600}"#) == .installLimit(max: 5, until: now.addingTimeInterval(3600)))
    #expect(refusal(#"{"limit":"minute","max":2,"retryAfter":60}"#) == .tooFast)
    #expect(refusal(#"{"limit":"everyone","max":50,"retryAfter":7200}"#) == .everyoneLimit(until: now.addingTimeInterval(7200)))
    #expect(refusal(#"{"limit":"everyone","max":50}"#) == .everyoneLimit(until: nil))
    // A server from before it named the cap answers an empty 429.
    #expect(refusal("") == .tooMany)
    #expect(refusal(#"{"limit":"other"}"#) == .tooMany)
    #expect(Feedback.Failure.installLimit(max: 5, until: nil).errorDescription?.contains("5") == true)
    #expect(Feedback.Failure.installLimit(max: 5, until: now).errorDescription?.contains(Feedback.moment(now)) == true)
}

@Test func feedbackRemembersWhatWasSentNewestFirst() throws {
    let defaults = try #require(UserDefaults(suiteName: "feedback-sent-\(UUID())"))
    let date = Date(timeIntervalSince1970: 1_792_870_000)
    func issue(_ number: Int) throws -> Feedback.Issue {
        Feedback.Issue(number: number, url: try #require(URL(string: "https://github.com/o/r/issues/\(number)")))
    }
    Feedback.remember(try issue(191), message: "\n  Page scrolls by itself  \nSubscriptions:\n- none", kind: .bug, date: date, defaults: defaults)
    Feedback.remember(try issue(192), message: "Reverse the episodes", kind: .idea, date: date, defaults: defaults)
    #expect(Feedback.sent(defaults: defaults).map(\.number) == [192, 191])
    #expect(Feedback.sent(defaults: defaults).last?.title == "Page scrolls by itself")
    #expect(Feedback.sent(defaults: defaults).last?.kind == .bug)

    Feedback.markSeen(191, replies: 2, defaults: defaults)
    #expect(Feedback.sent(defaults: defaults).map(\.seen) == [0, 2])
    // Kept to the newest few.
    for number in 1...30 { Feedback.remember(try issue(number), message: "x", kind: .other, defaults: defaults) }
    #expect(Feedback.sent(defaults: defaults).count == Feedback.sentLimit)
    #expect(Feedback.sent(defaults: defaults).first?.number == 30)
}

@Test func feedbackTitlesLikeTheServer() {
    #expect(Feedback.title(" \n 自动页面滑动 \n\nmore") == "自动页面滑动")
    #expect(Feedback.title(String(repeating: "a", count: 100)) == String(repeating: "a", count: 79) + "…")
    #expect(Feedback.title("") == "")
}

@Test func feedbackReadsTheServersStatuses() throws {
    // Services/error-reports, /v1/feedback/replies: oldest reply first, ISO dates.
    let body = #"{"issues":[{"number":192,"state":"open","replies":[{"date":"2026-10-28T12:21:47Z","text":"Could you send a **screen recording**?"}]},{"number":191,"state":"declined","replies":[]}]}"#
    let statuses = try Feedback.statuses(Data(body.utf8))
    #expect(statuses[192]?.state == .open)
    #expect(statuses[192]?.replies.first?.date == Date(timeIntervalSince1970: 1_793_190_107))
    #expect(statuses[191]?.state == .declined)
    #expect(statuses[191]?.replies.isEmpty == true)
    #expect(String(Feedback.reply("Could you send a **screen recording**?\n- iOS 18.5").characters) == "Could you send a screen recording?\n- iOS 18.5")
}
