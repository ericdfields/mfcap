// CollectionsModel.swift — the collection catalog mirror (UX addendum §26,
// §28.3). Local-only: this model never touches the device.
//
// Collections are owned by the FreakCore Library folder (data-model spec
// §4: <root>/collections/<id>.json), and the Library actor is their single
// writer. This model mirrors the parsed PresetCollection list for the UI and
// routes list/rename/delete/duplicate through the actor. Create-from-device
// and import-bank need the device / a file parse and so live on AppModel,
// which calls back here to refresh after a change.

import Foundation
import FreakCore

@MainActor @Observable
final class CollectionsModel {
    enum Sort: String, CaseIterable, Identifiable {
        case name, dateCreated, presetCount
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "Name"
            case .dateCreated: return "Date"
            case .presetCount: return "Preset Count"
            }
        }
    }

    private(set) var collections: [PresetCollection] = []
    /// Non-nil when the last scan of collections/*.json failed (a corrupt
    /// file names itself; the list still shows what parsed).
    private(set) var loadError: String?
    private(set) var scanning = false

    var sort: Sort = .name

    // ------------------------------------------------------------- reading

    var sorted: [PresetCollection] {
        switch sort {
        case .name:
            return collections.sorted {
                ($0.name.lowercased(), $0.createdAt) < ($1.name.lowercased(), $1.createdAt)
            }
        case .dateCreated:
            return collections.sorted { $0.createdAt > $1.createdAt }
        case .presetCount:
            return collections.sorted { $0.slots.count > $1.slots.count }
        }
    }

    func collection(id: String) -> PresetCollection? {
        collections.first { $0.id == id }
    }

    // ------------------------------------------------------------- driving

    /// Re-scan the library folder's collections. A missing folder is zero
    /// collections, never an error (data-model spec §4.4).
    func refresh(from library: Library?) async {
        guard let library else {
            collections = []
            return
        }
        scanning = true
        defer { scanning = false }
        do {
            collections = try await library.collections()
            loadError = nil
        } catch let error as FreakError {
            loadError = error.userMessage
        } catch {
            loadError = String(describing: error)
        }
    }

    func rename(id: String, to name: String, in library: Library?) async {
        guard let library else { return }
        _ = try? await library.renameCollection(id: id, to: name)
        await refresh(from: library)
    }

    func delete(id: String, in library: Library?) async {
        guard let library else { return }
        try? await library.deleteCollection(id: id)
        await refresh(from: library)
    }

    /// Duplicate mints a fresh id + created stamp with a " copy" name, reusing
    /// the same content-addressed refs (no blob copy). Provenance carried over.
    func duplicate(id: String, in library: Library?) async {
        guard let library, let source = collection(id: id) else { return }
        let copy = PresetCollection.new(name: source.name + " copy",
                                        provenance: source.provenance,
                                        slots: source.slots)
        try? await library.saveCollection(copy)
        await refresh(from: library)
    }
}
