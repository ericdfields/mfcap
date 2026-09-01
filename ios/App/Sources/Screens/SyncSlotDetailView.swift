// SyncSlotDetailView.swift — one slot's diff, in full (UX §17).
//
// Both sides' names and shas, judgment evidence, the name-vs-content note
// (a name difference never changes sync status), a slot-history excerpt,
// and the same explicit actions with full context.

import SwiftUI
import FreakCore

struct SyncSlotDetailView: View {
    @Environment(AppModel.self) private var model
    let slot: SlotID

    private var row: SlotDiff? { model.sync.row(for: slot) }

    var body: some View {
        List {
            if let row {
                Section {
                    HStack {
                        Text("Slot \(slot.display)")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        SyncBadge(status: row.status)
                    }
                }
                deviceSection(row)
                librarySection(row)
                notesSection(row)
                actionsSection(row)
            } else {
                Section {
                    Text("No diff for this slot — run Read Device & Compare "
                         + "from the Sync view.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                SlotHistoryList(slot: slot)
            } header: {
                Text("Slot history")
            } footer: {
                Text("History of this app's activity — changes made on the "
                     + "synth itself appear only as differences at the next "
                     + "read.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sync · Slot \(slot.display)")
    }

    private func deviceSection(_ row: SlotDiff) -> some View {
        Section("On the device") {
            if let device = row.device {
                LabeledContent("Name") {
                    Text(device.name ?? "— read failed")
                }
                LabeledContent("SHA-256") {
                    Text(Format.shaPrefix(device.sha256))
                        .font(.caption.monospaced())
                }
                if let judgment = model.slots.record(slot)?.judgment {
                    LabeledContent("Judgment") {
                        HStack(spacing: 6) {
                            JudgmentDot(judgment: judgment)
                            Text(model.slots.record(slot)?.judgmentCopy ?? "")
                        }
                    }
                }
            } else {
                Text("Not part of the compared snapshot.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func librarySection(_ row: SlotDiff) -> some View {
        Section("In the library") {
            if let entry = row.library {
                LabeledContent("Name") {
                    Button(entry.name) {
                        model.detail = .libraryEntry(entry.id)
                    }
                }
                LabeledContent("SHA-256") {
                    Text(Format.shaPrefix(entry.sha256))
                        .font(.caption.monospaced())
                }
            } else {
                Text("No library entry claims this slot.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ row: SlotDiff) -> some View {
        if row.status == .inSync,
           let device = row.device, let entry = row.library,
           device.name != entry.name {
            Section {
                Label("Names differ; contents identical. A name difference "
                      + "never changes sync status — the diff is "
                      + "content-based.",
                      systemImage: "character.cursor.ibeam")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionsSection(_ row: SlotDiff) -> some View {
        Section {
            let deviceReady = model.connection.hasDevice
                && model.operations.exclusiveLongOp == nil
            switch row.status {
            case .deviceOnly:
                Button("Import to Library (instant — bytes already on disk)") {
                    model.syncImportRow(row)
                }
            case .libraryOnly:
                Button("Send to Device (verified write)") {
                    model.syncSendRow(row)
                }
                .disabled(!deviceReady)
            case .differs:
                Button("Push Library → Device (verified write)") {
                    model.syncPushRow(row)
                }
                .disabled(!deviceReady)
                Button("Pull Device → Library (instant; the new entry takes "
                       + "the slot claim, the old entry is kept)") {
                    model.syncPullRow(row)
                }
            case .inSync, .empty:
                Button("Open in browser") { model.detail = .slot(slot) }
            }
        }
    }
}

#Preview("Sync slot detail") {
    PreviewHost { _ in
        NavigationStack { SyncSlotDetailView(slot: SlotID(0)) }
    }
}
