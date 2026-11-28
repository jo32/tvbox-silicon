import SwiftUI
import TVCore

/// One of the viewer's settings as the assistant sees it: the switch or picker on a Settings page, read and written
/// through the same key (and the same side effects) as that row, so the page shows the change at once.
@MainActor struct AgentSetting {
    enum Kind: String { case bool, number, choice, text }
    struct Choice { let value: JSONValue; let label: String }

    /// The id the tools use.
    let id: String
    /// The user-defaults key behind it, for the catalog's completeness test; nil when the store keeps it.
    let key: String?
    let title: () -> String
    /// The Settings page it is on.
    let page: () -> String
    let kind: Kind
    var choices: () -> [Choice] = { [] }
    var range: ClosedRange<Double>?
    /// More words people may search for it with.
    var keywords: [String] = []
    /// The Settings row `settings_open` scrolls to (a `SettingsSearchTarget` name).
    var anchor: String?
    /// A page of its own that `settings_open` pushes (the Danmaku page), instead of scrolling to a row.
    var subpage: (@MainActor () -> AnyView)?
    /// Whether this device and app show the row (the App Store build hides the danmaku rows until unlocked).
    var available: @MainActor (Store) -> Bool = { _ in true }
    let read: @MainActor (Store) -> JSONValue
    let write: @MainActor (Store, JSONValue) -> Void

    /// The label of `value` among the choices, or the value itself.
    func label(_ value: JSONValue) -> String {
        if kind == .bool, let on = AgentArguments.flag(value) { return on ? L10n.text("On") : L10n.text("Off") }
        return choices().first { Self.same($0.value, value) }?.label ?? (value.string ?? "")
    }

    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if case .number(let x) = a, case .number(let y) = b { return abs(x - y) < 0.0001 }
        return a == b
    }

    /// `value` as this setting stores it, or why it can't be.
    func validate(_ value: JSONValue) throws -> JSONValue {
        switch kind {
        case .bool:
            guard let on = AgentArguments.flag(value) else { throw AgentToolError("`\(id)` is on or off: send true or false.") }
            return .bool(on)
        case .number:
            guard let number = value.string.flatMap(Double.init), number.isFinite else { throw AgentToolError("`\(id)` takes a number.") }
            if let range, !range.contains(number) {
                throw AgentToolError("`\(id)` must be between \(range.lowerBound) and \(range.upperBound).")
            }
            return .number(number)
        case .choice:
            let options = choices()
            if let match = options.first(where: { Self.same($0.value, value) }) { return match.value }
            // A choice also by its value as text ("1.5"), or its label in any case.
            let text = (value.string ?? "").trimmingCharacters(in: .whitespaces)
            if let number = Double(text), let match = options.first(where: { Self.same($0.value, .number(number)) }) { return match.value }
            if let match = options.first(where: { $0.value.string?.caseInsensitiveCompare(text) == .orderedSame
                || $0.label.caseInsensitiveCompare(text) == .orderedSame }) { return match.value }
            throw AgentToolError("`\(id)` must be one of: \(options.map { $0.value.string ?? "" }.joined(separator: ", ")).")
        case .text:
            guard case .string(let text) = value else { throw AgentToolError("`\(id)` takes text.") }
            guard text.count <= 4_000 else { throw AgentToolError("`\(id)` is too long.") }
            return .string(text)
        }
    }

    func json(_ store: Store, detailed: Bool) -> JSONValue {
        let value = read(store)
        var fields: [String: JSONValue?] = [
            "id": .str(id), "title": .str(title()), "page": .str(page()), "type": .str(kind.rawValue), "value": value,
        ]
        if kind == .choice {
            fields["value_label"] = .str(label(value))
            if detailed { fields["choices"] = .list(choices().map { .obj(["value": $0.value, "label": .str($0.label)]) }) }
            else { fields["choices"] = .list(choices().map(\.value)) }
        }
        if let range { fields["min"] = .number(range.lowerBound); fields["max"] = .number(range.upperBound) }
        return .obj(fields)
    }
}

