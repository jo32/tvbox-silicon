#if !os(tvOS)
import ImageIO
import SwiftUI
import TVCore

/// UC's TV token for a CatPawOpen bundle (`CatPawSignIn`). Only the UC Browser app can approve its code, so iPhone and
/// iPad hand the code's link to UC Browser, and the code is there for UC Browser on another phone. Playback resumes once
/// the bundle has the token.
struct CatPawSignInView: View {
    let client: CatalogClient
    let provider: String
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var signIn: CatPawSignIn?
    @State private var expired = false
    @State private var error: String?
    @State private var withoutApp = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            // Side by side on an iPad or Mac; stacked on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 32) { code; details }
                ScrollView { VStack(alignment: .leading, spacing: 32) { code; details } }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
            .screenBackdrop()
            .navigationTitle(L10n.text("UC TV Token"))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 380)
        #endif
        .task(id: attempt) { await run() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                Text(L10n.text("UC TV Token")).font(.title2.weight(.bold))
                Text(L10n.text("Scan this code with the UC Browser app on your phone, signed in to the same UC account, and approve it."))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #else
                Text(L10n.text("Approve the token in the UC Browser app, signed in to the same UC account: open it here, or scan the code with UC Browser on another phone."))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #endif
            }
            status
            VStack(alignment: .leading, spacing: 14) {
                #if os(iOS)
                if let link = signIn?.link, !expired, error == nil {
                    Button { open(link) } label: { Label(L10n.text("Open in UC Browser"), systemImage: "arrow.up.forward.app") }
                        .settingsButton(prominent: true)
                        .accessibilityIdentifier("catPawSignIn.open")
                    if withoutApp {
                        Text(L10n.text("UC Browser isn't on this device. Get UC Browser (UC浏览器) from the App Store and sign in to it, or scan the code with another phone."))
                            .font(.callout).foregroundStyle(Brand.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }
                #endif
                if expired || error != nil {
                    Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            if let picture {
                Image(picture, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                    .padding(28).opacity(expired ? 0.15 : 1)
            } else if error == nil {
                ProgressView().tint(.black)
            }
            if expired {
                Image(systemName: "arrow.clockwise").font(.system(size: 64, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            }
        }
        .frame(width: 240, height: 240)
    }
    /// The code drawn from its link, or the bundle's own picture when its link can't be read.
    private var picture: CGImage? {
        guard let signIn else { return nil }
        if let link = signIn.link, let image = QRCode.image(link.absoluteString) { return image }
        guard let data = signIn.image, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if signIn != nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("Waiting for UC Browser to approve…")).foregroundStyle(.secondary)
            }
        }
    }

    #if os(iOS)
    /// UC Browser opens an address put after its scheme.
    private func open(_ link: URL) {
        guard let app = URL(string: "ucbrowser://" + link.absoluteString) else { return }
        openURL(app) { opened in withoutApp = !opened }
    }
    #endif

    private func run() async {
        signIn = nil; expired = false; error = nil; withoutApp = false
        var started: CatPawSignIn?
        do {
            var signIn = try await CatPawSignIn.start(provider, client: client)
            started = signIn
            self.signIn = signIn
            while true {
                try await Task.sleep(for: .seconds(2))
                try await signIn.poll()
                switch signIn.status {
                case .waiting: continue
                case .expired: expired = true; return
                case .failed: error = signIn.message.isEmpty ? L10n.text("The plugin returned no content. Try another source.") : signIn.message; return
                case .done:
                    Diagnostics.shared.record(.info, "cloud.signin", "source=\(client.site.key) \(provider) approved")
                    dismiss()
                    signedIn()
                    return
                }
            }
        } catch is CancellationError {
            // Closed or restarted: the bundle drops the code.
            if let started { Task { await started.cancel() } }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
