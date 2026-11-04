import SwiftUI
import TVCore

/// Which language posters, logos and backdrops come in — and what that choice costs.
///
/// The warning is the point of this page. Choosing anything but "follow metadata" means one extra
/// TMDB image request per title as it scrolls into view, a visible swap from the old poster to the
/// new one, and more traffic and battery. Rex puts that on the settings page rather than in a
/// changelog; this does the same, and only shows it once a choice that costs something is made.
struct ArtworkLanguageView: View {
    @Environment(Store.self) private var store
    @State private var settings = ArtworkLanguage()
    @State private var showsCostWarning = false
    @State private var pendingChange: (() -> Void)?

    var body: some View {
        Form {
            Section {
                picker(L10n.text("Poster Language"), selection: $settings.poster)
                picker(L10n.text("Logo Language"), selection: $settings.logo)
            } footer: {
                Text(L10n.text("Choosing a poster language other than Follow Metadata makes one extra TMDB image request per title when it scrolls into view, and the result is cached on this device. The original poster shows first, then is replaced."))
            }
        }
        .settingsForm(L10n.text("Artwork Language"))
        .task { settings = store.artworkLanguage }
        .onChange(of: settings) { _, new in
            // Warn the first time a costly choice is made, not every time.
            if new.costsExtraRequests, !store.artworkLanguage.costsExtraRequests {
                pendingChange = { store.artworkLanguage = new }
                showsCostWarning = true
            } else {
                store.artworkLanguage = new
            }
        }
        .alert(L10n.text("Extra Requests Warning"), isPresented: $showsCostWarning) {
            Button(L10n.text("Cancel"), role: .cancel) { pendingChange = nil; settings = store.artworkLanguage }
            Button(L10n.text("Continue")) { pendingChange?(); pendingChange = nil }
        } message: {
            Text(L10n.text("Choosing a poster language other than Follow Metadata makes one extra TMDB image request per title when it scrolls into view, and the result is cached on this device. The original poster shows first, then is replaced."))
        }
    }

    @ViewBuilder
    private func picker(_ title: String, selection: Binding<ArtworkLanguage.Choice>) -> some View {
        Picker(title, selection: selection) {
            Text(L10n.text("Follow Metadata")).tag(ArtworkLanguage.Choice.metadata)
            Text(L10n.text("Film's Own Language")).tag(ArtworkLanguage.Choice.original)
            Divider()
            ForEach(ArtworkLanguage.choices, id: \.self) { code in
                Text(Locale.current.localizedString(forIdentifier: code) ?? code)
                    .tag(ArtworkLanguage.Choice.fixed(code))
            }
        }
    }
}
