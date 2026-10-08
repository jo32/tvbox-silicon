import SwiftUI
import TVCore

// MARK: Settings building blocks
// Grouped rows in the style of System Settings: a section title, a rounded group with
// hairline separators, and an optional footnote.

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id { Divider().padding(.leading, 14) }
                    }
                }
            }
            .background(SettingsStyle.groupFill, in: RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

enum SettingsStyle {
    static let radius: CGFloat = 12
    static let groupFill = Color.primary.opacity(0.05)
    #if os(tvOS)
    static let rowHeight: CGFloat = 88
    static let icon: CGFloat = 48, iconSymbol: CGFloat = 24, chevron: CGFloat = 22, field: CGFloat = 66
    #else
    static let rowHeight: CGFloat = 52
    static let icon: CGFloat = 28, iconSymbol: CGFloat = 13, chevron: CGFloat = 12, field: CGFloat = 36
    #endif
}

/// Icon tile, title, optional subtitle and a trailing accessory.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: SettingsStyle.iconSymbol, weight: .semibold)).foregroundStyle(.white)
                .frame(width: SettingsStyle.icon, height: SettingsStyle.icon)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: SettingsStyle.icon * 0.25, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A row that opens a subpage, with a chevron and hover highlight.
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        let link = RouteLink(destination: destination) {
            SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
                Image(systemName: "chevron.right").font(.system(size: SettingsStyle.chevron, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        #if os(tvOS)
        link
        #else
        link.buttonStyle(SettingsRowStyle())
        #endif
    }
}

#if !os(tvOS)
private struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Highlight(configuration: configuration) }
    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

/// Compact capsule buttons used inside settings groups.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Brand.onAccent : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(prominent ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
#endif

extension View {
    @ViewBuilder func settingsButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        controlButton(prominent: prominent)
        #else
        buttonStyle(SettingsButtonStyle(prominent: prominent))
        #endif
    }
}

struct SettingsField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never).keyboardType(.URL)
            #endif
            .padding(.horizontal, 12).frame(minHeight: SettingsStyle.field)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
    }
}

/// Settings subpages share width, spacing and background.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) { content }
                .frame(maxWidth: Layout.settingsWidth).frame(maxWidth: .infinity)
                .padding(Layout.gutter)
        }
        .screenBackdrop()
        .screenTitle(title, width: Layout.settingsWidth)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var directURL = ""
    @State private var cloudSummary = ""
    private var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        return L10n.text("Version %@", short)
    }
    var body: some View {
        @Bindable var store = store
        SettingsPage(title: L10n.text("Settings")) {
            SettingsGroup(title: L10n.text("Subscription"), footer: store.notice) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsField(prompt: L10n.text("TVBox JSON URL"), text: $store.subscriptionAddress)
                    // One row whenever it fits; stack only when a narrow width or large text needs it.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { subscriptionActions }
                        VStack(alignment: .leading, spacing: 8) { subscriptionActions }
                    }
                }
                .padding(14)
                if let config = store.subscription {
                    SettingsRow(symbol: "checkmark.seal.fill", tint: .green,
                                title: L10n.text("Sources: %lld · Live playlists: %lld", config.sites.count, config.lives.count),
                                subtitle: L10n.text("Last updated %@", config.importedAt.formatted(date: .abbreviated, time: .shortened)))
                }
            }
            #if os(macOS)
            SettingsGroup(title: L10n.text("Accounts")) {
                SettingsLinkRow(symbol: "externaldrive.fill.badge.person.crop", tint: .brown,
                                title: L10n.text("Cloud Drive Accounts"), subtitle: cloudSummary) { CloudDriveView() }
            }
            #endif
            SettingsGroup(title: L10n.text("Playback")) {
                SettingsRow(symbol: "play.fill", tint: Brand.terracotta, title: L10n.text("Play a URL"))
                HStack(spacing: 10) {
                    SettingsField(prompt: L10n.text("HTTP / HTTPS media URL"), text: $directURL)
                    Button(L10n.text("Open Player")) {
                        do { store.playing = Channel(name: L10n.text("URL Playback"), url: try WebAddress.resolve(directURL)) }
                        catch { store.error = error.localizedDescription }
                    }
                    .settingsButton(prominent: true)
                    .disabled(directURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(14)
            }
            SettingsGroup(title: L10n.text("Advanced")) {
                SettingsLinkRow(symbol: "cpu.fill", tint: .orange, title: L10n.text("JAR Runtime and Compatibility")) { RuntimeView() }
                SettingsLinkRow(symbol: "doc.text.magnifyingglass", tint: .gray, title: L10n.text("Diagnostic Logs")) { DiagnosticsView() }
            }
            SettingsGroup(title: L10n.text("About"),
                          footer: L10n.text("Supports TVBox JSON subscriptions, M3U / TXT live playlists, and standard type 1 / type 4 JSON APIs. Media formats depend on the device. Local JavaScript and Python plugins are experimental on Mac, and JAR plugins are experimental on every platform; compatibility varies by source.")) {
                SettingsRow(symbol: "play.tv.fill", tint: .pink, title: L10n.text("Yingxia"),
                            subtitle: [version, Brand.copyright].compactMap { $0 }.joined(separator: " · "))
                SettingsLinkRow(symbol: "doc.plaintext.fill", tint: .gray, title: L10n.text("Open Source Licenses")) { LicensesView() }
            }
        }
        #if os(macOS)
        .task { cloudSummary = CloudProvider.summary() }
        #endif
    }
    @ViewBuilder private var subscriptionActions: some View {
        Button { Task { await store.importSubscription() } } label: {
            HStack(spacing: 6) {
                if store.importing { ProgressView().controlSize(.mini) }
                Text(store.importing ? L10n.text("Importing…") : L10n.text("Save and Refresh"))
                if store.importing { ElapsedTime() }
            }
        }
        .settingsButton(prominent: true)
        .disabled(store.importing || store.subscriptionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button(L10n.text("Use Default URL")) { store.subscriptionAddress = Store.defaultURL }.settingsButton()
    }
}

struct LicensesView: View {
    private var notices: String {
        (Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "DexLoom · MIT License"
    }
    var body: some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Yingxia \(Brand.copyright)").font(.headline)
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel(cornerRadius: 18).focusable()
                ForEach(Array(notices.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.body)
                        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .contentPanel(cornerRadius: 18).focusable()
                }
            }.frame(maxWidth: 1200).frame(maxWidth: .infinity).padding(Layout.gutter)
        }
        .screenBackdrop()
        .screenTitle(L10n.text("Open Source Licenses"))
        #else
        SettingsPage(title: L10n.text("Open Source Licenses")) {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Yingxia \(Brand.copyright)").font(.headline)
                    Link("www.getmegaportal.com", destination: Brand.website).font(.subheadline)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsGroup {
                Text(notices)
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).selectable()
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #endif
    }
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
                    Circle().fill(live ? Brand.accent : .secondary).frame(width: 6, height: 6)
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
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear Search"))
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
    private func levelButton(_ value: String, title: String, count: Int, color: Color) -> some View {
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
                                .buttonStyle(.plain)
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
