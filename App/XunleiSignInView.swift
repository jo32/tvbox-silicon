import SwiftUI
import TVCore

/// Xunlei signs in with a code texted to the account's phone number, as its own app does. The sign-in is kept
/// with the other drives' and reaches CatPawOpen sources on their next request.
struct XunleiSignInView: View {
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mobile = ""
    @State private var code = ""
    @State private var challenge: XunleiSignIn.Challenge?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        #if os(iOS)
        phoneForm
        #else
        panel
        #endif
    }

    private var title: String { L10n.text("Sign In to %@", L10n.text("Xunlei")) }
    private var prompt: String {
        challenge.map { L10n.text("Enter the code Xunlei texted to %@.", $0.account.mobile ?? "") }
            ?? L10n.text("Enter the phone number of your Xunlei account. Xunlei texts it a code.")
    }

    #if os(iOS)
    /// A grouped form like the system's sign-in sheets: the drive's icon and the prompt, the fields, one wide button.
    private var phoneForm: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        // The drive's icon from the accounts list, at a header's size.
                        Image(systemName: CloudProvider.xunlei.symbol)
                            .font(.system(size: 28, weight: .semibold)).foregroundStyle(CloudProvider.xunlei.tint)
                            .frame(width: 60, height: 60)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHidden(true)
                        Text(title).font(.title2.weight(.bold))
                        Text(prompt).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField(L10n.text("Phone Number"), text: $mobile)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        .disabled(challenge != nil || busy)
                    if challenge != nil {
                        TextField(L10n.text("Verification Code"), text: $code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .focused($codeFocused)
                            .disabled(busy)
                    }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.rose)
                    }
                }
                Section {
                    Button { Task { if challenge == nil { await send() } else { await signIn() } } } label: {
                        ZStack {
                            Text(L10n.text(challenge == nil ? "Send Code" : "Sign In")).opacity(busy ? 0 : 1)
                            if busy { ProgressView() }
                        }
                        .font(.headline).frame(maxWidth: .infinity)
                    }
                    .settingsButton(prominent: true).controlSize(.large)
                    .disabled(busy || (challenge == nil ? XunleiSignIn.normalized(mobile) == nil : code.trimmingCharacters(in: .whitespaces).isEmpty))
                    if challenge != nil {
                        Button(L10n.text("Send Again")) { code = ""; challenge = nil; Task { await send() } }
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).disabled(busy)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
    #else
    private var panel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.bold))
                Text(prompt)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                TextField(L10n.text("Phone Number"), text: $mobile)
                    .phoneEntry()
                    .disabled(challenge != nil || busy)
                    .onSubmit { Task { await send() } }
                if challenge != nil {
                    TextField(L10n.text("Verification Code"), text: $code)
                        .codeEntry()
                        .focused($codeFocused)
                        .disabled(busy)
                        .onSubmit { Task { await signIn() } }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if challenge == nil {
                    Button(L10n.text("Send Code")) { Task { await send() } }
                        .settingsButton(prominent: true).disabled(busy || XunleiSignIn.normalized(mobile) == nil)
                } else {
                    Button(L10n.text("Sign In")) { Task { await signIn() } }
                        .settingsButton(prominent: true).disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L10n.text("Send Again")) { code = ""; challenge = nil; Task { await send() } }.settingsButton().disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton()
            }
        }
        .padding(28)
        #if os(macOS)
        .frame(width: 460)
        #elseif os(tvOS)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackdrop()
        #endif
    }
    #endif

    private func send() async {
        guard !busy, XunleiSignIn.normalized(mobile) != nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            challenge = try await XunleiSignIn.sendCode(to: mobile)
            codeFocused = true
        } catch { self.error = error.localizedDescription }
    }

    private func signIn() async {
        guard !busy, let challenge else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let account = try await XunleiSignIn.signIn(challenge, code: code)
            var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
            accounts.xunlei = account
            try accounts.save()
            Diagnostics.shared.record(.info, "cloud.signin", "xunlei signed in")
            signedIn()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    @ViewBuilder func phoneEntry() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder)
        #elseif os(tvOS)
        keyboardType(.phonePad).textContentType(.telephoneNumber)
        #else
        textFieldStyle(.roundedBorder).keyboardType(.phonePad).textContentType(.telephoneNumber)
        #endif
    }
    @ViewBuilder func codeEntry() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder).textContentType(.oneTimeCode)
        #elseif os(tvOS)
        keyboardType(.numberPad).textContentType(.oneTimeCode)
        #else
        textFieldStyle(.roundedBorder).keyboardType(.numberPad).textContentType(.oneTimeCode)
        #endif
    }
}
