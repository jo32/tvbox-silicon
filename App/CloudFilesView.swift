import SwiftUI
import TVCore

/// Cloud Files: the Quark and UC drives signed in under Cloud Drive Accounts and the saved AList
/// servers and WebDAV shares. Open folders and play their videos; the rest of the folder plays
/// after the one chosen.
struct CloudFilesView: View {
    @State private var drives: [CloudFilesDrive] = []
    /// The server being added (a blank one) or edited.
    @State private var editing: AListServer?
    @State private var removing: AListServer?
    @State private var error: String?

    private var signedIn: [CloudFilesDrive] { drives.filter { if case .alist = $0 { false } else { true } } }
    private var servers: [AListServer] { drives.compactMap { if case .alist(let server) = $0 { server } else { nil } } }

    var body: some View {
        FilesList {
            FilesSection(title: L10n.text("Cloud Drives"),
                         footer: signedIn.count < 2 ? L10n.text("Sign in to Quark or UC under Cloud Drive Accounts to browse their files here.") : nil) {
                ForEach(signedIn) { drive in
                    FolderLink(drive: drive, folder: drive.root, name: drive.name) {
                        FileRowLabel(symbol: drive.symbol, tint: drive.tint, title: drive.name, chevron: true)
                    }
                }
                if signedIn.count < 2 {
                    RouteLink { CloudDriveView() } label: {
                        FileRowLabel(symbol: "person.crop.circle.badge.plus", tint: .gray, title: L10n.text("Cloud Drive Accounts"), chevron: true)
                    }
                    .glassRow()
                }
            }
            FilesSection(title: "AList · WebDAV", footer: L10n.text("Add an AList or OpenList server, or a NAS's WebDAV share, by the address you open it at. Pasting an AList address, or a TVBox AList configuration, in Add Subscription adds servers too.")) {
                ForEach(servers) { server in
                    FolderLink(drive: .alist(server), folder: server.root, name: server.name) {
                        FileRowLabel(symbol: CloudFilesDrive.alist(server).symbol, tint: .teal, title: server.name,
                                     subtitle: server.address + (server.root == "/" ? "" : server.root), chevron: true)
                    }
                    .contextMenu {
                        Button(L10n.text("Edit Server"), systemImage: "pencil") { editing = server }
                        Button(L10n.text("Remove Server"), systemImage: "trash", role: .destructive) { removing = server }
                    }
                    #if os(iOS)
                    .swipeActions {
                        Button(L10n.text("Remove Server"), systemImage: "trash", role: .destructive) { removing = server }
                        Button(L10n.text("Edit Server"), systemImage: "pencil") { editing = server }
                    }
                    #endif
                }
                Button { editing = AListServer(name: "", address: "") } label: {
                    FileRowLabel(symbol: "plus", tint: .green, title: L10n.text("Add Server"))
                }
                .glassRow()
                .accessibilityIdentifier("files.addServer")
            }
            if let error { StatusNotice(text: error) }
        }
        .screenBackdrop()
        .tabTitle(L10n.text("Cloud Files"))
        .onAppear(perform: reload)
        .filesModal(item: $editing) { AListServerForm(server: $0, saved: reload) }
        .confirmationDialog(L10n.text("Remove %@ from Cloud Files?", removing?.name ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Remove Server"), role: .destructive) {
                if let removing {
                    do { try AListServers.remove(removing.id) } catch { self.error = error.localizedDescription }
                }
                removing = nil
                reload()
            }
        }
    }

    private func reload() { drives = CloudFiles.drives() }
}

/// One folder of a drive: its folders, then its files. Videos and songs play; the others are listed
/// so the folder reads as it does on the drive.
struct CloudFolderView: View {
    @Environment(Store.self) private var store
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    let drive: CloudFilesDrive
    let folder: String
    let name: String
    @State private var files: [CloudFile]?
    @State private var failure: Error?
    @State private var asksPassword = false
    @State private var password = ""

