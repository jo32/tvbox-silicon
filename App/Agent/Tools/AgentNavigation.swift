import SwiftUI
import TVCore

/// A page the assistant opened (`open_page`, `settings_open`, `novels_open`…): pushed by the stack of `section` once
/// that section is on screen (`agentPages`), as the page's own link would push it.
struct AgentPageRequest: Equatable {
    let id = UUID()
    let section: AppSection
    let route: Route
    static func == (lhs: AgentPageRequest, rhs: AgentPageRequest) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// Pushes the assistant's page requests for the sections `accepts` takes onto this stack.
    func agentPages(accepts: @escaping (AppSection) -> Bool, push: @escaping (Route) -> Void) -> some View {
        modifier(AgentPageFollower(accepts: accepts, push: push))
    }
}

private struct AgentPageFollower: ViewModifier {
    @Environment(Store.self) private var store
    let accepts: (AppSection) -> Bool
    let push: (Route) -> Void
    func body(content: Content) -> some View {
        // `initial`: a tab whose stack is first built for this request (iOS builds a tab's page when it is chosen).
        content.onChange(of: store.agentPage, initial: true) { _, request in
            guard let request, accepts(request.section) else { return }
            store.agentPage = nil
            push(request.route)
        }
    }
}

@MainActor enum AgentNavigator {
    /// The sections in the order the sidebar lists them, by the names the tools use.
    static let names: [(AppSection, String)] = [
        (.home, "watch_now"), (.discover, "discover"), (.live, "live_tv"), (.music, "music"), (.manga, "manga"),
        (.novels, "novels"), (.search, "global_search"), (.sites, "sources"), (.files, "cloud_files"),
        (.history, "history"), (.favorites, "favorites"), (.downloads, "downloads"), (.settings, "settings"),
    ]

    static func name(_ section: AppSection) -> String {
        names.first { $0.0 == section }?.1 ?? (section == .more ? "more" : section.rawValue)
    }

    static func section(named name: String) -> AppSection? { names.first { $0.1 == name }?.0 }

    /// The sections the viewer can open now: what the App Store build hides until a subscription is added (Music),
    /// and Manga and Novels with no source list, stay out.
    static func sections(_ store: Store) -> [AppSection] {
        names.map(\.0).filter { !store.hiddenSections.contains($0) }
    }

    static func open(_ section: AppSection, in store: Store) throws {
        guard sections(store).contains(section) else { throw AgentToolError("\(name(section)) isn't available in this app right now.") }
        store.section = section
    }

    /// Opens `section`, then pushes `route` onto its stack once the section shows.
    static func push(_ route: Route, in section: AppSection, store: Store) async throws {
        let changes = store.section != section
        if changes { try open(section, in: store) }
        // The section's stack first resets for the new section (the Mac's detail column clears its path).
        if changes { try? await Task.sleep(for: .milliseconds(450)) }
        store.agentPage = AgentPageRequest(section: section, route: route)
    }

    /// Where a page opened from the current page goes: the section on screen, or Watch Now from one without a stack.
    static func currentStack(_ store: Store) -> AppSection {
        // The phone's More tab, showing a section kept there: its own stack takes the page.
        if store.section == .more { return .more }
        return sections(store).contains(store.section) ? store.section : .home
    }
}
