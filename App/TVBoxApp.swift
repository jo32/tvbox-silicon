import SwiftUI
import TVCore

@main struct TVBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var store = Store.shared
    #else
    @State private var store = Store()
    #endif
    @State private var updates = Updates()
    @State private var announcements = Announcements()
    #if os(iOS)
    /// An Apple TV's Douyin code, scanned with the Camera.
    @State private var douyinHandoff: DouyinHandoff.Link?
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(iOS) || os(macOS)
    /// A link that asks to add a subscription, waiting for the viewer to agree (#167). Apple TV opens no links.
    @State private var subscriptionLink: SubscriptionImportLink?
    /// A live plugin source link (`yingxia://install-source`), opened in Live Plugins.
    @State private var pluginSourceLink: LivePluginSourceLink?
    #endif
    init() {
        #if os(macOS)
        // Use thin overlay scrollers app-wide. With "Show scroll bars: Always" or a mouse attached,
        // AppKit otherwise draws wide legacy scrollers that crowd poster grids and the episode rail.
        // The app's own defaults domain takes precedence over the global setting.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
        #if os(iOS)
        _ = MusicRemoteControl.shared
        DownloadsLifecycle.install()
        #endif
        SubtitleTranslationSetup.install()
    }
    var body: some Scene {
        WindowGroup {
            // Store, Updates and Announcements go in last, below: sheets attached here show outside RootView.
            RootView()
                #if !os(tvOS)
                // tvOS draws plain buttons and section links in the tint, so it keeps the neutral default.
                .tint(Brand.accent)
                #endif
                .task { Diagnostics.shared.record(.info, "app", "Application scene opened") }
                .task { await ErrorReports.shared.start() }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil || QALaunch.page != nil { await QALaunch.start(store); return }
                    #endif
                    await store.restoreSubscription()
                    // After the saved subscriptions load, so the ones another device added load beside them.
                    store.cloudSync?.start()
                }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil, UserDefaults.standard.string(forKey: "qaReleaseFeed") == nil { return }
                    #endif
                    // Builds before 1.1 recorded no version, so earlier use shows as a saved subscription.
                    await updates.launched(returning: UserDefaults.standard.string(forKey: "subscriptionAddress") != nil)
                }
                .task {
                    #if DEBUG
                    if QALaunch.section != nil, UserDefaults.standard.string(forKey: "qaMessageFeed") == nil { return }
                    #endif
                    await announcements.check()
                }
                #if os(tvOS) || os(macOS)
                .task { BilibiliCastController.shared.start(store) }
                .onChange(of: store.extrasUnlocked) { _, unlocked in if unlocked { BilibiliCastController.shared.start(store) } }
                #endif
                #if os(tvOS) || os(macOS)
                .task { PlayOnController.shared.start(store) }
                #endif
                #if os(macOS)
                // The Dock icon picked in Settings › App Icon; the bundle's own shows until here.
                .task { AppIcons.shared.apply() }
                #endif
                #if os(iOS)
                // Both links carry the app's one scheme, and only the action's host tells them apart.
                .onOpenURL { url in
                    if let link = DouyinHandoff.Link(url) { douyinHandoff = link }
                    else if let link = SubscriptionImportLink(url) { subscriptionLink = link }
                    else if let link = LivePluginSourceLink(url), store.extrasUnlocked { pluginSourceLink = link }
                }
                .sheet(item: $pluginSourceLink) { link in LivePluginSourceSheet(link: link).environment(store) }
                .sheet(item: $douyinHandoff) { DouyinHandoffView(link: $0) }
                .sheet(item: $subscriptionLink) { SubscriptionImportView(link: $0) }
                #elseif os(macOS)
                .onOpenURL { url in
                    if let link = SubscriptionImportLink(url) { subscriptionLink = link }
                    else if let link = LivePluginSourceLink(url), store.extrasUnlocked { pluginSourceLink = link }
                }
                .sheet(item: $pluginSourceLink) { link in LivePluginSourceSheet(link: link).environment(store) }
                .sheet(item: $subscriptionLink) { SubscriptionImportView(link: $0) }
                // Without this, every link opened a second main window, and the sheet showed in both.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
                // A launch that ends while active, without passing through here, crashed or was ended.
                .onChange(of: scenePhase, initial: true) { _, phase in ErrorReports.shared.onScreen(phase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        Task { _ = await Diagnostics.shared.snapshot(); ErrorReports.shared.save() }
                        store.cloudSync?.flushPending()
                    }
                    if phase == .active {
                        Task { await ErrorReports.shared.sendIfDue() }
                        // Another viewer may have taken over the Apple TV: ask iCloud for what changed (#584).
                        store.cloudSync?.refresh()
                    }
                    #if os(tvOS) || os(macOS)
                    // Phones only see the TV while the app is open.
                    if phase == .background { BilibiliCastController.shared.stop() }
                    if phase == .active { BilibiliCastController.shared.start(store) }
                    #endif
                    #if os(tvOS)
                    // As for Bilibili casts: other devices only see the TV while the app is open.
                    if phase == .background { PlayOnController.shared.stop() }
                    if phase == .active { PlayOnController.shared.start(store) }
                    #endif
                    #if !os(macOS)
                    if phase == .background { DownloadsLifecycle.enteredBackground() }
                    if phase == .active { DownloadsLifecycle.becameActive() }
                    #endif
                    // Apple TV and Mac sessions run for days; look again when the app comes back.
                    if phase == .active { Task { await updates.check(); await announcements.check() } }
                }
                #if os(tvOS)
                .preferredColorScheme(.dark)
                #endif
                #if os(macOS)
                .frame(minWidth: 920, minHeight: 640)
                #endif
                // Outside every modifier above, so the import and Douyin sheets get them too: on RootView alone, a
                // yingxia://import link stopped the app ("No Observable object of type Store found", TestFlight 49-51).
                .environment(store).environment(updates).environment(announcements)
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                if Updates.channel != .none {
                    Button(L10n.text("Check for Updates…")) { Task { await updates.check(manual: true) } }
                        .disabled(updates.checking)
                }
            }
        }
        #endif
        #if os(macOS)
        // The music mini player, floating over other apps at the bottom right; also in the Window menu.
        Window(L10n.text("Mini Player"), id: MusicMacMiniPlayer.windowID) {
            MusicMacMiniPlayer().environment(store).tint(Brand.accent)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            let size = content.sizeThatFits(.unspecified)
            let screen = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20), size: size)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The player's rotate button narrows this to landscape (see PlayerOrientation).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerOrientation.mask }
    }
}
#endif

