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
    /// Read from the sidecar in `.task`, never in a body pass — notes live in
    /// their own file (docs/voice-notes.md §0) and a list must not touch disk.
    @State private var notes: [PresetNote] = []
    @State private var noteDraft = ""
    @State private var correcting: PresetNote?
    @State private var correctionDraft = ""

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
        .task(id: entryID) { await reloadNotes() }
    }

    private func reloadNotes() async {
        notes = await model.libraryModel.notes(for: entryID)
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
                VerdictPickerRow(verdict: entry.verdict) { newVerdict in
                    Task { await model.libraryModel
                        .setVerdict(id: entry.id, newVerdict) }
                }
            }

            Section("Tags") {
                TagEditor(tags: entry.tags) { tag in
                    Task { await model.libraryModel.addTag(id: entry.id, tag) }
                } remove: { tag in
                    Task { await model.libraryModel.removeTag(id: entry.id, tag) }
                }
            }

            notesSection(entry)

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
                // "Hear it now" — one preset, same borrowed-slot guarantee.
                AuditionButton(titleKey: "Audition this preset…") {
                    model.auditionRequest(for: entry)
                }
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
        // A correction is a SIBLING of the verbatim text, never a replacement:
        // the original stays so a mishearing is always distinguishable from
        // something the user actually said (docs/voice-notes.md §3 rule 1).
        .alert("Correct this note",
               isPresented: Binding(get: { correcting != nil },
                                    set: { if !$0 { correcting = nil } })) {
            TextField("What you meant", text: $correctionDraft)
            Button("Save") {
                if let note = correcting {
                    Task {
                        await model.libraryModel.correctNote(
                            note, on: entry.id, to: correctionDraft)
                        await reloadNotes()
                    }
                }
                correcting = nil
            }
            Button("Clear Correction", role: .destructive) {
                if let note = correcting {
                    Task {
                        await model.libraryModel.correctNote(note, on: entry.id,
                                                             to: nil)
                        await reloadNotes()
                    }
                }
                correcting = nil
            }
            Button("Cancel", role: .cancel) { correcting = nil }
        } message: {
            Text("The words that were heard are kept exactly as they were. "
                 + "Your correction is stored alongside them.")
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

    // ---------------------------------------------------------------- notes
    //
    // What was said (or typed) about this preset, verbatim. Two rules are
    // visible here and both are deliberate:
    //
    //   The transcript is NEVER edited. "Correct…" writes a SIBLING field and
    //   leaves the original in place, which is the only way the user can tell
    //   a mishearing from something they actually said.
    //
    //   Nothing in this section is consulted to decide the entry's verdict,
    //   category or tags. Those live in the sections above; this one is
    //   provenance. Delete every note and the library is exactly as correct.

    @ViewBuilder
    private func notesSection(_ entry: LibraryEntry) -> some View {
        Section("Notes") {
            // A note write that fails has to say so HERE: the audition cover
            // is the only other surface that renders a note failure, and it is
            // long gone by the time anyone edits a note from the library.
            if let failure = model.libraryModel.noteFailure
                ?? model.voiceNotes.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    NoteRowView(note: note)
                    HStack(spacing: 16) {
                        Button {
                            correctionDraft = note.textCorrected ?? note.text
                            correcting = note
                        } label: {
                            Label("Correct…", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task {
                                await model.libraryModel.deleteNote(note,
                                                                    on: entry.id)
                                await reloadNotes()
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if notes.isEmpty {
                Text("No notes yet. Turn on voice notes in the audition setup "
                     + "to talk while you play, or type one here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField("Add a note", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("Add") { addTypedNote(entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespaces)
                        .isEmpty)
            }
        }
    }

    private func addTypedNote(_ entry: LibraryEntry) {
        let text = noteDraft
        noteDraft = ""
        Task { @MainActor in
            await model.voiceNotes.addTypedNote(text, to: entry.id, app: model)
            await reloadNotes()
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
