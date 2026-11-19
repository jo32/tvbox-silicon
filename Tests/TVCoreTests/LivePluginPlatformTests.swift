import Foundation
import Testing
@testable import TVCore

struct LivePluginPlatformTests {
    private func installed(_ id: String) -> LivePlugins.Installed {
        LivePlugins.Installed(pluginId: id, version: "1", name: id, summary: "", sha256: "", zipURLs: [], source: nil, icon: nil, tint: nil,
                              requiresLogin: false, installedAt: Date(timeIntervalSince1970: 0))
    }

    /// Plugin IDs may start with a digit, "-" or ".", which a URL scheme can't (report fcf1a90b1cfb: a launch crash).
    @Test func everyValidPluginIDMakesAUsableScheme() throws {
        for id in ["douyu", "9xiu", "17live", "-live", ".live", "_live", "___", "a_b.c-d"] {
            #expect(LivePlugins.validID(id))
            let platform = LivePlatform(plugin: installed(id))
            #expect(platform.scheme.first?.isLetter == true, "\(id) -> \(platform.scheme)")
            let rooms = try #require(URL(string: "\(platform.scheme)://rooms"), "\(id) -> \(platform.scheme)")
            #expect(platform.source.url == rooms)
            #expect(URL(string: "\(platform.scheme)://room/123") != nil)
            let shown = Subscription(origin: URL(string: "https://example.org/tv.json")!, importedAt: Date(), sites: [], lives: [], raw: [:]).withLivePlugins([platform])
            #expect(shown.lives.map(\.url) == [rooms])
        }
        // IDs that already started with a letter keep their address, so saved channels still open.
        #expect(LivePlatform(plugin: installed("Douyu")).scheme == "douyu-plugin-live")
        #expect(LivePlatform(plugin: installed("9xiu")).scheme == "p9xiu-plugin-live")
    }

    /// Douyu's plugin says it needs no account (`auth.required: false`) yet signs in on the web or by QR code for
    /// better picture; its page must still offer that. Huya has no sign-in at all.
    @Test func pluginsThatCanSignInOfferItEvenWhenNotRequired() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "live-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let plugins = LivePlugins(defaults: UserDefaults(suiteName: UUID().uuidString)!, folder: folder)
        let manifests = [
            "douyu": #"{"pluginId":"douyu","auth":{"required":false,"credentialKinds":["cookie"]},"loginFlow":{"kind":"webview","loginURL":"https://www.douyu.com/member/login","cookieDomains":["douyu.com"]},"loginChallenge":{"kind":"qrcode","minLoginChallengeProtocol":1,"functions":{"create":"createLoginChallenge","poll":"pollLoginChallenge"}}}"#,
            "qronly": #"{"pluginId":"qronly","loginChallenge":{"kind":"qrcode","functions":{"create":"createLoginChallenge","poll":"pollLoginChallenge"}}}"#,
            "huya": #"{"pluginId":"huya","auth":{"required":false}}"#,
        ]
        for (id, manifest) in manifests {
            let directory = plugins.directory(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: directory.appending(path: "manifest.json"))
        }
        #expect(await plugins.offersSignIn("douyu"))
        #expect(await plugins.offersSignIn("qronly"))
        #expect(await !plugins.offersSignIn("huya"))
    }
}