/// A Settings page or link (not a value) the assistant can find and open.
@MainActor struct AgentSettingsLink {
    let id: String
    let title: () -> String
    let page: () -> String
    var keywords: [String] = []
    /// The row `settings_open` scrolls to.
    let anchor: String
    var available: @MainActor (Store) -> Bool = { _ in true }
}

/// Every setting the assistant may read and change. Each mirrors a row of App/SettingsView.swift (and its subpages),
/// with that row's key and side effects; `AgentSettingsCatalogTests` checks no Settings key is missing here.
@MainActor enum AgentSettingsCatalog {
    /// The store the tools work in, for the choices that depend on it (the launch page lists the sections shown).
    static weak var store: Store?

    // MARK: Building blocks

    private static func flag(_ id: String, _ key: String, _ title: String, page: @escaping () -> String, standard: Bool,
                             anchor: String? = nil, keywords: [String] = [], available: @escaping @MainActor (Store) -> Bool = { _ in true },
                             changed: (@MainActor (Store, Bool) -> Void)? = nil) -> AgentSetting {
        AgentSetting(id: id, key: key, title: { L10n.text(title) }, page: page, kind: .bool, keywords: keywords, anchor: anchor,
                     available: available,
                     read: { _ in .bool(UserDefaults.standard.object(forKey: key) as? Bool ?? standard) },
                     write: { store, value in
                         let on = AgentArguments.flag(value) ?? standard
                         UserDefaults.standard.set(on, forKey: key)
                         changed?(store, on)
                     })
    }

    private static func numbers(_ id: String, _ key: String, _ title: String, page: @escaping () -> String, standard: Double,
                                choices: @escaping () -> [Double], label: @escaping (Double) -> String = { Self.plain($0) },
                                anchor: String? = nil, keywords: [String] = [],
                                available: @escaping @MainActor (Store) -> Bool = { _ in true }) -> AgentSetting {
        AgentSetting(id: id, key: key, title: { L10n.text(title) }, page: page, kind: .choice,
                     choices: { choices().map { AgentSetting.Choice(value: .number($0), label: label($0)) } },
                     keywords: keywords, anchor: anchor, available: available,
                     read: { _ in .number(UserDefaults.standard.object(forKey: key) as? Double ?? standard) },
                     write: { _, value in if let number = value.string.flatMap(Double.init) { UserDefaults.standard.set(number, forKey: key) } })
    }

    private static func texts(_ id: String, _ key: String, _ title: String, page: @escaping () -> String, standard: String,
                              choices: @escaping () -> [(String, String)], anchor: String? = nil, keywords: [String] = [],
                              available: @escaping @MainActor (Store) -> Bool = { _ in true }) -> AgentSetting {
        AgentSetting(id: id, key: key, title: { L10n.text(title) }, page: page, kind: .choice,
                     choices: { choices().map { AgentSetting.Choice(value: .string($0.0), label: $0.1) } },
                     keywords: keywords, anchor: anchor, available: available,
                     read: { _ in .string(UserDefaults.standard.string(forKey: key) ?? standard) },
                     write: { _, value in if let text = value.string { UserDefaults.standard.set(text, forKey: key) } })
    }

    private static func integers(_ id: String, _ key: String, _ title: String, page: @escaping () -> String, standard: Int,
                                 choices: @escaping () -> [(Int, String)], keywords: [String] = [],
                                 available: @escaping @MainActor (Store) -> Bool = { _ in true }) -> AgentSetting {
        AgentSetting(id: id, key: key, title: { L10n.text(title) }, page: page, kind: .choice,
                     choices: { choices().map { AgentSetting.Choice(value: .number(Double($0.0)), label: $0.1) } },
                     keywords: keywords, available: available,
                     read: { _ in .number(Double(UserDefaults.standard.object(forKey: key) as? Int ?? standard)) },
                     write: { _, value in if let number = value.int { UserDefaults.standard.set(number, forKey: key) } })
    }

