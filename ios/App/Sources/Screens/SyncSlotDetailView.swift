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
                baselineSection(row)
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

    private var baselineName: String {
        model.sync.baseline?.name ?? "the collection"
    }

    private func baselineSection(_ row: SlotDiff) -> some View {
        Section("In '\(baselineName)'") {
            if let ref = row.baseline {
                LabeledContent("Name") {
                    // The catalog is keyed by CONTENT, not by slot claims:
                    // link out only when the library actually holds these bytes.
                    if let entry = model.libraryModel
                        .entriesSharing(sha256: ref.sha256).first {
                        Button(ref.name) {
                            model.detail = .libraryEntry(entry.id)
                        }
                    } else {
                        Text(ref.name)
                    }
                }
                LabeledContent("SHA-256") {
                    Text(Format.shaPrefix(ref.sha256))
                        .font(.caption.monospaced())
                }
                if model.libraryModel.entriesSharing(sha256: ref.sha256).isEmpty {
                    Text("These bytes are not in your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("'\(baselineName)' says nothing about this slot — it is "
                     + "not part of this arrangement.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ row: SlotDiff) -> some View {
        if row.status == .inSync, row.nameDiffers {
            Section {
                Label("Names differ; contents identical. A name difference "
                      + "never changes sync status — the diff is "
                      + "content-based — but it is still a difference: "
                      + "'Make Device Match' rewrites this slot.",
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
            case .unlisted:
                Button("Save to Library (instant — bytes already on disk)") {
                    model.syncSaveRowToLibrary(row)
                }
                Button("Add to '\(baselineName)' at slot \(slot.display) "
                       + "(local — no device write)") {
                    model.syncAdoptRowIntoBaseline(row)
                }
            case .baselineOnly:
                Button("Send to Device (verified write)") {
                    model.syncSendBaselineRow(row)
                }
                .disabled(!deviceReady)
            case .differs:
                Button("Send '\(baselineName)'s Preset to Device "
                       + "(verified write)") {
                    model.syncSendBaselineRow(row)
                }
                .disabled(!deviceReady)
                Button("Update '\(baselineName)' from Device (local — the "
                       + "collection adopts what is on the synth)") {
                    model.syncAdoptRowIntoBaseline(row)
                }
                Button("Save Device Preset to Library (instant)") {
                    model.syncSaveRowToLibrary(row)
                }
            case .inSync where row.nameDiffers:
                // Contents match, names do not. `planApply` WRITES this slot,
                // so the screen must offer the same two resolutions rather
                // than presenting it as settled.
                Button("Send '\(baselineName)'s Name to Device "
                       + "(verified write)") {
                    model.syncSendBaselineRow(row)
                }
                .disabled(!deviceReady)
                Button("Update '\(baselineName)' from Device (local — the "
                       + "collection adopts the device's name)") {
                    model.syncAdoptRowIntoBaseline(row)
                }
                Button("Open in browser") { model.detail = .slot(slot) }
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
