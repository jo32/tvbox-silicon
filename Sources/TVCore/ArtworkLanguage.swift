import Foundation

/// Which language a poster, logo or backdrop should be in, and what that choice costs.
///
/// TMDB keeps artwork in many languages. Asking for all of it is one request; getting the right one
/// onto the screen costs another, per title, because the language is chosen by inspecting the
/// image list rather than by asking for it directly.
///
/// Rex is unusually honest about this (`settings.aggregated.posterLanguage.cost.message`): choosing
/// anything other than "follow the metadata language" means an extra TMDB image request per title,
/// the old poster shows first and is then replaced, and both traffic and battery go up. Its settings
/// page says so before the viewer commits. This type exists so 映匣 can say the same thing rather
/// than silently spending the requests.
///
/// Two modes matter:
///
/// * **Metadata** — whatever language the title's own text is in. Free: the request already
///   happened, and TMDB returns the default artwork with it.
/// * **Original** — the film's own language, so a Japanese film gets a Japanese logo even when the
///   viewer reads Chinese. This is what makes a shelf look right rather than merely legible, and it
///   is the one that costs a request per title.
public struct ArtworkLanguage: Codable, Hashable, Sendable {

    /// What the viewer chose.
    public enum Choice: Codable, Hashable, Sendable {
        /// Follow the metadata language. No extra requests.
        case metadata
        /// Follow the title's original language, falling back to the metadata language.
        case original
        /// One fixed language, whatever the title.
        case fixed(String)

        public var code: String? {
            if case let .fixed(code) = self { return code }
            return nil
        }
    }

    public var poster: Choice
    public var backdrop: Choice
    public var logo: Choice

    public init(poster: Choice = .metadata, backdrop: Choice = .metadata, logo: Choice = .original) {
        self.poster = poster
        self.backdrop = backdrop
        self.logo = logo
    }

    /// True when any choice will cost an extra request per title.
    ///
    /// The settings page uses this to decide whether to show the warning, which is the whole point:
    /// the cost is invisible until it is described.
    public var costsExtraRequests: Bool {
        [poster, backdrop, logo].contains { choice in
            switch choice {
            case .metadata: return false
            case .original, .fixed: return true
            }
        }
    }

    /// The language to ask TMDB for, given what the title says about itself.
    ///
    /// `original` resolves per title: a Japanese film asks for `ja`, a Korean drama for `ko`. When
    /// the title does not know its own language the metadata language is used, which is why the
    /// fallback is not an error path.
    public func language(for choice: Choice,
                         originalLanguage: String?,
                         metadataLanguage: String) -> String {
        switch choice {
        case .metadata:
            return metadataLanguage
        case .original:
            guard let original = originalLanguage, !original.isEmpty else { return metadataLanguage }
            return original
        case let .fixed(code):
            return code.isEmpty ? metadataLanguage : code
        }
    }

    /// Picks one image from a TMDB-style list for a given language.
    ///
    /// TMDB returns every language at once. The wanted one is chosen here, and when it is absent the
    /// better-tagged, higher-voted image wins — TMDB's own `vote_average` plus the ISO 639-1 tag on
    /// the image. Falling back to "first in the list" would put a random low-quality asset on screen.
    public func bestImage<T>(_ images: [T],
                             language: String,
                             languageOf: (T) -> String?,
                             scoreOf: (T) -> Double?,
                             widthOf: (T) -> Int?) -> T? {
        guard !images.isEmpty else { return nil }
        let wanted = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()

        let exact = images.filter { (languageOf($0) ?? "").lowercased() == wanted }
        let pool = exact.isEmpty ? images : exact

        return pool.max { lhs, rhs in
            let ls = scoreOf(lhs) ?? 0, rs = scoreOf(rhs) ?? 0
            if ls != rs { return ls < rs }
            // Same vote: prefer the larger image, which survives a big screen.
            return (widthOf(lhs) ?? 0) < (widthOf(rhs) ?? 0)
        }
    }

    /// The languages the settings page offers, matching the app's own localisations.
    public static let choices: [String] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar",
    ]
}

// MARK: - Choosing from what TMDB carries

extension ArtworkLanguage {
    /// The artwork to show, given the viewer's choice and everything TMDB keeps.
    ///
    /// TMDB parents a language's assets with a tag, and the plain `poster` field on details is
    /// whatever it picked for the language *the request asked in* — which is the metadata language,
    /// not the artwork language. So a viewer who chose "the film's own language" still gets the
    /// metadata-language poster unless this runs.
    ///
    /// Falling back to the plain field (rather than nil) is deliberate: a title TMDB has no artwork
    /// for in the wanted language should still show *something*, and the caller cannot usefully
    /// distinguish "wrong language" from "no poster" on screen.
    public func artwork(poster: URL?,
                        backdrop: URL?,
                        logo: URL?,
                        images: TMDBMatch.TMDBImages?,
                        originalLanguage: String?,
                        metadataLanguage: String) -> (poster: URL?, backdrop: URL?, logo: URL?) {
        guard let images else { return (poster, backdrop, logo) }

        let posterCode = language(for: self.poster, originalLanguage: originalLanguage, metadataLanguage: metadataLanguage)
        let logoCode = language(for: self.logo, originalLanguage: originalLanguage, metadataLanguage: metadataLanguage)

        // A backdrop carries no written language, so it follows the metadata language: choosing a
        // poster language must not silently change the backdrop too.
        let backdropCode = metadataLanguage

        func pick(_ assets: [TMDBMatch.TMDBImages.Asset], _ code: String) -> URL? {
            bestImage(assets,
                      language: code,
                      languageOf: { $0.language },
                      scoreOf: { Double($0.votes) },
                      widthOf: { $0.width })?.file
        }

        return (
            pick(images.posters, posterCode) ?? poster,
            pick(images.backdrops, backdropCode) ?? backdrop,
            pick(images.logos, logoCode) ?? logo
        )
    }

    /// Whether the choice actually changes what is on screen. `false` means the plain fields already
    /// carry it, which is when the page should skip the picker's work entirely.
    public var needsArtworkSelection: Bool {
        poster != .metadata || logo != .metadata
    }
}
