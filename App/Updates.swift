import SwiftUI
import CoreImage.CIFilterBuiltins
import TVCore

/// Tells people when a new version is out and, after they update, what it brings.
/// Reads the release feed the website publishes; the bundled copy covers offline launches.
@MainActor @Observable final class Updates {
    enum Sheet: Identifiable {
        /// Newer releases to install, newest first.
        case available([ReleaseFeed.Release])
        /// Releases installed since the last launch, newest first.
        case whatsNew([ReleaseFeed.Release])
        var id: String {
            switch self {
            case .available(let releases): "available-" + (releases.first?.version ?? "")
            case .whatsNew(let releases): "new-" + (releases.first?.version ?? "")
            }
        }
    }

    /// The version this build carries, e.g. "1.0.1".
    let current: String
    /// Newer releases for this platform, newest first. Drives the "New" badges.
    /// The release feed points at direct downloads; the App Store updates its own builds.
    var available: [ReleaseFeed.Release] { Distribution.isAppStore ? [] : feed.updates(after: current) }
    var sheet: Sheet?
    /// Result of a check someone asked for.
    var message: String?
    #if os(macOS)
    /// Installs Mac updates in place and relaunches; nil where Get the Update opens the download instead.
    let installer = MacUpdater.make()
    #endif
    private(set) var checking = false
    private(set) var lastChecked: Date?
    private var feed: ReleaseFeed
    private let defaults: UserDefaults
    private let address: URL
    private static let interval: TimeInterval = 6 * 3600

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        var current = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var address = ReleaseFeed.address
        #if DEBUG
        // QA: `-qaReleaseFeed <url>` reads another feed, `-qaVersion 1.0` pretends to be an older build.
        if let value = defaults.string(forKey: "qaReleaseFeed"), let url = URL(string: value) { address = url }
        if let value = defaults.string(forKey: "qaVersion") { current = value }
        #endif
        self.current = current
        self.address = address
        let bundled = bundle.url(forResource: "releases", withExtension: "json")
            .flatMap { try? JSONDecoder().decode(ReleaseFeed.self, from: Data(contentsOf: $0)) } ?? ReleaseFeed(releases: [])
        let cached = defaults.data(forKey: Keys.feed).flatMap { try? JSONDecoder().decode(ReleaseFeed.self, from: $0) }
        feed = cached.map(bundled.merged(with:)) ?? bundled
        lastChecked = defaults.object(forKey: Keys.checked) as? Date
        #if os(macOS)
        installer?.closeSheet = { [weak self] in self?.sheet = nil }
        #endif
    }

    /// The current release's notes, for "What's New in This Version".
    var currentNotes: [ReleaseFeed.Release] { Distribution.isAppStore ? [] : feed.whatsNew(since: nil, current: current) }

    /// Once per launch: queue What's New after an update, then look for a newer release.
    /// `returning` says whether someone used the app before this build recorded versions.
    func launched(returning: Bool) async {
        guard !Distribution.isAppStore else { return }
        let previous = defaults.string(forKey: Keys.lastVersion)
        defaults.set(current, forKey: Keys.lastVersion)
        if previous != nil || returning, previous.map({ AppVersion($0) < AppVersion(current) }) ?? true {
            let notes = feed.whatsNew(since: previous, current: current)
            if !notes.isEmpty { sheet = .whatsNew(notes) }
        }
        await check()
    }

    /// Looks for a newer release. Automatic checks run at most every few hours and announce each
    /// version once; a check someone asks for always runs and reports the outcome.
    func check(manual: Bool = false) async {
        guard !checking, !Distribution.isAppStore else { return }
        if !manual, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { announce(); return }
        checking = true
        defer { checking = false }
        do {
            let fetched = try await ReleaseFeed.fetch(address)
            feed = feed.merged(with: fetched)
            defaults.set(try? JSONEncoder().encode(fetched), forKey: Keys.feed)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.checked)
            Diagnostics.shared.record(.info, "updates", "Release feed checked: current=\(current) latest=\(available.first?.version ?? current)")
        } catch {
            Diagnostics.shared.record(.warning, "updates", "Release feed check failed: \(error.localizedDescription)")
            if manual { message = L10n.text("Couldn't check for updates: %@", error.localizedDescription) }
            return
        }
        if manual {
            if available.isEmpty { message = L10n.text("Yingxia %@ is the latest version.", current) }
            else { show() }
        } else { announce() }
    }

    /// Shows the newer releases.
    func show() {
        guard !available.isEmpty else { return }
        sheet = .available(available)
        defaults.set(available.first?.version, forKey: Keys.announced)
    }

    func showCurrentNotes() {
        if !currentNotes.isEmpty { sheet = .whatsNew(currentNotes) }
    }

    /// Presents a newer release the first time it is seen; later it only shows as a badge.
    private func announce() {
        guard sheet == nil, let latest = available.first,
              defaults.string(forKey: Keys.announced).map({ AppVersion($0) < AppVersion(latest.version) }) ?? true else { return }
        show()
    }

    private enum Keys {
        static let lastVersion = "updates.lastVersion"
        static let announced = "updates.announcedVersion"
        static let checked = "updates.lastChecked"
        static let feed = "updates.feed"
    }
}

