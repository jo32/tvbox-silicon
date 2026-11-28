import SwiftUI
import TVCore
#if !os(tvOS)
import AuthenticationServices
#endif

/// What Settings › Assistant edits, shared by the form (iPhone, iPad, Mac) and Apple TV's rows.
@MainActor @Observable final class AssistantSettingsModel {
    enum Kind: Hashable { case chatGPT, apiKey }
    var kind: Kind
    var baseURL: String
    var wire: APIKeyConnection.Wire
    /// The key being typed; saved to the Keychain when it's done.
    var key = ""
    private(set) var hasKey = false
    private(set) var models: [AgentModelInfo] = []
    private(set) var testing = false
    /// What the last test found: how many models, or why it failed.
    private(set) var testResult: String?
    private(set) var testFailed = false
    var model: String? = AgentSettings.model {
        didSet { AgentSettings.model = model }
    }
    #if !os(tvOS)
    private(set) var signInError: String?
    @ObservationIgnored private let web = AssistantWebSignIn()
    #endif

    init() {
        switch AgentSettings.connection {
        case .chatGPT?:
            kind = AgentSettings.offersChatGPTSignIn ? .chatGPT : .apiKey
            baseURL = APIKeyConnection.openAI.baseURL.absoluteString; wire = .responses
        case .apiKey(let connection)?:
            kind = .apiKey; baseURL = connection.baseURL.absoluteString; wire = connection.wire
        case nil:
            kind = AgentSettings.offersChatGPTSignIn ? .chatGPT : .apiKey
            baseURL = APIKeyConnection.openAI.baseURL.absoluteString; wire = .responses
        }
        hasKey = parsedURL.map { AgentKeychain().apiKey(for: $0) != nil } ?? false
    }

    var parsedURL: URL? {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// Saves the API key connection (and the key, when one was typed) as the one the assistant uses.
    func saveAPIKey() {
        guard let url = parsedURL else { return }
        let keychain = AgentKeychain()
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keychain.setAPIKey(key, for: url)
            key = ""
        }
        hasKey = keychain.apiKey(for: url) != nil
        AgentSettings.connection = .apiKey(APIKeyConnection(baseURL: url, wire: wire))
    }

    func removeKey() {
        guard let url = parsedURL else { return }
        AgentKeychain().setAPIKey(nil, for: url)
        hasKey = false
    }

    /// Asks the server for its models with what is set now.
    func test() async {
        if kind == .apiKey { saveAPIKey() }
        guard let connection = AgentSettings.connection else { return }
        testing = true; testResult = nil
        defer { testing = false }
        do {
            let found = try await AgentClients.make(connection).models()
            models = found
            testFailed = false
            testResult = L10n.text("Connected · %lld models", found.count)
        } catch {
            testFailed = true
            testResult = (error as? AgentFailure)?.message ?? error.localizedDescription
        }
    }

    /// The models to pick from, quietly, when the page opens.
    func loadModels() async {
        guard models.isEmpty, let connection = AgentSettings.connection, let client = try? AgentClients.make(connection) else { return }
        if let found = try? await client.models() { models = found }
    }

    /// The model's name for a row: the picked one, or the connection's first.
    var modelTitle: String {
        if let model { return models.first { $0.id == model }?.name ?? model }
        return L10n.text("Automatic")
    }

    #if !os(tvOS)
    func signIn() async {
        signInError = nil
        do {
            try await web.run()
            if let email = ChatGPTSignIn.shared.email { AgentSettings.connection = .chatGPT(accountLabel: email) }
            models = []
            await loadModels()
        } catch let failure as AgentFailure where failure.kind == .cancelled {
        } catch {
            signInError = (error as? AgentFailure)?.message ?? error.localizedDescription
        }
    }

    func signOut() async {
        await ChatGPTSignIn.shared.signOut()
        if case .chatGPT? = AgentSettings.connection { AgentSettings.connection = nil }
        models = []
    }