    static func plain(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%g", number)
    }

    private static func seconds(_ number: Double) -> String { L10n.text("%@ s", plain(number)) }

    private static var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private static func on(_ platforms: Set<String>) -> @MainActor (Store) -> Bool {
        let here = AppTools.platform == "iPadOS" ? "iOS" : AppTools.platform
        return { _ in platforms.contains(here) }
    }

    private static let extras: @MainActor (Store) -> Bool = { $0.extrasUnlocked }
    private static func extrasOn(_ platforms: Set<String>) -> @MainActor (Store) -> Bool {
        let platform = on(platforms)
        return { $0.extrasUnlocked && platform($0) }
    }

    // MARK: Pages

    private static let general = { L10n.text("Settings") }
    private static let playback = { L10n.text("Playback") }
    private static let picture = { L10n.text("Picture") }
    private static let gestures = { L10n.text("Gestures") }
    private static let controls = { L10n.text("Controls") }
    private static let videoPage = { L10n.text("Video Page") }
    private static let danmaku = { L10n.text("Danmaku") }
    private static let watchNow = { L10n.text("Show on Watch Now") }
    private static let privacy = { L10n.text("Privacy") }
    private static let subtitles = { L10n.text("Subtitles") }

    // MARK: The settings

    static var settings: [AgentSetting] { cachedSettings }
    private static let cachedSettings: [AgentSetting] = build()