// MARK: Release notes

/// Release notes in the manner of the Apple TV app: a cinematic backdrop, a big headline with
/// pill buttons, and a shelf of artwork cards, one per feature.
struct ReleaseNotesView: View {
    let sheet: Updates.Sheet
    #if os(macOS)
    @Environment(Updates.self) private var updates
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var releases: [ReleaseFeed.Release] {
        switch sheet { case .available(let value), .whatsNew(let value): value }
    }
    private var update: ReleaseFeed.Release? {
        if case .available(let value) = sheet { value.first } else { nil }
    }
    private var features: [ReleaseFeed.Feature] {
        var seen = Set<ReleaseFeed.Feature>()
        return releases.flatMap { $0.features(for: ReleaseFeed.platform) }.filter { seen.insert($0).inserted }
    }
    private var version: String { releases.first?.version ?? "" }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ReleaseBackdrop(animated: !reduceMotion)
                .frame(height: Size.backdrop).frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: [.top, .horizontal])
            layout
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(width: 780).fixedSize(horizontal: false, vertical: true)
        #endif
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        // Phones scroll the story and keep the buttons under the thumb.
        ScrollView {
            VStack(alignment: .leading, spacing: Size.sectionGap) {
                hero
                if sizeClass == .compact { featureList } else { shelf }
            }
            .padding(.top, sizeClass == .compact ? Size.top * 2 : Size.top).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions.padding(.horizontal, Size.margin).padding(.top, 16).padding(.bottom, 12)
                .background { LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .center).ignoresSafeArea() }
        }
        #else
        VStack(alignment: .leading, spacing: Size.sectionGap) {
            HStack(alignment: .bottom, spacing: 60) {
                VStack(alignment: .leading, spacing: Size.buttonGap) { hero; actions.padding(.horizontal, Size.margin) }
                Spacer(minLength: 0)
                #if os(tvOS)
                if let link = update?.link() { scanCode(link).padding(.trailing, Size.margin) }
                #endif
            }
            shelf
            #if os(tvOS)
            Spacer(minLength: 0)
            #endif
        }
        .padding(.top, Size.top)
        #if os(macOS)
        .padding(.bottom, Size.top)
        #endif
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Size.heroSpacing) {
            HStack(spacing: Size.markGap) {
                AppMark(size: Size.mark)
                // Letter-spaced capitals read as a label in Latin scripts; CJK stays unspaced.
                Text(eyebrow).font(.system(size: Size.eyebrow, weight: .semibold)).tracking(L10n.resolvedLanguage() == "en" ? 1.2 : 0)
                    .textCase(.uppercase).foregroundStyle(.white.opacity(0.8))
            }
            .accessibilityElement(children: .combine)
            Text(update == nil ? L10n.text("What's New in Yingxia") : L10n.text("Something New Is Here"))
                .font(.system(size: Size.title, weight: .heavy)).tracking(-0.6)
                .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(update == nil ? L10n.text("Here's what's new in version %@.", version) : L10n.text("Yingxia %@ is ready with new features.", version))
                .font(.system(size: Size.subtitle, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: Size.textWidth, alignment: .leading)
        }
        .padding(.horizontal, Size.margin)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
    }

    private var eyebrow: String {
        let name = L10n.text("Yingxia %@", version)
        return "\(name) · \(update == nil ? L10n.text("What's New") : L10n.text("Now Available"))"
    }

    /// One artwork card per feature, title and description underneath, as in an Apple TV shelf.
    @ViewBuilder private var shelf: some View {
        #if os(tvOS)
        ScrollView(.horizontal) { cards.padding(.horizontal, Size.margin) }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        #else
        // A mouse wheel can't scroll sideways, so the strip adds dragging and arrows floating at its ends.
        ScrollStrip(overlayArrows: true, arrowCenter: Size.card * 9 / 32) { cards.padding(.horizontal, Size.margin) }
        #endif
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: Size.cardGap) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                VStack(alignment: .leading, spacing: Size.captionGap) {
                    #if os(tvOS)
                    // Focusable so the remote can scroll the shelf; the card lifts like a poster.
                    Button {} label: { ReleaseArt(symbol: feature.symbol, index: index) }.buttonStyle(.card)
                    #else
                    ReleaseArt(symbol: feature.symbol, index: index)
                    #endif
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title.text()).font(.system(size: Size.cardTitle, weight: .semibold)).lineLimit(1)
                        Text(feature.detail.text()).font(.system(size: Size.cardDetail)).foregroundStyle(.white.opacity(0.6))
                            .lineLimit(3, reservesSpace: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(width: Size.card)
            }
        }
    }

    #if os(iOS)
    /// On a phone each feature is a card as wide as the screen, artwork on top and the words under
    /// it, like the shelf cards elsewhere; artwork beside the text squeezed both.
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                VStack(alignment: .leading, spacing: Size.captionGap) {
                    ReleaseArt(symbol: feature.symbol, index: index)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(feature.title.text()).font(.system(size: Size.cardTitle + 1, weight: .semibold))
                        Text(feature.detail.text()).font(.system(size: Size.cardDetail)).foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Size.margin)
    }
    #endif

    @ViewBuilder private var actions: some View {
        #if os(tvOS)
        Button(L10n.text(update == nil ? "Continue" : "OK")) { dismiss() }.controlButton(prominent: true)
        #else
        let primary = update?.link()
        #if os(macOS)
        if update != nil, let installer = updates.installer {
            MacInstallActions(installer: installer, link: primary)
        } else {
            linkActions(primary)
        }
        #else
        linkActions(primary)
        #endif
        #endif
    }

    #if !os(tvOS)
    /// Get the Update opens the download page or file.
    private func linkActions(_ primary: URL?) -> some View {
        let layout = Self.stackedButtons ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button { if let primary { openURL(primary) }; dismiss() } label: {
                Label(L10n.text(primary == nil ? "Continue" : "Get the Update"), systemImage: primary == nil ? "play.fill" : "arrow.down.circle.fill")
                    .frame(maxWidth: Self.stackedButtons ? .infinity : nil)
            }
            .buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            if primary != nil {
                Button { dismiss() } label: { Text(L10n.text("Not Now")).frame(maxWidth: Self.stackedButtons ? .infinity : nil) }
                    .buttonStyle(PillButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
            }
        }
    }
    #endif

    #if os(tvOS)
    /// Apple TV can't open web pages, so the install page goes to a phone as a QR code.
    private func scanCode(_ link: URL) -> some View {
        VStack(spacing: 18) {
            if let image = QRCode.image(link.absoluteString) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220).padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            Text(L10n.text("Scan with your iPhone to get the update."))
                .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
        .frame(width: 300)
    }
    #endif

    private static var stackedButtons: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private enum Size {
        #if os(tvOS)
        static let margin: CGFloat = 90, top: CGFloat = 70, backdrop: CGFloat = 760, sectionGap: CGFloat = 56, buttonGap: CGFloat = 36
        static let mark: CGFloat = 44, markGap: CGFloat = 14, eyebrow: CGFloat = 24, title: CGFloat = 80, subtitle: CGFloat = 32
        static let heroSpacing: CGFloat = 16, textWidth: CGFloat = 1000
        static let card: CGFloat = 480, cardGap: CGFloat = 48, captionGap: CGFloat = 22, cardTitle: CGFloat = 29, cardDetail: CGFloat = 23
        #elseif os(macOS)
        static let margin: CGFloat = 44, top: CGFloat = 44, backdrop: CGFloat = 420, sectionGap: CGFloat = 34, buttonGap: CGFloat = 24
        static let mark: CGFloat = 26, markGap: CGFloat = 9, eyebrow: CGFloat = 12, title: CGFloat = 44, subtitle: CGFloat = 16
        static let heroSpacing: CGFloat = 10, textWidth: CGFloat = 520
        static let card: CGFloat = 250, cardGap: CGFloat = 18, captionGap: CGFloat = 12, cardTitle: CGFloat = 14, cardDetail: CGFloat = 12
        #else
        static let margin: CGFloat = 24, top: CGFloat = 56, backdrop: CGFloat = 520, sectionGap: CGFloat = 36, buttonGap: CGFloat = 24
        static let mark: CGFloat = 26, markGap: CGFloat = 9, eyebrow: CGFloat = 12, title: CGFloat = 40, subtitle: CGFloat = 17
        static let heroSpacing: CGFloat = 12, textWidth: CGFloat = 520
        static let card: CGFloat = 260, cardGap: CGFloat = 14, captionGap: CGFloat = 12, cardTitle: CGFloat = 16, cardDetail: CGFloat = 14
        #endif
    }
}

