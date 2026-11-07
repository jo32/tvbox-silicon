import AVFoundation
import SwiftUI
import TVCore
import UniformTypeIdentifiers

/// Subtitle files the app shows over the picture itself (#576): those a source offers beside a video AVPlayer plays
/// directly (an MP4, an HLS stream), which used to be dropped, and those the viewer adds while watching. A file the
/// repackager made a track of (`Remux.subtitleSources`) stays AVPlayer's.
///
/// They load after the picture starts, never before it. One that fails says why and can be tried again; it never
/// stops the video. Choosing one turns the item's own subtitles off, and choosing one of those turns this off.
@MainActor @Observable final class ExternalSubtitles {
    struct Entry: Identifiable, Equatable {
        enum State: Equatable { case loading, ready(SubtitleDocument), failed(String) }
        let id: String
        let name: String
        /// Added by the viewer rather than offered by the source.
        let imported: Bool
        var state: State
        /// What to fetch again.
        var subtitle: ExternalSubtitle?
        /// A subtitle source's result (#576 M2), downloaded again on Try Again.
        var candidate: SubtitleCandidate?

        var canRetry: Bool { subtitle != nil || candidate != nil }

        var document: SubtitleDocument? { if case .ready(let document) = state { document } else { nil } }
        var title: String {
            let language = document?.language ?? subtitle.map { $0.language.isEmpty ? SubtitleMatch.language($0.name) : $0.language } ?? candidate?.language ?? ""
            guard !language.isEmpty, let named = Locale.current.localizedString(forIdentifier: language) else { return name }
            return "\(named) · \(name)"
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var selected: String?
    private(set) var timing = SubtitleTiming()
    /// A file or address the viewer added that couldn't be read, for an alert.
    var importFailure: String?
    var document: SubtitleDocument? { entries.first { $0.id == selected }?.document }

    /// Searching the viewer's subtitle sources (#576 M2).
    enum OnlineState: Equatable { case idle, noSources, searching, done }
    private(set) var online = SubtitleSearchProgress()
    private(set) var onlineState = OnlineState.idle
    /// What the search asks for: the playing video, as the catalog names it, until the viewer edits it.
    private(set) var hint: SubtitleHint?
    /// Whether any subtitle source is on, for showing the search at all.
    private(set) var hasSources = false
    /// The sources' names by id, in their order, for the search's status lines.
    private(set) var sourceNames: [(id: String, name: String)] = []
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var sources: [SubtitleSearchSource] = []

    /// The player shows what is chosen; set by the session.
    @ObservationIgnored var cues: SubtitleCues?
    @ObservationIgnored weak var player: AVPlayer?
    /// Runs when a file is chosen or put away, for the session's clock.
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var headers: [String: String] = [:]
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var retries: [String: Task<Void, Never>] = [:]
    /// The first file that loads comes on by itself, unless the viewer chose (or the video has its own on).
    @ObservationIgnored private var automatic = true
    @ObservationIgnored private var generation = UUID()
    /// At most this many of a source's files, three at a time.
    static let limit = 8, concurrent = 3

    /// A new episode: its source's files, after the picture.
    func begin(_ channel: Channel, playing url: URL) {
        stop()
        hint = Self.hint(for: channel)
        let current = generation
        Task { [weak self] in
            let any = await SubtitleSourceLibrary.shared.hasEnabledSources()
            guard let self, self.generation == current else { return }
            self.hasSources = any
        }
        headers = channel.headers
        scope = channel.historyContext?.id ?? channel.skipScope
        timing = SubtitleTimingStore.load(scope: scope)
        cues?.timing = timing
        let included = Remux.subtitleSources(url)
        // The title names the episode ("第02集", "S01E02") more often than a drive's address does.
        let file = channel.url.lastPathComponent.removingPercentEncoding ?? channel.url.lastPathComponent
        let video = SubtitleMatch.episode(channel.name) != nil || file.isEmpty ? channel.name : file
        let wanted = SubtitleMatch.candidates(channel.subtitles, video: video).filter { !included.contains($0.url) }.prefix(Self.limit)
        guard !wanted.isEmpty else { return }
        entries = wanted.map { Entry(id: $0.url.absoluteString, name: $0.name, imported: false, state: .loading, subtitle: $0) }
        Diagnostics.shared.record(.info, "subtitles", "external files=\(wanted.count) of=\(channel.subtitles.count) in-stream=\(included.count)")
        let active = generation, headers = headers
        loading = Task { [weak self] in
            await withTaskGroup(of: (String, Result<SubtitleDocument, Error>).self) { group in
                var queued = wanted.makeIterator(), running = 0
                func next() {
                    guard let subtitle = queued.next() else { return }
                    running += 1
                    group.addTask { (subtitle.url.absoluteString, await Self.fetch(subtitle, headers: headers)) }
                }
                for _ in 0..<Self.concurrent { next() }
                while running > 0, let (id, result) = await group.next() {
                    running -= 1
                    guard let self, self.generation == active, !Task.isCancelled else { group.cancelAll(); return }
                    self.finish(id, result)
                    next()
                }
            }
        }
    }

    /// The episode plays from another address now (repackaged after AVPlayer refused it): the source's files that
    /// became tracks of the stream are AVPlayer's from here on.
    func playing(_ url: URL) {
        let included = Remux.subtitleSources(url)
        guard !included.isEmpty else { return }
        entries.removeAll { entry in
            guard !entry.imported, let source = entry.subtitle?.url, included.contains(source) else { return false }
            retries[entry.id]?.cancel()
            return true
        }
        if let selected, !entries.contains(where: { $0.id == selected }) { self.selected = nil; show() }
    }

    /// Puts everything away: the episode ended or another began.
    func stop() {
        generation = UUID()
        loading?.cancel(); loading = nil
        retries.values.forEach { $0.cancel() }; retries = [:]
        entries = []; automatic = true; importFailure = nil
        searching?.cancel(); searching = nil
        online = SubtitleSearchProgress(); onlineState = .idle; sources = []
        if selected != nil { selected = nil; show() }
    }

    func select(_ id: String?) {
        automatic = false
        guard id != selected else { return }
        selected = id
        if id != nil { Task { await self.nativeOff() } }
        show()
    }

    /// One of the item's own subtitles was chosen (or Off), here or in the system's menu.
    func nativeChosen() {
        automatic = false
        guard selected != nil else { return }
        selected = nil
        show()
    }

    func retry(_ id: String) {
        if let candidate = entries.first(where: { $0.id == id })?.candidate { download(candidate); return }
        guard let index = entries.firstIndex(where: { $0.id == id }), let subtitle = entries[index].subtitle else { return }
        entries[index].state = .loading
        let active = generation, headers = headers
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            let result = await Self.fetch(subtitle, headers: headers)
            guard let self, self.generation == active, !Task.isCancelled else { return }
            self.retries[id] = nil
            self.finish(id, result, chosen: true)
        }
    }

