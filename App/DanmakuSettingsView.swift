import SwiftUI
import TVCore

/// Settings › Danmaku (#768, #789, #924): every choice about bullet comments on one page, as Subtitle Style is for
/// subtitles. A picture with sample comments crossing it sits on top, drawn by the player's own renderer
/// (`DanmakuCanvas`), so each change shows there at once. The keys are the ones the player's danmaku menus and its
/// Danmaku Settings sheet set, and they apply to every track (matched or imported comments, Bilibili videos, live
/// rooms), including one that is playing. The service rows are `DanmakuServiceSettings`, shared with that sheet.
struct DanmakuSettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVDanmakuSettingsPage()
        #else
        FormDanmakuSettingsPage()
        #endif
    }
}

/// The look and filters as stored, under the keys `DanmakuCanvas` and the player's menus read.
struct DanmakuSettings: DynamicProperty {
    @AppStorage(DanmakuPreference.key) var shows = true
    @AppStorage(DanmakuArea.key) var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) var fontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.opacityKey) var opacity = DanmakuStyle.standardOpacity
    @AppStorage(DanmakuStyle.speedKey) var speed = DanmakuStyle.standardSpeed
    @AppStorage(DanmakuStyle.scrollKey) var scrolling = true
    @AppStorage(DanmakuStyle.topKey) var top = true
    @AppStorage(DanmakuStyle.bottomKey) var bottom = true
    @AppStorage(DanmakuFilter.colorsKey) var colors = true
    @AppStorage(DanmakuFilter.wordsKey) var storedWords = ""

    var words: [String] { DanmakuFilter.words(storedWords) }

    func add(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !words.contains(word) else { return }
        storedWords = DanmakuFilter.stored(words + [word])
    }

    func remove(_ word: String) { storedWords = DanmakuFilter.stored(words.filter { $0 != word }) }

    /// The speeds offered, slowest first, and the place of the stored one among them.
    var speeds: [Double] { DanmakuStyle.speeds(including: speed) }
    var speedIndex: Int { speeds.firstIndex { abs($0 - DanmakuStyle.clampedSpeed(speed)) < 0.001 } ?? 0 }

    /// The look and the kinds shown are as they come; blocked words and the service are not part of it.
    var isStandard: Bool {
        area == .standard && fontSize == DanmakuStyle.standardFontSize && opacity == DanmakuStyle.standardOpacity
            && speed == DanmakuStyle.standardSpeed && scrolling && top && bottom && colors
    }

    func reset() {
        area = .standard; fontSize = DanmakuStyle.standardFontSize; opacity = DanmakuStyle.standardOpacity
        speed = DanmakuStyle.standardSpeed; scrolling = true; top = true; bottom = true; colors = true
    }

    static var colorsNote: String { L10n.text("Turn off Colored Comments to draw every comment in white, which stays readable over bright pictures.") }
    static var wordsNote: String {
        L10n.text("Comments containing any of these words are hidden in every video. Put a pattern between slashes, like /^哈+$/, to match it as a regular expression.")
    }
    static var appliesNote: String { L10n.text("Applies to comments in every video, including one that is playing.") }
}

/// The Subtitle Style picture with sample comments crossing it, over and over. For a moment after the area changes, a
/// frame shows what it covers. (A sample subtitle under them read as a glitch where bottom comments crossed it.)
struct DanmakuPreview: View {
    var cornerRadius: CGFloat = 12
    @AppStorage(DanmakuArea.key) private var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) private var fontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.opacityKey) private var opacity = DanmakuStyle.standardOpacity
    @State private var start = Date()
    @State private var showsArea = false
    @State private var appeared = false
    /// A 720p screen: comments are 4% of its height, as over any video playing full screen.
    private static let screen = CGSize(width: 1280, height: 720)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                SubtitleScene()
                if showsArea {
                    let frame = DanmakuEngine.areaFrame(in: Self.screen, area: area, textScale: DanmakuStyle.textScale(fontSize))
                    let shrink = size.width / Self.screen.width
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Brand.amber.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.amber, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                        .frame(width: max(0, size.width - 8), height: frame.height * shrink)
                        .offset(x: 4, y: frame.minY * shrink)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Drawn on a full-size screen and shrunk: comments are sized from the screen with a smallest size, so drawn
            // on the small picture itself they came out far larger, and fewer rows fit, than over a video playing.
            .overlay(alignment: .topLeading) {
                DanmakuCanvas(comments: DanmakuSamples.comments, revision: "preview", opacity: opacity) {
                    Date().timeIntervalSince(start).truncatingRemainder(dividingBy: DanmakuSamples.length)
                }
                .frame(width: Self.screen.width, height: Self.screen.height)
                .scaleEffect(size.width / Self.screen.width, anchor: .topLeading)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Danmaku"))
        .accessibilityValue(area.title)
        .task(id: area) {
            guard appeared else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.2)) { showsArea = true }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showsArea = false }
        }
    }
}

