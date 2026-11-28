import SwiftUI
import TVCore

/// Sizes that differ by platform: the TV is read from across the room, at the app's fixed TV sizes.
enum AssistantMetrics {
    #if os(tvOS)
    static let gutter: CGFloat = 0, spacing: CGFloat = 26, bubbleRadius: CGFloat = 30, bubbleInset: CGFloat = 24
    static let body = Font.system(size: 29), detail = Font.system(size: 23), code = Font.system(size: 22, design: .monospaced)
    #elseif os(macOS)
    static let gutter: CGFloat = 16, spacing: CGFloat = 14, bubbleRadius: CGFloat = 16, bubbleInset: CGFloat = 12
    static let body = Font.body, detail = Font.callout, code = Font.system(.caption, design: .monospaced)
    #else
    static let gutter: CGFloat = 16, spacing: CGFloat = 16, bubbleRadius: CGFloat = 20, bubbleInset: CGFloat = 14
    static let body = Font.body, detail = Font.footnote, code = Font.system(.caption, design: .monospaced)
    #endif
}

/// The chat: the conversation, what the assistant is doing, its questions, and the box to write in. The iPhone's
/// full-height panel, the iPad's and Mac's trailing panel; Apple TV lays the same pieces out as a page
/// (`AssistantTVPage`).
struct AssistantPanel: View {
    @Environment(AssistantController.self) private var assistant
    /// A close button in the header (iPhone, iPad, Mac).
    var closes = true
    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            AssistantHeader(closes: closes)
            Divider().opacity(0.5)
            AssistantTranscript()
            AssistantComposer()
        }
        .background { Backdrop() }
        #if !os(tvOS)
        .sheet(isPresented: $assistant.showsSettings, onDismiss: { assistant.prepare() }) {
            NavigationStack {
                AssistantSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { assistant.showsSettings = false } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        #endif
    }
}

private struct AssistantHeader: View {
    @Environment(AssistantController.self) private var assistant
    let closes: Bool
    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(L10n.text("Assistant")).font(.headline)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Brand.cyan)
            }
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Menu {
                Button(role: .destructive) { assistant.clear() } label: { Label(L10n.text("Clear Conversation"), systemImage: "trash") }
                    .disabled(assistant.messages.isEmpty)
                Button { assistant.showsSettings = true } label: { Label(L10n.text("Assistant Settings"), systemImage: "gearshape") }
            } label: {
                headerIcon("ellipsis")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text("More"))
            if closes {
                Button { assistant.setOpen(false) } label: { headerIcon("xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Close Assistant"))
                    #if os(macOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
            }
        }
        .padding(.horizontal, AssistantMetrics.gutter)
        .padding(.vertical, 10)
    }

    private func headerIcon(_ name: String) -> some View {
        #if os(macOS)
        let size: CGFloat = 28
        #else
        let size: CGFloat = 36
        #endif
        return Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .glassSurface(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }
}

// MARK: Transcript

/// One line of the conversation as it is drawn.
private enum TranscriptItem: Identifiable {
    case user(AgentMessage)
    case text(id: String, String)
    case tool(AgentToolCall, result: String?, running: Bool)
    var id: String {
        switch self {
        case .user(let message): "user \(message.id)"
        case .text(let id, _): "text \(id)"
        case .tool(let call, _, _): "tool \(call.id)"
        }
    }
}

struct AssistantTranscript: View {
    @Environment(AssistantController.self) private var assistant
    private static let bottom = "assistant.bottom"