    /// The chosen file read again with another text encoding.
    func read(as encoding: SubtitleEncoding) {
        guard let index = entries.firstIndex(where: { $0.id == selected }), let document = entries[index].document,
              document.encoding != encoding else { return }
        do {
            entries[index].state = .ready(try document.reading(as: encoding))
            show()
        } catch {
            importFailure = error.localizedDescription
        }
    }

    func setTiming(_ next: SubtitleTiming) {
        guard next != timing else { return }
        timing = next
        SubtitleTimingStore.save(next, scope: scope)
        cues?.timing = next
    }

    /// A file picked on this device or dropped on the player; it comes on.
    func add(file url: URL) {
        do { add(try SubtitleDocument.load(file: url)) }
        catch { fail(url.lastPathComponent, error) }
    }

    /// A file at an address the viewer typed; it comes on once loaded.
    func add(address text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            importFailure = L10n.text("Enter an address that starts with http:// or https://.")
            return
        }
        let id = url.absoluteString, active = generation
        if !entries.contains(where: { $0.id == id }) {
            entries.append(Entry(id: id, name: url.lastPathComponent, imported: true, state: .loading))
        }
        retries[id] = Task { [weak self] in
            let result = await Self.fetch(address: url)
            guard let self, self.generation == active, !Task.isCancelled else { return }
            self.retries[id] = nil
            if case .failure(let error) = result { self.fail(url.lastPathComponent, error) }
            self.finish(id, result, chosen: true)
        }
    }

    /// Asks the enabled sources; results come in as each answers. `hint` is the viewer's edit of the video's.
    func search(_ edited: SubtitleHint? = nil) {
        searching?.cancel()
        let hint = edited ?? self.hint ?? SubtitleHint(title: "")
        self.hint = hint
        online = SubtitleSearchProgress()
        onlineState = .searching
        let active = generation
        searching = Task { [weak self] in
            let sources = await SubtitleSourceLibrary.shared.searchSources()
            guard let self, self.generation == active, !Task.isCancelled else { return }
            self.sources = sources
            self.sourceNames = sources.map { ($0.provider.manifest.id, $0.provider.manifest.name) }
            self.hasSources = !sources.isEmpty
            guard !sources.isEmpty else { self.onlineState = .noSources; return }
            Diagnostics.shared.record(.info, "subtitles", "online search sources=\(sources.count) episode=\(hint.episode != nil)")
            for await progress in SubtitleSearch.shared.search(hint, sources: sources) {
                guard self.generation == active, !Task.isCancelled else { return }
                self.online = progress
            }
            if self.generation == active, !Task.isCancelled { self.onlineState = .done }
        }
    }

