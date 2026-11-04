import SwiftUI
import TVCore

/// Configures the viewer's own HTTP/HTTPS/SOCKS5 proxy endpoints and, per source, which one to use.
/// This is separate from the built-in relay (`SourceRelay`): those endpoints are the user's own
/// egress, where the built-in relay is a fixed public server.

struct ProxySettingsView: View {
    @Environment(Store.self) private var store
    @State private var editing: CustomProxyEndpoint?
    @State private var adding = false

    var body: some View {
        let endpoints = store.customProxy.store.endpoints
        NavigationStack {
            Form {
                Section {
                    ForEach(endpoints) { endpoint in
                        Button { editing = endpoint } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "network").foregroundStyle(Brand.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(endpoint.name).foregroundStyle(.primary).lineLimit(1)
                                    Text("\(endpoint.scheme.title) · \(endpoint.host):\(endpoint.port)").foregroundStyle(.secondary).font(.caption)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .formRowButton()
                    }
                } footer: {
                    Text(L10n.text("Proxies carry the sources you route through them; a source without a route goes direct."))
                }
                Section {
                    Button { adding = true } label: {
                        Label(L10n.text("Add Proxy"), systemImage: "plus").foregroundStyle(.primary)
                    }
                    .formRowButton()
                }
            }
            .navigationTitle(L10n.text("Outbound Proxy"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Done")) { dismiss() } }
            }
            .sheet(item: $editing) { endpoint in
                CustomProxyEndpointEditor(endpoint: endpoint)
            }
            .sheet(isPresented: $adding) {
                CustomProxyEndpointEditor(endpoint: nil)
            }
        }
    }
    @Environment(\.dismiss) private var dismiss
}

/// Adds or edits one proxy endpoint: its name, scheme (HTTP / HTTPS / SOCKS5), host, port, and
/// optional username and password.
private struct CustomProxyEndpointEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let endpoint: CustomProxyEndpoint?

    @State private var name = ""
    @State private var scheme: CustomProxyEndpoint.Scheme = .http
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmsRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Name")) {
                    TextField(L10n.text("Name"), text: $name)
                }
                Section(L10n.text("Scheme")) {
                    Picker(L10n.text("Scheme"), selection: $scheme) {
                        ForEach(CustomProxyEndpoint.Scheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(L10n.text("Address")) {
                    TextField(L10n.text("Host"), text: $host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField(L10n.text("Port"), text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section(L10n.text("Authentication (optional)")) {
                    TextField(L10n.text("Username"), text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField(L10n.text("Password"), text: $password)
                }
                Section {
                    Button(L10n.text("Save"), action: save)
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(port) == nil)
                }
                if endpoint != nil {
                    Section {
                        Button(L10n.text("Remove"), role: .destructive) { confirmsRemoval = true }
                    }
                }
            }
            .navigationTitle(endpoint == nil ? L10n.text("Add Proxy") : L10n.text("Edit Proxy"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
            }
            .confirmationDialog(L10n.text("Remove Proxy"), isPresented: $confirmsRemoval) {
                Button(L10n.text("Remove"), role: .destructive) {
                    if let endpoint { store.customProxy.store.removeEndpoint(id: endpoint.id); store.customProxy.touch() }
                    dismiss()
                }
            }
            .onAppear {
                name = endpoint?.name ?? ""
                scheme = endpoint?.scheme ?? .http
                host = endpoint?.host ?? ""
                port = endpoint.map { String($0.port) } ?? ""
                username = endpoint?.username ?? ""
                password = endpoint?.password ?? ""
            }
        }
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = CustomProxyEndpoint(id: endpoint?.id ?? UUID().uuidString,
                                  name: trimmedName.isEmpty ? "\(scheme.title) \(trimmedHost):\(trimmedPort)" : trimmedName,
                                  scheme: scheme, host: trimmedHost, port: trimmedPort,
                                  username: username, password: password)
        store.customProxy.store.upsert(value)
        store.customProxy.touch()
        dismiss()
    }
}
