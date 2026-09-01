// Library.swift — a local folder of content-addressed preset blobs +
// index.json (port of library.py). An actor: single-writer semantics with
// data-race freedom under Swift 6.
//
//     <root>/
//       index.json                 {"schema": 1, "entries": [entry...]}
//       blobs/<sha256>.bin         content-addressed 4672-byte blobs
//                                  (269 Inits cost one file)
//
// Index writes are atomic (temp file + rename). Single-writer assumption;
// no cross-process locking. Every get() re-hashes the blob file against its
// filename (.integrity on rot). Interop encodings pinned by §10: entry ids
// are uuid4 hex — lowercase, 32 chars, NO hyphens; timestamps are
// "yyyy-MM-dd'T'HH:mm:ss" local; `slot: null` is written explicitly for an
// unassigned entry.

import Foundation

private let librarySchema = 1

public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let id: String            // uuid4 hex; minted at add(); survives renames
    public let name: String
    public let sha256: String
    public let metaHex: String       // 18 hex chars, round-trips Preset.meta
    public let slot: Int?            // desired device slot; at most one entry per slot
    public let addedAt: String
    public let tags: [String]

    public init(id: String, name: String, sha256: String, metaHex: String,
                slot: Int?, addedAt: String, tags: [String]) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.metaHex = metaHex
        self.slot = slot
        self.addedAt = addedAt
        self.tags = tags
    }

    fileprivate func with(name: String? = nil, slot: Int?? = nil) -> LibraryEntry {
        LibraryEntry(id: id, name: name ?? self.name, sha256: sha256,
                     metaHex: metaHex, slot: slot ?? self.slot,
                     addedAt: addedAt, tags: tags)
    }
}