    private static func build() -> [AgentSetting] {
        var list: [AgentSetting] = []
        let mobile = on(["iOS"]), macOrTV = on(["macOS", "tvOS"]), notTV = on(["iOS", "macOS"])
        let danmakuPage: @MainActor () -> AnyView = { AnyView(DanmakuSettingsView()) }

        // General
        list.append(texts("appearance", "app.appearance", "Appearance", page: general, standard: "system",
                          choices: { [("system", L10n.text("System")), ("light", L10n.text("Light")), ("dark", L10n.text("Dark"))] },
                          anchor: "appearance", keywords: ["dark mode", "light mode", "深色", "浅色", "外观"], available: notTV))
        list.append(AgentSetting(
            id: "color_theme", key: "colorTheme", title: { L10n.text("Color Theme") }, page: general, kind: .choice,
            choices: { ColorTheme.choices.filter { $0 != .custom }.map { .init(value: .string($0.rawValue), label: $0.title) } },
            keywords: ["theme", "color", "accent", "主题", "配色"], anchor: "colorTheme",
            read: { _ in .string(ColorThemes.shared.current.rawValue) },
            write: { _, value in if let theme = value.string.flatMap(ColorTheme.init(rawValue:)) { ColorThemes.shared.choose(theme) } }))
        list.append(AgentSetting(
            id: "launch_page", key: nil, title: { L10n.text("Launch Page") }, page: general, kind: .choice,
            choices: {
                let hidden = store?.hiddenSections ?? []
                return AppSection.launchChoices.filter { !hidden.contains($0) }.map { .init(value: .string(AgentNavigator.name($0)), label: $0.title) }
            }, keywords: ["start page", "startup", "启动页"], anchor: "launchPage",
            read: { store in .string(AgentNavigator.name(store.launchSection ?? .home)) },
            write: { store, value in
                if let name = value.string, let section = AgentNavigator.section(named: name) { store.launchSection = section }
            }))
        #if os(iOS)
        list.append(flag("tab_bar_labels", PhoneTabs.labelsKey, "Tab Bar Labels", page: general, standard: true,
                         anchor: "tabBarLabels", available: { _ in phone }))
        list.append(flag("collapse_tab_bar", PhoneTabs.collapsesKey, "Collapse Tab Bar When Scrolling", page: general,
                         standard: true, anchor: "collapseTabBar", available: { _ in phone }))
        #endif
        list.append(flag("icloud_sync", CloudSync.enabledKey, "iCloud Sync", page: general, standard: true, anchor: "iCloudSync",
                         keywords: ["sync", "同步"], available: { $0.cloudSync != nil },
                         changed: { store, on in store.cloudSync?.setEnabled(on) }))

        // Watch Now
        for section in HomeSection.available {
            list.append(AgentSetting(
                id: "watch_now_" + section.rawValue.snakeCased, key: section.key, title: { section.title }, page: watchNow,
                kind: .bool, keywords: ["watch now", "home", "首页"], anchor: "watchNow",
                read: { _ in .bool(UserDefaults.standard.object(forKey: section.key) as? Bool ?? true) },
                write: { _, value in UserDefaults.standard.set(AgentArguments.flag(value) ?? true, forKey: section.key) }))
        }
        list.append(flag("history_file_details", HistoryFileDetails.key, "Show File Size and Quality", page: watchNow,
                         standard: false, anchor: "watchNow"))

        // Playback
        list.append(flag("show_danmaku", DanmakuPreference.key, "Show Danmaku", page: playback, standard: true, anchor: "showDanmaku",
                         keywords: ["danmaku", "bullet comments", "弹幕"], available: extras))
        list.append(AgentSetting(
            id: "auto_play_next_episode", key: nil, title: { L10n.text("Auto-play next episode") }, page: playback, kind: .bool,
            keywords: ["next episode", "autoplay", "连播", "自动播放"],
            read: { .bool($0.autoPlayNext) }, write: { store, value in store.autoPlayNext = AgentArguments.flag(value) ?? true }))
        list.append(AgentSetting(
            id: "skip_intro_outro", key: nil, title: { L10n.text("Automatically skip intro and outro") }, page: playback,
            kind: .bool, keywords: ["intro", "outro", "opening", "片头", "片尾", "跳过"], anchor: "skipIntroOutro",
            read: { .bool(EpisodeSkipSettings.isAutomatic(defaults: $0.playbackDefaults)) },
            write: { store, value in EpisodeSkipSettings.setAutomatic(AgentArguments.flag(value) ?? false, defaults: store.playbackDefaults) }))
        list.append(flag("online_skip_markers", PlaybackSkipLookup.enabledKey, "Look Up Intro and Outro Times Online", page: playback,
                         standard: false, anchor: "skipIntroOutro", keywords: ["intro", "outro", "片头"]))
        list.append(AgentSetting(
            id: "start_speed", key: PlaybackSpeed.key, title: { L10n.text("Start Speed") }, page: playback, kind: .choice,
            choices: { PlaybackSpeed.speeds.map { .init(value: .number(Double($0)), label: PlaybackSpeed.speedLabel($0)) } },
            keywords: ["speed", "playback speed", "倍速", "速度"], anchor: "playback",
            read: { _ in .number(Double(PlaybackSpeed.load())) },
            write: { _, value in if let speed = value.string.flatMap(Float.init) { PlaybackSpeed.save(speed) } }))
        list.append(flag("show_video_info", PlaybackInfo.key, "Show Video Info", page: playback, standard: false, anchor: "showVideoInfo",
                         keywords: ["codec", "resolution", "bitrate", "信息"]))
        list.append(numbers("subtitle_search_time_limit", SubtitleSearchPolicy.timeLimitKey, "Search Time Limit", page: subtitles,
                            standard: SubtitleSearchPolicy.defaultTimeLimit, choices: { SubtitleSearchPolicy.timeLimits },
                            label: seconds, anchor: "subtitleSources", keywords: ["subtitles", "字幕"]))
        #if os(iOS)
        list.append(flag("show_video_tags", PlaybackTags.key, "Show Video Tags", page: playback, standard: true, anchor: "playback"))
        list.append(flag("skip_ads", AdSkip.key, "Skip Ad Segments", page: playback, standard: true, anchor: "playback",
                         keywords: ["ads", "advert", "广告"]))
        list.append(flag("picture_in_picture", PictureInPicturePreference.key, "Picture in Picture", page: controls, standard: true,
                         anchor: "playback", keywords: ["pip", "画中画"]))
        list.append(flag("keep_controls_visible", PlayerControlsVisibility.key, "Keep Controls Visible", page: controls,
                         standard: false, anchor: "playback"))
        list.append(texts("lock_button_side", LockButtonSide.key, "Lock Button", page: controls, standard: LockButtonSide.left.rawValue,
                          choices: { [("left", L10n.text("Left")), ("right", L10n.text("Right"))] }, anchor: "playback"))
        list.append(numbers("touch_and_hold_speed", SpeedBoost.key, "Touch and Hold Speed", page: gestures, standard: SpeedBoost.standard,
                            choices: { [SpeedBoost.off] + SpeedBoost.startRates },
                            label: { $0 == SpeedBoost.off ? L10n.text("Off") : PlaybackSpeed.speedLabel(Float($0)) },
                            anchor: "playback", keywords: ["long press", "长按", "倍速"]))
        list.append(numbers("skip_interval", SkipInterval.key, "Skip Interval", page: gestures, standard: SkipInterval.standard,
                            choices: { SkipInterval.choices }, label: seconds, anchor: "playback", keywords: ["seek", "快进"]))
        list.append(flag("double_tap_to_skip", PictureDoubleTap.key, "Double-Tap to Skip", page: gestures,
                         standard: PictureDoubleTap.standard, anchor: "playback", keywords: ["double tap", "双击"]))
        list.append(flag("brightness_and_volume", PictureLevel.key, "Brightness and Volume", page: gestures, standard: true,
                         anchor: "playback", keywords: ["swipe", "brightness", "volume", "亮度", "音量"]))
        list.append(flag("watch_page_auto_play", WatchPage.autoPlayKey, "Play Automatically", page: videoPage, standard: true,
                         anchor: "playback", available: { _ in phone }))
        list.append(flag("watch_page_full_screen", WatchPage.fullScreenKey, "Start in Full Screen", page: videoPage, standard: false,
                         anchor: "playback", available: { _ in phone }))
        #endif
        #if os(macOS)
        list.append(texts("player_window_size", MacPlayerWindowSize.key, "Default Window Size", page: playback,
                          standard: MacPlayerWindowSize.keep.rawValue, choices: { MacPlayerWindowSize.allCases.map { ($0.rawValue, $0.title) } },
                          anchor: "playerWindowSize"))
        #endif
        #if os(macOS) || os(tvOS)
        list.append(flag("cast_from_bilibili", BilibiliCastController.key, "Cast from the Bilibili App", page: playback, standard: true,
                         anchor: "bilibiliCast", keywords: ["cast", "投屏"], available: extrasOn(["macOS", "tvOS"]),
                         changed: { store, on in if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() } }))
        list.append(flag("play_from_other_devices", PlayOnController.key, "Play from Other Devices", page: playback, standard: true,
                         anchor: "playOn", keywords: ["play on", "airplay", "receive", "接收"], available: macOrTV,
                         changed: { store, on in if on { PlayOnController.shared.start(store) } else { PlayOnController.shared.stop() } }))
        #endif