    private var items: [TranscriptItem] {
        let messages = assistant.messages
        let results = Dictionary(messages.compactMap { message in message.toolCallID.map { ($0, message.text) } }, uniquingKeysWith: { $1 })
        let running = assistant.runningTool
        var items: [TranscriptItem] = []
        for message in messages {
            switch message.role {
            case .user: items.append(.user(message))
            case .assistant:
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(.text(id: message.id.uuidString, message.text)) }
                for call in message.toolCalls { items.append(.tool(call, result: results[call.id], running: running?.id == call.id)) }
            case .tool: break
            }
        }
        if let running, !items.contains(where: { $0.id == "tool \(running.id)" }) {
            items.append(.tool(running, result: nil, running: true))
        }
        return items
    }

    var body: some View {
        if !assistant.isReady {
            AssistantSetupState()
        } else if assistant.messages.isEmpty && assistant.streamingText.isEmpty && !assistant.isRunning {
            AssistantEmptyState()
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AssistantMetrics.spacing) {
                    ForEach(items) { item in
                        switch item {
                        case .user(let message): AssistantUserBubble(text: message.text)
                        case .text(_, let text): AssistantAnswer(text: text)
                        case .tool(let call, let result, let running): AssistantToolRow(call: call, result: result, running: running)
                        }
                    }
                    if !assistant.streamingText.isEmpty {
                        AssistantAnswer(text: assistant.streamingText, streaming: true)
                    } else if assistant.isRunning, assistant.runningTool == nil, assistant.pendingConfirmation == nil {
                        AssistantThinking()
                    }
                    if let confirmation = assistant.pendingConfirmation {
                        AssistantConfirmationCard(confirmation: confirmation)
                    }
                    if let failure = assistant.failure {
                        AssistantFailureBanner(failure: failure)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, AssistantMetrics.gutter)
                .padding(.vertical, AssistantMetrics.spacing)
                #if os(tvOS)
                .glassRowInsets()
                #endif
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .onChange(of: assistant.messages.count) { scrollDown(proxy) }
            .onChange(of: assistant.streamingText.count / 40) { scrollDown(proxy, animated: false) }
            .onChange(of: assistant.pendingConfirmation?.id) { scrollDown(proxy) }
            .onChange(of: assistant.failure != nil) { scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .easeOut(duration: 0.25) : nil) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
    }
}

/// The viewer's words, in a bubble at the trailing edge.
private struct AssistantUserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(AssistantMetrics.body)
                .foregroundStyle(bubbleText)
                .selectable()
                .padding(.horizontal, AssistantMetrics.bubbleInset).padding(.vertical, AssistantMetrics.bubbleInset * 0.7)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: AssistantMetrics.bubbleRadius, style: .continuous))
                .tvFocusableMessage()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("You: %@", text))
    }
    private var bubbleFill: Color {
        #if os(tvOS)
        .white.opacity(0.16)
        #else
        systemAccent
        #endif
    }
    private var bubbleText: Color {
        #if os(tvOS)
        .primary
        #else
        .white
        #endif
    }
}

/// The assistant's words, Markdown drawn: paragraphs, lists, headings and code.
struct AssistantAnswer: View {
    let text: String
    var streaming = false
    var body: some View {
        let blocks = AssistantMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                AssistantBlockView(block: block, cursor: streaming && index == blocks.count - 1)
            }
        }
        .font(AssistantMetrics.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectable()
        .tvFocusableMessage()
        .accessibilityElement(children: .combine)
    }
}

private struct AssistantBlockView: View {
    let block: AssistantMarkdown.Block
    let cursor: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        switch block {
        case .paragraph(let text): line(text)
        case .heading(let text): line(text).font(AssistantMetrics.body.weight(.semibold))
        case .bullet(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                line(text)
            }
        case .code(let code):
            Text(code + (cursor ? " ▍" : ""))
                .font(AssistantMetrics.code)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder private func line(_ text: String) -> some View {
        let words = Text(AssistantMarkdown.inline(text))
        if cursor {
            // A soft caret after the last word while the answer arrives; steady with Reduce Motion.
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                words + Text(" ▍").foregroundStyle(Brand.cyan.opacity(on ? 0.8 : 0.2))
            }
        } else {
            words
        }
    }
}

/// Three dots while the model thinks, before any words.
private struct AssistantThinking: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .opacity(reduceMotion || index == step ? 0.9 : 0.3)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Thinking…"))
    }
}

/// A tool the assistant used: a line saying what it did, opening to the call's arguments and result.
private struct AssistantToolRow: View {
    let call: AgentToolCall
    let result: String?
    let running: Bool
    @State private var expanded = false
    var body: some View {
        let activity = AssistantActivity(call)
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Group {
                        if running { ProgressView().appControlSize(.mini) } else { Image(systemName: activity.symbol) }
                    }
                    .frame(width: 18)
                    Text(running ? activity.running : activity.done).lineLimit(2).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .font(AssistantMetrics.detail)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .glassRow()
            .accessibilityLabel(running ? activity.running : activity.done)
            .accessibilityHint(L10n.text(expanded ? "Hides the details" : "Shows the details"))
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    detail(L10n.text("Request"), AssistantActivity.pretty(call.arguments))
                    if let result { detail(L10n.text("Result"), AssistantActivity.pretty(result)) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AssistantMetrics.detail.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(AssistantMetrics.code).lineLimit(40).selectable()
        }
    }
}

