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
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Sign In to %@", L10n.text("Xunlei"))).font(.title2.weight(.bold))
                Text(challenge.map { L10n.text("Enter the code Xunlei texted to %@.", $0.account.mobile ?? "") }
                     ?? L10n.text("Enter the phone number of your Xunlei account. Xunlei texts it a code."))
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
        #else
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
    }

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
