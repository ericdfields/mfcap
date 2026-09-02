// LibraryEntryDetailView.swift — library-entry detail (UX §7, library
// flavor). Same layout skeleton as SlotDetailView, differing in the action
// row. Rename is local and instant; when the entry is content-in-sync with
// a device slot an inline follow-up offers "Also rename on device?"
// (default no) — a name difference never changes sync status (UX §8.3).

import SwiftUI
import UIKit
import FreakCore

struct LibraryEntryDetailView: View {
    @Environment(AppModel.self) private var model
    let entryID: String

    @State private var renaming = false
    @State private var shaExpanded = false
    @State private var offerDeviceRename: (slot: SlotID, name: String)?
    @State private var exporting = false
    @State private var exportDocument: MFPresetDocument?
    @State private var confirmDelete = false

    private var entry: LibraryEntry? { model.libraryModel.entry(id: entryID) }

    var body: some View {
        Group {
            if let entry {
                detail(entry)
            } else {
                // EntryNotFound: the list refreshed under us (UX §14).
                ContentUnavailableView("That preset is no longer in the library.",
                                       systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(entry?.name ?? "Preset")
    }

    private func detail(_ entry: LibraryEntry) -> some View {
        List {
            Section {
                if renaming {
                    RenameField(original: entry.name) { newName in
                        renaming = false
                        commitRename(entry, to: newName)
                    } cancel: {
                        renaming = false
                    }
                    .font(.title2)
                } else {
                    HStack {
                        Button {
                            renaming = true
                        } label: {
                            HStack {
                                Text(entry.name).font(.title2.weight(.semibold))
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        FavoriteToggle(isFavorite: entry.favorite) {
                            Task { await model.libraryModel
                                .toggleFavorite(id: entry.id) }
                        }
                    }
                }
                if let corrupt = model.libraryModel.corruptEntries[entry.id] {
                    Label("Blob file damaged: \(corrupt)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Remove Entry", role: .destructive) {
                        Task { try? await model.libraryModel.delete(id: entry.id) }
                    }
                }
            }

            Section {
                LabeledContent("Slot claim") {
                    if let slot = entry.slot {
                        Button("→ slot \(SlotID(slot).display)") {
                            model.detail = .slot(SlotID(slot))
                        }
                    } else {
                        Text("no slot assigned").foregroundStyle(.secondary)
                    }
                }
                ShaRow(sha256: entry.sha256, expanded: $shaExpanded)
                LabeledContent("Added") {
                    Text(Format.parseCoreTimestamp(entry.addedAt)
                        .map { Format.relativeAge($0) } ?? entry.addedAt)
                }
                // Editable category — where a wrong device-byte auto-fill is
                // corrected (UX addendum §22.3).
                CategoryPickerRow(category: entry.category) { newCategory in
                    Task { await model.libraryModel
                        .setCategory(id: entry.id, newCategory) }
                }
            }

            Section("Tags") {
                TagEditor(tags: entry.tags) { tag in
                    Task { await model.libraryModel.addTag(id: entry.id, tag) }
                } remove: { tag in
                    Task { await model.libraryModel.removeTag(id: entry.id, tag) }
                }
            }

            Section("Provenance") {
                if let slot = entry.slot {
                    Text("Assigned to device slot \(SlotID(slot).display)")
                        .foregroundStyle(.secondary)
                }
                let sharing = model.libraryModel
                    .entriesSharing(sha256: entry.sha256)
                    .filter { $0.id != entry.id }
                if !sharing.isEmpty {
                    Text("Bytes shared with \(sharing.count) other "
                         + "entr\(sharing.count == 1 ? "y" : "ies").")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    model.requestSlotPicker(for: [
                        PresetTransfer(source: .library(entryID: entry.id),
                                       displayName: entry.name)])
                } label: {
                    Label("Send to Slot…", systemImage: "arrow.right.square")
                }
                .disabled(!model.connection.hasDevice)
                Button {
                    model.requestAssignSlotPicker(entryID: entry.id)
                } label: {
                    Label("Assign Slot… (library only)",
                          systemImage: "number.square")
                }
                Button {
                    Task { @MainActor in
                        if let preset = try? await model.libraryModel
                            .preset(id: entry.id) {
                            exportDocument = MFPresetDocument(preset: preset)
                            exporting = true
                        }
                    }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { _ = try? await model.libraryModel.duplicate(id: entry.id) }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .mfPreset,
                      defaultFilename: entry.name) { _ in }
        .alert("Also rename on device?",
               isPresented: Binding(
                   get: { offerDeviceRename != nil },
                   set: { if !$0 { offerDeviceRename = nil } })) {
            Button("Rename slot \(offerDeviceRename?.slot.display ?? 0)") {
                if let offer = offerDeviceRename {
                    model.renameSlot(offer.slot, to: offer.name)
                }
                offerDeviceRename = nil
            }
            Button("Library Only", role: .cancel) { offerDeviceRename = nil }
        } message: {
            Text("This entry's bytes are in sync with the device slot. A "
                 + "name difference never changes sync status; the sync row "
                 + "would show a 'names differ' hint.")
        }
        .alert("Delete '\(entry.name)'?", isPresented: $confirmDelete) {
            Button("Delete Entry", role: .destructive) {
                Task {
                    try? await model.libraryModel.delete(id: entry.id)
                    model.detail = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(entry))
        }
    }

    /// Local rename, instant; then the honest device follow-up (UX §8.3).
    private func commitRename(_ entry: LibraryEntry, to newName: String) {
        Task { @MainActor in
            try? await model.libraryModel.rename(id: entry.id, to: newName)
            if let slot = entry.slot,
               model.slots.record(SlotID(slot))?.sha256 == entry.sha256,
               model.connection.hasDevice {
                offerDeviceRename = (SlotID(slot), newName)
            }
        }
    }

    private func deleteMessage(_ entry: LibraryEntry) -> String {
        var lines: [String] = []
        if let facts = model.libraryModel.deleteGuardFacts(id: entry.id) {
            lines.append(facts.sharedBy > 0
                ? "\(facts.sharedBy) other entr\(facts.sharedBy == 1 ? "y shares" : "ies share") these bytes — the blob file survives."
                : "The blob file is removed with the entry.")
        }
        if let slot = entry.slot,
           model.slots.record(SlotID(slot))?.sha256 == entry.sha256 {
            lines.append("Still on the device in slot \(SlotID(slot).display) "
                + "— deleting the library copy does not touch the device.")
        }
        return lines.joined(separator: "\n")
    }
}

#Preview("Library entry detail") {
    PreviewHost { _ in
        NavigationStack { LibraryEntryDetailView(entryID: "missing") }
    }
}
