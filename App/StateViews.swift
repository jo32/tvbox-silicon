import SwiftUI
import TVCore

// Pages with nothing to show and pages that failed share one look: the symbol on a Liquid Glass disc, what happened,
// glass buttons for the ways forward, and the raw error on demand. No card around them.

/// What a page state is about; it picks its symbol's colours.
enum StateTone {
    /// Nothing here yet, or nothing matched.
    case neutral
    /// Something failed.
    case problem

    /// The faint tint of the glass disc.
    fileprivate var tint: Color {
        switch self {
        case .neutral: Brand.cyan
        case .problem: Brand.amber
        }
    }
    /// The symbol's colour, deep enough to read on light glass.
    fileprivate var ink: Color {
        switch self {
        case .neutral: Color(light: Color(red: 0.20, green: 0.36, blue: 0.88), dark: Color(red: 0.62, green: 0.84, blue: 1.0))
        case .problem: Color(light: Color(red: 0.88, green: 0.38, blue: 0.14), dark: Brand.amber)
        }
    }
    /// Symbols that warn mark a failure, so call sites that only pass a symbol get the right colours.
    static func inferred(from symbol: String) -> StateTone { symbol.contains("exclamationmark") || symbol.contains("slash") ? .problem : .neutral }
}

/// A symbol on a Liquid Glass disc tinted with the tone's colour.
struct StateArt: View {
    let symbol: String
    var tone = StateTone.neutral
    var size: CGFloat = 76
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tone.ink)
            .frame(width: size, height: size)
            .glassSurface(.regular.tint(tone.tint.opacity(0.08)), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The shared layout of every empty and error state. Pages use `EmptyPage`, `EmptyResults` and `ErrorState`.
struct StateMessage<Actions: View, Footer: View>: View {
    enum Scale { case page, section }
    let symbol: String
    let title: String
    var message: String?
    var tone = StateTone.neutral
    var scale = Scale.section
    /// The raw error, shown under the actions on demand.
    var details: String?
    var hasActions = true
    @ViewBuilder var actions: Actions
    @ViewBuilder var footer: Footer
    #if DEBUG
    /// `-qaErrorDetails 1` opens the details, for screenshots.
    @State private var showsDetails = UserDefaults.standard.bool(forKey: "qaErrorDetails")
    #else
    @State private var showsDetails = false
    #endif
    @State private var detailsHeight: CGFloat = 0

    #if os(tvOS)
    private var art: CGFloat { scale == .page ? 150 : 110 }
    private var titleSize: CGFloat { scale == .page ? 46 : 38 }
    private var text: CGFloat { scale == .page ? 28 : 26 }
    private var spacing: CGFloat { scale == .page ? 30 : 24 }
    private let width: CGFloat = 940, detailsWidth: CGFloat = 900, detailsLimit: CGFloat = 240
    #else
    private var art: CGFloat { scale == .page ? 96 : 76 }
    private var titleSize: CGFloat { scale == .page ? 24 : 20 }
    private let text: CGFloat = 15
    private var spacing: CGFloat { scale == .page ? 20 : 16 }
    private let width: CGFloat = 420, detailsWidth: CGFloat = 560, detailsLimit: CGFloat = 180
    #endif

    var body: some View {
        VStack(spacing: spacing) {
            StateArt(symbol: symbol, tone: tone, size: art).padding(.bottom, spacing * 0.35)
            VStack(spacing: spacing * 0.4) {
                Text(title).font(.system(size: titleSize, weight: scale == .page ? .bold : .semibold))
                // No vertical fixedSize: on the Mac it made the page's minimum height that of the
                // message wrapped at zero width, which stretched the split view past the window.
                if let message { Text(message).font(.system(size: text)).foregroundStyle(.secondary).selectable() }
            }
            .multilineTextAlignment(.center).frame(maxWidth: width)
            if hasActions {
                GlassGroup(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions }
                        VStack(spacing: 12) { actions }
                    }
                }
                .padding(.top, spacing * 0.35)
            }
            if let details, !details.isEmpty { disclosure(details) }
            footer.font(.system(size: text * 0.8)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .onChange(of: details) { showsDetails = false }
    }

    private func disclosure(_ details: String) -> some View {
        VStack(spacing: 12) {
            Button { withAnimation(.smooth(duration: 0.25)) { showsDetails.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(L10n.text(showsDetails ? "Hide details" : "Show details"))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).rotationEffect(.degrees(showsDetails ? 180 : 0))
                }
                #if !os(tvOS)
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassSurface(.regular.interactive(), in: Capsule()).contentShape(Capsule())
                #endif
            }
            #if os(tvOS)
            .controlButton()
            #else
            .buttonStyle(.plain)
            #endif
            if showsDetails {
                // As tall as the error, up to a limit; a long trace scrolls.
                ScrollView {
                    Text(details).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .selectable().padding(16)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(height: min(max(detailsHeight, 48), detailsLimit))
                .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: detailsWidth)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }
}

/// A page with nothing in it yet: a symbol, what the page is for, and one way forward. The button is
/// also the remote's focus target; a tvOS page with nothing to focus strands it.
struct EmptyPage<Footer: View>: View {
    let symbol: String
    let title: String
    let message: String
    let action: String
    let actionSymbol: String
    let perform: () -> Void
    @ViewBuilder var footer: Footer
    var body: some View {
        StateMessage(symbol: symbol, title: title, message: message, scale: .page) {
            Button(action: perform) { Label(action, systemImage: actionSymbol).padding(.horizontal, 8) }
                .controlButton(prominent: true).appControlSize(.large)
        } footer: { footer }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyPage where Footer == EmptyView {
    init(symbol: String, title: String, message: String, action: String, actionSymbol: String, perform: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, message: message, action: action, actionSymbol: actionSymbol, perform: perform) { EmptyView() }
    }
}

/// Nothing to list under a page's header or filters, centred in the width below them and sized for the screen,
/// with an optional way out. A bare ContentUnavailableView hugged the leading edge of leading stacks, and on
/// tvOS left the remote nothing to focus under the filters.
struct EmptyResults<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String?
    /// Nil takes it from the symbol: one that warns is a failure.
    var tone: StateTone?
    /// Centred in the page's height too, for a page that shows nothing else.
    var fills = false
    var hasActions = true
    @ViewBuilder var actions: Actions
    #if os(tvOS)
    private let inset: CGFloat = 60
    #else
    private let inset: CGFloat = 40
    #endif
    var body: some View {
        StateMessage(symbol: symbol, title: title, message: message, tone: tone ?? .inferred(from: symbol), hasActions: hasActions) {
            actions
        } footer: { EmptyView() }
        .padding(.vertical, inset).padding(.horizontal, Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
        // Down from filters at the leading edge reaches the centred button.
        .tvFocusSection()
        .accessibilityElement(children: .contain)
    }
}

extension EmptyResults where Actions == AnyView {
    /// One optional button.
    init(symbol: String, title: String, message: String? = nil, action: String? = nil, actionSymbol: String = "arrow.clockwise",
         tone: StateTone? = nil, fills: Bool = false, perform: (() -> Void)? = nil) {
        let button = action.flatMap { action in perform.map { perform in
            AnyView(Button(action: perform) { Label(action, systemImage: actionSymbol).padding(.horizontal, 8) }.controlButton())
        } }
        self.init(symbol: symbol, title: title, message: message, tone: tone, fills: fills, hasActions: button != nil) { button ?? AnyView(EmptyView()) }
    }
}

/// A page or list that failed to load: what went wrong in plain words, the ways forward, and the raw error on demand.
struct ErrorState: View {
    let title: String
    let message: String
    let details: String
    var symbol = "exclamationmark.triangle.fill"
    var retry: (() -> Void)?
    var goBack: (() -> Void)?
    var busy = false
    var backTitle = L10n.text("Back to sources")

    var body: some View {
        StateMessage(symbol: symbol, title: title, message: message, tone: .problem, details: details, hasActions: retry != nil || goBack != nil) {
            if let retry {
                Button(action: retry) { Label(L10n.text("Retry"), systemImage: "arrow.clockwise").padding(.horizontal, 12) }
                    .controlButton(prominent: true).disabled(busy)
            }
            if let goBack {
                Button(action: goBack) { Text(backTitle).padding(.horizontal, 8) }.controlButton()
            }
        } footer: { EmptyView() }
        .appControlSize(.large)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyResults where Actions == AnyView {
    /// A search that found nothing.
    static func search(_ query: String) -> EmptyResults {
        EmptyResults(symbol: "magnifyingglass", title: L10n.text("No Results"), message: L10n.text("Try another keyword."))
    }
}

/// The name open branches still use.
typealias ErrorStateCard = ErrorState
