import ImageIO
import SwiftUI
import TVCore

/// A drive sign-in a CatPawOpen bundle runs itself (`CatPawSignIn`): its config center's code, scanned and confirmed
/// in the drive's app. It is the bundle's own sign-in, not the app's; the app's sign-ins stay in Settings. Playback
/// resumes once the bundle has the account. UC's TV token is the one code only the UC Browser app can approve, so
/// iPhone and iPad hand its link to UC Browser, and the code is there for UC Browser on another phone.
struct CatPawSignInView: View {
    let client: CatalogClient
    let provider: String
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var signIn: CatPawSignIn?
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0

    /// UC's TV token, approved in UC Browser; every other sign-in is a drive's, scanned in that drive's app.
    private var tvToken: Bool { provider == "ucToken" }
    private var name: String { CatPawSignIn.driveName(provider) }
    private var title: String { tvToken ? L10n.text("UC TV Token") : L10n.text("Sign In to %@", name) }

    var body: some View {
        #if os(tvOS)
        // Side by side, as the other sign-in codes on a TV; Menu closes it.
        HStack(alignment: .center, spacing: 80) { code; details }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackdrop()
            .task(id: attempt) { await run() }
        #else
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
            .navigationTitle(title)
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
        #endif
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                #if !os(iOS)
                Text(title).font(.title2.weight(.bold))
                #endif
                Text(instructions)
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            status
            VStack(alignment: .leading, spacing: 14) {
                #if os(iOS)
                if let link = signIn?.link, !expired, error == nil {
                    // This phone can't scan its own screen: the drive's app opens the code, or scans it from Photos.
                    let app = OpenDriveAppButton.target(drive: provider, page: link.absoluteString)
                    if let app, app.opensPage { OpenDriveAppButton(target: app) }
                    if !tvToken { SaveCodeButton(text: link.absoluteString, app: name) }
                    if let app, !app.opensPage { OpenDriveAppButton(target: app, prominent: false) }
                }
                #endif
                if expired || error != nil {
                    Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
                }
                #if os(tvOS)
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton()
                #endif
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var instructions: String {
        #if os(iOS)
        if !tvToken, OpenDriveAppButton.target(drive: provider, page: signIn?.link?.absoluteString)?.opensPage == true {
            return L10n.text("Confirm the sign-in in the %@ app: open it here, or scan the code with another phone.", name)
        }
        #endif
        guard tvToken else { return L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name) }
        #if os(iOS)
        return L10n.text("Approve the token in the UC Browser app, signed in to the same UC account: open it here, or scan the code with UC Browser on another phone.")
        #else
        return L10n.text("Scan this code with the UC Browser app on your phone, signed in to the same UC account, and approve it.")
        #endif
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
        .frame(width: codeSize, height: codeSize)
    }
    private var codeSize: CGFloat {
        #if os(tvOS)
        440
        #else
        240
        #endif
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
                Text(tvToken ? L10n.text("Waiting for UC Browser to approve…") : L10n.text("Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }

    private func run() async {
        signIn = nil; expired = false; error = nil
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
                    Diagnostics.shared.record(.info, "cloud.signin", "source=\(client.site.key) bundle \(provider) signed in")
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