/// A feature's 16:9 artwork: a deep gradient with a lit corner and the feature's symbol.
private struct ReleaseArt: View {
    let symbol: String
    let index: Int
    static let palettes: [[Color]] = [
        [Color(red: 1.0, green: 0.60, blue: 0.28), Color(red: 0.78, green: 0.20, blue: 0.28)],
        [Color(red: 0.52, green: 0.42, blue: 1.0), Color(red: 0.16, green: 0.14, blue: 0.50)],
        [Color(red: 0.18, green: 0.80, blue: 0.72), Color(red: 0.05, green: 0.30, blue: 0.56)],
        [Color(red: 1.0, green: 0.82, blue: 0.32), Color(red: 0.88, green: 0.38, blue: 0.12)],
        [Color(red: 1.0, green: 0.45, blue: 0.62), Color(red: 0.45, green: 0.12, blue: 0.42)],
    ]
    var body: some View {
        let colors = Self.palettes[index % Self.palettes.count]
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: geometry.size.width * 0.9)
                Image(systemName: symbol)
                    .font(.system(size: geometry.size.height * 0.38, weight: .semibold))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: geometry.size.height * 0.08, y: geometry.size.height * 0.03)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(.white.opacity(0.12)) }
        .accessibilityHidden(true)
    }
    static var radius: CGFloat {
        #if os(tvOS)
        16
        #else
        12
        #endif
    }
}