    /// A search result: downloaded (or taken from the cache) and shown.
    func download(_ candidate: SubtitleCandidate) {
        let id = candidate.id
        if entries.contains(where: { $0.id == id && $0.document != nil }) { select(id); return }
        guard let source = sources.first(where: { $0.provider.manifest.id == candidate.provider }) else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].state = .loading }
        else { entries.append(Entry(id: id, name: candidate.title, imported: true, state: .loading, candidate: candidate)) }
        let active = generation
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            let result = await Self.fetch(candidate, from: source)
            guard let self, self.generation == active, !Task.isCancelled else { return }
            self.retries[id] = nil
            self.finish(id, result, chosen: true)
        }
    }

    /// The playing video as a search: the catalog's names, and the file's when the address has one.
    static func hint(for channel: Channel) -> SubtitleHint {
        let context = channel.historyContext
        let last = channel.url.lastPathComponent.removingPercentEncoding ?? channel.url.lastPathComponent
        let videos: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "flv", "webm", "rmvb"]
        let file = videos.contains((last as NSString).pathExtension.lowercased()) ? last : nil
        // A link played as it is is named after its file: the title is the name without the extension.
        let ext = (channel.name as NSString).pathExtension.lowercased()
        let name = videos.contains(ext) ? (channel.name as NSString).deletingPathExtension : channel.name
        return SubtitleHint(video: context?.videoName ?? name, episodeName: context?.episodeName ?? name, year: context?.year, fileName: file)
    }

    private func add(_ document: SubtitleDocument) {
        entries.removeAll { $0.id == document.id }
        entries.append(Entry(id: document.id, name: document.name, imported: true, state: .ready(document)))
        Diagnostics.shared.record(.info, "subtitles", "imported format=\(document.format.rawValue) cues=\(document.cues.count)")
        select(document.id)
    }

    private func fail(_ name: String, _ error: Error) {
        importFailure = "\(name): \(error.localizedDescription)"
    }

    private func finish(_ id: String, _ result: Result<SubtitleDocument, Error>, chosen: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let document):
            entries[index].state = .ready(document)
            if chosen { select(id) }
            if selected == id { show() }
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            Diagnostics.shared.record(.warning, "subtitles", "external host=\(entries[index].subtitle?.url.host() ?? "-") \(error.localizedDescription)")
            entries[index].state = .failed(error.localizedDescription)
        }
        chooseAutomatically()
    }

    /// The best file (the first, by `SubtitleMatch`) comes on once it has loaded, unless the video shows its own
    /// subtitles or the viewer chose. One that failed gives way to the next.
    private func chooseAutomatically() {
        guard automatic, let best = entries.first(where: { if case .failed = $0.state { false } else { true } }), best.document != nil else { return }
        automatic = false
        let active = generation
        Task {
            guard await self.nativeShowing() != true, self.generation == active, self.selected == nil else { return }
            self.select(best.id)
        }
    }

    private func show() {
        cues?.show(document, timing: timing, at: player?.currentTime().seconds)
        changed()
    }

    /// Whether the item shows one of its own subtitles now; nil when it has none.
    private func nativeShowing() async -> Bool? {
        guard let item = player?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group).map { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? false
    }

    /// The item's own subtitles off, so the two don't show at once.
    private func nativeOff() async {
        guard let item = player?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              group.allowsEmptySelection, item.currentMediaSelection.selectedMediaOption(in: group) != nil else { return }
        item.select(nil, in: group)
    }

    nonisolated private static func fetch(_ subtitle: ExternalSubtitle, headers: [String: String]) async -> Result<SubtitleDocument, Error> {
        do { return .success(try await SubtitleDocument.load(subtitle, headers: headers)) } catch { return .failure(error) }
    }

    nonisolated private static func fetch(_ candidate: SubtitleCandidate, from source: SubtitleSearchSource) async -> Result<SubtitleDocument, Error> {
        do { return .success(try await SubtitleSearch.shared.download(candidate, from: source)) } catch { return .failure(error) }
    }

    nonisolated private static func fetch(address url: URL) async -> Result<SubtitleDocument, Error> {
        do { return .success(try await SubtitleDocument.load(address: url)) } catch { return .failure(error) }
    }

    /// The kinds of file the import panels offer.
    static let types: [UTType] = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    static func handles(_ url: URL) -> Bool { ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased()) }
}


