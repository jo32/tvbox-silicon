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
@Test func watchNowSettingsAreTranslated() {
    let expected = ["en": "Show on Watch Now", "zh-Hans": "在“现在观看”中显示", "zh-Hant": "在「立即觀看」中顯示", "ja": "「今すぐ観る」に表示"]
    for language in L10n.supportedLanguages {
        #expect(L10n.text("Show on Watch Now", language: language) == expected[language])
        if language != "en" {
            #expect(L10n.text("Choose what Watch Now shows in Settings.", language: language) != "Choose what Watch Now shows in Settings.")
        }
    }
}
@Test func watchNowSourceActionsAreTranslated() {
    #expect(L10n.text("Search This Source", language: "zh-Hans") == "在此源中搜索")
    #expect(L10n.text("Manage Sources", language: "zh-Hant") == "管理隨選來源")
    #expect(L10n.text("Manage Sources", language: "ja") == "配信ソースを管理")
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
    let screen: [String: JSONValue] = ["error": .string("java.lang.RuntimeException: Stub!"), "errorCode": .string("android_screen")]
    #expect(PluginFailure.message(screen, language: "zh-Hans") == "此条目会打开来源自带的设置或登录界面（例如二维码），映匣无法显示。请改在“设置 → 网盘账号”中登录。")
    #expect(PluginFailure.inPlugin(screen))
    #expect(PluginFailure.message(["error": .string("boom")], language: "en") == "Plugin error: boom")
}
@Test func embeddedPluginFailuresAreLocalizedAndKeepTheNativeReason() {
    let failure: [String: JSONValue] = ["error": .string("The embedded plugin request failed. See diagnostic logs."), "errorCode": .string("embedded_request")]
    let expected = [
        "en": "The plugin runtime could not complete this request. Try again or use another source.",
        "zh-Hans": "插件运行时无法完成此请求，请重试或使用其他来源。",
        "zh-Hant": "外掛執行環境無法完成此請求，請重試或使用其他來源。",
        "ja": "プラグインの実行環境でリクエストを完了できませんでした。再試行するか、別のソースを使用してください。"
    ]
    for (language, message) in expected {
        #expect(PluginFailure.message(failure, language: language) == message)
    }
    #expect(PluginFailure.diagnostic(source: "test", failure) == "source=test code=embedded_request The embedded plugin request failed. See diagnostic logs.")
}
#if os(macOS)
@Test func structuredPluginFailuresAreLocalizedWithoutChangingHostOrStatus() {
    let failure: [String: JSONValue] = ["error": .string("raw diagnostic"), "errorCode": .string("source_http"), "host": .string("example.com"), "status": .number(403)]
    #expect(LocalJarHost.errorMessage(failure, language: "zh-Hant") == "來源 example.com 回傳 HTTP 403。")
    #expect(LocalJarHost.errorMessage(failure, language: "en") == "The source example.com returned HTTP 403.")
    #expect(LocalJarHost.errorMessage(["result": .string("{}")], language: "ja") == nil)
}
#endif

@Test func cloudLoginHandoffKeepsTheProviderWithoutDependingOnEpisodeFlags() {
    let failure: [String: JSONValue] = ["error": .string("plugin QR login"), "errorCode": .string("cloud_login_required"), "drive": .string("quark")]
    #expect(CloudDriveLoginRequired(envelope: failure) == .quark)
    #expect(PluginFailure.message(failure, language: "en") == "Your Quark sign-in is missing or has expired. Sign in again to play this episode.")
    #expect(!PluginFailure.inPlugin(failure))
    #expect(CloudDriveLoginRequired(envelope: ["errorCode": .string("cloud_login_required"), "drive": .string("unknown")]) == nil)
}