/// Comments for the preview: everyday ones, two a second, a few in Bilibili's colours, a few pinned to the top or
/// the bottom, looping.
enum DanmakuSamples {
    static let length = 60.0
    static let comments: [Danmaku] = {
        let texts = [
            L10n.text("Here it comes!"), L10n.text("This scene is incredible"), L10n.text("Hahahahaha"),
            L10n.text("Third time watching"), L10n.text("The music is so good"), L10n.text("Plot twist!"),
            L10n.text("Classic moment"), L10n.text("Welcome back, everyone"), L10n.text("Who else is watching tonight?"),
        ]
        let colors: [UInt32] = [0xFE0302, 0xFFD302, 0x00CD00, 0x89D5FF, 0xCC0273, 0xFF7204]
        return (0..<Int(length * 2)).map { index in
            let position: Danmaku.Position = index % 13 == 4 ? .top : index % 13 == 10 ? .bottom : .scroll
            let color = index % 4 == 1 ? colors[(index / 4) % colors.count] : 0xFFFFFF
            return Danmaku(time: Double(index) / 2 + 0.2, position: position, color: color, text: texts[(index * 7) % texts.count])
        }
    }()
}

#if !os(tvOS)
// MARK: iPhone, iPad and Mac

/// The preview pinned over a settings form, as on Subtitle Style.
private struct FormDanmakuSettingsPage: View {
    private let settings = DanmakuSettings()
    @State private var newWord = ""

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle(isOn: settings.$shows) {
                        FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"))
                    }
                    .settingsSwitch()
                }
                Section {
                    Picker(selection: settings.$area) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        // "Danmaku Area" beside "Top Three Quarters" put the value on a line of its own on iPhone.
                        FormLabel(symbol: "rectangle.tophalf.inset.filled", tint: .teal, title: L10n.text("Area"))
                    }
                    slider(symbol: "textformat.size", tint: .orange, title: L10n.text("Text Size"), value: DanmakuStyle.sizeTitle(settings.fontSize)) {
                        Slider(value: settings.$fontSize, in: 16...36, step: 2) {
                            Text(L10n.text("Text Size"))
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller").accessibilityLabel(L10n.text("Smaller"))
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger").accessibilityLabel(L10n.text("Larger"))
                        }
                    }
                    slider(symbol: "circle.lefthalf.filled", tint: .indigo, title: L10n.text("Opacity"), value: DanmakuStyle.percent(settings.opacity)) {
                        Slider(value: settings.$opacity, in: 0.2...1, step: 0.05) {
                            Text(L10n.text("Opacity"))
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                    }
                    slider(symbol: "speedometer", tint: .green, title: L10n.text("Scroll Speed"), value: DanmakuStyle.speedTitle(settings.speed)) {
                        Slider(value: speedStep, in: 0...Double(settings.speeds.count - 1), step: 1) {
                            Text(L10n.text("Scroll Speed"))
                        } minimumValueLabel: {
                            Image(systemName: "tortoise.fill")
                        } maximumValueLabel: {
                            Image(systemName: "hare.fill")
                        }
                    }
                } header: {
                    Text(L10n.text("Display"))
                }
                Section {
                    Toggle(isOn: settings.$scrolling) {
                        FormLabel(symbol: "arrow.left", tint: .blue, title: L10n.text("Scrolling Comments"))
                    }
                    .settingsSwitch()
                    Toggle(isOn: settings.$top) {
                        FormLabel(symbol: "arrow.up.to.line", tint: .blue, title: L10n.text("Top Comments"))
                    }
                    .settingsSwitch()
                    Toggle(isOn: settings.$bottom) {
                        FormLabel(symbol: "arrow.down.to.line", tint: .blue, title: L10n.text("Bottom Comments"))
                    }
                    .settingsSwitch()
                    Toggle(isOn: settings.$colors) {
                        FormLabel(symbol: "paintpalette.fill", tint: .purple, title: L10n.text("Colored Comments"))
                    }
                    .settingsSwitch()
                } header: {
                    Text(L10n.text("Comment Types"))
                } footer: {
                    Text(DanmakuSettings.colorsNote)
                }
                Section {
                    HStack {
                        TextField(L10n.text("Add a word or /pattern/"), text: $newWord)
                            .onSubmit(addWord)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                            .accessibilityIdentifier("danmaku.words.field")
                        Button(L10n.text("Add"), action: addWord)
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(settings.words, id: \.self) { word in
                        HStack(spacing: 10) {
                            Text(word).lineLimit(1).truncationMode(.middle)
                            if DanmakuFilter.isPattern(word) {
                                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button { settings.remove(word) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("Remove"))
                        }
                    }
                } header: {
                    Text(L10n.text("Blocked Words"))
                } footer: {
                    Text(DanmakuSettings.wordsNote)
                }
                // Matching, the preferred platform and the server, as in the player's Danmaku Settings sheet.
                DanmakuServiceSettings(showsSwitch: false, showsDisplay: false)
                Section {
                    Button(L10n.text("Reset to Standard")) { settings.reset() }
                        .formRowButton()
                        .disabled(settings.isStandard)
                } footer: {
                    Text(DanmakuSettings.appliesNote)
                }
            }
            .settingsRows()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            DanmakuPreview()
                .frame(maxWidth: 560)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .settingsForm(L10n.text("Danmaku"))
    }

    /// A row's title and value over its slider, as on Subtitle Style.
    private func slider<Content: View>(symbol: String, tint: Color, title: String, value: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            } label: {
                FormLabel(symbol: symbol, tint: tint, title: title)
            }
            content().labelsHidden()
        }
    }

    /// The speeds as the slider's steps, slowest on the left.
    private var speedStep: Binding<Double> {
        let settings = settings
        return Binding(get: { Double(settings.speedIndex) },
                       set: { let speeds = settings.speeds; settings.speed = speeds[min(speeds.count - 1, max(0, Int($0.rounded())))] })
    }

    private func addWord() {
        settings.add(newWord)
        newWord = ""
    }
}
#endif