/// The assistant wants to change something: what, and the viewer's yes or no.
private struct AssistantConfirmationCard: View {
    @Environment(AssistantController.self) private var assistant
    let confirmation: AgentConfirmation
    var body: some View {
        let destructive = confirmation.effect == .destructive
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .foregroundStyle(destructive ? Brand.rose : Brand.amber)
                Text(confirmation.summary).font(AssistantMetrics.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = confirmation.detail, !detail.isEmpty {
                AssistantDiff(text: detail)
            }
            HStack(spacing: 10) {
                Button { assistant.confirm(false) } label: { Text(L10n.text("Don't Allow")).frame(maxWidth: .infinity) }
                    .controlButton()
                #if os(tvOS)
                Button { assistant.confirm(true) } label: { Text(L10n.text("Allow")).frame(maxWidth: .infinity) }
                    .controlButton()
                #else
                // Filled like the system's own default button: red when it can't easily be undone.
                Button { assistant.confirm(true) } label: {
                    Text(L10n.text("Allow")).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(destructive ? Color.red : systemAccent))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressFade())
                #endif
            }
            .tvFocusSection()
        }
        .padding(AssistantMetrics.bubbleInset + 2)
        .contentPanel(cornerRadius: AssistantMetrics.bubbleRadius)
        .overlay {
            RoundedRectangle(cornerRadius: max(AssistantMetrics.bubbleRadius, 14), style: .continuous)
                .strokeBorder((destructive ? Brand.rose : Brand.amber).opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A diff or a value change, in monospace with added lines green and removed lines red.
private struct AssistantDiff: View {
    let text: String
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(fill(line))
                }
            }
            .font(AssistantMetrics.code)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(text)
    }
    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        return .primary
    }
    private func fill(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.16) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.16) }
        return .clear
    }
}

