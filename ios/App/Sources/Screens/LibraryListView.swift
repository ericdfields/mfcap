// LibraryListView.swift — the local collection (UX §6).
//
// Fully functional with no device attached. Flat list + tags + one optional
// slot assignment — the entire v1 organizational model, honestly. Rows are
// drag sources (multi-drag supported); delete has the §6 guard; corruption
// badges per entry; LibraryCorruptError renders full-screen.

import SwiftUI
import UniformTypeIdentifiers
import FreakCore

struct LibraryListView: View {
    @Environment(AppModel.self) private var model
    let tag: String?

    @State private var showImporter = false
    @State private var showImportDevice = false
    @State private var deleteCandidate: LibraryEntry?
    @State private var renamingEntry: String?

    var body: some View {
        @Bindable var libraryModel = model.libraryModel
        Group {
            if let failure = model.libraryModel.openFailure {
                corruptState(failure)
            } else if model.libraryModel.entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .navigationTitle(tag.map { "Library · \($0)" } ?? "Library")
        // §8.1 drop table: slot row → library list saves to library;
        // .mfpreset files dropped from Files import here too.
        .dropDestination(for: PresetTransfer.self) { items, _ in
            guard !items.isEmpty else { return false }
            for item in items { model.saveTransferToLibrary(item) }
            return true
        }
        .searchable(text: $libraryModel.searchText, prompt: "Name or tag")
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.mfPreset, .json, .data],
                      allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .confirmationDialog(
            "Import the whole device?",
            isPresented: $showImportDevice, titleVisibility: .visible) {
            Button("Import (skip empty-judged slots)") {
                model.importDeviceToLibrary(skipExpendable: true)
            }
            Button("Import everything, including empties") {
                model.importDeviceToLibrary(skipExpendable: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs off the latest complete backup. Expendable slots are "
                 + "skipped by default.")
        }
        .alert(item: $deleteCandidate) { entry in
            deleteAlert(entry)
        }
    }

    // ---------------------------------------------------------------- list

    private var entryList: some View {
        List {
            ForEach(model.libraryModel.filtered(tag: tag)) { entry in
                LibraryRowView(entry: entry, renamingEntry: $renamingEntry,
                               requestDelete: { deleteCandidate = $0 })
            }
        }
        .listStyle(.plain)
    }

    // -------------------------------------------------------------- states

    /// Teaching state with the three §6 CTAs.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "books.vertical")
        } description: {
            Text("Presets saved here live on the iPad and work without "
                 + "the synth.")
        } actions: {
            Button("Save presets from the device") {
                model.sidebar = .device
            }
            .buttonStyle(.borderedProminent)
            Button("Import the whole device") { showImportDevice = true }
                .buttonStyle(.bordered)
            Button("Import a file") { showImporter = true }
                .buttonStyle(.bordered)
        }
    }

    /// LibraryCorruptError → full-screen, names the path, never deletes
    /// silently (UX §14).
    private func corruptState(_ failure: LibraryModel.OpenFailure) -> some View {
        ContentUnavailableView {
            Label("Library can't be opened",
                  systemImage: "exclamationmark.triangle")
        } description: {
            Text("The library index at \(failure.path) is damaged: "
                 + "\(failure.detail)\nNothing has been deleted.")
        } actions: {
            Button("Move Aside & Start Fresh") {
                model.libraryModel.moveAsideAndStartFresh()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // -------------------------------------------------------------- toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: Binding(
                    get: { model.libraryModel.sort },
                    set: { model.libraryModel.sort = $0 })) {
                    ForEach(LibraryModel.Sort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Menu {
                Button("Import File…") { showImporter = true }
                Button("Import Device…") { showImportDevice = true }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
    }

    // -------------------------------------------------------------- intents

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task { @MainActor in
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let preset = try MFPresetFile.decode(
                        data: data, filename: url.lastPathComponent)
                    _ = try await model.libraryModel.add(preset, slot: nil,
                                                         tags: [])
                    model.toasts.show("Imported '\(preset.name)'")
                } catch FreakError.blobSize(let expected, let actual) {
                    // §14's specific import line.
                    model.toasts.show("Not a MicroFreak preset (expected "
                        + "\(expected) bytes, got \(actual)).", isError: true)
                } catch let error as FreakError {
                    model.toasts.show("Import failed: \(error.userMessage)",
                                      isError: true)
                } catch {
                    model.toasts.show("Import failed: "
                        + "\(String(describing: error))", isError: true)
                }
            }
        }
    }

    /// §6 delete guard: names the entry, states blob survival and device
    /// impact honestly.
    private func deleteAlert(_ entry: LibraryEntry) -> Alert {
        var lines: [String] = []
        if let facts = model.libraryModel.deleteGuardFacts(id: entry.id) {
            lines.append(facts.sharedBy > 0
                ? "\(facts.sharedBy) other "
                    + "entr\(facts.sharedBy == 1 ? "y shares" : "ies share") "
                    + "these bytes — the blob file survives."
                : "No other entry shares these bytes — the blob file is "
                    + "removed.")
        }
        if let slot = entry.slot {
            let slotID = SlotID(slot)
            if model.slots.record(slotID)?.sha256 == entry.sha256 {
                lines.append("Still on the device in slot \(slotID.display) — "
                    + "deleting the library copy does not touch the device.")
            }
        }
        return Alert(
            title: Text("Delete '\(entry.name)' from the library?"),
            message: Text(lines.joined(separator: "\n")),
            primaryButton: .destructive(Text("Delete Entry")) {
                Task { try? await model.libraryModel.delete(id: entry.id) }
            },
            secondaryButton: .cancel())
    }
}