    var body: some View {
        Group {
            if let files, !files.isEmpty {
                FilesList {
                    FilesSection(title: nil, footer: nil) {
                        ForEach(files) { row($0, in: files) }
                    }
                }
                #if os(iOS)
                .refreshable { await load() }
                #endif
            } else if files != nil {
                #if os(tvOS)
                // A text-only page has no focused control to receive the remote's Back press.
                FilesMessage(symbol: "folder", title: L10n.text("This Folder Is Empty")) {
                    Button(L10n.text("Back")) { dismiss() }.controlButton(prominent: true)
                }
                #else
                FilesMessage(symbol: "folder", title: L10n.text("This Folder Is Empty"))
                #endif
            } else if let failure {
                FilesMessage(symbol: "exclamationmark.triangle", title: L10n.text("Couldn't Open This Folder"), message: failure.localizedDescription) {
                    Button(L10n.text("Retry")) { Task { await load() } }.controlButton(prominent: true)
                    if case CloudFilesError.signInRequired = failure, !drive.isAList {
                        RouteLink { CloudDriveView() } label: { Text(L10n.text("Cloud Drive Accounts")) }.controlButton()
                    }
                }
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(tvOS)
                    .focusable()
                    #endif
            }
        }
        .screenBackdrop()
        .screenTitle(name)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .task { if files == nil { await load() } }
        .alert(L10n.text("Folder Password"), isPresented: $asksPassword) {
            SecureField(L10n.text("Password"), text: $password)
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Open")) { Task { await load(password: password) } }
        } message: { Text(L10n.text("Enter the password for %@.", name)) }
    }

    @ViewBuilder private func row(_ file: CloudFile, in files: [CloudFile]) -> some View {
        let label = FileRowLabel(symbol: file.symbol, tint: file.tint, title: file.name, subtitle: subtitle(file), chevron: file.isFolder)
        if file.isFolder {
            FolderLink(drive: drive, folder: file.id, name: file.name) { label }
        } else if drive.plays(file) {
            let item = FavoriteItem.cloud(FavoriteCloudFile(driveKey: drive.key, folderID: folder, folderName: name, fileID: file.id, fileName: file.name, size: file.size))
            Button { play(file, in: files) } label: {
                HStack(spacing: 8) {
                    label
                    if store.favorites.contains(item) {
                        Image(systemName: "heart.fill").foregroundStyle(Brand.rose).fixedSize().accessibilityHidden(true)
                    }
                }
            }
            .glassRow()
            .contextMenu { FavoriteMenuButton(item: item, name: file.name) }
            .accessibilityIdentifier("files.play." + file.name)
        } else {
            // Focusable on Apple TV all the same, or the remote couldn't scroll past these rows.
            #if os(tvOS)
            Button {} label: { label.opacity(0.55) }.glassRow()
            #else
            label.opacity(0.55)
            #endif
        }
    }

    private func subtitle(_ file: CloudFile) -> String {
        var parts: [String] = []
        if !file.isFolder, file.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) }
        if let modified = file.modified { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func play(_ file: CloudFile, in files: [CloudFile]) {
        store.playFile(file, in: CloudFilesFolder(drive: drive, id: folder, name: name, files: files.filter { $0.kind == file.kind && drive.plays($0) }))
    }

    private func load(password: String? = nil) async {
        do {
            files = try await CloudFiles.list(drive, folder: folder, password: password)
            failure = nil
        } catch CloudFilesError.passwordRequired {
            self.password = ""
            asksPassword = true
            failure = CloudFilesError.passwordRequired
        } catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.failure("files", "list \(drive.isAList ? "alist" : drive.key)", error)
            failure = error
        }
    }
}