/// Slowly drifting colours from the icon (cyan, blue, indigo) that fade into black, like the Apple
/// TV app's hero glow.
private struct ReleaseBackdrop: View {
    var animated: Bool
    private static let top = [Color(red: 0.16, green: 0.62, blue: 0.98), Color(red: 0.10, green: 0.30, blue: 0.86), Color(red: 0.20, green: 0.12, blue: 0.56)]
    private static let middle = [Color(red: 0.04, green: 0.22, blue: 0.46), Color(red: 0.06, green: 0.12, blue: 0.38), Color(red: 0.06, green: 0.05, blue: 0.22)]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            let drift = Float(sin(context.date.timeIntervalSinceReferenceDate * 0.3)) * 0.12
            if #available(iOS 18, *) {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + drift, 0.42 - drift / 2], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: Self.top + Self.middle + [.black, .black, .black])
            } else {
                // No mesh gradients before iOS 18: the top row's colours drift sideways over the middle row's.
                LinearGradient(colors: Self.top, startPoint: UnitPoint(x: CGFloat(drift), y: 0), endPoint: UnitPoint(x: 1 + CGFloat(drift), y: 0))
                    .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)) }
                    .background { LinearGradient(colors: Self.middle, startPoint: .leading, endPoint: .trailing) }
                    .mask { LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom) }
                    .background(.black)
            }
        }
        .overlay { LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom) }
        .accessibilityHidden(true)
    }
}

