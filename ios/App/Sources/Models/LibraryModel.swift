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
    /// Fires after any library mutation so dependents (sync diff) recompute.
    var onChange: (@MainActor () -> Void)?

    init(root: URL) {
        self.root = root
    }

    // ------------------------------------------------------------- opening

    /// Open-or-create (architecture spec §10.2 idiom). A corrupt index is a
    /// full-screen error naming the path — never silently deleted.
    func openOrCreate() {
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
        Array(Set(entries.flatMap(\.tags))).sorted()
    }

    func entry(id: String) -> LibraryEntry? {
        entries.first { $0.id == id }
    }

    func entryClaiming(slot: SlotID) -> LibraryEntry? {
        entries.first { $0.slot == slot.raw }
    }

    func entriesSharing(sha256: String) -> [LibraryEntry] {
        entries.filter { $0.sha256 == sha256 }
    }

    func filtered(tag: String?) -> [LibraryEntry] {
        var out = entries
        if let tag { out = out.filter { $0.tags.contains(tag) } }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            out = out.filter {
                $0.name.lowercased().contains(query)
                    || $0.tags.contains { $0.lowercased().contains(query) }
            }
        }
        switch sort {
        case .name:
            return out.sorted {
                ($0.name.lowercased(), $0.addedAt) < ($1.name.lowercased(), $1.addedAt)
            }
        case .dateAdded:
            return out.sorted { $0.addedAt > $1.addedAt }
        case .slot:
            return out.sorted {
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

    func add(_ preset: Preset, slot: SlotID?, tags: [String]) async throws
        -> LibraryEntry {
        guard let library else {
            throw FreakError.libraryNotFound(path: root.path)
        }
        let entry = try await library.add(preset, slot: slot?.raw, tags: tags)
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

    /// Edit an entry's tags. The core has no in-place tag mutation, so this
    /// is re-add (same bytes, same name, same slot claim, new tags) followed
    /// by removal of the old entry — the entry id and added-at change, which
    /// callers must expect. FLAGGED for a core-side `setTags` later.
    func setTags(id: String, tags: [String]) async throws -> LibraryEntry? {
        guard let library, let old = entry(id: id) else { return nil }
        let preset = try await preset(id: id)
        try await library.remove(id: id)
        let replacement = try await library.add(preset, slot: old.slot,
                                                tags: tags)
        await refresh()
        return replacement
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
