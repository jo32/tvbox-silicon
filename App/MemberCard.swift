import SwiftUI
import TVCore

/// The card that leads Settings › Account, like a membership card in a wallet: black with gold foil for Pro, midnight
/// blue with silver for everyone else (and always in App Store builds, which never show Pro). It carries the points,
/// the person, and how long Pro lasts, and catches the light once when it appears.
struct MemberCard: View {
    enum Tier: Equatable {
        case member
        /// `until` is nil for life.
        case pro(until: Date?)
    }

    let name: String
    /// "apple", "telegram": the ways this person signs in, as small marks.
    let providers: [String]
    let points: Int
    let tier: Tier
    var memberSince: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheen: CGFloat = -0.7

    private var isPro: Bool { tier != .member }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: Metrics.gap)
            pointsBlock
            Spacer(minLength: Metrics.gap)
            footer
        }
        .padding(Metrics.padding)
        .frame(maxWidth: Metrics.maxWidth, minHeight: Metrics.minHeight)
        // Its own height, never stretched (Apple TV's left column is as tall as the screen).
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .background { background.clipShape(shape) }
        .overlay { sheenLayer.clipShape(shape).allowsHitTesting(false) }
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
        // Only a small lift: a list row cuts any wider glow or shadow off in a hard-edged box around the card.
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            sheen = -0.7
            withAnimation(.easeInOut(duration: 1.9).delay(0.35)) { sheen = 1.4 }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: Metrics.small) {
            AppMark(size: Metrics.mark)
            Text(L10n.text("Yingxia")).font(.system(size: Metrics.brand, weight: .semibold)).tracking(1.5)
            Spacer(minLength: 8)
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        if isPro {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill")
                Text(verbatim: "PRO").tracking(1.6)
            }
            .font(.system(size: Metrics.badge, weight: .heavy))
            .foregroundStyle(MemberCard.ink)
            .padding(.horizontal, Metrics.badge * 0.9).padding(.vertical, Metrics.badge * 0.42)
            .background(MemberCard.gold, in: Capsule())
            .shadow(color: MemberCard.goldGlow.opacity(0.5), radius: 6)
        } else {
            Text(L10n.text("Member"))
                .font(.system(size: Metrics.badge, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, Metrics.badge * 0.9).padding(.vertical, Metrics.badge * 0.42)
                .background(.white.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8) }
        }
    }

    private var pointsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Points")).font(.system(size: Metrics.caption, weight: .medium)).tracking(1)
                .foregroundStyle(.white.opacity(0.6))
            Text(points.formatted())
                .font(.system(size: Metrics.points, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(isPro ? AnyShapeStyle(MemberCard.gold) : AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom)))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            HStack(spacing: Metrics.small) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: Metrics.name, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 7) {
                        ForEach(providers, id: \.self) { provider in
                            Image(systemName: provider == "apple" ? "apple.logo" : "paperplane.fill")
                        }
                    }
                    .font(.system(size: Metrics.caption))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if let status {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(status.caption).font(.system(size: Metrics.caption, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    Text(status.value).font(.system(size: Metrics.value, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(isPro ? AnyShapeStyle(MemberCard.gold) : AnyShapeStyle(.white))
                }
                .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    private var status: (caption: String, value: String)? {
        switch tier {
        case .pro(let until?): (L10n.text("Valid Until"), until.formatted(.dateTime.year().month().day()))
        case .pro(.none): (L10n.text("Yingxia Pro"), L10n.text("Lifetime"))
        case .member: memberSince.map { (L10n.text("Member Since"), $0.formatted(.dateTime.year().month())) }
        }
    }

    private var avatar: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
        return Text(initial)
            .font(.system(size: Metrics.avatar * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(isPro ? MemberCard.ink : .white)
            .frame(width: Metrics.avatar, height: Metrics.avatar)
            .background {
                Circle().fill(isPro ? AnyShapeStyle(MemberCard.gold)
                              : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 1), Color(red: 0.25, green: 0.78, blue: 0.95)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
    }

    // MARK: Surface

    /// The light in the card's top corner.
    private var glow: Color { isPro ? MemberCard.goldGlow : Color(red: 0.32, green: 0.48, blue: 1) }

    private var background: some View {
        ZStack {
            LinearGradient(colors: isPro
                           ? [Color(red: 0.16, green: 0.14, blue: 0.11), Color(red: 0.05, green: 0.045, blue: 0.04)]
                           : [Color(red: 0.15, green: 0.21, blue: 0.47), Color(red: 0.05, green: 0.07, blue: 0.19)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [glow.opacity(isPro ? 0.38 : 0.5), .clear], center: .topTrailing, startRadius: 0, endRadius: Metrics.maxWidth * 0.75)
            // Fine engraved rings, like the guilloche on a banknote, rising from the lower right.
            Canvas { context, size in
                let center = CGPoint(x: size.width * 1.02, y: size.height * 1.18)
                for ring in 0..<22 {
                    let radius = size.height * (0.3 + Double(ring) * 0.07)
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color((isPro ? MemberCard.goldGlow : .white).opacity(ring.isMultiple(of: 2) ? 0.11 : 0.06)),
                                   lineWidth: 0.7)
                }
            }
        }
    }

    private var border: LinearGradient {
        LinearGradient(colors: isPro
                       ? [MemberCard.goldGlow.opacity(0.85), MemberCard.goldGlow.opacity(0.12), MemberCard.goldGlow.opacity(0.55)]
                       : [.white.opacity(0.32), .white.opacity(0.05), .white.opacity(0.2)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var sheenLayer: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(isPro ? 0.26 : 0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.32, height: proxy.size.height * 2.2)
                .rotationEffect(.degrees(20))
                .offset(x: sheen * proxy.size.width, y: -proxy.size.height * 0.6)
        }
    }

    // MARK: Colours and sizes

    /// Gold foil: light and dark bands, so it reads as metal rather than yellow.
    static let gold = LinearGradient(colors: [Color(red: 0.99, green: 0.91, blue: 0.67), Color(red: 0.85, green: 0.67, blue: 0.31),
                                              Color(red: 0.98, green: 0.86, blue: 0.57), Color(red: 0.73, green: 0.53, blue: 0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let goldGlow = Color(red: 0.88, green: 0.69, blue: 0.33)
    /// Text on gold.
    static let ink = Color(red: 0.17, green: 0.12, blue: 0.04)

    private enum Metrics {
        #if os(tvOS)
        static let maxWidth: CGFloat = 540, minHeight: CGFloat = 330, radius: CGFloat = 34, padding: CGFloat = 34, gap: CGFloat = 18
        static let mark: CGFloat = 46, brand: CGFloat = 28, badge: CGFloat = 20, caption: CGFloat = 20, points: CGFloat = 76
        static let name: CGFloat = 28, value: CGFloat = 26, avatar: CGFloat = 60, small: CGFloat = 14
        #else
        static let maxWidth: CGFloat = 440, minHeight: CGFloat = 214, radius: CGFloat = 24, padding: CGFloat = 20, gap: CGFloat = 12
        static let mark: CGFloat = 28, brand: CGFloat = 16, badge: CGFloat = 12, caption: CGFloat = 12, points: CGFloat = 46
        static let name: CGFloat = 17, value: CGFloat = 15, avatar: CGFloat = 40, small: CGFloat = 10
        #endif
    }
}

/// One way to earn points, as a tile: what it gave so far, large, then the rule. The tiles of a row share one height.
struct EarnTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let earned: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: Circle())
                Spacer(minLength: 6)
                Text(verbatim: earned > 0 ? "+\(earned.formatted())" : earned.formatted())
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(earned > 0 ? tint : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.bottom, 4)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            // "rule · count": the rule, then how often it was earned on a line of its own, so neither breaks mid-phrase.
            let parts = detail.components(separatedBy: " · ")
            VStack(alignment: .leading, spacing: 1) {
                Text(parts[0]).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                if parts.count > 1 { Text(parts.dropFirst().joined(separator: " · ")).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsStyle.rowFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A short status in a tinted capsule, at the end of a row.
struct StatusPill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 5)
            #else
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            #endif
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Gold, for the one button on the page that brings Pro.
struct GoldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(MemberCard.ink)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(MemberCard.gold, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

enum AccountColors {
    static let telegram = Color(red: 0x22 / 255, green: 0x9E / 255, blue: 0xD9 / 255)
}
