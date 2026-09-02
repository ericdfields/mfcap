// LibraryModel.swift — entries cache mirroring the FreakCore Library actor
// (UX §6, §18.2). Local-only: this model never touches the device.
//
// v1 organizational model, kept honest: flat list + tags + one optional slot
// assignment per entry. No folders, no smart groups, no ratings, no iCloud.

import Foundation
import FreakCore

@MainActor @Observable
final class LibraryModel {
    enum Sort: String, CaseIterable, Identifiable {
        case name, dateAdded, slot
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "Name"
            case .dateAdded: return "Date Added"
            case .slot: return "Slot"
            }
        }
    }

    /// LibraryCorruptError on open → the full-screen state (UX §6).
    struct OpenFailure: Equatable {
        let path: String
        let detail: String
    }

    let root: URL
    private(set) var library: Library?
    private(set) var entries: [LibraryEntry] = []
    private(set) var openFailure: OpenFailure?
    /// Entry id → integrity detail (corruption badge on the row, UX §6).
    private(set) var corruptEntries: [String: String] = [:]

    var searchText = ""
    var sort: Sort = .name
    /// Faceted-filter state (UX addendum §21.3). All compose with AND; the
    /// browser and its chip grid read the same derived helpers below.
    var categoryFilter: FreakCore.Category?          // nil = all categories
    var tagFilter: Set<String> = []        // AND across selected tags
    var favoritesOnly = false              // set by the Favorites selection (§24)
    /// Fires after any library mutation so dependents (sync diff) recompute.
    var onChange: (@MainActor () -> Void)?

    /// First-run seeding of the bundled starter library (README in
    /// App/Resources/SeedBanks). Off for previews/tests (ephemeral sandboxes).
    private let seedFromBundle: Bool

    init(root: URL, seedFromBundle: Bool = false) {
        self.root = root
        self.seedFromBundle = seedFromBundle
    }

    // ------------------------------------------------------------- opening

    /// Open-or-create (architecture spec §10.2 idiom). A corrupt index is a
    /// full-screen error naming the path — never silently deleted.
    func openOrCreate() {
        // First launch with no user library: copy the bundled starter library
        // in place before opening, so a new install opens fully populated.
        if seedFromBundle {
            SeedInstaller.installIfNeeded(libraryRoot: root)
        }
        do {
            library = try Library.open(at: root)
            openFailure = nil
        } catch FreakError.libraryNotFound {
            do {
                library = try Library.create(at: root)
                openFailure = nil
            } catch let error as FreakError {
                openFailure = OpenFailure(path: root.path,
                                          detail: error.userMessage)
            } catch {
                openFailure = OpenFailure(path: root.path,
                                          detail: String(describing: error))
            }
        } catch let error as FreakError {
            openFailure = OpenFailure(path: root.path, detail: error.userMessage)
        } catch {
            openFailure = OpenFailure(path: root.path,
                                      detail: String(describing: error))
        }
        Task { await refresh() }
    }

    /// "Move Aside & Start Fresh" (UX §14 LibraryCorruptError) — renames the
    /// folder next to itself, then creates a new library.
    func moveAsideAndStartFresh() {
        let aside = root.deletingLastPathComponent()
            .appendingPathComponent("Library-corrupt-\(AppPaths.backupStamp())")
        try? FileManager.default.moveItem(at: root, to: aside)
        openOrCreate()
    }

    func refresh() async {
        guard let library else { return }
        entries = await library.entries()
        onChange?()
    }

    // -------------------------------------------------------------- reads

    var tags: [String] {
        Attributes.allTags(entries)
    }

    func entry(id: String) -> LibraryEntry? {
        entries.first { $0.id == id }
    }

    /// Favorited entries in the current sort (UX addendum §24.3).
    var favorites: [LibraryEntry] {
        sortedForDisplay(entries.filter(\.favorite))
    }

    /// Does a favorited entry hold these exact bytes? Drives the device-row
    /// and device-detail heart (UX addendum §24.2).
    func favoritedSha(_ sha256: String) -> Bool {
        entries.contains { $0.sha256 == sha256 && $0.favorite }
    }

    /// Per-category counts, faceted over every active facet EXCEPT the
    /// category filter itself (standard faceted search, UX addendum §22.2).
    /// Every FreakCore.Category key is present (0 when none) so the chip row is stable.
    var categoryCounts: [FreakCore.Category: Int] {
        Attributes.categoryCensus(entries.filter { matches($0, ignoreCategory: true) })
    }

    func entryClaiming(slot: SlotID) -> LibraryEntry? {
        entries.first { $0.slot == slot.raw }
    }

    func entriesSharing(sha256: String) -> [LibraryEntry] {
        entries.filter { $0.sha256 == sha256 }
    }

    /// The browser's rows: every active facet (category ∧ tagFilter ∧
    /// favorite ∧ search) plus the sidebar's legacy single-tag selection,
    /// composed with AND (UX addendum §21.3), then sorted.
    func filtered(tag: String?) -> [LibraryEntry] {
        sortedForDisplay(entries.filter { entry in
            matches(entry) && (tag == nil || entry.tags.contains(tag!))
        })
    }

    /// One matcher, so the chip counts and the list can never disagree.
    /// `ignoreCategory` powers the faceted category census (§22.2).
    private func matches(_ entry: LibraryEntry,
                         ignoreCategory: Bool = false) -> Bool {
        if !ignoreCategory, let categoryFilter, entry.category != categoryFilter {
            return false
        }
        if favoritesOnly, !entry.favorite { return false }
        if let verdictFilter, entry.verdict != verdictFilter { return false }
        if !tagFilter.isSubset(of: Set(entry.tags)) { return false }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let hit = entry.name.lowercased().contains(query)
                || entry.tags.contains { $0.lowercased().contains(query) }
            if !hit { return false }
        }
        return true
    }

    private func sortedForDisplay(_ list: [LibraryEntry]) -> [LibraryEntry] {
        switch sort {
        case .name:
            return list.sorted {
                ($0.name.lowercased(), $0.addedAt) < ($1.name.lowercased(), $1.addedAt)
            }
        case .dateAdded:
            return list.sorted { $0.addedAt > $1.addedAt }
        case .slot:
            return list.sorted {
                ($0.slot ?? Int.max, $0.name) < ($1.slot ?? Int.max, $1.name)
            }
        }
    }

    /// Facts for the delete guard (UX §6): does the blob file survive?
    func deleteGuardFacts(id: String) -> (sharedBy: Int, name: String)? {
        guard let entry = entry(id: id) else { return nil }
        return (entriesSharing(sha256: entry.sha256).count - 1, entry.name)
    }

    /// Resolve an entry's bytes. Marks the row corrupt on IntegrityError.
    func preset(id: String) async throws -> Preset {
        guard let library else {
            throw FreakError.entryNotFound(entryID: id)
        }
        do {
            let preset = try await library.get(id: id)
            corruptEntries[id] = nil
            return preset
        } catch let error as FreakError {
            if case .integrity(_, let detail) = error {
                corruptEntries[id] = detail
            }
            throw error
        }
    }

    // ---------------------------------------------- local mutations (no device)

    func add(_ preset: Preset, slot: SlotID?, tags: [String],
             category: FreakCore.Category = .uncategorized,
             favorite: Bool = false) async throws -> LibraryEntry {
        guard let library else {
            throw FreakError.libraryNotFound(path: root.path)
        }
        let entry = try await library.add(preset, slot: slot?.raw, tags: tags,
                                          category: category, favorite: favorite)
        await refresh()
        return entry
    }

    func rename(id: String, to name: String) async throws {
        guard let library else { return }
        _ = try await library.renameEntry(id: id, to: name)
        await refresh()
    }

    func delete(id: String) async throws {
        guard let library else { return }
        try await library.remove(id: id)
        corruptEntries[id] = nil
        await refresh()
    }

    func assignSlot(id: String, slot: SlotID?) async throws {
        guard let library else { return }
        try await library.assignSlot(id: id, slot: slot?.raw)
        await refresh()
    }

    func duplicate(id: String) async throws -> LibraryEntry? {
        guard let source = entry(id: id) else { return nil }
        let preset = try await preset(id: id)
        return try await add(preset, slot: nil, tags: source.tags)
    }

    // -------------------------------------------- attribute edits (id-stable)
    //
    // Backed by the core's in-place index mutators (data-model spec §2.4):
    // the blob, id, slot claim, and added-at are all preserved; only the
    // index entry is rewritten, atomically per edit. None touch the device.

    /// Replace an entry's tags. The UI owns add/remove; the core stores the
    /// final set (UX addendum §23.1). id-stable — no longer the re-add hack.
    @discardableResult
    func setTags(id: String, tags: [String]) async throws -> LibraryEntry? {
        guard let library else { return nil }
        let updated = try await library.setTags(id: id, to: tags)
        await refresh()
        return updated
    }

    func addTag(id: String, _ tag: String) async {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let existing = entry(id: id) else { return }
        // Case-insensitive de-dupe (UX addendum §23.1).
        guard !existing.tags.contains(where: {
            $0.lowercased() == trimmed.lowercased() }) else { return }
        _ = try? await setTags(id: id, tags: existing.tags + [trimmed])
    }

    func removeTag(id: String, _ tag: String) async {
        guard let existing = entry(id: id) else { return }
        _ = try? await setTags(id: id, tags: existing.tags.filter { $0 != tag })
    }

    func setCategory(id: String, _ category: FreakCore.Category) async {
        guard let library else { return }
        _ = try? await library.setCategory(id: id, to: category)
        await refresh()
    }

    /// Bulk category assignment over a selection (UX addendum §22.4) — one
    /// atomic index rewrite per entry, all local, then a single refresh.
    func setCategory(ids: [String], _ category: FreakCore.Category) async {
        guard let library else { return }
        for id in ids {
            _ = try? await library.setCategory(id: id, to: category)
        }
        await refresh()
    }

    /// Audition verdict facet: nil = all; `.unrated` = "not yet judged".
    var verdictFilter: Verdict?

    func setVerdict(id: String, _ verdict: Verdict) async {
        guard let library else { return }
        _ = try? await library.setVerdict(id: id, to: verdict)
        await refresh()
    }

    func toggleFavorite(id: String) async {
        guard let library, let existing = entry(id: id) else { return }
        _ = try? await library.setFavorite(id: id, to: !existing.favorite)
        await refresh()
    }

    func setFavorite(id: String, _ favorite: Bool) async {
        guard let library else { return }
        _ = try? await library.setFavorite(id: id, to: favorite)
        await refresh()
    }

    // ------------------------------------------------------ collection bytes

    /// Resolve a collection's slot occupant to real bytes (data-model spec
    /// §4.4) — the standard resolver Apply pre-loads its changed slots from.
    func presetForRef(_ ref: PresetRef) async throws -> Preset {
        guard let library else {
            throw FreakError.libraryNotFound(path: root.path)
        }
        return try await library.presetForRef(ref)
    }

    /// Bulk import off a backup-built snapshot (UX §6 Import Device…).
    /// Expendable slots are skipped by default, stated in the sheet.
    func importSnapshot(_ snapshot: DeviceSnapshot, skipExpendable: Bool)
        async throws -> [LibraryEntry] {
        guard let library else {
            throw FreakError.libraryNotFound(path: root.path)
        }
        let added = try await library.importSnapshot(
            snapshot, skipExpendable: skipExpendable)
        await refresh()
        return added
    }
}
