import SwiftUI
import TVCore

/// The "back up to a cloud drive" sheet: pick a signed-in drive, then back up into it or restore a
/// backup from it. Reuses the drives the viewer already signed in to under Cloud Drive Accounts and
/// the AList/WebDAV servers they saved, so no new account is needed.
///
/// Backing up writes straight into the drive's `Mi3sBackup` folder. Restoring first opens that
/// folder so the viewer picks the snapshot they want.
struct CloudBackupSheet: View {
    enum Mode: String, Identifiable { case backup, restore
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let mode: Mode
    let categories: BackupCategory

    @State private var drives: [CloudFilesDrive] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var restoring: CloudFilesDrive?

    var body: some View {
        NavigationStack {
            Group {
                if drives.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("No Cloud Drive"), systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(L10n.text("Sign in to a cloud drive or add a server in Cloud Files first."))
                    }
                } else {
                    List {
                        Section {
                            ForEach(drives) { drive in
                                Button {
                                    Task { await choose(drive) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: drive.symbol)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(drive.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(drive.name).foregroundStyle(.primary)
                                            Text(mode == .backup ? L10n.text("Back up here") : L10n.text("Restore from here"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if busy { ProgressView().controlSize(.small) } else { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                                    }
                                }
                                .disabled(busy)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(mode == .backup ? L10n.text("Back Up to Cloud Drive") : L10n.text("Restore from Cloud Drive"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
            }
            .navigationDestination(item: $restoring) { drive in
                CloudBackupFolderView(drive: drive, categories: categories)
            }
            .alert(L10n.text("Cloud Backup"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .onAppear { drives = CloudFiles.drives() }
    }

    private func choose(_ drive: CloudFilesDrive) async {
        switch mode {
        case .backup:
            busy = true
            do {
                try await store.backupToCloudDrive(categories: categories, drive: drive)
                dismiss()
            } catch let caught {
                errorMessage = errorText(caught, drive: drive)
            }
            busy = false
        case .restore:
            restoring = drive
        }
    }

    private func errorText(_ caught: Error, drive: CloudFilesDrive) -> String {
        if case CloudFilesError.signInRequired = caught {
            return L10n.text("Sign in to %@ first.", drive.name)
        }
        return caught.localizedDescription
    }
}

/// The `Mi3sBackup` folder of one drive, listing the snapshots inside so the viewer picks which to
/// restore. Backups are JSON files; everything else is dimmed.
private struct CloudBackupFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let drive: CloudFilesDrive
    let categories: BackupCategory

    @State private var files: [CloudFile]?
    @State private var failure: Error?
    @State private var busy = false

    var body: some View {
        Group {
            if let files {
                if files.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("No Backups Yet"), systemImage: "externaldrive.badge.xmark")
                    } description: {
                        Text(L10n.text("Back up from another device first."))
                    }
                } else {
                    List {
                        Section {
                            ForEach(files.filter { !$0.isFolder }) { file in
                                Button {
                                    Task { await restore(file) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name).foregroundStyle(.primary)
                                            if let modified = file.modified {
                                                Text(modified, style: .date).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if busy { ProgressView().controlSize(.small) }
                                    }
                                }
                                .disabled(busy)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label(L10n.text("Couldn't Open Backups"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.localizedDescription)
                }
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L10n.text("Backups"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let root = try await CloudFiles.list(drive, folder: drive.root)
            let folder = root.first(where: { $0.isFolder && $0.name == CloudDriveBackup.folder })
            files = try await CloudFiles.list(drive, folder: folder?.id ?? drive.root)
        } catch {
            failure = error
        }
    }

    private func restore(_ file: CloudFile) async {
        busy = true
        do {
            try await store.restoreFromCloudDrive(id: file.id, name: file.name, drive: drive, categories: categories)
            dismiss()
        } catch {
            failure = error
        }
        busy = false
    }
}
