import SwiftUI
import TVCore

// MARK: Settings building blocks
// The pages under Settings are built from these, so they match the Settings page itself: the
// system's grouped form on iPhone, iPad and Mac, and on Apple TV a page like the TV's own Settings
// subpages, with a symbol and title on the left and sections of rows on the right.

/// A titled run of rows with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSection(title: title, footer: footer) { content }
        #else
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
        #endif
    }
}

/// Icon tile, title, optional subtitle and a trailing accessory. On Apple TV the row goes without
/// the tile, as rows do in the TV's own Settings.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 29, weight: .medium)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 32)
            trailing
        }
        // The insets of a `glassRow()`, so static rows line up with the rows that can be selected.
        .padding(.horizontal, 28).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        #else
        LabeledContent { trailing } label: { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A row that opens a subpage.
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        #if os(tvOS)
        TVSettingsLink(title: title, value: subtitle, destination: destination)
        #else
        RouteLink(destination: destination) { FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle) }
        #endif
    }
}

/// A row that does something in place, such as clearing the cache: the whole row is the button.
struct SettingsActionRow: View {
    let title: String
    var destructive = false
    let action: () -> Void
    var body: some View {
        #if os(tvOS)
        TVSettingsAction(title: title, destructive: destructive, action: action)
        #else
        Button(title, role: destructive ? .destructive : nil, action: action).formRowButton()
        #endif
    }
}

extension View {
    /// Buttons inside settings rows: the TV's control style, and the system's bordered buttons in
    /// the system accent elsewhere, as in System Settings and the Settings app.
    @ViewBuilder func settingsButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        controlButton(prominent: prominent)
        #elseif os(iOS)
        if prominent { buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(systemAccent) }
        else { buttonStyle(.bordered).buttonBorderShape(.capsule).tint(systemAccent) }
        #else
        if prominent { buttonStyle(.borderedProminent).tint(systemAccent) } else { buttonStyle(.bordered) }
        #endif
    }
}

#if !os(tvOS)
/// The system's accent, not the app's: `Color.accentColor` follows the app-wide tint here.
var systemAccent: Color {
    #if os(macOS)
    Color(nsColor: .controlAccentColor)
    #else
    Color(uiColor: .systemBlue)
    #endif
}
#endif

/// A page under Settings. `symbol` and `subtitle` lead the page on Apple TV.
struct SettingsPage<Content: View>: View {
    let title: String
    var symbol = "gearshape"
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: symbol, title: title, subtitle: subtitle) { content }
        #else
        Form { Group { content }.settingsRows() }.settingsForm(title)
        #endif
    }
}

/// The panel around the diagnostic log list.
enum SettingsStyle {
    static let radius: CGFloat = 12
    static let groupFill = Color.primary.opacity(0.05)
    /// Row fill on the app's canvas on iPhone and iPad: the navy of the More tab's tiles.
    static let rowFill = Color(light: .white, dark: Color(red: 0.075, green: 0.105, blue: 0.19))
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVSettingsView()
        #else
        FormSettingsView()
        #endif
    }
}

extension Store {
    /// What a subscription row shows before its chevron.
    fileprivate func subscriptionValue(_ entry: SubscriptionEntry) -> String {
        if subscriptionErrors[entry.address] != nil { return L10n.text("Couldn't refresh") }
        if !entry.enabled { return L10n.text("Off") }
        guard let copy = documents[entry.address] else { return L10n.text("Not loaded yet") }
        return L10n.text("%lld sources", copy.sites.count)
    }
}

#if !os(tvOS)
// MARK: Settings on iPhone, iPad and Mac
// A native grouped form, as in the Settings app and System Settings: the app as the first card,
// icon-led rows that show their current value, switches in place, and subpages for the rest.

private enum FormMetrics {
    #if os(macOS)
    static let icon: CGFloat = 22, symbol: CGFloat = 11, hero: CGFloat = 52
    #else
    static let icon: CGFloat = 30, symbol: CGFloat = 14, hero: CGFloat = 64
    #endif
}

/// The tile that leads a row: a coloured symbol on grey on iPhone and iPad, white on colour on the Mac.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .gray
    var body: some View {
        #if os(iOS)
        // Black (Douyin) would vanish in dark mode, so it follows the text colour.
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(tint == .black ? Color.primary : tint)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #else
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(.white)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #endif
    }
}

/// Icon tile, title and an optional second line.
struct FormLabel: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { SettingsIcon(symbol: symbol, tint: tint) }
    }
}

/// A row that opens a page, with its current value before the chevron.
struct FormLink<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            #if os(iOS)
            // One line, as in the Settings app: the title keeps its width and a long value is cut
            // short; LabeledContent dropped the value under the title instead.
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if let value, !value.isEmpty { valueText(value) }
            }
            #else
            LabeledContent {
                if let value, !value.isEmpty { valueText(value) }
            } label: { FormLabel(symbol: symbol, tint: tint, title: title) }
            #endif
        }
    }
    private func valueText(_ value: String) -> some View {
        Text(value).lineLimit(1).foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
    }
}

/// A row that opens a web page outside the app, with an arrow where other rows have a chevron.
struct SettingsWebRow: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    let url: URL
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #else
        // A button in a list draws its title in the tint; this one reads like the rows around it.
        .tint(.primary)
        #endif
    }
}

extension View {
    /// A button that fills its row: tinted text on iPhone, a plain clickable row on the Mac, where a
    /// form would otherwise draw a push button around the whole label.
    @ViewBuilder func formRowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain).contentShape(Rectangle())
        #else
        self
        #endif
    }
    /// Settings as the system draws them, like System Settings and the Settings app: the system's
    /// grouped background and row fills, and the system accent on switches and buttons instead of
    /// the app's neutral one. The scroll view spans the page and margins centre the rows; a narrowed
    /// frame left the toolbar's scroll edge as a band over the middle column only.
    func settingsForm(_ title: String) -> some View {
        GeometryReader { proxy in
            let extra = (proxy.size.width - Layout.settingsWidth) / 2
            let form = formStyle(.grouped).tint(systemAccent)
                #if os(iOS)
                // The app's navy canvas, as on every other page, instead of the system's black.
                .scrollContentBackground(.hidden)
                .background { Backdrop() }
                #endif
            // Only when there is room to spare: a zero margin would replace the system's own insets.
            if extra > 0 { form.contentMargins(.horizontal, extra, for: .scrollContent) } else { form }
        }
        .screenTitle(title, width: Layout.settingsWidth)
    }
    /// Rows in the app's fill on iPhone and iPad; the Mac keeps System Settings' own.
    @ViewBuilder func settingsRows() -> some View {
        #if os(iOS)
        listRowBackground(SettingsStyle.rowFill)
        #else
        self
        #endif
    }
    /// Switches in the system's own colour: green on iPhone and iPad, the accent on the Mac. Every switch on
    /// iPhone and iPad takes it: the neutral accent is near-white in Dark Mode, so a switch tinted with it turned white.
    @ViewBuilder func settingsSwitch() -> some View {
        #if os(iOS)
        tint(.green)
        #else
        self
        #endif
    }
}

/// The notes under settings switches, shared by Settings and the pages under it.
private enum SettingsNote {
    static var playbackInfo: String { L10n.text("Shows the video's format, resolution, frame rate and bitrate in a corner of the player.") }
    static var danmaku: String { L10n.text("Bilibili's bullet comments, drawn over the video. You can also switch them in the player.") }
    static var tmdb: String {
        L10n.text("Shows cast, artwork and episode details from TMDB on video pages. Sends the video's title, its details from the source and the source's name to Yingxia's lookup service, never your accounts or subscription addresses.")
    }
    static var errorReports: String {
        L10n.text("Sends errors to the developer a few times a day so they can be fixed: the error text with web addresses cut to the server name, the app and system versions, and a random ID. Never your accounts, passwords or viewing history.")
    }
    static var iCloud: String {
        L10n.text("Keeps favorites, Continue Watching, subscriptions, and the sources you pinned, hid or ordered the same on your devices signed in to the same iCloud account. Accounts, passwords and downloads stay on each device.")
    }
    static var support: String {
        L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.")
    }
}