    /// Picking ChatGPT uses the sign-in when there is one; picking API key uses the address and key below.
    func choose(_ kind: Kind) {
        self.kind = kind
        models = []; testResult = nil
        switch kind {
        case .chatGPT:
            if let email = ChatGPTSignIn.shared.email { AgentSettings.connection = .chatGPT(accountLabel: email) }
            else if case .apiKey? = AgentSettings.connection { AgentSettings.connection = nil }
        case .apiKey: saveAPIKey()
        }
    }
    #endif

    static var privacyNote: String {
        L10n.text("Your messages, and what the assistant's tools read for it (titles, settings, and the script text you ask about), go to the model's provider. Passwords, cookies, keys and tokens are never sent. The provider's own terms and privacy policy apply.")
    }

    static var asksNote: String {
        L10n.text("The assistant asks before it changes a setting, a favorite or the playback speed. It always asks before it removes anything or overwrites a script.")
    }

    static var howToOpen: String {
        #if os(tvOS)
        L10n.text("Open it with the sparkles button at the top of Watch Now or Discover. You can dictate to it with the remote's microphone.")
        #elseif os(macOS)
        L10n.text("Open it with the sparkles button on Watch Now or Discover, or press ⇧⌘A.")
        #else
        L10n.text("Swipe left from the right edge of Watch Now or Discover, or tap the sparkles button.")
        #endif
    }
}

/// Settings › Assistant: on or off, how it reaches a model, which model, whether it asks first, and what it sends.
struct AssistantSettingsView: View {
    @Environment(AssistantController.self) private var assistant
    @State private var model = AssistantSettingsModel()
    @AppStorage(AgentSettings.enabledKey) private var enabled = false
    @AppStorage(AgentSettings.asksKey) private var asks = true
    @State private var confirmsClear = false

    var body: some View {
        page
            .task { await model.loadModels() }
            .onDisappear { assistant.prepare() }
            #if !os(tvOS)
            .confirmationDialog(L10n.text("Clear the conversation?"), isPresented: $confirmsClear) {
                Button(L10n.text("Clear Conversation"), role: .destructive) { assistant.clear() }
            }
            #endif
    }

