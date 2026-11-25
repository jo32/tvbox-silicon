import Testing
@testable import TVCore

@Test func emptyAndWhitespaceQueriesReturnEmpty() {
    let items = [
        SettingsSearchItem(id: "icloud", title: "iCloud Sync", section: "Sync", order: 0),
        SettingsSearchItem(id: "cache", title: "Local Cache", section: "Advanced", order: 1),
    ]
    #expect(SettingsSearchEngine.search(query: "", in: items).isEmpty)
    #expect(SettingsSearchEngine.search(query: "   \n ", in: items).isEmpty)
}

@Test func exactAndPrefixOutrankSubstringAndFuzzy() {
    let items = [
        SettingsSearchItem(id: "sub", title: "Auto Download Subtitles", section: "Playback", order: 0),
        SettingsSearchItem(id: "prefix", title: "Subtitle Style", section: "Playback", order: 1),
        SettingsSearchItem(id: "exact", title: "Subtitle", section: "Playback", order: 2),
        SettingsSearchItem(id: "fuzzy", title: "Smooth Motion", section: "Picture", keywords: ["sbtitle"], order: 3),
    ]
    let results = SettingsSearchEngine.search(query: "subtitle", in: items).map(\.id)
    #expect(results.first == "exact")
    #expect(results[1] == "prefix")
    #expect(results[2] == "sub")
}

@Test func multiTokenRequiresAllTokens() {
    let items = [
        SettingsSearchItem(id: "skip", title: "Automatically skip intro and outro", section: "Playback", order: 0),
        SettingsSearchItem(id: "size", title: "Default Window Size", section: "Playback", order: 1),
        SettingsSearchItem(id: "info", title: "Show Video Info", section: "Playback", order: 2),
    ]
    let results = SettingsSearchEngine.search(query: "skip outro", in: items).map(\.id)
    #expect(results == ["skip"])

    let noMatch = SettingsSearchEngine.search(query: "skip window", in: items)
    #expect(noMatch.isEmpty)
}

@Test func supportsKeywordsAndChinesePinyin() {
    let items = [
        SettingsSearchItem(id: "danmaku", title: "弹幕设置", section: "播放", keywords: ["danmaku", "bullet"], order: 0),
        SettingsSearchItem(id: "cache", title: "本地缓存", section: "高级", keywords: ["cache", "storage"], order: 1),
        SettingsSearchItem(id: "bili", title: "Bilibili", section: "账号", keywords: ["b站", "大会员"], order: 2),
    ]
    #expect(SettingsSearchEngine.search(query: "danmu", in: items).map(\.id) == ["danmaku"])
    #expect(SettingsSearchEngine.search(query: "dm", in: items).map(\.id) == ["danmaku"])
    #expect(SettingsSearchEngine.search(query: "huancun", in: items).map(\.id) == ["cache"])
    #expect(SettingsSearchEngine.search(query: "b站", in: items).map(\.id) == ["bili"])
}

@Test func supportsTypoAndSubsequenceMatching() {
    let items = [
        SettingsSearchItem(id: "danmaku", title: "Danmaku Settings", section: "Playback", order: 0),
        SettingsSearchItem(id: "icloud", title: "iCloud Sync", section: "Sync", order: 1),
    ]
    // Transposition typo: "danamku" -> "danmaku"
    #expect(SettingsSearchEngine.search(query: "danamku", in: items).map(\.id) == ["danmaku"])
    // Subsequence abbreviation: "dmk" -> "danmaku"
    #expect(SettingsSearchEngine.search(query: "dmk", in: items).map(\.id) == ["danmaku"])
    // Missing-char typo: "iclod" -> "icloud"
    #expect(SettingsSearchEngine.search(query: "iclod", in: items).map(\.id) == ["icloud"])
}