struct FormSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    @AppStorage(CloudSync.enabledKey) private var syncsWithICloud = true
    #if os(iOS)
    @State private var addingSubscription = false
    @State private var showsFeedback = false
    @Environment(\.openURL) private var openURL
    @AppStorage(PhoneTabs.labelsKey) private var showsTabLabels = true
    #endif
    #if os(macOS)
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true
    @AppStorage(PlayOnController.key) private var receivesPlayOn = true
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    #endif
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }

    var body: some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
        Form { Group {
            heroSection

            // Right under the app, so a problem or an idea is never more than one click away.
            #if os(iOS)
            // Two tiles side by side, so the way to the developer reads as a place, not two more rows.
            Section {
                HStack(spacing: 12) {
                    Button { showsFeedback = true } label: {
                        SettingsTile(symbol: "bubble.left.and.text.bubble.right.fill", tint: Brand.indigo, title: L10n.text("Send Feedback"),
                                     subtitle: L10n.text("Report a problem or share an idea"))
                    }
                    Button { openURL(Support.telegram) } label: {
                        SettingsTile(symbol: "paperplane.fill", tint: Brand.cyan, title: L10n.text("Telegram Group"),
                                     subtitle: L10n.text("Chat with the developer and other users"), external: true)
                    }
                }
                // Its own style per button, so each tile takes its own taps rather than the row's.
                .buttonStyle(PressableStyle())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            #else
            Section {
                SettingsLinkRow(symbol: "bubble.left.and.text.bubble.right.fill", tint: Brand.indigo, title: L10n.text("Send Feedback"),
                                subtitle: L10n.text("Report a problem or share an idea")) { FeedbackView() }
                SettingsWebRow(symbol: "paperplane.fill", tint: Brand.cyan, title: L10n.text("Telegram Group"),
                               subtitle: L10n.text("Chat with the developer and other users"), url: Support.telegram)
            }
            #endif

            Section {
                ForEach(store.subscriptions) { entry in
                    let failure = store.subscriptionErrors[entry.address]
                    FormLink(symbol: failure == nil ? "list.bullet.rectangle.fill" : "exclamationmark.triangle.fill",
                             tint: failure != nil ? .orange : entry.enabled ? .blue : .gray,
                             title: entry.title, value: store.subscriptionValue(entry), warning: failure != nil) {
                        SubscriptionDetailView(entry: entry)
                    }
                }
                if store.subscriptions.count > 1 {
                    FormLink(symbol: "trash.fill", tint: .red, title: L10n.text("Remove Subscriptions")) { RemoveSubscriptionsView() }
                }
                #if os(iOS)
                // One row instead of an always-open field and three text buttons; the address goes in a sheet.
                Button { addingSubscription = true } label: {
                    FormLabel(symbol: "plus", tint: .green, title: L10n.text("Add Subscription")).foregroundStyle(.primary)
                }
                #else
                TextField(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress, prompt: Text(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onSubmit { add() }
                TextField(L10n.text("Name (optional)"), text: $store.subscriptionName, prompt: Text(L10n.text("Name (optional)")))
                    .labelsHidden()
                    .onSubmit { add() }
                subscriptionActions
                #endif
            } header: {
                #if os(iOS)
                HStack {
                    Text(L10n.text("Subscriptions"))
                    Spacer()
                    if store.importing {
                        ProgressView().controlSize(.small)
                    } else if !store.subscriptions.isEmpty {
                        // Quiet, in the header's own grey: a page of settings has no one blue action.
                        Button { Task { await store.refreshSubscriptions() } } label: {
                            Label(L10n.text("Refresh All"), systemImage: "arrow.clockwise")
                        }
                        .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                    }
                }
                #else
                Text(L10n.text("Subscriptions"))
                #endif
            } footer: {
                if let message = store.error ?? store.notice { Text(message) }
            }

            Section(L10n.text("Accounts")) {
                if store.extrasUnlocked {
                    FormLink(symbol: "play.tv.fill", tint: .pink, title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                    FormLink(symbol: "music.note", tint: .black, title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                }
                FormLink(symbol: "externaldrive.fill.badge.person.crop", tint: .brown, title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }

            Section {
                Toggle(isOn: $syncsWithICloud) {
                    FormLabel(symbol: "icloud.fill", tint: .blue, title: L10n.text("iCloud Sync"))
                }
                .settingsSwitch()
                .onChange(of: syncsWithICloud) { _, on in store.cloudSync?.setEnabled(on) }
            } footer: {
                Text(SettingsNote.iCloud)
            }

            #if os(iOS)
            // The app's own pages in one group, as in the Settings app. Playback's switches and notes live a level
            // deeper, so this page stays a short list of places.
            Section {
                FormLink(symbol: AppSection.home.icon, tint: Brand.cyan, title: L10n.text("Watch Now")) { WatchNowSettingsView() }
                FormLink(symbol: "slider.horizontal.below.rectangle", tint: .orange, title: L10n.text("Playback")) { PlaybackSettingsView() }
                FormLink(symbol: "play.fill", tint: Brand.indigo, title: L10n.text("Play a URL")) { PlayURLView() }
                Toggle(isOn: $showsTabLabels) {
                    FormLabel(symbol: "dock.rectangle", tint: .gray, title: L10n.text("Tab Bar Labels"))
                }
                .settingsSwitch()
            }
            #else
            Section {
                FormLink(symbol: AppSection.home.icon, tint: Brand.cyan, title: L10n.text("Watch Now")) { WatchNowSettingsView() }
            }
            #endif

            #if os(macOS)
            Section {
                if store.extrasUnlocked {
                    Toggle(isOn: $showsDanmaku) {
                        FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"), subtitle: danmakuNote)
                    }
                    .settingsSwitch()
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "rectangle.tophalf.inset.filled", tint: .teal, title: L10n.text("Danmaku Area"))
                    }
                    Toggle(isOn: $receivesCasts) {
                        FormLabel(symbol: "tv.and.mediabox.fill", tint: BilibiliMark.blue, title: L10n.text("Cast from the Bilibili App"),
                                  subtitle: L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Yingxia")))
                    }
                    .onChange(of: receivesCasts) { _, on in
                        if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                    }
                }
                Toggle(isOn: $receivesPlayOn) {
                    FormLabel(symbol: "play.tv.fill", tint: Brand.indigo, title: L10n.text("Play from Other Devices"),
                              subtitle: L10n.text("With Yingxia open here, your other devices on the same network can send it what they play: tap Play On in their player."))
                }
                .settingsSwitch()
                .onChange(of: receivesPlayOn) { _, on in
                    if on { PlayOnController.shared.start(store) } else { PlayOnController.shared.stop() }
                }
                Toggle(isOn: $showsPlaybackInfo) {
                    FormLabel(symbol: "info.circle.fill", tint: .blue, title: L10n.text("Show Video Info"), subtitle: SettingsNote.playbackInfo)
                }
                .settingsSwitch()
                FormLink(symbol: "play.fill", tint: Brand.indigo, title: L10n.text("Play a URL")) { PlayURLView() }
            } header: {
                Text(L10n.text("Playback"))
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                Section {
                    if VideoEnhancement.canUpscale {
                        Toggle(isOn: $upscalesVideo) {
                            FormLabel(symbol: "wand.and.sparkles", tint: .purple, title: L10n.text("Sharper Picture"), subtitle: upscaleNote)
                        }
                        .settingsSwitch()
                    }
                    if VideoEnhancement.canSmooth {
                        Toggle(isOn: $smoothsVideo) {
                            FormLabel(symbol: "film.stack", tint: .indigo, title: L10n.text("Smooth Motion (60 fps)"), subtitle: smoothNote)
                        }
                        .settingsSwitch()
                    }
                } header: {
                    Text(L10n.text("Picture"))
                }
            }
            #endif

            Section {
                FormLink(symbol: "internaldrive", tint: .blue, title: L10n.text("Local Cache")) { CacheSettingsView() }
                if store.extrasUnlocked {
                    FormLink(symbol: "cpu.fill", tint: .orange, title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() }
                }
                FormLink(symbol: "doc.text.magnifyingglass", tint: .gray, title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
                #if os(iOS)
                // The two switches that send something off the device, with their notes, on a page of their own.
                FormLink(symbol: "hand.raised.fill", tint: .blue, title: L10n.text("Privacy")) { PrivacySettingsView() }
                #else
                Toggle(isOn: $sendsErrorReports) {
                    FormLabel(symbol: "ladybug.fill", tint: .red, title: L10n.text("Send Error Reports"), subtitle: errorReportsNote)
                }
                .settingsSwitch()
                .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
                Toggle(isOn: $looksUpTMDB) {
                    FormLabel(symbol: "film.stack.fill", tint: .teal, title: L10n.text("Look Up Titles on TMDB"), subtitle: tmdbNote)
                }
                .settingsSwitch()
                #endif
            } header: {
                Text(L10n.text("Advanced"))
            } footer: {
                #if os(iOS)
                if store.extrasUnlocked { Text(supportNote) }
                #endif
            }

            if store.extrasUnlocked { ContributorsSection() }

            #if os(iOS)
            // As in the Settings app: one-line rows with their state on the right, and the notes under
            // each group instead of a second line and a small link inside the row.
            Section {
                if Updates.channel != .none {
                Button {
                    if updates.available.isEmpty { Task { await updates.check(manual: true) } } else { updates.show() }
                } label: {
                    HStack(spacing: 8) {
                        FormLabel(symbol: "arrow.triangle.2.circlepath", tint: .gray, title: L10n.text("Software Update"))
                            .foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                        if updates.checking { ProgressView() }
                        else if !updates.available.isEmpty { NewBadge() }
                        else { Text(updates.lastChecked == nil ? L10n.text("Check Now") : L10n.text("Up to Date")).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                // Rows that act in place still read like the rows around them, not like links.
                .tint(.primary)
                .disabled(updates.checking)
                }
                if !updates.currentNotes.isEmpty {
                    Button(action: updates.showCurrentNotes) {
                        HStack(spacing: 8) {
                            FormLabel(symbol: "sparkles", tint: .purple, title: L10n.text("What's New in Version %@", updates.displayVersion))
                                .foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
                FormLink(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
                    .id("settings.end")
            } header: {
                Text(L10n.text("About"))
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    if Updates.channel != .none {
                        if let title = updates.availableTitle { Text(title) }
                        else if let checked = updates.lastChecked { Text(L10n.text("Last checked %@", checked.formatted(date: .abbreviated, time: .shortened))) }
                    }
                    // The page ends on the copyright, centred, as the hero no longer carries it.
                    Text(Brand.copyright).font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 28)
                }
            }
            #else
            Section {
                if updates.available.isEmpty, Updates.channel != .none {
                    LabeledContent {
                        Button { Task { await updates.check(manual: true) } } label: {
                            if updates.checking { ProgressView().controlSize(.small) } else { Text(L10n.text("Check Now")) }
                        }
                        .disabled(updates.checking)
                    } label: {
                        FormLabel(symbol: "checkmark.circle.fill", tint: .green, title: L10n.text("Yingxia is up to date"),
                                  subtitle: updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) })
                    }
                }
                #if os(macOS)
                if let installer = updates.installer {
                    Toggle(isOn: Binding(get: { installer.automaticallyInstalls }, set: { installer.automaticallyInstalls = $0 })) {
                        FormLabel(symbol: "arrow.down.circle.fill", tint: .blue, title: L10n.text("Install Updates Automatically"),
                                  subtitle: L10n.text("Yingxia downloads updates in the background and installs them the next time it quits."))
                    }
                    .settingsSwitch()
                }
                #endif
                if !updates.currentNotes.isEmpty {
                    Button(action: updates.showCurrentNotes) {
                        FormLabel(symbol: "sparkles", tint: .purple, title: L10n.text("What's New in Version %@", updates.displayVersion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.formRowButton()
                }
                FormLink(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
                    .id("settings.end")
            } header: {
                Text(L10n.text("About"))
            } footer: {
                if store.extrasUnlocked { Text(supportNote) }
            }
            #endif
        }.settingsRows() }
        #if DEBUG
        // `-qaScrollBottom 1` opens Settings at its end for screenshots.
        .task {
            guard UserDefaults.standard.bool(forKey: "qaScrollBottom") else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo("settings.end", anchor: .bottom)
        }
        #endif
        }
        .settingsForm(L10n.text("Settings"))
        #if os(iOS)
        .sheet(isPresented: $addingSubscription) { AddSubscriptionSheet() }
        .navigationDestination(isPresented: $showsFeedback) { FeedbackView() }
        #if DEBUG
        // `-qaAddSubscription 1` opens the sheet for screenshots.
        .onAppear { if UserDefaults.standard.bool(forKey: "qaAddSubscription") { addingSubscription = true } }
        #endif
        #endif
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
        .task(id: store.extrasUnlocked) { if store.extrasUnlocked { await ContributorList.shared.check() } }
    }

    @ViewBuilder private var heroSection: some View {
        #if os(iOS)
        // The app on the page's own canvas, not in a card: its icon lit by a glow of itself, the name large, and the
        // version with the update state in one glass chip. A waiting release is the one prominent button.
        Section {
            VStack(spacing: 0) {
                // The row clips what it draws, so the glow stays small enough to fade out inside it.
                AppMark(size: 96)
                    .background { AppMark(size: 96).blur(radius: 22).opacity(0.7).accessibilityHidden(true) }
                    .padding(.top, 36).padding(.bottom, 18)
                Text(L10n.text("Yingxia")).font(.system(size: 32, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    if let version { Text(version) }
                    if updates.availableTitle == nil, Updates.channel != .none, updates.lastChecked != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(L10n.text("Up to Date"))
                    }
                }
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassSurface(.regular, in: Capsule())
                .padding(.top, 10)
                if let title = updates.availableTitle {
                    Button(action: updates.show) {
                        Label(title, systemImage: "gift.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Brand.accent, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 14)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            .listRowBackground(Color.clear)
        }
        #else
        // The app leads, like the account card in Settings; a waiting release sits right under it.
        Section {
            HStack(spacing: 14) {
                AppMark(size: FormMetrics.hero)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Yingxia")).font(.title3.weight(.semibold))
                    if let version { Text(version).font(.subheadline).foregroundStyle(.secondary) }
                    Text(Brand.copyright).font(.caption).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            if let title = updates.availableTitle {
                Button(action: updates.show) {
                    LabeledContent {
                        NewBadge()
                    } label: {
                        FormLabel(symbol: "gift.fill", tint: Brand.cyan, title: title,
                                  subtitle: L10n.text("New features are waiting for you."))
                    }
                }.formRowButton()
            }
        }
        #endif
    }

    private var canAdd: Bool { !store.importing && !store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var danmakuNote: String { SettingsNote.danmaku }
    private var upscaleNote: String { VideoEnhancement.upscaleNote }
    private var smoothNote: String { VideoEnhancement.smoothNote }
    private var tmdbNote: String { SettingsNote.tmdb }
    private var supportNote: String { SettingsNote.support }
    private var errorReportsNote: String { SettingsNote.errorReports }
    private func add() { if canAdd { Task { await store.importSubscription() } } }

    #if os(macOS)
    @ViewBuilder private var subscriptionActions: some View {
        // System Settings style: the actions as buttons at the trailing edge, the default one prominent.
        HStack {
            if !store.subscriptions.isEmpty {
                Button(L10n.text("Refresh All")) { Task { await store.refreshSubscriptions() } }.disabled(store.importing)
            }
            Spacer()
            if store.importing { ProgressView().controlSize(.small); ElapsedTime() }
            Button(L10n.text("Use a Demo URL")) { store.subscriptionAddress = Store.defaultURL }
            Button(store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription")) { add() }
                .buttonStyle(.borderedProminent).disabled(!canAdd)
        }
    }
    #endif
}

#if os(iOS)
/// The hero card's fill: the row colour lit from above by the icon's cyan and indigo.
private struct SettingsHeroGlow: View {
    var body: some View {
        ZStack {
            SettingsStyle.rowFill
            RadialGradient(colors: [Brand.cyan.opacity(0.32), .clear], center: .top, startRadius: 0, endRadius: 230)
            RadialGradient(colors: [Brand.indigo.opacity(0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 260)
        }
    }
}

/// A tile at the top of Settings: a symbol on a grey disc and the way out in the corner, then the title and one line
/// about it. Drawn in the rows' fill and corner, so it reads as part of the same form.
private struct SettingsTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var external = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                Spacer(minLength: 0)
                Image(systemName: external ? "arrow.up.right" : "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.rowFill, in: shape)
        .contentShape(shape)
    }
}

/// Answers the press itself, not the release: a slight sink on a critically damped spring, so a quick tap still shows.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Playback on iPhone and iPad: the player's gestures, danmaku and picture, each note under the group it explains.
struct PlaybackSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    var body: some View {
        SettingsPage(title: L10n.text("Playback"), symbol: "slider.horizontal.below.rectangle") {
            SettingsGroup(footer: L10n.text("Touch and hold the video to play at this speed. Slide sideways to change it, or slide down to keep it after you let go.")) {
                Picker(selection: $holdSpeed) {
                    ForEach(SpeedBoost.startRates, id: \.self) { Text($0.formatted(.number.precision(.fractionLength(0...2))) + "×").tag($0) }
                } label: {
                    FormLabel(symbol: "forward.fill", tint: .orange, title: L10n.text("Touch and Hold Speed"))
                }
            }
            SettingsGroup(footer: L10n.text("Slide up or down on the left of the video to change the brightness, or on the right to change the volume.")) {
                Toggle(isOn: $slidesLevels) {
                    FormLabel(symbol: "sun.max.fill", tint: .yellow, title: L10n.text("Slide for Brightness and Volume"))
                }
                .settingsSwitch()
            }
            SettingsGroup(footer: SettingsNote.playbackInfo) {
                Toggle(isOn: $showsPlaybackInfo) {
                    FormLabel(symbol: "info.circle.fill", tint: .blue, title: L10n.text("Show Video Info"))
                }
                .settingsSwitch()
            }
            if store.extrasUnlocked {
                SettingsGroup(footer: SettingsNote.danmaku) {
                    Toggle(isOn: $showsDanmaku) {
                        FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"))
                    }
                    .settingsSwitch()
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "rectangle.tophalf.inset.filled", tint: .teal, title: L10n.text("Danmaku Area"))
                    }
                }
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                SettingsGroup(title: L10n.text("Picture"), footer: VideoEnhancement.note) {
                    if VideoEnhancement.canUpscale {
                        Toggle(isOn: $upscalesVideo) {
                            FormLabel(symbol: "wand.and.sparkles", tint: .purple, title: L10n.text("Sharper Picture"))
                        }
                        .settingsSwitch()
                    }
                    if VideoEnhancement.canSmooth {
                        Toggle(isOn: $smoothsVideo) {
                            FormLabel(symbol: "film.stack", tint: .indigo, title: L10n.text("Smooth Motion (60 fps)"))
                        }
                        .settingsSwitch()
                    }
                }
            }
        }
    }
}

/// The two switches that send something off the device, each with what it sends.
struct PrivacySettingsView: View {
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    var body: some View {
        SettingsPage(title: L10n.text("Privacy"), symbol: "hand.raised.fill") {
            SettingsGroup(footer: SettingsNote.errorReports) {
                Toggle(isOn: $sendsErrorReports) {
                    FormLabel(symbol: "ladybug.fill", tint: .red, title: L10n.text("Send Error Reports"))
                }
                .settingsSwitch()
                .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
            }
            SettingsGroup(footer: SettingsNote.tmdb) {
                Toggle(isOn: $looksUpTMDB) {
                    FormLabel(symbol: "film.stack.fill", tint: .teal, title: L10n.text("Look Up Titles on TMDB"))
                }
                .settingsSwitch()
            }
        }
    }
}

/// Adding a subscription: the address, a shortcut to the default one, and Add in the toolbar.
/// Closes itself once the import succeeds; a failure stays here under the field.
private struct AddSubscriptionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    private var canAdd: Bool { !store.importing && !store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form { Group {
                Section {
                    TextField(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress, prompt: Text(L10n.text("Subscription URL (TVBox JSON, M3U or TXT)")))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(add)
                    TextField(L10n.text("Name (optional)"), text: $store.subscriptionName, prompt: Text(L10n.text("Name (optional)")))
                        .labelsHidden()
                        .submitLabel(.done)
                        .onSubmit(add)
                } footer: {
                    if let error = store.error { Text(error).foregroundStyle(Brand.amber) }
                    else { Text(L10n.text("Paste the address of a TVBox JSON subscription, an M3U or TXT live playlist, or an AList server.")) }
                }
                // Offered, never filled in or imported on its own.
                Section {
                    Button { store.subscriptionAddress = Store.defaultURL } label: {
                        FormLabel(symbol: "sparkles", tint: Brand.indigo, title: L10n.text("Use a Demo URL"))
                            .foregroundStyle(.primary)
                    }
                }
            }.settingsRows() }
            .settingsForm(L10n.text("Add Subscription"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.importing { ProgressView() }
                    else { Button(L10n.text("Add"), action: add).fontWeight(.semibold).disabled(!canAdd) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { store.error = nil; focused = true }
    }

    private func add() {
        guard canAdd else { return }
        Task {
            await store.importSubscription()
            if store.error == nil { dismiss() }
        }
    }
}
#endif

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct SubscriptionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    var body: some View {
        let current = store.subscriptions.first { $0.address == entry.address } ?? entry
        let index = store.subscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        Form { Group {
            Section {
                Toggle(isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } })) {
                    FormLabel(symbol: "list.bullet.rectangle.fill", tint: current.enabled ? .blue : .gray, title: L10n.text("Use This Subscription"))
                }
                .settingsSwitch()
                .disabled(store.importing)
                LabeledContent(L10n.text("Name")) {
                    // Empty shows the name it would otherwise have.
                    TextField(L10n.text("Name"), text: Binding(get: { current.name }, set: { store.renameSubscription(current, to: $0) }),
                              prompt: Text(SubscriptionEntry(address: current.address).title))
                        .labelsHidden().multilineTextAlignment(.trailing)
                }
                LabeledContent(L10n.text("Subscription URL")) {
                    Text(current.address).lineLimit(2).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } footer: {
                if let failure { Text(L10n.text("Couldn't refresh: %@", failure)) }
                else if let copy { Text(L10n.text("Sources: %lld · Live playlists: %lld", copy.sites.count, copy.lives.count)) }
            }
            if store.subscriptions.count > 1 {
                Section(L10n.text("Order")) {
                    if index > 0 { Button(L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.subscriptions.count - 1 { Button(L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            Section {
                Button(L10n.text("Remove"), role: .destructive) { confirmsRemoval = true }
            }
        }.settingsRows() }
        .settingsForm(current.title)
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Removing many subscriptions at once: tick them, or take all or the switched-off ones, then remove.
private struct RemoveSubscriptionsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmsRemoval = false
    var body: some View {
        let chosen = store.subscriptions.filter { selection.contains($0.address) }
        let all = chosen.count == store.subscriptions.count
        let off = store.subscriptions.filter { !$0.enabled }.map(\.address)
        Form { Group {
            Section {
                Button(L10n.text(all ? "Deselect All" : "Select All")) { selection = all ? [] : Set(store.subscriptions.map(\.address)) }
                if !off.isEmpty { Button(L10n.text("Select Turned-Off Subscriptions")) { selection = Set(off) } }
            }
            Section {
                ForEach(store.subscriptions) { entry in
                    let selected = selection.contains(entry.address)
                    Button {
                        if selected { selection.remove(entry.address) } else { selection.insert(entry.address) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            Text(entry.title).lineLimit(1).foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text(store.subscriptionValue(entry)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .formRowButton()
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            Section {
                Button(L10n.text("Remove %lld Subscriptions", chosen.count), role: .destructive) { confirmsRemoval = true }
                    .disabled(chosen.isEmpty || store.importing)
            }
        }.settingsRows() }
        .settingsForm(L10n.text("Remove Subscriptions"))
        .confirmationDialog(L10n.text("Remove %lld Subscriptions", chosen.count), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscriptions(Set(chosen.map(\.address))); dismiss() }
        }
    }
}

/// Playing a media address directly.
private struct PlayURLView: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    private var empty: Bool { address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        Form { Group {
            Section {
                TextField(L10n.text("HTTP / HTTPS media URL"), text: $address, prompt: Text(L10n.text("HTTP / HTTPS media URL")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit(open)
                #if os(macOS)
                HStack { Spacer(); Button(L10n.text("Open Player"), action: open).buttonStyle(.borderedProminent).disabled(empty) }
                #else
                Button(L10n.text("Open Player"), action: open).disabled(empty)
                #endif
            }
        }.settingsRows() }
        .settingsForm(L10n.text("Play a URL"))
    }
    private func open() {
        guard !empty else { return }
        do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
        catch { store.error = error.localizedDescription }
    }
}
#endif

struct LicensesView: View {
    private var notices: String {
        (Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "DexLoom · MIT License"
    }
    var body: some View {
        #if os(tvOS)
        // Each paragraph is a row the remote can land on, which is how the page scrolls.
        SettingsPage(title: L10n.text("Open Source Licenses"), symbol: "doc.plaintext", subtitle: "Yingxia \(Brand.copyright)") {
            SettingsGroup {
                ForEach(Array(notices.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Button {} label: {
                        // The file is wrapped for a terminal; proportional text reads better reflowed.
                        Text(paragraph.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ParagraphStyle())
                }
            }
        }
        #else
        SettingsPage(title: L10n.text("Open Source Licenses")) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yingxia \(Brand.copyright)").font(.headline)
                    Link("www.getmegaportal.com", destination: Brand.website).font(.subheadline)
                }
            }
            Section {
                Text(notices)
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).selectable()
            }
        }
        #endif
    }
    #if os(tvOS)
    /// A glass row's focus, in a rounded rectangle: a capsule around a tall paragraph looked odd.
    private struct ParagraphStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
        private struct Plate: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var focused
            var body: some View {
                configuration.label
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .glassSurface(focused ? .regular.tint(.white.opacity(0.12)) : .identity, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: focused)
            }
        }
    }
    #endif
}

struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var level = "all"
    @State private var search = ""
    @State private var live = true
    @State private var dropped = 0
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var selected: LogEntry?
    private var filtered: [LogEntry] {
        entries.reversed().filter {
            (level == "all" || $0.level.rawValue == level) &&
            (search.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { heading; Spacer(minLength: 24); actions }
                VStack(alignment: .leading, spacing: 16) { heading; actions }
            }
            VStack(spacing: 0) {
                filters.padding(16)
                Divider()
                logList
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: live ? "circle.fill" : "pause.circle.fill").font(.system(size: live ? 6 : 11)).foregroundStyle(live ? Brand.accent : .secondary)
                    Text(L10n.text(live ? "Newest first · Updates every 2 seconds" : "Updates paused"))
                    Spacer()
                    Text("\(filtered.count) / \(entries.count)").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DiagnosticGrid.inset).padding(.vertical, 12)
            }
            .background(SettingsStyle.groupFill, in: RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            Text(L10n.text("Shows the latest 1,000 events from this run. Export includes retained log files."))
                .font(.caption).foregroundStyle(.secondary)
            if dropped > 0 {
                Label(L10n.text("Log overload: %lld events dropped", dropped), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.amber)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Brand.rose).selectable() }
        }
        .padding(Layout.gutter)
        .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackdrop()
        .screenTitle(L10n.text("Diagnostic Logs"))
        .sheet(item: $selected) { entry in DiagnosticDetail(entry: entry) }
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                if live { await refresh() }
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if !os(tvOS)
            Text(L10n.text("Runtime Activity")).font(.title2.weight(.bold))
            #endif
            Text(L10n.text("Inspect plugin requests and errors.")).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }.controlSize(.regular)
    }
    @ViewBuilder private var actionButtons: some View {
            Button { live.toggle() } label: {
                Label(L10n.text(live ? "Pause Logs" : "Resume Logs"), systemImage: live ? "pause.fill" : "play.fill")
            }.controlButton()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }.controlButton().accessibilityLabel(L10n.text("Refresh Logs")).help(L10n.text("Refresh Logs"))
            Menu {
                Button { export() } label: { Label(L10n.text("Export Logs"), systemImage: "square.and.arrow.up") }.disabled(exporting)
                #if os(macOS)
                Button { NSWorkspace.shared.open(Diagnostics.shared.directory) } label: {
                    Label(L10n.text("Open Log Folder"), systemImage: "folder")
                }
                #endif
                #if !os(tvOS)
                if let exportURL { ShareLink(item: exportURL) { Label(L10n.text("Share Logs"), systemImage: "square.and.arrow.up") } }
                #endif
            } label: {
                Label(L10n.text(exporting ? "Exporting Logs…" : "Log Files"), systemImage: "doc.text")
            }.controlButton()
    }
    private var filters: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search Logs"), text: $search).textFieldStyle(.plain).autocorrectionDisabled()
                if !search.isEmpty {
                    let clear = Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.text("Clear Search"))
                    #if os(tvOS)
                    clear.glassPill()
                    #else
                    clear.buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            ChipRow {
                HStack(spacing: 6) {
                    levelButton("all", title: L10n.text("All Logs"), count: entries.count, color: Brand.accent)
                    ForEach(LogLevel.allCases, id: \.rawValue) { item in
                        levelButton(item.rawValue, title: item.title, count: entries.filter { $0.level == item }.count, color: item.tint)
                    }
                }
            }
        }
    }
    @ViewBuilder private func levelButton(_ value: String, title: String, count: Int, color: Color) -> some View {
        #if os(tvOS)
        // The glass chips of every other filter on the TV, with the level's dot and its count.
        Chip(title: "\(title) \(count)", selected: level == value, dot: value == "all" ? nil : color) { level = value }
        #else
        Button { level = value } label: {
            HStack(spacing: 7) {
                if value != "all" { Circle().fill(color).frame(width: 5, height: 5) }
                Text(title).fontWeight(.semibold)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 26, alignment: .trailing)
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(level == value ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(level == value ? color.opacity(0.35) : .clear, lineWidth: 1) }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(level == value ? .isSelected : [])
        #endif
    }
    private var logList: some View {
        let visible = filtered
        return GeometryReader { geometry in
            #if os(tvOS)
            let compact = true
            #else
            let compact = geometry.size.width < DiagnosticGrid.compactWidth
            #endif
            VStack(spacing: 0) {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        Text(L10n.text("Log Time")).frame(width: DiagnosticGrid.time, alignment: .leading)
                        Text(L10n.text("Log Level")).frame(width: DiagnosticGrid.level, alignment: .leading)
                        Text(L10n.text("Log Module")).frame(width: DiagnosticGrid.module, alignment: .leading)
                        Text(L10n.text("Log Message")).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: DiagnosticGrid.accessory, height: 1)
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, DiagnosticGrid.inset).frame(height: 36)
                    .background(Color.primary.opacity(0.025))
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            Button { selected = entry } label: { DiagnosticRow(entry: entry, compact: compact).foregroundStyle(.primary) }
                                .glassRow()
                            Divider().padding(.horizontal, DiagnosticGrid.inset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.text("No Logs"), systemImage: "waveform.path")
                        } description: {
                            Text(L10n.text(search.isEmpty && level == "all" ? "Plugin activity will appear here." : "Try another level or search term."))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportURL = try await Diagnostics.shared.export()
                #if os(macOS)
                if let exportURL { NSWorkspace.shared.activateFileViewerSelecting([exportURL]) }
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }
    private func refresh() async {
        let snapshot = await Diagnostics.shared.snapshot()
        if entries.last?.id != snapshot.entries.last?.id { entries = snapshot.entries }
        dropped = snapshot.dropped
        error = snapshot.fileError
    }
}

private extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: .secondary
        case .info: Brand.accent
        case .warning: Brand.amber
        case .error: Brand.rose
        }
    }
    var title: String {
        switch self {
        case .debug: L10n.text("Debug Logs")
        case .info: L10n.text("Info Logs")
        case .warning: L10n.text("Warning Logs")
        case .error: L10n.text("Error Logs")
        }
    }
}

// One grid for the header and every row. Content never selects its own layout.
private enum DiagnosticGrid {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 12
    static let time: CGFloat = 76
    static let level: CGFloat = 76
    static let module: CGFloat = 112
    static let accessory: CGFloat = 12
    static let compactWidth: CGFloat = 620
}

private struct DiagnosticRow: View {
    let entry: LogEntry
    let compact: Bool
    @State private var hovering = false
    var body: some View {
        Group {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    Text(entry.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(entry.level.rawValue.uppercased()).foregroundStyle(entry.level.tint)
                    Text(entry.category)
                }.font(.caption).foregroundStyle(.secondary)
                Text(entry.message).font(.body).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(.vertical, 18)
            #else
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                        timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                        badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                        module
                        Spacer(minLength: 0)
                    }
                    message.lineLimit(2, reservesSpace: true)
                }
                .padding(.vertical, 12)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DiagnosticGrid.gap) {
                    timestamp.frame(width: DiagnosticGrid.time, alignment: .leading)
                    badge.frame(width: DiagnosticGrid.level, alignment: .leading)
                    module.frame(width: DiagnosticGrid.module, alignment: .leading)
                    message.lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: DiagnosticGrid.accessory)
                }
                .frame(height: 44)
            }
            #endif
        }
        .padding(.horizontal, DiagnosticGrid.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        #if !os(tvOS)
        .onHover { hovering = $0 }
        #endif
    }
    private var timestamp: some View {
        Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .lineLimit(1)
    }
    private var badge: some View {
        Text(entry.level.rawValue.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(entry.level.tint).frame(width: 60, height: 20)
            .background(entry.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
    private var module: some View {
        Text(entry.category).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var message: some View {
        let preview = entry.message.split(whereSeparator: \.isWhitespace).filter {
            !$0.hasPrefix("session=") && !$0.hasPrefix("request=") && !$0.hasPrefix("command=")
        }.joined(separator: " ")
        return Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.88))
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticDetail: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Pill(text: entry.level.title, tint: entry.level.tint)
                Text(entry.category).font(.headline)
                Spacer()
                Button(L10n.text("OK")) { dismiss() }.controlButton()
            }
            Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(entry.message).font(.system(.body, design: .monospaced)).selectable()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.contentPanel(cornerRadius: 14)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 720, minHeight: 360, idealHeight: 480)
        #elseif os(tvOS)
        .frame(width: 1100, height: 700)
        #endif
        .screenBackdrop()
    }
}

#if os(tvOS)
// MARK: Settings on Apple TV
// Laid out like the system's own Settings: the app on the left, a list on the right. Every row is
// one press of the remote: its current value sits at the trailing edge, a switch flips in place,
// and anything that needs typing or choosing opens a page of its own.

struct TVSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @State private var cloudSummary = ""
    @State private var bilibiliSummary = ""
    @State private var douyinSummary = ""
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(BilibiliCastController.key) private var receivesCasts = true
    @AppStorage(PlayOnController.key) private var receivesPlayOn = true
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    @AppStorage(ErrorReports.key) private var sendsErrorReports = true
    @AppStorage(TMDBMatch.key) private var looksUpTMDB = true
    @AppStorage(CloudSync.enabledKey) private var syncsWithICloud = true

    var body: some View {
        TVSettingsLayout {
            TVSettingsHero()
        } list: {
            if !updates.available.isEmpty { updateSection }
            // First in the list, beside the app: a problem or an idea is one press away.
            TVSettingsSection {
                TVSettingsLink(title: L10n.text("Send Feedback")) { FeedbackView() }
                TVSettingsLink(title: L10n.text("Telegram Group")) { TelegramGroupView() }
            }
            subscriptionSection
            TVSettingsSection(title: L10n.text("Accounts")) {
                if store.extrasUnlocked {
                    TVSettingsLink(title: L10n.text("Bilibili"), value: bilibiliSummary) { BilibiliAccountView() }
                    TVSettingsLink(title: L10n.text("Douyin"), value: douyinSummary) { DouyinAccountView() }
                }
                TVSettingsLink(title: L10n.text("Cloud Drive Accounts"), value: cloudSummary) { CloudDriveView() }
            }
            TVSettingsSection(footer: L10n.text("Keeps favorites, Continue Watching, subscriptions, and the sources you pinned, hid or ordered the same on your devices signed in to the same iCloud account. Accounts, passwords and downloads stay on each device.")) {
                TVSettingsToggle(title: L10n.text("iCloud Sync"), isOn: $syncsWithICloud)
                    .onChange(of: syncsWithICloud) { _, on in store.cloudSync?.setEnabled(on) }
            }
            TVSettingsSection {
                TVSettingsLink(title: L10n.text("Watch Now")) { WatchNowSettingsView() }
            }
            TVSettingsSection(title: L10n.text("Playback"), footer: playbackFooter) {
                if store.extrasUnlocked {
                    TVSettingsToggle(title: L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                    TVSettingsAction(title: L10n.text("Danmaku Area"), value: danmakuArea.title) { danmakuArea = danmakuArea.next }
                    TVSettingsToggle(title: L10n.text("Cast from the Bilibili App"), isOn: $receivesCasts)
                        .onChange(of: receivesCasts) { _, on in
                            if on { BilibiliCastController.shared.start(store) } else { BilibiliCastController.shared.stop() }
                        }
                }
                TVSettingsToggle(title: L10n.text("Play from Other Devices"), isOn: $receivesPlayOn)
                    .onChange(of: receivesPlayOn) { _, on in
                        if on { PlayOnController.shared.start(store) } else { PlayOnController.shared.stop() }
                    }
                TVSettingsLink(title: L10n.text("Play a URL")) { TVPlayURLPage() }
            }
            TVSettingsSection(footer: L10n.text("Shows the video's format, resolution, frame rate and bitrate in a corner of the player.")) {
                TVSettingsToggle(title: L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                TVSettingsSection(title: L10n.text("Picture"), footer: VideoEnhancement.note) {
                    if VideoEnhancement.canUpscale { TVSettingsToggle(title: L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
                    if VideoEnhancement.canSmooth { TVSettingsToggle(title: L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
                }
            }
            TVSettingsSection(title: L10n.text("Advanced"),
                              footer: L10n.text("Sends errors to the developer a few times a day so they can be fixed: the error text with web addresses cut to the server name, the app and system versions, and a random ID. Never your accounts, passwords or viewing history.")) {
                TVSettingsLink(title: L10n.text("Local Cache")) { CacheSettingsView() }
                if store.extrasUnlocked { TVSettingsLink(title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() } }
                TVSettingsLink(title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
                TVSettingsToggle(title: L10n.text("Send Error Reports"), isOn: $sendsErrorReports)
                    .onChange(of: sendsErrorReports) { _, on in if !on { ErrorReports.shared.discard() } }
                TVSettingsToggle(title: L10n.text("Look Up Titles on TMDB"), isOn: $looksUpTMDB)
            }
            if updates.available.isEmpty, Updates.channel != .none { updateSection }
            if store.extrasUnlocked { ContributorsSection() }
            TVSettingsSection(title: L10n.text("About"),
                              footer: store.extrasUnlocked ? L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.") : nil) {
                TVSettingsLink(title: L10n.text("Open Source Licenses")) { LicensesView() }
            }
        }
        .tabTitle(L10n.text("Settings"))
        // Refreshed whenever Settings reappears, so a sign-in on the account page shows here.
        .onAppear { bilibiliSummary = BilibiliAccount.load().summary; douyinSummary = DouyinAccount.load().summary; cloudSummary = CloudProvider.summary() }
        .task(id: store.extrasUnlocked) { if store.extrasUnlocked { await ContributorList.shared.check() } }
    }

    private var playbackFooter: String {
        let phones = L10n.text("With Yingxia open here, your other devices on the same network can send it what they play: tap Play On in their player.")
        guard store.extrasUnlocked else { return phones }
        return L10n.text("With your phone on the same network, tap the TV button in a Bilibili video and choose %@.", L10n.text("Yingxia")) + "\n" + phones
    }

    private var subscriptionSection: some View {
        TVSettingsSection(title: L10n.text("Subscriptions"), footer: store.notice) {
            ForEach(store.subscriptions) { entry in
                let failed = store.subscriptionErrors[entry.address] != nil
                TVSettingsLink(title: entry.title, value: store.subscriptionValue(entry), warning: failed) { TVSubscriptionPage(entry: entry) }
            }
            TVSettingsLink(title: L10n.text("Add Subscription")) { TVAddSubscriptionPage() }
            if store.subscriptions.count > 1 { TVSettingsLink(title: L10n.text("Remove Subscriptions")) { TVRemoveSubscriptionsPage() } }
            if !store.subscriptions.isEmpty {
                TVSettingsAction(title: L10n.text("Refresh All"),
                                 value: store.importing ? L10n.text("Importing…") : store.subscription.map { $0.importedAt.formatted(date: .abbreviated, time: .shortened) },
                                 busy: store.importing) { Task { await store.refreshSubscriptions() } }
                    .disabled(store.importing)
            }
        }
    }

    private var updateSection: some View {
        TVSettingsSection(title: L10n.text("Software Update")) {
            if let title = updates.availableTitle {
                Button(action: updates.show) {
                    TVSettingsRowLabel(title: title, chevron: true) { NewBadge() }
                }.glassRow()
            } else {
                TVSettingsAction(title: L10n.text("Check Now"),
                                 value: updates.checking ? L10n.text("Checking…") : updates.lastChecked.map { L10n.text("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) },
                                 busy: updates.checking) { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
            }
            if !updates.currentNotes.isEmpty {
                Button(action: updates.showCurrentNotes) {
                    TVSettingsRowLabel(title: L10n.text("What's New in Version %@", updates.displayVersion), chevron: true)
                }.glassRow()
            }
        }
    }
}

/// The page frame: a hero column on the left, vertically centred, and the scrolling list on the right.
struct TVSettingsLayout<Hero: View, List: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var list: List
    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            hero.frame(width: 560).frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 48) { list }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassRowInsets()
                    .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
        .padding(.horizontal, Layout.gutter)
        .screenBackdrop()
    }
}

/// The app as the left column of Settings: its icon, name, version and credit.
private struct TVSettingsHero: View {
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : L10n.text("Version %@", $0) }
    }
    var body: some View {
        VStack(spacing: 34) {
            AppMark(size: 300)
            VStack(spacing: 10) {
                Text(L10n.text("Yingxia")).font(.system(size: 48, weight: .bold))
                if let version { Text(version).font(.system(size: 26)).foregroundStyle(.secondary) }
                Text(Brand.copyright).font(.system(size: 22)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A titled run of rows with an optional note under it.
struct TVSettingsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer).font(.system(size: 22)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 8)
            }
        }
    }
}

/// The title on the leading edge; the current value, an accessory and a chevron on the trailing one.
struct TVSettingsRowLabel<Accessory: View>: View {
    let title: String
    /// A line under the title, saying what the row is about.
    var detail: String? = nil
    var value: String? = nil
    var warning = false
    var busy = false
    var chevron = false
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 29, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .layoutPriority(1)
            Spacer(minLength: 32)
            if busy { ProgressView() }
            if let value, !value.isEmpty {
                Text(value).font(.system(size: 27)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
            }
            accessory
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension TVSettingsRowLabel where Accessory == EmptyView {
    init(title: String, detail: String? = nil, value: String? = nil, warning: Bool = false, busy: Bool = false, chevron: Bool = false) {
        self.init(title: title, detail: detail, value: value, warning: warning, busy: busy, chevron: chevron) { EmptyView() }
    }
}

/// A row that opens a page.
struct TVSettingsLink<Destination: View>: View {
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) { TVSettingsRowLabel(title: title, value: value, warning: warning, chevron: true) }
            .glassRow()
    }
}

/// A switch as a row: selecting it flips the value shown at the trailing edge.
struct TVSettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: { TVSettingsRowLabel(title: title, detail: detail, value: L10n.text(isOn ? "On" : "Off")) }
            .glassRow()
            .accessibilityValue(L10n.text(isOn ? "On" : "Off"))
    }
}

/// A row that does something in place.
struct TVSettingsAction: View {
    let title: String
    var value: String? = nil
    var busy = false
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TVSettingsRowLabel(title: title, value: value, busy: busy).foregroundStyle(destructive ? Brand.rose : Color.primary)
        }
        .glassRow()
    }
}

/// Text entry as a row: the title and the current text, like any other row. A focused tvOS text
/// field always draws the system's white platter, which sat inside the glass row as a box in a box,
/// so selecting the row opens the system's text entry instead, as Wi-Fi passwords do.
struct TVSettingsField: View {
    let title: String
    @Binding var text: String
    /// Words rather than an address: the usual keyboard, with capitals and corrections.
    var prose = false
    @State private var editing = false
    @State private var draft = ""
    @State private var cancelled = false
    var body: some View {
        Button { draft = text; cancelled = false; editing = true } label: {
            TVSettingsRowLabel(title: title, value: text.isEmpty ? L10n.text("Not set") : text)
        }
        .glassRow()
        .alert(title, isPresented: $editing) {
            TextField(title, text: $draft)
                .autocorrectionDisabled(!prose)
                .textInputAutocapitalization(prose ? .sentences : .never).keyboardType(prose ? .default : .URL)
            Button(L10n.text("Done")) {}
            Button(L10n.text("Cancel"), role: .cancel) { cancelled = true }
        }
        // Closing the alert any way but Cancel keeps the text. tvOS 18 also shows the text field as a second
        // button under it, which closes the alert without running any action, so a typed address was lost (#291).
        .onChange(of: editing) { _, open in
            if !open, !cancelled { text = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// A page under Settings: a large symbol and title on the left, its rows on the right.
struct TVSettingsSubpage<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        TVSettingsLayout {
            VStack(spacing: 30) {
                Image(systemName: symbol).font(.system(size: 120, weight: .regular)).foregroundStyle(.secondary)
                    .frame(height: 180)
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 44, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } list: { content }
        .screenTitle("")
    }
}

/// One subscription: switch it on or off, move it (earlier subscriptions win duplicate sources), or remove it.
private struct TVSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: SubscriptionEntry
    @State private var confirmsRemoval = false
    var body: some View {
        let current = store.subscriptions.first { $0.address == entry.address } ?? entry
        let index = store.subscriptions.firstIndex { $0.address == entry.address } ?? 0
        let failure = store.subscriptionErrors[entry.address]
        let copy = store.documents[entry.address]
        TVSettingsSubpage(symbol: "list.bullet.rectangle", title: current.title, subtitle: current.address) {
            TVSettingsSection(title: L10n.text("Subscription"),
                              footer: failure.map { L10n.text("Couldn't refresh: %@", $0) }
                                ?? copy.map { L10n.text("Sources: %lld · Live playlists: %lld", $0.sites.count, $0.lives.count) }) {
                TVSettingsToggle(title: L10n.text("Use This Subscription"),
                                 isOn: Binding(get: { current.enabled }, set: { on in Task { await store.setSubscription(current, enabled: on) } }))
                    .disabled(store.importing)
                TVSettingsField(title: L10n.text("Name"), text: Binding(get: { current.name }, set: { store.renameSubscription(current, to: $0) }))
            }
            if store.subscriptions.count > 1 {
                TVSettingsSection(title: L10n.text("Order")) {
                    if index > 0 { TVSettingsAction(title: L10n.text("Move Up")) { store.moveSubscription(current, by: -1) } }
                    if index < store.subscriptions.count - 1 { TVSettingsAction(title: L10n.text("Move Down")) { store.moveSubscription(current, by: 1) } }
                }
            }
            TVSettingsSection(title: L10n.text("Remove")) {
                TVSettingsAction(title: L10n.text("Remove"), destructive: true) { confirmsRemoval = true }
            }
        }
        .confirmationDialog(L10n.text("Remove"), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscription(current); dismiss() }
        }
    }
}

/// Removing many subscriptions at once: tick them, or take all or the switched-off ones, then remove.
private struct TVRemoveSubscriptionsPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmsRemoval = false
    var body: some View {
        let chosen = store.subscriptions.filter { selection.contains($0.address) }
        let all = chosen.count == store.subscriptions.count
        let off = store.subscriptions.filter { !$0.enabled }.map(\.address)
        TVSettingsSubpage(symbol: "trash", title: L10n.text("Remove Subscriptions")) {
            TVSettingsSection {
                TVSettingsAction(title: L10n.text(all ? "Deselect All" : "Select All")) { selection = all ? [] : Set(store.subscriptions.map(\.address)) }
                if !off.isEmpty { TVSettingsAction(title: L10n.text("Select Turned-Off Subscriptions")) { selection = Set(off) } }
            }
            TVSettingsSection(title: L10n.text("Subscriptions")) {
                ForEach(store.subscriptions) { entry in
                    let selected = selection.contains(entry.address)
                    Button {
                        if selected { selection.remove(entry.address) } else { selection.insert(entry.address) }
                    } label: {
                        TVSettingsRowLabel(title: entry.title, value: store.subscriptionValue(entry)) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                        }
                    }
                    .glassRow()
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            TVSettingsSection {
                TVSettingsAction(title: L10n.text("Remove %lld Subscriptions", chosen.count), destructive: true) { confirmsRemoval = true }
                    .disabled(chosen.isEmpty || store.importing)
            }
        }
        .confirmationDialog(L10n.text("Remove %lld Subscriptions", chosen.count), isPresented: $confirmsRemoval) {
            Button(L10n.text("Remove"), role: .destructive) { store.removeSubscriptions(Set(chosen.map(\.address))); dismiss() }
        }
    }
}

/// Adding a subscription: the address, then add it or fill in the default one.
private struct TVAddSubscriptionPage: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var store = store
        let empty = store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        TVSettingsSubpage(symbol: "plus.rectangle.on.rectangle", title: L10n.text("Add Subscription")) {
            TVSettingsSection(title: L10n.text("Subscription"), footer: store.error ?? store.notice) {
                TVSettingsField(title: L10n.text("Subscription URL (TVBox JSON, M3U or TXT)"), text: $store.subscriptionAddress)
                TVSettingsField(title: L10n.text("Name (optional)"), text: $store.subscriptionName)
                TVSettingsAction(title: store.importing ? L10n.text("Importing…") : L10n.text("Add Subscription"), busy: store.importing) {
                    Task {
                        let before = store.subscriptions.count
                        await store.importSubscription()
                        if store.error == nil, store.subscriptions.count > before { dismiss() }
                    }
                }
                .disabled(store.importing || empty)
                TVSettingsAction(title: L10n.text("Use a Demo URL")) { store.subscriptionAddress = Store.defaultURL }
            }
        }
    }
}

/// Playing a media address directly.
private struct TVPlayURLPage: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    var body: some View {
        TVSettingsSubpage(symbol: "play.rectangle", title: L10n.text("Play a URL")) {
            TVSettingsSection(title: L10n.text("Playback")) {
                TVSettingsField(title: L10n.text("HTTP / HTTPS media URL"), text: $address)
                TVSettingsAction(title: L10n.text("Open Player")) {
                    do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(address)) }
                    catch { store.error = error.localizedDescription }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
#endif

// MARK: Contributors

/// The last 30 days' contributors that Settings lists, kept between launches and asked for at most every six hours.
@MainActor @Observable final class ContributorList {
    static let shared = ContributorList()
    /// At most this many rows; the list is ranked, so the rest have the fewest commits.
    static let shown = 20
    private(set) var people: [Contributor]
    private var checking = false
    private let defaults: UserDefaults
    private static let interval: TimeInterval = 6 * 60 * 60
    private enum Keys { static let people = "contributors.people", checked = "contributors.checked" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        people = defaults.data(forKey: Keys.people).flatMap { try? JSONDecoder().decode([Contributor].self, from: $0) } ?? []
    }

    /// A failed check keeps the last list and tries again the next time Settings opens.
    func check() async {
        guard !checking else { return }
        if let checked = defaults.object(forKey: Keys.checked) as? Date, Date().timeIntervalSince(checked) < Self.interval { return }
        checking = true
        defer { checking = false }
        // Its own task: Settings restarts its task when it unlocks, and that mustn't cancel the request halfway.
        let fetch = Task { try await Contributors.fetch() }
        do {
            people = try await fetch.value.contributors
            defaults.set(try? JSONEncoder().encode(people), forKey: Keys.people)
            defaults.set(Date(), forKey: Keys.checked)
        } catch {
            Diagnostics.shared.record(.warning, "contributors", "Contributor list check failed: \(error.localizedDescription)")
        }
    }

    static func commits(_ count: Int) -> String { count == 1 ? L10n.text("1 commit") : L10n.text("%lld commits", count) }
}

/// A contributor's GitHub picture in a circle, or their initial while it loads or when it can't.
private struct ContributorAvatar: View {
    let person: Contributor
    let size: CGFloat
    var body: some View {
        AsyncImage(url: person.avatar(points: Int(size.rounded(.up)))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(person.login.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
}

#if os(tvOS)
/// Everyone with commits in the last 30 days, most first. Apple TV can't open their GitHub pages, so the rows only show them.
struct ContributorsSection: View {
    private var list: ContributorList { .shared }
    var body: some View {
        if !list.people.isEmpty {
            TVSettingsSection(title: L10n.text("Contributors"), footer: L10n.text("Ranked by commits in the last 30 days.")) {
                ForEach(list.people.prefix(ContributorList.shown)) { person in
                    HStack(spacing: 18) {
                        ContributorAvatar(person: person, size: 52)
                        Text(person.login).font(.system(size: 29, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 32)
                        Text(ContributorList.commits(person.commits)).font(.system(size: 27)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // The insets of a `glassRow()`, so these line up with the rows that can be selected.
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
#else
/// Everyone with commits in the last 30 days, most first; a row opens the person's GitHub page.
struct ContributorsSection: View {
    @Environment(\.openURL) private var openURL
    private var list: ContributorList { .shared }
    var body: some View {
        if !list.people.isEmpty {
            Section {
                ForEach(list.people.prefix(ContributorList.shown)) { person in
                    Button { if let profile = person.profile { openURL(profile) } } label: {
                        HStack(spacing: 8) {
                            Label { Text(person.login).lineLimit(1) } icon: { ContributorAvatar(person: person, size: FormMetrics.icon) }
                                .foregroundStyle(.primary).layoutPriority(1)
                            Spacer(minLength: 0)
                            Text(ContributorList.commits(person.commits)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tint(.primary)
                    .formRowButton()
                }
            } header: {
                Text(L10n.text("Contributors"))
            } footer: {
                Text(L10n.text("Ranked by commits in the last 30 days."))
            }
        }
    }
}
#endif