#if !os(tvOS)
/// White and translucent capsules, the Apple TV app's primary and secondary buttons.
private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Self.font, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 26).frame(minHeight: Self.height)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.16)), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
    #if os(macOS)
    static let font: CGFloat = 14, height: CGFloat = 38
    #else
    static let font: CGFloat = 17, height: CGFloat = 52
    #endif
}
#endif

#if os(macOS)
/// Install and Relaunch on the Mac, with the download's progress in place of the buttons while it runs.
private struct MacInstallActions: View {
    let installer: MacUpdater
    /// The DMG, for when the update can't be installed in place.
    let link: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch installer.phase {
        case .idle, .ready:
            HStack(spacing: 12) {
                let ready = installer.phase == .ready
                Button(action: installer.install) {
                    Label(L10n.text(ready ? "Relaunch to Update" : "Install and Relaunch"),
                          systemImage: ready ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                }
                .buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                notNow
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let link {
                        Button { installer.clearFailure(); openURL(link); dismiss() } label: {
                            Label(L10n.text("Download Manually"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                    notNow
                }
            }
        case .checking, .downloading, .preparing, .installing:
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                    Group {
                        if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                    }
                    .progressViewStyle(.linear).tint(.white)
                }
                .frame(width: 300, alignment: .leading)
                if installer.canCancel {
                    Button(action: installer.cancel) { Text(L10n.text("Cancel")) }
                        .buttonStyle(PillButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
                }
            }
            .frame(minHeight: PillButtonStyle.height)
        }
    }

    private var notNow: some View {
        Button { installer.clearFailure(); dismiss() } label: { Text(L10n.text("Not Now")) }
            .buttonStyle(PillButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
    }

    private var fraction: Double? {
        if case .downloading(let received, let expected) = installer.phase, expected > 0 { min(1, Double(received) / Double(expected)) } else { nil }
    }

    private var status: String {
        switch installer.phase {
        case .downloading:
            L10n.text("Downloading…") + (fraction.map { "  " + $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
        case .preparing: L10n.text("Preparing the update…")
        case .installing: L10n.text("Relaunching…")
        default: L10n.text("Checking for the update…")
        }
    }
}
#endif

// MARK: Settings

/// The small "New" capsule on the Settings entry while an update waits.
struct NewBadge: View {
    var body: some View {
        Text(L10n.text("New"))
            .font(.caption2.weight(.bold)).foregroundStyle(Brand.onAccent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Brand.accent, in: Capsule())
    }
}

extension View {
    /// Presents release sheets and update-check results, holding them back while a video plays.
    func updatePresentation(_ updates: Updates, playing: Bool) -> some View {
        @Bindable var updates = updates
        let item = Binding(get: { playing ? nil : updates.sheet }, set: { updates.sheet = $0 })
        #if os(macOS)
        let presented = sheet(item: item) { ReleaseNotesView(sheet: $0).environment(updates) }
        #else
        let presented = fullScreenCover(item: item) { ReleaseNotesView(sheet: $0) }
        #endif
        return presented
        .alert(L10n.text("Software Update"), isPresented: Binding(get: { !playing && updates.message != nil }, set: { if !$0 { updates.message = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { updates.message = nil }
        } message: { Text(updates.message ?? "") }
    }
}

enum QRCode {
    /// One pixel per module unless `scale` is given; a scaled code gets the white margin scanners
    /// need when it's read from a photo.
    static func image(_ text: String, scale: CGFloat = 1) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard var output = filter.outputImage else { return nil }
        if scale != 1 {
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let margin = output.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
            output = output.composited(over: CIImage(color: .white).cropped(to: margin))
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