#if os(tvOS)
// MARK: Apple TV

/// A large preview on the left and the choices on the right, as on Subtitle Style: each row steps through its choices
/// with a press, as rows in the TV's own Settings do.
private struct TVDanmakuSettingsPage: View {
    private let settings = DanmakuSettings()
    @AppStorage(DanmakuService.automaticKey) private var automatic = true
    @AppStorage(DanmakuService.preferredSourceKey) private var preferredSource = ""
    @AppStorage(DanmakuService.serverKey) private var server = CatalogDanmakuClient.defaultServer
    @AppStorage(DanmakuService.officialLookupKey) private var officialLookup = true
    @State private var failure: String?
    private static let sizes: [Double] = [16, 18, 20, 22, 26, 30, 36]
    private static let opacities: [Double] = [0.3, 0.5, 0.7, 0.85, 1]

    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            VStack(spacing: 30) {
                DanmakuPreview(cornerRadius: 24)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                Text(L10n.text("Danmaku")).font(.system(size: 44, weight: .bold))
            }
            .frame(width: 860)
            .frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    TVSettingsSection {
                        TVSettingsToggle(title: L10n.text("Show Danmaku"), isOn: settings.$shows)
                    }
                    TVSettingsSection(title: L10n.text("Display")) {
                        TVSettingsAction(title: L10n.text("Danmaku Area"), value: settings.area.title) { settings.area = settings.area.next }
                        TVSettingsAction(title: L10n.text("Text Size"), value: DanmakuStyle.sizeTitle(settings.fontSize)) {
                            settings.fontSize = Self.sizes.first { $0 > settings.fontSize + 0.01 } ?? Self.sizes[0]
                        }
                        TVSettingsAction(title: L10n.text("Opacity"), value: DanmakuStyle.percent(settings.opacity)) {
                            settings.opacity = Self.opacities.first { $0 > settings.opacity + 0.01 } ?? Self.opacities[0]
                        }
                        TVSettingsAction(title: L10n.text("Scroll Speed"), value: DanmakuStyle.speedTitle(settings.speed)) {
                            let speeds = settings.speeds
                            settings.speed = speeds[(settings.speedIndex + 1) % speeds.count]
                        }
                    }
                    TVSettingsSection(title: L10n.text("Comment Types"), footer: DanmakuSettings.colorsNote) {
                        TVSettingsToggle(title: L10n.text("Scrolling Comments"), isOn: settings.$scrolling)
                        TVSettingsToggle(title: L10n.text("Top Comments"), isOn: settings.$top)
                        TVSettingsToggle(title: L10n.text("Bottom Comments"), isOn: settings.$bottom)
                        TVSettingsToggle(title: L10n.text("Colored Comments"), isOn: settings.$colors)
                    }
                    TVSettingsSection {
                        TVSettingsLink(title: L10n.text("Blocked Words"), value: settings.words.count.formatted()) { TVDanmakuWordsPage() }
                    }
                    // Saved through `DanmakuService`, which checks the address and tells the player, as the iPhone's rows do.
                    TVSettingsSection(title: L10n.text("Danmaku Service"),
                                      footer: failure ?? L10n.text("Matching comments appear automatically. If none match or the service is unavailable, the video stays clear.")) {
                        TVSettingsToggle(title: L10n.text("Automatically match the current episode"),
                                         isOn: Binding(get: { automatic }, set: { save(automatic: $0) }))
                        TVSettingsAction(title: L10n.text("Preferred Source Platform"), value: source.title) {
                            let all = DanmakuProvider.allCases
                            save(source: all[((all.firstIndex(of: source) ?? 0) + 1) % all.count])
                        }
                        TVSettingsField(title: L10n.text("Danmaku server URL"), text: Binding(get: { server }, set: { save(server: $0) }))
                    }
                    if !DanmakuService.isCustomServer(server) {
                        TVSettingsSection(footer: DanmakuService.officialLookupNote) {
                            TVSettingsToggle(title: L10n.text("Find official episodes for dmku"), isOn: $officialLookup)
                        }
                    }
                    TVSettingsSection(footer: DanmakuSettings.appliesNote) {
                        TVSettingsAction(title: L10n.text("Reset to Standard")) { settings.reset() }
                            .disabled(settings.isStandard)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassRowInsets()
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
        .padding(.horizontal, Layout.gutter)
        .screenBackdrop()
        .screenTitle("")
    }