        // Picture
        list.append(flag("sharper_picture", VideoEnhancement.upscaleKey, "Sharper Picture", page: picture, standard: false,
                         anchor: "sharperPicture", keywords: ["upscale", "super resolution", "超分"],
                         available: { _ in VideoEnhancement.canUpscale }))
        list.append(flag("smooth_motion", VideoEnhancement.smoothKey, "Smooth Motion (60 fps)", page: picture, standard: false,
                         anchor: "smoothMotion", keywords: ["60fps", "frame", "补帧"], available: { _ in VideoEnhancement.canSmooth }))

        // Privacy
        list.append(flag("send_error_reports", ErrorReports.key, "Send Error Reports", page: privacy, standard: true, anchor: "errorReports",
                         keywords: ["crash", "report", "崩溃"], changed: { _, on in if !on { ErrorReports.shared.discard() } }))
        list.append(flag("look_up_titles_on_tmdb", TMDBMatch.key, "Look Up Titles on TMDB", page: privacy, standard: true,
                         anchor: "tmdbLookup", keywords: ["tmdb", "poster", "metadata"]))

        // Danmaku page
        var danmakuSettings: [AgentSetting] = []
        danmakuSettings.append(integers("danmaku_area", DanmakuArea.key, "Area", page: danmaku, standard: DanmakuArea.standard.rawValue,
                                        choices: { DanmakuArea.allCases.map { ($0.rawValue, $0.title) } }))
        danmakuSettings.append(numbers("danmaku_text_size", DanmakuStyle.fontSizeKey, "Text Size", page: danmaku,
                                       standard: DanmakuStyle.standardFontSize,
                                       choices: { DanmakuStyle.fontSizes(including: DanmakuStyle.standardFontSize) }, keywords: ["font", "字号"]))
        danmakuSettings.append(numbers("danmaku_opacity", DanmakuStyle.opacityKey, "Opacity", page: danmaku,
                                       standard: DanmakuStyle.standardOpacity,
                                       choices: { DanmakuStyle.opacities(including: DanmakuStyle.standardOpacity) },
                                       label: { "\(Int(($0 * 100).rounded()))%" }, keywords: ["transparency", "透明度"]))
        danmakuSettings.append(numbers("danmaku_speed", DanmakuStyle.speedKey, "Scroll Speed", page: danmaku, standard: DanmakuStyle.standardSpeed,
                                       choices: { DanmakuStyle.speeds(including: DanmakuStyle.standardSpeed) },
                                       label: { PlaybackSpeed.speedLabel(Float($0)) }))
        let spacingTitles = ["Compact", "Standard", "Relaxed", "Wide"]
        danmakuSettings.append(numbers("danmaku_line_spacing", DanmakuStyle.spacingKey, "Line Spacing", page: danmaku,
                                       standard: DanmakuStyle.standardSpacing, choices: { DanmakuStyle.spacings },
                                       label: { value in
                                           DanmakuStyle.spacings.firstIndex(of: value).map { L10n.text(spacingTitles[min($0, spacingTitles.count - 1)]) } ?? plain(value)
                                       }))
        danmakuSettings.append(integers("danmaku_density", DanmakuDensity.key, "Density", page: danmaku, standard: DanmakuDensity.standard.rawValue,
                                        choices: { DanmakuDensity.allCases.map { ($0.rawValue, $0.title) } }))
        danmakuSettings.append(flag("danmaku_scrolling", DanmakuStyle.scrollKey, "Scrolling Comments", page: danmaku, standard: true))
        danmakuSettings.append(flag("danmaku_top", DanmakuStyle.topKey, "Top Comments", page: danmaku, standard: true))
        danmakuSettings.append(flag("danmaku_bottom", DanmakuStyle.bottomKey, "Bottom Comments", page: danmaku, standard: true))
        danmakuSettings.append(flag("danmaku_colors", DanmakuFilter.colorsKey, "Colored Comments", page: danmaku, standard: true))
        danmakuSettings.append(AgentSetting(
            id: "danmaku_blocked_words", key: DanmakuFilter.wordsKey, title: { L10n.text("Blocked Words") }, page: danmaku, kind: .text,
            keywords: ["block", "filter", "屏蔽"],
            read: { _ in .list(DanmakuFilter.words(UserDefaults.standard.string(forKey: DanmakuFilter.wordsKey) ?? "").map { JSONValue.string($0) }) },
            write: { _, value in
                let words = (value.string ?? "").split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
                UserDefaults.standard.set(DanmakuFilter.stored(words.filter { !$0.isEmpty }), forKey: DanmakuFilter.wordsKey)
            }))
        danmakuSettings.append(flag("danmaku_auto_match", DanmakuService.automaticKey, "Automatically match the current episode",
                                    page: danmaku, standard: true,
                                    changed: { _, _ in NotificationCenter.default.post(name: DanmakuService.changed, object: nil) }))
        danmakuSettings.append(flag("danmaku_official_lookup", DanmakuService.officialLookupKey, "Find official episodes for dmku",
                                    page: danmaku, standard: true))
        for var setting in danmakuSettings {
            setting.subpage = danmakuPage
            setting.available = extras
            setting.keywords += ["danmaku", "弹幕"]
            list.append(setting)
        }
        return list
    }

    // MARK: Pages and links

    static var links: [AgentSettingsLink] {
        [
            AgentSettingsLink(id: "page_danmaku", title: { L10n.text("Danmaku Settings") }, page: playback,
                              keywords: ["danmaku", "弹幕"], anchor: "danmakuSettings", available: extras),
            AgentSettingsLink(id: "page_local_cache", title: { L10n.text("Local Cache") }, page: { L10n.text("Advanced") },
                              keywords: ["cache", "storage", "clear", "缓存"], anchor: "localCache"),
            AgentSettingsLink(id: "page_diagnostics", title: { L10n.text("Diagnostic Logs") }, page: { L10n.text("Advanced") },
                              keywords: ["log", "debug", "日志"], anchor: "diagnostics"),
            AgentSettingsLink(id: "page_jar_runtime", title: { L10n.text("JAR Runtime and Compatibility") }, page: { L10n.text("Advanced") },
                              keywords: ["jar", "python", "runtime"], anchor: "jarRuntime", available: extras),
            AgentSettingsLink(id: "page_watch_now", title: { L10n.text("Watch Now") }, page: general,
                              keywords: ["home", "首页"], anchor: "watchNow"),
            AgentSettingsLink(id: "page_color_theme", title: { L10n.text("Color Theme") }, page: general,
                              keywords: ["theme", "主题"], anchor: "colorTheme"),
            AgentSettingsLink(id: "page_subtitle_sources", title: { L10n.text("Subtitles") }, page: playback,
                              keywords: ["subtitles", "字幕"], anchor: "subtitleSources"),
        ]
    }

    static func available(_ store: Store) -> [AgentSetting] { settings.filter { $0.available(store) } }

    static func setting(_ id: String, store: Store) throws -> AgentSetting {
        guard let setting = available(store).first(where: { $0.id == id }) else {
            throw AgentToolError("No setting has the id `\(id)` here. Use settings_search to find the id.")
        }
        return setting
    }

    /// The settings and pages that match `query`, best first, through the Settings page's own search.
    static func search(_ query: String, store: Store) -> [(setting: AgentSetting?, link: AgentSettingsLink?)] {
        let settings = available(store), links = self.links.filter { $0.available(store) }
        var items: [SettingsSearchItem<String>] = []
        for (order, setting) in settings.enumerated() {
            let labels = setting.choices().map(\.label)
            items.append(SettingsSearchItem(id: setting.id, title: setting.title(), section: setting.page(),
                                            keywords: setting.keywords + labels + [setting.id.replacingOccurrences(of: "_", with: " ")],
                                            order: order))
        }
        for (order, link) in links.enumerated() {
            items.append(SettingsSearchItem(id: link.id, title: link.title(), section: link.page(), keywords: link.keywords,
                                            order: settings.count + order))
        }
        return SettingsSearchEngine.search(query: query, in: items).map { item in
            (settings.first { $0.id == item.id }, links.first { $0.id == item.id })
        }
    }
}

private extension String {
    /// "continueWatching" as "continue_watching".
    var snakeCased: String {
        reduce(into: "") { result, character in
            if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
        }
    }
}