// =============================================================== row view

struct LibraryRowView: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    @Binding var renamingEntry: String?
    let requestDelete: (LibraryEntry) -> Void

    @State private var editingTags = false
    @State private var tagsText = ""
    @State private var exporting = false
    @State private var exportDocument: MFPresetDocument?

    var body: some View {
        HStack(spacing: 10) {
            if renamingEntry == entry.id {
                RenameField(original: entry.name) { newName in
                    renamingEntry = nil
                    Task {
                        try? await model.libraryModel.rename(id: entry.id,
                                                             to: newName)
                    }
                } cancel: {
                    renamingEntry = nil
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.body)
                    if !entry.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(entry.tags, id: \.self) { TagChip(tag: $0) }
                        }
                    }
                }
            }
            Spacer()
            if let detail = model.libraryModel.corruptEntries[entry.id] {
                SlotFlagBadge(flag: .verifyFailed)
                    .help(detail)
            }
            if let slot = entry.slot {
                Text("→ \(SlotID(slot).display)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            if let hint = syncHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { model.detail = .libraryEntry(entry.id) }
        .draggable(PresetTransfer(source: .library(entryID: entry.id),
                                  displayName: entry.name))
        .contextMenu { menuItems }
        .alert("Tags for '\(entry.name)'", isPresented: $editingTags) {
            TextField("comma, separated, tags", text: $tagsText)
            Button("Save") {
                let tags = tagsText.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                Task {
                    _ = try? await model.libraryModel.setTags(id: entry.id,
                                                              tags: tags)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(isPresented: $exporting,
                      document: exportDocument,
                      contentType: .mfPreset,
                      defaultFilename: entry.name) { _ in }
    }

    private var syncHint: String? {
        guard let slot = entry.slot,
              let status = model.slots.syncBadges[slot] else { return nil }
        switch status {
        case .inSync: return "in sync"
        case .differs: return "differs"
        case .libraryOnly: return "not on device"
        default: return nil
        }
    }

    @ViewBuilder
    private var menuItems: some View {
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
            Label("Assign Slot…", systemImage: "number.square")
        }
        if entry.slot != nil {
            Button {
                Task {
                    try? await model.libraryModel.assignSlot(id: entry.id,
                                                             slot: nil)
                }
            } label: {
                Label("Clear Slot Assignment", systemImage: "xmark.square")
            }
        }
        Button {
            renamingEntry = entry.id
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { _ = try? await model.libraryModel.duplicate(id: entry.id) }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            tagsText = entry.tags.joined(separator: ", ")
            editingTags = true
        } label: {
            Label("Tags…", systemImage: "tag")
        }
        Button {
            Task { @MainActor in
                if let preset = try? await model.libraryModel.preset(id: entry.id) {
                    exportDocument = MFPresetDocument(preset: preset)
                    exporting = true
                }
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            requestDelete(entry)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

#Preview("Library") {
    PreviewHost { _ in
        NavigationStack { LibraryListView(tag: nil) }
    }
}