    #if os(tvOS)
    private var page: some View {
        @Bindable var model = model
        return TVSettingsSubpage(symbol: "sparkles", title: L10n.text("Assistant"), subtitle: AssistantSettingsModel.howToOpen) {
            TVSettingsSection {
                TVSettingsToggle(title: L10n.text("Assistant"), isOn: $enabled)
            }
            TVSettingsSection(title: L10n.text("API Key"), footer: model.testResult) {
                TVSettingsField(title: L10n.text("Server"), text: Binding(get: { model.baseURL }, set: { model.baseURL = $0; model.saveAPIKey() }))
                TVSettingsAction(title: L10n.text("API"), value: wireTitle(model.wire)) {
                    model.wire = model.wire == .responses ? .chatCompletions : .responses
                    model.saveAPIKey()
                }
                TVSettingsField(title: L10n.text("API Key"), text: Binding(get: { model.key }, set: { model.key = $0; model.saveAPIKey() }),
                                secret: true, emptyValue: model.hasKey ? L10n.text("Saved") : L10n.text("Not set"))
                TVSettingsAction(title: L10n.text("Test Connection"), busy: model.testing) { Task { await model.test() } }
                    .disabled(model.testing || model.parsedURL == nil)
            }
            TVSettingsSection(footer: AssistantSettingsModel.asksNote) {
                TVSettingsLink(title: L10n.text("Model"), value: model.modelTitle) { AssistantModelPage(model: model) }
                TVSettingsToggle(title: L10n.text("Ask Before Changes"), isOn: $asks)
            }
            TVSettingsSection(footer: AssistantSettingsModel.privacyNote) {
                AssistantTVClearRow()
            }
        }
    }
    #else
    private var page: some View {
        @Bindable var model = model
        return Form { Group {
            Section {
                Toggle(isOn: $enabled) {
                    FormLabel(symbol: "sparkles", tint: Brand.cyan, title: L10n.text("Assistant"))
                }
                .settingsSwitch()
                .accessibilityIdentifier("assistant.enabled")
            } footer: {
                Text(AssistantSettingsModel.howToOpen)
            }

            Section {
                if AgentSettings.offersChatGPTSignIn {
                    Picker(selection: Binding(get: { model.kind }, set: { model.choose($0) })) {
                        Text(L10n.text("ChatGPT")).tag(AssistantSettingsModel.Kind.chatGPT)
                        Text(L10n.text("API Key")).tag(AssistantSettingsModel.Kind.apiKey)
                    } label: {
                        FormLabel(symbol: "point.3.connected.trianglepath.dotted", tint: .indigo, title: L10n.text("Connect With"))
                    }
                }
                if model.kind == .chatGPT && AgentSettings.offersChatGPTSignIn {
                    chatGPTRows
                } else {
                    apiKeyRows
                }
            } header: {
                Text(L10n.text("Connection"))
            } footer: {
                if let result = model.testResult {
                    Text(result).foregroundStyle(model.testFailed ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
                } else if model.kind == .apiKey {
                    Text(L10n.text("OpenAI, or any server that speaks its API. The key stays in this device's Keychain and is never synced."))
                } else {
                    Text(L10n.text("Uses your ChatGPT plan and its usage limits. You sign in on OpenAI's page; this app never sees your password."))
                }
            }

            Section {
                Picker(selection: $model.model) {
                    Text(L10n.text("Automatic")).tag(String?.none)
                    ForEach(model.models) { Text($0.name).tag(String?.some($0.id)) }
                    // The saved one, while the list hasn't loaded.
                    if let picked = model.model, !model.models.contains(where: { $0.id == picked }) { Text(picked).tag(String?.some(picked)) }
                } label: {
                    FormLabel(symbol: "cpu", tint: .gray, title: L10n.text("Model"))
                }
                .accessibilityIdentifier("assistant.model")
                Toggle(isOn: $asks) {
                    FormLabel(symbol: "hand.raised.fill", tint: .orange, title: L10n.text("Ask Before Changes"))
                }
                .settingsSwitch()
            } footer: {
                Text(AssistantSettingsModel.asksNote)
            }

            Section {
                Button(role: .destructive) { confirmsClear = true } label: {
                    FormLabel(symbol: "trash.fill", tint: .red, title: L10n.text("Clear Conversation")).foregroundStyle(.red)
                }
                .formRowButton()
                .disabled(assistant.messages.isEmpty)
            } footer: {
                Text(AssistantSettingsModel.privacyNote)
            }
        }.settingsRows() }
        .settingsForm(L10n.text("Assistant"))
    }

    @ViewBuilder private var chatGPTRows: some View {
        let signIn = ChatGPTSignIn.shared
        switch signIn.status {
        case .signedIn(let email), .planUsageUnavailable(let email):
            let usage = signIn.status == .signedIn(email: email)
            LabeledContent {
                EmptyView()
            } label: {
                FormLabel(symbol: "person.crop.circle.fill", tint: .green, title: email.isEmpty ? L10n.text("ChatGPT") : email,
                          subtitle: usage ? L10n.text("Using ChatGPT plan") : L10n.text("Plan usage wasn't allowed. Sign in again and allow it, or use an API key."))
            }
            SettingsWebRow(symbol: "gauge.with.dots.needle.67percent", tint: .blue, title: L10n.text("Manage Usage"), url: ChatGPTSignIn.usageURL)
            if !usage {
                signInButton(continues: true)
            }
            Button(role: .destructive) { Task { await model.signOut() } } label: {
                FormLabel(symbol: "rectangle.portrait.and.arrow.right", tint: .red, title: L10n.text("Sign Out")).foregroundStyle(.red)
            }
            .formRowButton()
        case .signedOut:
            signInButton(continues: signIn.clientID != nil)
            if let error = model.signInError {
                Text(error).font(.footnote).foregroundStyle(Brand.amber)
            }
        }
    }

    /// OpenAI's own wording: "Sign in with ChatGPT", or "Continue with ChatGPT" for an account it already knows.
    private func signInButton(continues: Bool) -> some View {
        Button { Task { await model.signIn() } } label: {
            HStack(spacing: 8) {
                FormLabel(symbol: "person.crop.circle.badge.checkmark", tint: .green,
                          title: L10n.text(continues ? "Continue with ChatGPT" : "Sign in with ChatGPT"))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if ChatGPTSignIn.shared.isSigningIn { ProgressView().appControlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .formRowButton()
        .disabled(ChatGPTSignIn.shared.isSigningIn)
        .accessibilityIdentifier("assistant.signIn")
    }

    @ViewBuilder private var apiKeyRows: some View {
        @Bindable var model = model
        LabeledContent {
            TextField(L10n.text("Server"), text: $model.baseURL, prompt: Text(APIKeyConnection.openAI.baseURL.absoluteString))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .onSubmit { model.saveAPIKey() }
                .labelsHidden()
        } label: {
            FormLabel(symbol: "server.rack", tint: .gray, title: L10n.text("Server"))
        }
        Picker(selection: Binding(get: { model.wire }, set: { model.wire = $0; model.saveAPIKey() })) {
            Text(L10n.text("Responses")).tag(APIKeyConnection.Wire.responses)
            Text(L10n.text("Chat Completions")).tag(APIKeyConnection.Wire.chatCompletions)
        } label: {
            FormLabel(symbol: "arrow.left.arrow.right", tint: .gray, title: L10n.text("API"))
        }
        LabeledContent {
            SecureField(L10n.text("API Key"), text: $model.key, prompt: Text(model.hasKey ? L10n.text("Saved") : "sk-…"))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .textContentType(.password)
                .onSubmit { model.saveAPIKey() }
                .labelsHidden()
                .accessibilityIdentifier("assistant.apiKey")
        } label: {
            FormLabel(symbol: "key.fill", tint: .yellow, title: L10n.text("API Key"))
        }
        Button { Task { await model.test() } } label: {
            HStack(spacing: 8) {
                FormLabel(symbol: "checkmark.seal.fill", tint: .blue, title: L10n.text("Test Connection")).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if model.testing { ProgressView().appControlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .formRowButton()
        .disabled(model.testing || model.parsedURL == nil)
        .accessibilityIdentifier("assistant.test")
        if model.hasKey {
            Button(role: .destructive) { model.removeKey() } label: {
                FormLabel(symbol: "key.slash", tint: .red, title: L10n.text("Remove API Key")).foregroundStyle(.red)
            }
            .formRowButton()
        }
    }
    #endif

    private func wireTitle(_ wire: APIKeyConnection.Wire) -> String {
        wire == .responses ? L10n.text("Responses") : L10n.text("Chat Completions")
    }
}

#if os(tvOS)
/// Apple TV: the models the server offers, one row each.
private struct AssistantModelPage: View {
    let model: AssistantSettingsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TVSettingsSubpage(symbol: "cpu", title: L10n.text("Model")) {
            TVSettingsSection(footer: model.models.isEmpty ? L10n.text("Test the connection to list the server's models.") : nil) {
                row(L10n.text("Automatic"), id: nil)
                ForEach(model.models) { row($0.name, id: $0.id) }
            }
        }
        .task { await model.loadModels() }
    }
    private func row(_ title: String, id: String?) -> some View {
        Button { model.model = id; dismiss() } label: {
            TVSettingsRowLabel(title: title) {
                if model.model == id { Image(systemName: "checkmark").font(.system(size: 24, weight: .semibold)) }
            }
        }
        .glassRow()
    }
}
#endif

#if !os(tvOS)
/// Shows OpenAI's sign-in page in the system's web sign-in sheet while `ChatGPTSignIn` waits for the answer on its
/// loopback listener, then closes it. Closing the sheet stops the sign-in.
@MainActor final class AssistantWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run() async throws {
        defer { session?.cancel(); session = nil }
        try await ChatGPTSignIn.shared.signIn { [weak self] url in self?.present(url) }
    }

    private func present(_ url: URL) {
        // The answer goes to the loopback address, not to an app scheme, so the sheet never completes by itself.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "yingxia-assistant") { [weak self] _, _ in
            Task { @MainActor in
                // Closed by the viewer; after a sign-in it is closed here, with `session` already let go.
                guard let self, self.session != nil else { return }
                self.session = nil
                ChatGPTSignIn.shared.cancelSignIn()
            }
        }
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #endif
        }
    }
}
#endif