/// Why the last answer didn't come, and what to do about it.
private struct AssistantFailureBanner: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(\.openURL) private var openURL
    let failure: AgentFailure
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Brand.amber)
                Text(failure.message).font(AssistantMetrics.detail).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action: action.run) { Label(action.title, systemImage: action.symbol) }
                    .controlButton()
                    .appControlSize(.small)
            }
        }
        .padding(AssistantMetrics.bubbleInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: AssistantMetrics.bubbleRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch failure.kind {
        case .network: "wifi.exclamationmark"
        case .usageLimit: "gauge.with.dots.needle.100percent"
        case .notSignedIn, .unauthorized: "person.crop.circle.badge.exclamationmark"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var action: (title: String, symbol: String, run: () -> Void)? {
        switch failure.kind {
        case .notSignedIn, .unauthorized:
            return (L10n.text("Sign In Again"), "person.crop.circle", { assistant.showsSettings = true })
        case .usageLimit:
            #if os(tvOS)
            return nil
            #else
            return (L10n.text("Open Usage Page"), "arrow.up.right", { openURL(Self.usage) })
            #endif
        case .unsupported:
            return (L10n.text("Assistant Settings"), "gearshape", { assistant.showsSettings = true })
        case .cancelled:
            return nil
        case .unavailable, .network, .server, .invalidResponse:
            return (L10n.text("Try Again"), "arrow.clockwise", { assistant.retry() })
        }
    }
}

// MARK: Empty and setup states

/// Before the first message: what the assistant can do, and a few things to ask.
struct AssistantEmptyState: View {
    @Environment(AssistantController.self) private var assistant
    static var suggestions: [String] {
        [L10n.text("Find the playback speed setting"), L10n.text("Search 庆余年"), L10n.text("What's playing?"), L10n.text("Fix my Python source")]
    }
    var body: some View {
        ScrollView {
            VStack(spacing: AssistantMetrics.spacing) {
                AssistantBadge()
                VStack(spacing: 6) {
                    Text(L10n.text("How can I help?")).font(titleFont).multilineTextAlignment(.center)
                    Text(L10n.text("Ask me to find a setting, search and play, or fix a source. I change things only after you allow it."))
                        .font(AssistantMetrics.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AssistantFlow(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button { assistant.send(suggestion) } label: {
                            Text(suggestion).font(AssistantMetrics.detail).lineLimit(2)
                                #if !os(tvOS)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .glassSurface(.regular.interactive(), in: Capsule())
                                #endif
                        }
                        #if os(tvOS)
                        .controlButton()
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, AssistantMetrics.gutter + 8)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 44, weight: .bold)
        #else
        .title2.weight(.bold)
        #endif
    }
}

/// On but not connected: where to set it up.
private struct AssistantSetupState: View {
    @Environment(AssistantController.self) private var assistant
    var body: some View {
        VStack(spacing: AssistantMetrics.spacing) {
            AssistantBadge()
            Text(L10n.text("Set Up the Assistant")).font(.title3.weight(.bold))
            Text(assistant.setupProblem ?? L10n.text("Choose how the assistant connects to a model in Settings › Assistant."))
                .font(AssistantMetrics.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { assistant.showsSettings = true } label: { Label(L10n.text("Assistant Settings"), systemImage: "gearshape") }
                .controlButton(prominent: true)
        }
        .padding(.horizontal, AssistantMetrics.gutter + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The assistant's mark: sparkles on a soft circle in the icon's cyan.
struct AssistantBadge: View {
    var size: CGFloat = {
        #if os(tvOS)
        120
        #else
        64
        #endif
    }()
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Brand.cyan)
            .frame(width: size, height: size)
            .background(Brand.cyan.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: Composer

struct AssistantComposer: View {
    @Environment(AssistantController.self) private var assistant
    @FocusState private var focused: Bool
    var body: some View {
        @Bindable var assistant = assistant
        let canSend = !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 8) {
            field($assistant.draft)
            Button {
                if assistant.isRunning { assistant.stop() } else { assistant.send(); focused = false }
            } label: {
                sendIcon(running: assistant.isRunning, enabled: canSend)
            }
            #if os(tvOS)
            .controlButton()
            #else
            .buttonStyle(.plain)
            #endif
            .disabled(!assistant.isReady || (!assistant.isRunning && !canSend))
            .accessibilityLabel(L10n.text(assistant.isRunning ? "Stop" : "Send"))
            #if os(macOS)
            .keyboardShortcut(assistant.isRunning ? KeyboardShortcut(".", modifiers: .command) : KeyboardShortcut(.return, modifiers: .command))
            #endif
        }
        .padding(.horizontal, AssistantMetrics.gutter)
        .padding(.top, 8).padding(.bottom, 10)
    }

    @ViewBuilder private func field(_ text: Binding<String>) -> some View {
        #if os(tvOS)
        // Selecting it opens the system keyboard, where the remote's microphone dictates.
        TextField(L10n.text("Ask the assistant"), text: text)
            .font(AssistantMetrics.body)
            .onSubmit { assistant.send() }
            .disabled(!assistant.isReady)
        #else
        TextField(L10n.text("Ask the assistant"), text: text, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(AssistantMetrics.body)
            .focused($focused)
            .onSubmit { assistant.send() }
            .disabled(!assistant.isReady)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(minHeight: 38)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
            }
            .accessibilityIdentifier("assistant.field")
        #endif
    }

    @ViewBuilder private func sendIcon(running: Bool, enabled: Bool) -> some View {
        let name = running ? "stop.fill" : "arrow.up"
        #if os(tvOS)
        Image(systemName: name).font(.system(size: 30, weight: .semibold))
        #else
        Image(systemName: name)
            .font(.system(size: running ? 13 : 16, weight: .bold))
            .foregroundStyle(running || enabled ? Color.white : Color.secondary)
            .frame(width: 38, height: 38)
            .background(Circle().fill(running || enabled ? systemAccent : Color.primary.opacity(0.1)))
            .contentShape(Circle())
        #endif
    }
}

// MARK: Pieces

/// Lays its children out in rows, wrapping as text does, centred.
struct AssistantFlow: SwiftUI.Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty { rows.append(row); row = Row() }
            row.width = row.indices.isEmpty ? min(size.width, width) : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

extension View {
    /// Apple TV: a message takes focus, so the remote can move through the conversation and scroll it.
    @ViewBuilder func tvFocusableMessage() -> some View {
        #if os(tvOS)
        Button {} label: { self.padding(16) }.panelCardButton(cornerRadius: 26).padding(-16)
        #else
        self
        #endif
    }
}

/// Just enough Markdown for chat answers: paragraphs, headings, bullet and numbered lists and fenced code, with
/// inline emphasis, code and links from `AttributedString(markdown:)`.
enum AssistantMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case bullet(marker: String, String)
        case code(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(marker: "•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(marker: String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence while the answer streams is still code.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A label that fades a little while pressed.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