    private var source: DanmakuProvider { DanmakuProvider(rawValue: preferredSource) ?? .automatic }

    private func save(server: String? = nil, source: DanmakuProvider? = nil, automatic: Bool? = nil) {
        do {
            try DanmakuService.save(server: server ?? self.server, preferredSource: source ?? self.source, automatic: automatic ?? self.automatic)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Blocked words on the TV: one row types a new one, and pressing a word removes it.
private struct TVDanmakuWordsPage: View {
    private let settings = DanmakuSettings()
    @State private var draft = ""

    var body: some View {
        TVSettingsSubpage(symbol: "nosign", title: L10n.text("Blocked Words"), subtitle: DanmakuSettings.wordsNote) {
            TVSettingsSection {
                TVSettingsField(title: L10n.text("Add Blocked Word"), text: $draft, prose: true, emptyValue: "")
                    .onChange(of: draft) { _, word in
                        guard !word.isEmpty else { return }
                        settings.add(word)
                        draft = ""
                    }
            }
            TVSettingsSection {
                if settings.words.isEmpty {
                    TVSettingsRowLabel(title: L10n.text("No blocked words")).foregroundStyle(.secondary).padding(.horizontal, 28)
                }
                ForEach(settings.words, id: \.self) { word in
                    TVSettingsAction(title: word, value: L10n.text("Remove")) { settings.remove(word) }
                }
            }
        }
    }
}
#endif