#if !os(tvOS)
/// What a `yingxia://import?url=` link opens: the subscription it names, and the viewer's agreement. A page
/// can point at a subscription, but nothing is downloaded before Add (#167).
#if os(iOS) || os(macOS)
/// Live Plugins in a sheet, adding the linked source.
struct LivePluginSourceSheet: View {
    let link: LivePluginSourceLink
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            LivePluginsView(initialSource: link.source)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}
#endif

struct SubscriptionImportView: View {
    let link: SubscriptionImportLink
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var failure: String?
    /// What the import added, shown before the sheet closes: a directory's subscriptions arrive switched off.
    @State private var added: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 40)).foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
                Text(L10n.text("Add This Subscription?"))
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    field(L10n.text("Subscription URL"), link.address.absoluteString)
                    if let name = link.name { field(L10n.text("Name"), name) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentPanel(cornerRadius: 16)
                Text(L10n.text("A page can only ask: Yingxia adds this subscription after you agree, never on its own."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.amber)
                }
                if let added {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { Backdrop() }
            .navigationTitle(L10n.text("Subscription"))
            .toolbar {
                if added == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if added != nil { Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold) }
                    // Settings may be importing already, and the store takes one import at a time.
                    else if adding || store.importing { ProgressView() }
                    else { Button(L10n.text("Add"), action: add).fontWeight(.semibold) }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func add() {
        adding = true; failure = nil
        Task {
            await store.importSubscription(address: link.address.absoluteString, name: link.name)
            adding = false
            // Settings shows these too; here they say what did or did not arrive.
            if let error = store.importError { failure = error } else { added = store.notice ?? L10n.text("Done") }
        }
    }
}
#endif