#if !os(tvOS)
/// The subtitle-file part of the player's Subtitles menu, on iPhone, iPad and Mac: the files, adding one, and the
/// chosen one's encoding, frame rate and timing.
struct ExternalSubtitleMenu: View {
    let subtitles: ExternalSubtitles
    let addFile: () -> Void
    let addAddress: () -> Void
    let searchOnline: () -> Void

    var body: some View {
        if !subtitles.entries.isEmpty {
            Section(L10n.text("Subtitle Files")) {
                ForEach(subtitles.entries) { entry in
                    switch entry.state {
                    case .ready:
                        Toggle(entry.title, isOn: Binding(get: { subtitles.selected == entry.id }, set: { subtitles.select($0 ? entry.id : nil) }))
                    case .loading:
                        Text(L10n.text("%@ (loading)", entry.title))
                    case .failed(let reason):
                        if entry.canRetry {
                            Button(L10n.text("%@: Try Again", entry.title)) { subtitles.retry(entry.id) }
                        }
                        Text(reason)
                    }
                }
            }
        }
        Section {
            Button(L10n.text("Search Online…"), action: searchOnline)
            Button(L10n.text("Add Subtitle File…"), action: addFile)
            Button(L10n.text("Add Subtitles from Address…"), action: addAddress)
        }
        if let document = subtitles.document {
            Section {
                if document.format.isStyled {
                    Text(L10n.text("ASS styling and effects show as plain text."))
                }
                Menu(L10n.text("Text Encoding")) {
                    Picker(L10n.text("Text Encoding"), selection: Binding(get: { document.encoding }, set: { subtitles.read(as: $0) })) {
                        ForEach(SubtitleEncoding.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Menu(L10n.text("Frame Rate")) {
                    Picker(L10n.text("Frame Rate"), selection: Binding(get: { subtitles.timing.rate?.id ?? "" },
                                                                     set: { id in subtitles.setTiming(SubtitleTiming(delay: subtitles.timing.delay, scale: SubtitleTiming.rates.first { $0.id == id }?.scale ?? 1)) })) {
                        Text(L10n.text("As Made")).tag("")
                        ForEach(SubtitleTiming.rates) { Text(L10n.text("%@ fps", $0.title)).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                }
                ExternalSubtitleDelayMenu(subtitles: subtitles)
            }
        }
    }
}

/// The chosen file's timing: half a second at a time, earlier as well as later.
struct ExternalSubtitleDelayMenu: View {
    let subtitles: ExternalSubtitles
    var body: some View {
        Menu(L10n.text("Subtitle Delay")) {
            Text(subtitles.timing.title)
            Button(String(format: "%+.1f s", -SubtitleTiming.step)) { shift(-SubtitleTiming.step) }
                .disabled(subtitles.timing.delay <= SubtitleTiming.delays.lowerBound)
            Button(String(format: "%+.1f s", SubtitleTiming.step)) { shift(SubtitleTiming.step) }
                .disabled(subtitles.timing.delay >= SubtitleTiming.delays.upperBound)
            if !subtitles.timing.isIdentity {
                Button(L10n.text("Reset")) { subtitles.setTiming(SubtitleTiming()) }
            }
        }
    }
    private func shift(_ seconds: Double) {
        subtitles.setTiming(SubtitleTiming(delay: subtitles.timing.delay + seconds, scale: subtitles.timing.scale))
    }
}

/// Asks for a subtitle file's address.
struct SubtitleAddressPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let subtitles: ExternalSubtitles
    @State private var address = ""
    func body(content: Content) -> some View {
        content
            .alert(L10n.text("Add Subtitles from Address"), isPresented: $isPresented) {
                TextField("https://…", text: $address)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button(L10n.text("Cancel"), role: .cancel) { address = "" }
                Button(L10n.text("Add")) { subtitles.add(address: address); address = "" }
            } message: {
                Text(L10n.text("An SRT, WebVTT or ASS file, up to 8 MB."))
            }
            .alert(L10n.text("Subtitles Not Added"), isPresented: Binding(get: { subtitles.importFailure != nil }, set: { if !$0 { subtitles.importFailure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) { subtitles.importFailure = nil }
            } message: {
                Text(subtitles.importFailure ?? "")
            }
    }
}

extension View {
    /// The file panel and address prompt that add subtitles to the playing video.
    func subtitleImport(files: Binding<Bool>, address: Binding<Bool>, search: Binding<Bool>, subtitles: ExternalSubtitles) -> some View {
        fileImporter(isPresented: files, allowedContentTypes: ExternalSubtitles.types) { result in
            if case .success(let url) = result { subtitles.add(file: url) }
        }
        .modifier(SubtitleAddressPrompt(isPresented: address, subtitles: subtitles))
        .sheet(isPresented: search) { SubtitleSearchSheet(subtitles: subtitles) }
    }
}
#endif
