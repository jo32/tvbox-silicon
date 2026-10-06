import Foundation
import Testing
@testable import TVCore

@Test func eachSupportedLanguageHasDistinctTranslations() {
    let expected = ["en": "Settings", "zh-Hans": "设置", "zh-Hant": "設定", "ja": "設定"]
    for language in L10n.supportedLanguages {
        #expect(L10n.text("Settings", language: language) == expected[language])
        #expect(!L10n.text("Your cinema,\non every screen.", language: language).contains("\\n"))
    }
    #expect(L10n.text("Sources", language: "zh-Hans") == "点播源")
    #expect(L10n.text("Sources", language: "zh-Hant") == "隨選來源")
    #expect(L10n.text("Sources", language: "ja") == "配信ソース")
}
@Test func englishIsTheFallbackAndRegionalLanguagesResolve() {
    #expect(L10n.text("Watch Now", language: "fr-FR") == "Watch Now")
    #expect(L10n.text("Sources", language: "zh-TW") == "隨選來源")
    #expect(L10n.text("Sources", language: "zh-CN") == "点播源")
    #expect(L10n.text("Sources", language: "ja-JP") == "配信ソース")
    #expect(L10n.text("An unknown English key", language: "ja") == "An unknown English key")
}
@Test func formattedTranslationsPreserveArguments() {
    #expect(L10n.text("The source %@ returned HTTP %lld.", "example.com", 403, language: "en") == "The source example.com returned HTTP 403.")
    #expect(L10n.text("Page %lld of %lld", 2, 12, language: "ja") == "2 / 12 ページ")
    #expect(L10n.text("Channels: %lld", 1, language: "en") == "Channels: 1")
    #expect(L10n.text("Remove %@ from favorites", "100% 日本語", language: "zh-Hant") == "取消收藏 100% 日本語")
}
@Test func missingGroupDoesNotPersistLocalizedText() throws {
    let channels = try Playlist.parse("#EXTM3U\n#EXTINF:-1,News\nhttps://example.com/live.m3u8", origin: URL(string: "https://example.com/list.m3u")!)
    #expect(channels[0].group.isEmpty)
    #expect(channels[0].id == "|News|https://example.com/live.m3u8")
}
@Test func pluginFailuresExplainTheReasonAndKeepTheTrace() {
    let crash: [String: JSONValue] = ["error": .string("java.lang.ArrayIndexOutOfBoundsException"), "errorCode": .string("plugin_crash"),
                                      "trace": .string("java.lang.ArrayIndexOutOfBoundsException\n\tat com.github.catvod.spider.Xb6v.searchContent(Unknown Source)")]
    #expect(PluginFailure.message(crash, language: "en") == "The source's plugin crashed. The site may have changed; try another source.")
    #expect(PluginFailure.diagnostic(source: "Xb6v", crash).hasPrefix("source=Xb6v code=plugin_crash java.lang.ArrayIndexOutOfBoundsException\n"))
    #expect(PluginFailure.diagnostic(source: "Xb6v", crash).contains("Xb6v.searchContent"))
    let android: [String: JSONValue] = ["error": .string("NoClassDefFoundError"), "errorCode": .string("unsupported_android"), "missingClass": .string("android.util.AtomicFile")]
    #expect(PluginFailure.message(android, language: "en") == "This source needs an Android feature that isn't supported yet: android.util.AtomicFile.")
    #expect(PluginFailure.diagnostic(source: "Luck", android) == "source=Luck code=unsupported_android NoClassDefFoundError missingClass=android.util.AtomicFile")
    #expect(PluginFailure.message(["error": .string("boom")], language: "en") == "Plugin error: boom")
}
#if os(macOS)
@Test func structuredPluginFailuresAreLocalizedWithoutChangingHostOrStatus() {
    let failure: [String: JSONValue] = ["error": .string("raw diagnostic"), "errorCode": .string("source_http"), "host": .string("example.com"), "status": .number(403)]
    #expect(LocalJarHost.errorMessage(failure, language: "zh-Hant") == "來源 example.com 回傳 HTTP 403。")
    #expect(LocalJarHost.errorMessage(failure, language: "en") == "The source example.com returned HTTP 403.")
    #expect(LocalJarHost.errorMessage(["result": .string("{}")], language: "ja") == nil)
}
#endif
