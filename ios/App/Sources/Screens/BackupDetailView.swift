// BackupDetailView.swift — one backup's contents (UX §16.1 detail).
//
// Per-slot table (number, name, sha), Restore… entry, Export folder,
// cross-identity warning when restoring a practice backup to hardware (or
// vice versa), and per-row drag sources for pulling single presets out.

import SwiftUI
import FreakCore

struct BackupDetailView: View {
    @Environment(AppModel.self) private var model
    let folderName: String

    private var summary: BackupSummary? { model.backups.summary(folderName) }
    private var records: [SlotRecord] {
        model.backups.set(folderName)?.records() ?? []
    }

    var body: some View {
        List {
            if let summary {
                Section {
                    LabeledContent("Created") { Text(summary.createdAt) }
                    LabeledContent("Coverage") { Text(summary.coverageLabel) }
                    LabeledContent("Size") {
                        Text(Format.fileSize(summary.sizeBytes))
                    }
                    if summary.identity.isPractice {
                        Label("Practice-device backup — not from your "
                              + "MicroFreak.", systemImage: "waveform.path")
                            .foregroundStyle(.purple)
                    }
                }
                Section {
                    Button {
                        model.requestRestore(from: folderName)
                    } label: {
                        Label("Restore…",
                              systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(!model.connection.hasDevice
                              || model.operations.exclusiveLongOp != nil)
                    ShareLink(item: summary.path) {
                        Label("Export Folder",
                              systemImage: "square.and.arrow.up")
                    }
                }
                Section("Slots (\(records.count))") {
                    ForEach(records, id: \.slot) { record in
                        recordRow(record)
                    }
                }
            } else {
                ContentUnavailableView("Backup not found",
                                       systemImage: "externaldrive.badge.xmark")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folderName)
    }

    private func recordRow(_ record: SlotRecord) -> some View {
        let slot = SlotID(record.slot)
        return HStack(spacing: 12) {
            SlotNumberLabel(slot: slot)
            Text(record.name ?? "—")
                .lineLimit(1)
            Spacer()
            Text(Format.shaPrefix(record.sha256, length: 8))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .draggable(PresetTransfer(
            source: .backup(path: summary?.path.path ?? folderName,
                            slot: slot),
            displayName: record.name ?? "Slot \(slot.display)"))
        .contextMenu {
            Button {
                model.requestRestore(from: folderName,
                                     scope: .singleSlot(slot))
            } label: {
                Label("Restore slot \(slot.display)…",
                      systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.connection.hasDevice)
        }
    }

    // §11 identity separation lives in AppModel.requestRestore(from:scope:)
    // — every entry point (this view, list context menus, per-slot and
    // torn-slot recovery) funnels through it, so the cross-identity warning
    // cannot be bypassed.
}

#Preview("Backup detail") {
    PreviewHost { _ in
        NavigationStack { BackupDetailView(folderName: "2026-09-01-120000") }
    }
}
