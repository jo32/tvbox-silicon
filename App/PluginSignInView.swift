import SwiftUI
import TVCore

/// The QR code a source's plugin made for a drive sign-in: Quark, UC, Baidu Netdisk or Aliyun Drive, or any
/// drive a Wex-family plugin signs in to itself (115, Tianyi, Guangya). It is the plugin's own sign-in, never
/// the app's: the plugin signs in by itself once the code is scanned and confirmed, then the video it was
/// opening plays. The app's sign-ins stay in Settings, whose accounts every plugin gets before it asks.
/// iPhone and iPad can't scan their own screen: the code is scanned with another phone, or saved to Photos
/// and scanned from there in the drive's app.
struct PluginSignInView: View {
    let prompt: PluginSignIn.Prompt
    @State private var now = Date()

    private var name: String {
        switch prompt.drive {
        case "baidu": L10n.text("Baidu Netdisk")
        case "aliyun": L10n.text("Aliyun Drive")
        case "quark": L10n.text("Quark")
        case "uc": "UC"
        case "pan115": L10n.text("115 Cloud")
        case "pan189": L10n.text("Tianyi Cloud")
        case "guangya": L10n.text("Guangya Cloud")
        default: prompt.drive
        }
    }
    private var expired: Bool { now >= prompt.expires }

    var body: some View {
        content
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 360)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackdrop()
        #endif
        .task {
            while !Task.isCancelled && !expired {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    #if os(iOS)
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Sign In to %@", name)).font(.title2.weight(.bold))
                    Text(L10n.text("%@ needs this account for the line you chose. The video plays once you confirm.", prompt.source))
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if expired {
                    Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                } else {
                    // Quark and UC open the code's page in their app on this phone; Baidu Netdisk's app scans it from Photos.
                    // Baidu's code is a page that signs in and approves it right here.
                    let page = DriveAppLink.confirmPage(drive: prompt.drive, page: prompt.content)
                    if let page { ConfirmCodePageButton(page: page) }
                    let app = OpenDriveAppButton.target(drive: prompt.drive, page: prompt.content)
                    if let app, app.opensPage { OpenDriveAppButton(target: app) }
                    VStack(alignment: .leading, spacing: 16) {
                        Text(app?.opensPage == true || page != nil ? L10n.text("Or scan this code with the %@ app on another phone.", name)
                             : L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name))
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        code
                        SaveCodeButton(text: prompt.content, image: prompt.content == nil ? prompt.image : nil, app: name)
                        if let app, !app.opensPage { OpenDriveAppButton(target: app, prominent: false) }
                    }
                }
                Button(L10n.text(expired ? "Close" : "Cancel")) { PluginSignIn.shared.dismiss() }
                    .settingsButton()
                    .accessibilityIdentifier("pluginSignIn.cancel")
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(spacing)
            .frame(maxWidth: .infinity)
        }
    }
    #else
    private var content: some View {
        // Side by side on a TV or Mac.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { code; details }
            ScrollView { VStack(alignment: .leading, spacing: spacing) { code; details } }
        }
        .padding(spacing)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Sign In to %@", name)).font(.title2.weight(.bold))
                Text(L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("%@ needs this account for the line you chose. The video plays once you confirm.", prompt.source))
                    .font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if expired {
                Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("Waiting for you to scan…")).foregroundStyle(.secondary)
                }
            }
            Button(L10n.text(expired ? "Close" : "Cancel")) { PluginSignIn.shared.dismiss() }
                .settingsButton()
                .accessibilityIdentifier("pluginSignIn.cancel")
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
    #endif

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            Group {
                if let content = prompt.content, let image = QRCode.image(content) {
                    Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                } else if let address = prompt.image {
                    AsyncImage(url: address) { phase in
                        if let image = phase.image { image.interpolation(.none).resizable().scaledToFit() }
                        else if phase.error != nil { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.black.opacity(0.5)) }
                        else { ProgressView().tint(.black) }
                    }
                    .accessibilityLabel(L10n.text("Sign-in code"))
                }
            }
            .padding(inset).opacity(expired ? 0.15 : 1)
        }
        .frame(width: size, height: size)
    }

    private var size: CGFloat {
        #if os(tvOS)
        440
        #elseif os(iOS)
        220
        #else
        240
        #endif
    }
    private var inset: CGFloat {
        #if os(iOS)
        20
        #else
        28
        #endif
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        80
        #else
        32
        #endif
    }
}
