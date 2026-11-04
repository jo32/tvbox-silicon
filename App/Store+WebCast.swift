import SwiftUI
import TVCore

/// Store as the Web Cast data source: it lists the same sources the app shows (every enabled
/// subscription plus the built-ins, in display order) and builds a ready `CatalogClient` for any of
/// them, so the web UI can browse, search and play *any* source the app can run.
extension Store: WebCastDataSource {
    func webCastState() async -> WebCastState {
        guard let config = subscription else {
            return WebCastState(sources: [], enabled: WebCastSettings.shared.enabled, port: WebCastSettings.shared.port)
        }
        let origin = config.origin
        let sources = sourceGroups(includeHidden: true).flatMap(\.sites).map { site -> WebCastState.SourceInfo in
            let isHidden = hiddenSources.contains(site, origin: origin) || !vault.permits(site: site, fallback: origin)
            return WebCastState.SourceInfo(key: site.sourceKey, name: site.name,
                                           runtime: site.compatibility, hidden: isHidden)
        }
        return WebCastState(sources: sources, enabled: WebCastSettings.shared.enabled, port: WebCastSettings.shared.port)
    }

    func webCastClient(for sourceKey: String) async throws -> (CatalogClient, siteName: String) {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.sourceKey == sourceKey }) else {
            throw TVError.unsupported(L10n.text("This source is no longer available."))
        }
        let resolved = resolvedSite(site, origin: config.origin)
        let client = CatalogClient(site: resolved, origin: config.origin, jarURL: config.spiderURL).applying(config)
        return (client, site.name)
    }

    /// Applies a settings edit from the web UI (hide/show a source).
    func webCastSetHidden(_ key: String, hidden: Bool) {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.sourceKey == key }) else { return }
        if hidden { hiddenSources.insert(site, origin: config.origin) }
        else { hiddenSources.toggle(site, origin: config.origin) }
    }
}
