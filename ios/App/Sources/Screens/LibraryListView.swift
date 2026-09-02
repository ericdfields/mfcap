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
    // Edit-mode multi-select for bulk attribute edits (UX addendum §22.4).
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var bulkTag = ""
    @State private var showBulkTag = false

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
        // Notes are searchable too: "the one I said sounded broken" is
        // how a preset actually gets found again.
        .searchable(text: $libraryModel.searchText,
                    prompt: "Name, tag or note")
        .safeAreaInset(edge: .top, spacing: 0) { facetHeader }
        .toolbar { toolbarContent }
        .alert("Add a tag to \(selectedIDs.count) presets",
               isPresented: $showBulkTag) {
            TextField("tag", text: $bulkTag)
            Button("Add") {
                let tag = bulkTag.trimmingCharacters(in: .whitespaces)
                bulkTag = ""
                guard !tag.isEmpty else { return }
                let ids = Array(selectedIDs)
                Task {
                    await model.libraryModel.addTag(ids: ids, tag)
                    model.toasts.show("Tagged \(ids.count) presets '\(tag)'.")
                }
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        }
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
        // Read the two wholesale-reassigned dictionaries ONCE per list body
        // instead of once per realized row: `syncBadges` is replaced entirely
        // on every recomputeSync(), which fires after every library mutation.
        let statusBySha = model.sync.statusBySha
        let baselineName = model.sync.baseline?.name
        let corrupt = model.libraryModel.corruptEntries
        // Note counts, like the two dictionaries above, are resolved ONCE per
        // list body: a row that subscribed to the whole cache itself would be
        // invalidated by a note taken about any other preset.
        let noteCounts = model.libraryModel.noteCounts
        return List {
            ForEach(model.libraryModel.filtered(tag: tag)) { entry in
                LibraryRowView(entry: entry, renamingEntry: $renamingEntry,
                               requestDelete: { deleteCandidate = $0 },
                               syncHint: LibraryRowView.syncHint(
                                   for: entry, statusBySha: statusBySha,
                                   baselineName: baselineName),
                               corruptDetail: corrupt[entry.id],
                               noteCount: noteCounts[entry.id] ?? 0,
                               selecting: selecting,
                               isSelected: selectedIDs.contains(entry.id),
                               onToggleSelect: { toggleSelect(entry.id) })
            }
        }
        .listStyle(.plain)
    }

    // ------------------------------------------- faceted header (§22, §23.2)

    @ViewBuilder
    private var facetHeader: some View {
        VStack(spacing: 0) {
            CategoryFilterBar()
            if !model.libraryModel.tagFilter.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.libraryModel.tagFilter).sorted(),
                                id: \.self) { tag in
                            Button {
                                model.libraryModel.tagFilter.remove(tag)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("#\(tag)").font(.caption2)
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12),
                                            in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .background(.thinMaterial)
            }
        }
    }

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    private func endSelecting() {
        selecting = false
        selectedIDs.removeAll()
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
            if selecting {
                Menu {
                    Menu("Set Category…") {
                        ForEach(FreakCore.Category.displayOrder, id: \.self) { category in
                            Button(category.displayName) {
                                bulkSetCategory(category)
                            }
                        }
                    }
                    Button("Add Tag…") { showBulkTag = true }
                    Button("Favorite") { bulkSetFavorite(true) }
                    Button("Unfavorite") { bulkSetFavorite(false) }
                } label: {
                    Label("\(selectedIDs.count) selected",
                          systemImage: "checklist")
                }
                .disabled(selectedIDs.isEmpty)
                Button("Done") { endSelecting() }
            } else {
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
                let allTags = model.libraryModel.allTagNames
                if !allTags.isEmpty {
                    Menu {
                        ForEach(allTags, id: \.self) { tag in
                            Button {
                                toggleTagFacet(tag)
                            } label: {
                                if model.libraryModel.tagFilter.contains(tag) {
                                    Label(tag, systemImage: "checkmark")
                                } else {
                                    Text(tag)
                                }
                            }
                        }
                    } label: { Label("Tags", systemImage: "tag") }
                }
                Button {
                    selecting = true
                } label: { Label("Select", systemImage: "checkmark.circle") }
                // Audition is a function of what you are looking at (§30):
                // this button queues exactly the rows below it.
                AuditionButton { model.auditionRequestForLibrary(tag: tag) }
                Menu {
                    Button("Import File…") { showImporter = true }
                    Button("Import Device…") { showImportDevice = true }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private func toggleTagFacet(_ tag: String) {
        if model.libraryModel.tagFilter.contains(tag) {
            model.libraryModel.tagFilter.remove(tag)
        } else {
            model.libraryModel.tagFilter.insert(tag)
        }
    }

    private func bulkSetCategory(_ category: FreakCore.Category) {
        let ids = Array(selectedIDs)
        Task {
            await model.libraryModel.setCategory(ids: ids, category)
            model.toasts.show("Set \(ids.count) presets to \(category.displayName).")
        }
        endSelecting()
    }

    private func bulkSetFavorite(_ favorite: Bool) {
        let ids = Array(selectedIDs)
        Task {
            await model.libraryModel.setFavorite(ids: ids, favorite)
            model.toasts.show((favorite ? "Favorited " : "Unfavorited ")
                + "\(ids.count) presets.")
        }
        endSelecting()
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
    /// Resolved once per list body by the owning screen — a row that
    /// subscribed to `slots.syncBadges` / `libraryModel.corruptEntries`
    /// itself was invalidated by every unrelated library mutation.
    var syncHint: String? = nil
    var corruptDetail: String? = nil
    /// How many notes this preset carries. Resolved by the owning list from
    /// `LibraryModel.noteCounts`, which is a cache of the sidecars — a row
    /// never touches the file system.
    var noteCount = 0
    /// Edit-mode multi-select (UX addendum §22.4); off by default so
    /// FavoritesListView and others get the plain row.
    var selecting = false
    var isSelected = false
    var onToggleSelect: (() -> Void)? = nil

    @State private var editingTags = false
    @State private var exporting = false
    @State private var exportDocument: MFPresetDocument?

    var body: some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: isSelected
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityLabel(isSelected ? "selected" : "not selected")
            }
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
                    HStack(spacing: 4) {
                        CategoryBadge(category: entry.category)
                        VerdictBadge(verdict: entry.verdict)
                        NoteCountBadge(count: noteCount)
                        ForEach(entry.tags, id: \.self) { TagChip(tag: $0) }
                    }
                }
            }
            Spacer()
            FavoriteToggle(isFavorite: entry.favorite) {
                Task { await model.libraryModel.toggleFavorite(id: entry.id) }
            }
            if let corruptDetail {
                SlotFlagBadge(flag: .verifyFailed)
                    .help(corruptDetail)
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
        .onTapGesture {
            if selecting { onToggleSelect?() }
            else { model.detail = .libraryEntry(entry.id) }
        }
        .draggable(PresetTransfer(source: .library(entryID: entry.id),
                                  displayName: entry.name))
        .contextMenu { menuItems }
        .sheet(isPresented: $editingTags) {
            TagEditorSheet(entry: entry)
        }
        .fileExporter(isPresented: $exporting,
                      document: exportDocument,
                      contentType: .mfPreset,
                      defaultFilename: entry.name) { _ in }
    }

    /// Pure lookup, so the owning list can resolve it once for every row.
    ///
    /// Keyed on CONTENT, not on a slot claim: the catalog is a flat set of
    /// unique patches with no slot opinion, so an entry's relationship to the
    /// device is found by its bytes and reported against the collection Sync
    /// is comparing to.
    static func syncHint(for entry: LibraryEntry,
                         statusBySha: [String: SlotStatus],
                         baselineName: String?) -> String? {
        guard let status = statusBySha[entry.sha256] else { return nil }
        let suffix = baselineName.map { " in '\($0)'" } ?? ""
        switch status {
        case .inSync: return "in sync\(suffix)"
        case .differs: return "differs on device"
        case .baselineOnly: return "not on device"
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
            editingTags = true
        } label: {
            Label("Tags…", systemImage: "tag")
        }
        Menu {
            ForEach(FreakCore.Category.displayOrder, id: \.self) { category in
                Button {
                    Task { await model.libraryModel.setCategory(id: entry.id, category) }
                } label: {
                    if entry.category == category {
                        Label(category.displayName, systemImage: "checkmark")
                    } else {
                        Text(category.displayName)
                    }
                }
            }
        } label: {
            Label("Category…", systemImage: "square.grid.2x2")
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

// =============================================================== tag editor

/// The add/remove tag sheet (UX addendum §23.1), reading the live entry so
/// chips update as tags are edited. Replaces the base comma-string alert.
struct TagEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry

    private var current: LibraryEntry {
        model.libraryModel.entry(id: entry.id) ?? entry
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tags") {
                    TagEditor(tags: current.tags) { tag in
                        Task { await model.libraryModel.addTag(id: entry.id, tag) }
                    } remove: { tag in
                        Task { await model.libraryModel.removeTag(id: entry.id, tag) }
                    }
                }
            }
            .navigationTitle("Tags for \(entry.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Library") {
    PreviewHost { _ in
        NavigationStack { LibraryListView(tag: nil) }
    }
}