public actor Library {
    public nonisolated let root: URL
    private var entriesList: [LibraryEntry]

    /// Internal designated init — production code goes through create/open.
    init(root: URL, entries: [LibraryEntry]) {
        self.root = root
        self.entriesList = entries
    }

    // ------------------------------------------------------------ open/create

    /// Create a NEW library. Throws .libraryExists if root already holds an
    /// index.json (creating over an existing library would orphan its blobs).
    @discardableResult
    public static func create(at root: URL) throws -> Library {
        let indexPath = root.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexPath.path) {
            throw FreakError.libraryExists(path: indexPath.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("blobs"),
                withIntermediateDirectories: true)
        } catch {
            throw FreakError.integrity(path: root.path,
                                       detail: "cannot create library: \(error)")
        }
        try saveIndex(root: root, entries: [])
        return Library(root: root, entries: [])
    }

    /// Open an existing one. Missing index.json -> .libraryNotFound
    /// (open-or-create idiom: catch it and call create). Unreadable /
    /// malformed / unsupported-schema -> .libraryCorrupt.
    public static func open(at root: URL) throws -> Library {
        let indexPath = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            throw FreakError.libraryNotFound(path: indexPath.path)
        }
        let object: Any
        do {
            let raw = try Data(contentsOf: indexPath)
            object = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw FreakError.libraryCorrupt(path: indexPath.path,
                                            detail: String(describing: error))
        }
        guard let data = object as? [String: Any],
              (data["schema"] as? NSNumber)?.intValue == librarySchema,
              let rawEntries = data["entries"] as? [Any] else {
            let schema = (object as? [String: Any])?["schema"] ?? "nil"
            throw FreakError.libraryCorrupt(path: indexPath.path,
                                            detail: "unsupported schema: \(schema)")
        }
        var entries: [LibraryEntry] = []
        for rawEntry in rawEntries {
            guard let d = rawEntry as? [String: Any],
                  let id = d["id"] as? String,
                  let name = d["name"] as? String,
                  let sha256 = d["sha256"] as? String,
                  let metaHex = d["meta_hex"] as? String else {
                throw FreakError.libraryCorrupt(path: indexPath.path,
                                                detail: "bad entry: \(rawEntry)")
            }
            entries.append(LibraryEntry(
                id: id, name: name, sha256: sha256, metaHex: metaHex,
                slot: (d["slot"] as? NSNumber)?.intValue,
                addedAt: d["added_at"] as? String ?? "",
                tags: d["tags"] as? [String] ?? []))
        }
        return Library(root: root, entries: entries)
    }

    private static func saveIndex(root: URL, entries: [LibraryEntry]) throws {
        let payload: [String: Any] = [
            "schema": librarySchema,
            "entries": entries.map { e -> [String: Any] in
                ["id": e.id, "name": e.name, "sha256": e.sha256,
                 "meta_hex": e.metaHex,
                 "slot": e.slot.map { $0 as Any } ?? NSNull(),  // null written explicitly
                 "added_at": e.addedAt,
                 "tags": e.tags]
            },
        ]
        try AtomicFile.write(try jsonData(payload),
                             to: root.appendingPathComponent("index.json"))
    }

    private func save() throws {
        try Self.saveIndex(root: root, entries: entriesList)
    }

    private nonisolated func blobPath(_ sha256: String) -> URL {
        root.appendingPathComponent("blobs").appendingPathComponent("\(sha256).bin")
    }

    // ---------------------------------------------------------------- reads

    public func entries() -> [LibraryEntry] {
        entriesList
    }

    public func entry(id: String) throws -> LibraryEntry {
        guard let e = entriesList.first(where: { $0.id == id }) else {
            throw FreakError.entryNotFound(entryID: id)
        }
        return e
    }

    /// Re-hashes the blob file against its filename on EVERY get; .integrity
    /// on rot or a missing blob file.
    public func get(id: String) throws -> Preset {
        let e = try entry(id: id)
        let path = blobPath(e.sha256)
        guard let blob = try? Data(contentsOf: path) else {
            throw FreakError.integrity(path: path.path, detail: "blob file missing")
        }
        if Wire.digest(blob) != e.sha256 {
            throw FreakError.integrity(path: path.path,
                                       detail: "sha256 mismatch (bit rot?)")
        }
        guard let meta = Data(hexString: e.metaHex) else {
            throw FreakError.integrity(path: path.path,
                                       detail: "unparseable meta_hex: \(e.metaHex)")
        }
        return try Preset(name: e.name, blob: blob, meta: meta)
    }

    public func findBySha(_ sha256: String) -> [LibraryEntry] {
        entriesList.filter { $0.sha256 == sha256 }
    }

    public func hasBlob(_ sha256: String) -> Bool {
        FileManager.default.fileExists(atPath: blobPath(sha256).path)
    }

    public func slotMap() -> [Int: LibraryEntry] {
        var out: [Int: LibraryEntry] = [:]
        for e in entriesList {
            if let slot = e.slot {
                out[slot] = e
            }
        }
        return out
    }

    // --------------------------------------------------------------- writes
    // (the index is rewritten atomically after each)

    /// Blob file written iff absent; ALWAYS a new entry (two entries may
    /// share one blob sha under different names). Assigning a slot clears
    /// any other entry's claim first.
    @discardableResult
    public func add(_ preset: Preset, slot: Int? = nil,
                    tags: [String] = []) throws -> LibraryEntry {
        if let slot, !(0..<Wire.slots).contains(slot) {
            throw FreakError.slotOutOfRange(slot: slot)
        }
        let sha = preset.sha256
        let path = blobPath(sha)
        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try preset.blob.write(to: path)
            } catch {
                throw FreakError.integrity(path: path.path,
                                           detail: "cannot write blob: \(error)")
            }
        }
        let entry = LibraryEntry(
            // uuid4 hex, lowercase, 32 chars, NO hyphens (Python uuid4().hex)
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            name: preset.name, sha256: sha, metaHex: preset.meta.hexString,
            slot: slot, addedAt: isoNow(), tags: tags)
        if let slot {
            clearSlotClaims(slot)
        }
        entriesList.append(entry)
        try save()
        return entry
    }

    /// Validates the name.
    @discardableResult
    public func renameEntry(id: String, to name: String) throws -> LibraryEntry {
        try Wire.validateName(name)
        let e = try entry(id: id)
        let new = e.with(name: name)
        entriesList[entriesList.firstIndex(of: e)!] = new
        try save()
        return new
    }

    /// Deletes the entry; the blob file is deleted only when no remaining
    /// entry references it.
    public func remove(id: String) throws {
        let e = try entry(id: id)
        entriesList.removeAll { $0.id == id }
        if findBySha(e.sha256).isEmpty {
            try? FileManager.default.removeItem(at: blobPath(e.sha256))
        }
        try save()
    }

    /// Assigning a slot clears any other entry's claim to that slot.
    public func assignSlot(id: String, slot: Int?) throws {
        var e = try entry(id: id)
        if let slot {
            guard (0..<Wire.slots).contains(slot) else {
                throw FreakError.slotOutOfRange(slot: slot)
            }
            clearSlotClaims(slot)
            e = try entry(id: id)     // list may have been rewritten
        }
        entriesList[entriesList.firstIndex(of: e)!] = e.with(slot: .some(slot))
        try save()
    }

    private func clearSlotClaims(_ slot: Int) {
        for (i, other) in entriesList.enumerated() where other.slot == slot {
            entriesList[i] = other.with(slot: .some(nil))
        }
    }

    // --------------------------------------------------------------- import

    /// Bulk-import a device snapshot. Requires kept blobs (else
    /// .snapshotMissingBlobs — snapshot(readBlobs: true, keepBlobs: true)).
    /// Skips: expendable slots (when skipExpendable), records with meta ==
    /// nil (name read failed — cannot round-trip), and records whose
    /// (sha256, name) pair already exists (name nil -> ""). Each imported
    /// entry is assigned its source slot. Returns entries actually added.
    @discardableResult
    public func importSnapshot(_ snapshot: DeviceSnapshot,
                               skipExpendable: Bool = true,
                               threshold: Int = Wire.duplicateThreshold)
                               throws -> [LibraryEntry] {
        let records = snapshot.records
        guard records.allSatisfy({ $0.blob != nil }) else {
            throw FreakError.snapshotMissingBlobs
        }
        let expendable: Set<Int> = skipExpendable
            ? Analysis.findExpendable(records, threshold: threshold) : []
        struct Key: Hashable {
            let sha256: String?
            let name: String
        }
        var existing = Set(entriesList.map { Key(sha256: $0.sha256, name: $0.name) })
        var added: [LibraryEntry] = []
        for r in records {
            if expendable.contains(r.slot) {
                continue
            }
            guard let meta = r.meta else {
                continue     // name read failed: cannot round-trip meta
            }
            let name = r.name ?? ""
            let key = Key(sha256: r.sha256, name: name)
            if existing.contains(key) {
                continue
            }
            let entry = try add(Preset(name: name, blob: r.blob!, meta: meta),
                                slot: r.slot)
            existing.insert(key)
            added.append(entry)
        }
        return added
    }
}
