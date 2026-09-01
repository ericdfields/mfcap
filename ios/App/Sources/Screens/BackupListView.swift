// BackupListView.swift — the backup catalog (UX §16.1).
//
// Newest first; coverage ("512/512" / "partial · 341/512" + Resume), size,
// identity chip for practice backups, integrity badges for unloadable
// folders. Back Up Now always states the pre-flight line: reads all 512
// slots; the device is never modified by a backup.

import SwiftUI
import FreakCore

struct BackupListView: View {
    @Environment(AppModel.self) private var model
    @State private var deleteCandidate: BackupSummary?

    var body: some View {
        List {
            Section {
                preflight
            }
            if model.backups.items.isEmpty && model.backups.loadFailures.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No backups yet", systemImage: "externaldrive")
                    } description: {
                        Text("A backup is also how the sync view reads the "
                             + "device — either path creates one.")
                    }
                }
            }
            Section {
                ForEach(model.backups.items) { summary in
                    BackupRowView(summary: summary,
                                  requestDelete: { deleteCandidate = $0 })
                }
            }
            if !model.backups.loadFailures.isEmpty {
                Section("Damaged backups (nothing auto-deleted)") {
                    ForEach(model.backups.loadFailures.sorted(by: {
                        $0.key < $1.key
                    }), id: \.key) { name, detail in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(name, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backups")
        .refreshable { await model.backups.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.backUpNow()
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive.badge.plus")
                }
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
            }
        }
        .alert(item: $deleteCandidate) { summary in
            deleteAlert(summary)
        }
    }

    private var preflight: some View {
        Label {
            Text("Reads all 512 slots, about 3½ minutes. ")
            + Text("The device is never modified by a backup.").bold()
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func deleteAlert(_ summary: BackupSummary) -> Alert {
        guard let facts = model.backups.deleteGuard(summary.folderName) else {
            return Alert(title: Text("Backup not found"))
        }
        let message = facts.onlyComplete
            ? "This is your ONLY complete backup. Deleting it removes the "
                + "only full copy of the device this app holds."
            : "Deletes the folder \(summary.folderName) and its "
                + "\(summary.coveredCount) preset files."
        return Alert(
            title: Text("Delete backup \(summary.folderName)?"),
            message: Text(message),
            primaryButton: .destructive(Text("Delete Backup")) {
                Task { await model.backups.delete(summary.folderName) }
            },
            secondaryButton: .cancel())
    }
}

struct BackupRowView: View {
    @Environment(AppModel.self) private var model
    let summary: BackupSummary
    let requestDelete: (BackupSummary) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.folderName)
                    .font(.body.monospacedDigit())
                HStack(spacing: 8) {
                    Text(summary.coverageLabel)
                        .font(.caption)
                        .foregroundStyle(summary.isComplete
                            ? Color.secondary : .orange)
                    Text(Format.fileSize(summary.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if summary.identity.isPractice {
                        Text("practice")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
            }
            Spacer()
            if !summary.isComplete {
                Button("Resume") {
                    model.resumeBackup(summary.folderName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.connection.hasDevice
                          || model.operations.exclusiveLongOp != nil)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { model.detail = .backup(summary.folderName) }
        .contextMenu {
            Button {
                model.detail = .backup(summary.folderName)
            } label: {
                Label("Show Detail", systemImage: "info.circle")
            }
            Button {
                model.requestRestore(from: summary.folderName)
            } label: {
                Label("Restore…", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(!model.connection.hasDevice)
            ShareLink(item: summary.path) {
                Label("Export Folder", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                requestDelete(summary)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview("Backups") {
    PreviewHost { _ in
        NavigationStack { BackupListView() }
    }
}