/// Adding or editing an AList server or a WebDAV share: its address, and an account for servers
/// that keep guests out. The server is checked before it is saved.
struct AListServerForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server: AListServer
    @State private var address: String
    @State private var checking = false
    @State private var error: String?
    private let isNew: Bool
    private let saved: () -> Void

    init(server: AListServer, saved: @escaping () -> Void) {
        _server = State(initialValue: server)
        _address = State(initialValue: server.address.isEmpty ? "" : server.address + (server.root == "/" ? "" : server.root))
        isNew = server.address.isEmpty
        self.saved = saved
    }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.system(size: 46, weight: .bold))
                fields
                if let error { StatusNotice(text: error) }
                HStack(spacing: 20) {
                    Button(checking ? L10n.text("Checking…") : L10n.text("Save")) { save() }.controlButton(prominent: true).disabled(!canSave)
                    Button(L10n.text("Cancel")) { dismiss() }.controlButton()
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        #else
        NavigationStack {
            Form {
                Section {
                    fields
                } footer: {
                    Text(L10n.text("The server's address, such as http://192.168.1.10:5244 for AList, or the WebDAV address your NAS shows. Add a folder after it to start there. The user name and password are only for servers that don't let guests browse."))
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber) } }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking { ProgressView() } else { Button(L10n.text("Save")) { save() }.disabled(!canSave) }
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 420)
        #endif
        #endif
    }

    private var title: String { isNew ? L10n.text("Add Server") : L10n.text("Edit Server") }
    private var canSave: Bool { !checking && !address.trimmingCharacters(in: .whitespaces).isEmpty }

    @ViewBuilder private var fields: some View {
        TextField(L10n.text("Address"), text: $address, prompt: Text(verbatim: "http://192.168.1.10:5244"))
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL).textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("alist.address")
        TextField(L10n.text("Name (Optional)"), text: $server.name)
        TextField(L10n.text("User Name (Optional)"), text: $server.username)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        SecureField(L10n.text("Password (Optional)"), text: $server.password)
    }

    private func save() {
        checking = true; error = nil
        Task {
            defer { checking = false }
            do {
                let url = try WebAddress.resolve(address)
                let username = server.username.trimmingCharacters(in: .whitespaces)
                // An AList server, else a WebDAV share such as a NAS's.
                var probed = await AList.probe(url)
                if probed == nil { probed = try await WebDAV.shared.probe(url, username: username, password: server.password) }
                guard var found = probed else {
                    error = L10n.text("No AList or WebDAV server answered at this address.")
                    return
                }
                found.id = server.id
                if !server.name.trimmingCharacters(in: .whitespaces).isEmpty { found.name = server.name.trimmingCharacters(in: .whitespaces) }
                found.username = username
                found.password = server.password
                found.folderPassword = server.folderPassword
                if found.isWebDAV { try await WebDAV.shared.check(found) } else { try await AList.shared.check(found) }
                if isNew { try AListServers.add([found]) } else { try AListServers.update(found) }
                saved()
                dismiss()
            } catch CloudFilesError.signInRequired(_) where server.username.isEmpty {
                error = L10n.text("This server doesn't let guests browse. Enter a user name and password.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: Rows and lists

/// A drive's folder, pushed onto the stack.
private struct FolderLink<Label: View>: View {
    let drive: CloudFilesDrive
    let folder: String
    let name: String
    @ViewBuilder var label: Label
    var body: some View {
        RouteLink { CloudFolderView(drive: drive, folder: folder, name: name) } label: { label }
            .glassRow()
            .accessibilityIdentifier("files.open." + name)
    }
}

/// The page's rows: the system's grouped list on iPhone, iPad and Mac, and on Apple TV a column
/// of Liquid Glass rows.
private struct FilesList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) { content }
                .glassRowInsets()
                .frame(maxWidth: Layout.settingsWidth).frame(maxWidth: .infinity)
        }
        #elseif os(iOS)
        List { content.listRowBackground(SettingsStyle.rowFill) }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        #else
        List { content }.listStyle(.inset(alternatesRowBackgrounds: false))
        #endif
    }
}

private struct FilesSection<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 28).padding(.top, 24) }
            content
            if let footer { Text(footer).font(.system(size: 23)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 8) }
        }
        #else
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
        #endif
    }
}

struct FileRowLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String = ""
    var chevron = false
    #if os(tvOS)
    private let tile: CGFloat = 56, glyph: CGFloat = 26, titleFont = Font.system(size: 29, weight: .medium), detailFont = Font.system(size: 23)
    #elseif os(macOS)
    private let tile: CGFloat = 26, glyph: CGFloat = 13, titleFont = Font.body, detailFont = Font.caption
    #else
    private let tile: CGFloat = 32, glyph: CGFloat = 15, titleFont = Font.body, detailFont = Font.caption
    #endif
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold)).foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(titleFont).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                if !subtitle.isEmpty { Text(subtitle).font(detailFont).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            #if !os(iOS)
            // iPhone and iPad lists draw their own chevron beside a link.
            if chevron { Image(systemName: "chevron.right").font(detailFont.weight(.semibold)).foregroundStyle(.tertiary) }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// An empty folder or one that didn't open, in the middle of the page.
private struct FilesMessage<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520) }
            HStack(spacing: 14) { actions }.padding(.top, 6)
        }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FilesMessage where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

extension CloudFilesDrive {
    var isAList: Bool { if case .alist = self { true } else { false } }
    var symbol: String {
        switch self {
        case .quark: CloudProvider.quark.symbol
        case .uc: CloudProvider.uc.symbol
        case .alist(let server): server.isWebDAV ? "externaldrive.connected.to.line.below" : "server.rack"
        }
    }
    var tint: Color {
        switch self {
        case .quark: CloudProvider.quark.tint
        case .uc: CloudProvider.uc.tint
        case .alist: .teal
        }
    }
}

extension CloudFile {
    var symbol: String {
        switch kind {
        case .folder: "folder.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .image: "photo.fill"
        case .subtitle: "captions.bubble.fill"
        case .other: "doc.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .folder: Color(red: 0.25, green: 0.62, blue: 0.98)
        case .video: Brand.amber
        case .audio: Color(red: 1.0, green: 0.34, blue: 0.56)
        case .image: .green
        case .subtitle, .other: .gray
        }
    }
}

extension View {
    /// A sheet, or on Apple TV a full-screen page: tvOS sheets are small.
    @ViewBuilder func filesModal<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}
