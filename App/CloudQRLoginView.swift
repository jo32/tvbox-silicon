#if os(iOS) || os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins
import TVCore

/// Sign in to Quark or UC by scanning a code with the drive's phone app; there is no browser
/// on Apple TV. The saved cookie reaches the plugins on their next request.
struct CloudQRLoginView: View {
    let drive: CloudDriveQRLogin.Drive
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var login: CloudDriveQRLogin?
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0

    private var name: String { drive == .quark ? L10n.text("Quark") : "UC" }
    var body: some View {
        // Side by side on a TV or iPad; stacked on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: codeSpacing) { code; details }
            ScrollView { VStack(alignment: .leading, spacing: codeSpacing) { code; details } }
        }
        .padding(codeSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackdrop()
        .task(id: attempt) { await run() }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text(drive == .quark ? "Sign In to Quark" : "Sign In to UC")).font(.title2.weight(.bold))
                Text(L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            status
            HStack(spacing: 16) {
                #if os(iOS)
                if let login, let url = URL(string: login.code) {
                    Link(L10n.text("Open %@", name), destination: url).settingsButton(prominent: true)
                }
                #endif
                if expired || error != nil {
                    Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
                }
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton()
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            if let login, let image = Self.image(login.code) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
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
    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if login != nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }
    private func run() async {
        login = nil; expired = false; error = nil
        do {
            let login = try await CloudDriveQRLogin.start(drive)
            self.login = login
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                switch try await login.poll() {
                case .waiting: continue
                case .expired: expired = true; return
                case .signedIn(let cookie):
                    var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
                    if drive == .quark { accounts.quarkCookie = cookie } else { accounts.ucCookie = cookie }
                    try accounts.save()
                    dismiss()
                    signedIn()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
    private var codeSize: CGFloat {
        #if os(tvOS)
        440
        #else
        240
        #endif
    }
    private var codeSpacing: CGFloat {
        #if os(tvOS)
        80
        #else
        32
        #endif
    }
}
#endif
