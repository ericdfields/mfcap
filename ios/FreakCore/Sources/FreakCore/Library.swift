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
    /// A DELIBERATE user pin: "when I send this patch, it belongs in this
    /// slot". Set only by `assignSlot` (and device-capture adds that record
    /// where the bytes came from) — NEVER by importing a bank or merging a
    /// bundle, whose arrangement lives in a `PresetCollection`. At most one
    /// entry per slot.
    public let slot: Int?
    public let addedAt: String
    public let tags: [String]
    public let category: Category    // editable; auto-filled from meta[7] on device import
    public let favorite: Bool
    public let verdict: Verdict      // audition verdict (additive, back-compat)

    public init(id: String, name: String, sha256: String, metaHex: String,
                slot: Int?, addedAt: String, tags: [String],
                category: Category = .uncategorized, favorite: Bool = false,
                verdict: Verdict = .unrated) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.metaHex = metaHex
        self.slot = slot
        self.addedAt = addedAt
        self.tags = tags
        self.category = category
        self.favorite = favorite
        self.verdict = verdict
    }

    fileprivate func with(name: String? = nil, slot: Int?? = nil,
                          tags: [String]? = nil, category: Category? = nil,
                          favorite: Bool? = nil,
                          verdict: Verdict? = nil) -> LibraryEntry {
        LibraryEntry(id: id, name: name ?? self.name, sha256: sha256,
                     metaHex: metaHex, slot: slot ?? self.slot,
                     addedAt: addedAt, tags: tags ?? self.tags,
                     category: category ?? self.category,
                     favorite: favorite ?? self.favorite,
                     verdict: verdict ?? self.verdict)
    }
}

/// Pure read helpers over a loaded entry array, so the UI stays UI-only:
/// category chip counts and the tag universe are computed in the core.
public enum Attributes {
    /// Count entries per Category. Every Category key present (0 when none),
    /// so the UI renders a stable chip row.
    public static func categoryCensus(_ entries: [LibraryEntry]) -> [Category: Int] {
        var counts: [Category: Int] = [:]
        for c in Category.allCases { counts[c] = 0 }
        for e in entries { counts[e.category, default: 0] += 1 }
        return counts
    }

    /// Sorted unique tag set across entries.
    public static func allTags(_ entries: [LibraryEntry]) -> [String] {
        var seen = Set<String>()
        for e in entries { seen.formUnion(e.tags) }
        return seen.sorted()
    }
}

/// Concatenate two tag lists preserving first-seen order, dropping duplicates.
fileprivate func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for t in a + b where seen.insert(t).inserted { out.append(t) }
    return out
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
                tags: d["tags"] as? [String] ?? [],
                // additive back-compat: an index predating these keys loads
                // with defaults (category=uncategorized, favorite=false).
                category: Category.fromSlug(d["category"] as? String ?? "uncategorized"),
                favorite: (d["favorite"] as? NSNumber)?.boolValue ?? false,
                verdict: Verdict.fromSlug(d["verdict"] as? String ?? "unrated")))
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
                 "tags": e.tags,
                 "category": e.category.slug, "favorite": e.favorite,
                 "verdict": e.verdict.slug]
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

    /// Write the blob content-addressed iff absent; return its sha256. The
    /// blob half of add(), reused by the collection builders.
    private func ensureBlob(_ blob: Data) throws -> String {
        let sha = Wire.digest(blob)
        let path = blobPath(sha)
        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try blob.write(to: path)
            } catch {
                throw FreakError.integrity(path: path.path,
                                           detail: "cannot write blob: \(error)")
            }
        }
        return sha
    }

    private nonisolated func collectionsDir() -> URL {
        root.appendingPathComponent("collections")
    }

    private nonisolated func collectionPath(_ id: String) -> URL {
        collectionsDir().appendingPathComponent("\(id).json")
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
    public func add(_ preset: Preset, slot: Int? = nil, tags: [String] = [],
                    category: Category = .uncategorized,
                    favorite: Bool = false,
                    dedupe: Bool = false) throws -> LibraryEntry {
        if let slot, !(0..<Wire.slots).contains(slot) {
            throw FreakError.slotOutOfRange(slot: slot)
        }
        let sha = try ensureBlob(preset.blob)
        if dedupe, let i = entriesList.firstIndex(
            where: { $0.sha256 == sha && $0.name == preset.name }) {
            var e = entriesList[i]
            let newSlot: Int? = e.slot ?? slot
            // The new-entry path below clears competing claims; the dedupe
            // path must too, or two entries can claim one slot and slotMap()
            // would silently drop one.
            if e.slot == nil, let newSlot {
                clearSlotClaims(newSlot)
                e = entriesList[i]        // list may have been rewritten
            }
            let merged = e.with(
                slot: newSlot,
                tags: orderedUnion(e.tags, tags),
                category: e.category == .uncategorized ? category : e.category,
                favorite: e.favorite || favorite)
            entriesList[i] = merged
            try save()
            return merged
        }
        let entry = LibraryEntry(
            // uuid4 hex, lowercase, 32 chars, NO hyphens (Python uuid4().hex)
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            name: preset.name, sha256: sha, metaHex: preset.meta.hexString,
            slot: slot, addedAt: isoNow(), tags: tags,
            category: category, favorite: favorite)
        if let slot {
            clearSlotClaims(slot)
        }
        entriesList.append(entry)
        try save()
        return entry
    }

    /// Collapse entries with identical (sha256, name) into one, merging
    /// attributes (union tags, OR favorite, prefer a set category, keep the
    /// first slot). Safe for collections, which reference presets by sha, not
    /// by entry id. Returns the number of entries removed.
    @discardableResult
    public func dedupe() throws -> Int {
        var keep: [String: LibraryEntry] = [:]      // "sha\u{0}name" -> entry
        var order: [String] = []
        for e in entriesList {
            let key = e.sha256 + "\u{0}" + e.name
            if let p = keep[key] {
                keep[key] = p.with(
                    // `.some(...)` is load-bearing: `slot:` is `Int??`, so a
                    // bare `p.slot ?? e.slot` wraps p.slot into a non-nil
                    // outer optional and the survivor's nil slot would swallow
                    // e's real pin (Python: `p.slot if p.slot is not None
                    // else e.slot`).
                    slot: .some(p.slot ?? e.slot),
                    tags: orderedUnion(p.tags, e.tags),
                    category: p.category == .uncategorized ? e.category : p.category,
                    favorite: p.favorite || e.favorite,
                    verdict: p.verdict == .unrated ? e.verdict : p.verdict)
            } else {
                keep[key] = e
                order.append(key)
            }
        }
        let removed = entriesList.count - order.count
        if removed > 0 {
            entriesList = order.map { keep[$0]! }
            try save()
        }
        return removed
    }

    /// One-time repair for libraries built before bank import stopped stamping
    /// entry slots (every pack numbered from slot 1, so all of them claimed
    /// 0…31 and each import silently stole those slots from the last). Clears
    /// a claim ONLY when an `.importedBank` collection already records the
    /// same (sha256, name) at that same slot — i.e. only when the arrangement
    /// being removed from the flat catalog is stored, intact, in the imported
    /// bank that put it there. Loss-free by construction. Idempotent. Returns
    /// the number of claims cleared.
    ///
    /// The imported-bank restriction is what makes the promise true. Only
    /// `collectionFromBank` ever stamped a slot it did not own, so only an
    /// `.importedBank` collection can explain a claim that should not exist.
    /// A `.deviceSnapshot` collection records the very same (sha256, name,
    /// slot) triples as the `importSnapshot` pins taken in the same capture,
    /// so keying on every collection erased the ordinary "Import Device… then
    /// Snapshot This Device as a Collection" flow's pins wholesale; keying on
    /// imported banks alone leaves a device capture alone, as documented.
    ///
    /// Residual, unavoidable case: a deliberate `assignSlot` survives unless
    /// an imported bank happens to place those exact (sha256, name) bytes at
    /// that exact slot — the one state a legacy stamped claim is genuinely
    /// indistinguishable from, because the legacy import created it.
    @discardableResult
    public func clearCollectionSlotClaims() throws -> Int {
        var placed: [Int: Set<String>] = [:]          // slot -> {"sha\0name"}
        for coll in try collections() {
            // Only a bank import ever stamped a slot it did not own; a device
            // capture is left alone.
            guard coll.provenance.kind == .importedBank else { continue }
            for (slot, ref) in coll.slots {
                placed[slot, default: []].insert(ref.sha256 + "\u{0}" + ref.name)
            }
        }
        var cleared = 0
        for (i, e) in entriesList.enumerated() {
            guard let slot = e.slot else { continue }
            if placed[slot]?.contains(e.sha256 + "\u{0}" + e.name) == true {
                entriesList[i] = e.with(slot: .some(nil))
                cleared += 1
            }
        }
        if cleared > 0 { try save() }
        return cleared
    }

    /// Set the (editable) category attribute. Rewrites the index atomically.
    @discardableResult
    public func setCategory(id: String, to category: Category) throws -> LibraryEntry {
        try replaceEntry(id: id) { $0.with(category: category) }
    }

    /// Set the audition verdict. Rewrites the index atomically.
    @discardableResult
    public func setVerdict(id: String, to verdict: Verdict) throws -> LibraryEntry {
        try replaceEntry(id: id) { $0.with(verdict: verdict) }
    }

    /// Set the favorite flag. Rewrites the index atomically.
    @discardableResult
    public func setFavorite(id: String, to favorite: Bool) throws -> LibraryEntry {
        try replaceEntry(id: id) { $0.with(favorite: favorite) }
    }

    /// Replace-whole the tag set (the UI owns add/remove; the core stores the
    /// final set). Rewrites the index atomically.
    @discardableResult
    public func setTags(id: String, to tags: [String]) throws -> LibraryEntry {
        try replaceEntry(id: id) { $0.with(tags: tags) }
    }

    private func replaceEntry(id: String,
                              _ transform: (LibraryEntry) -> LibraryEntry) throws -> LibraryEntry {
        let e = try entry(id: id)
        let new = transform(e)
        entriesList[entriesList.firstIndex(of: e)!] = new
        try save()
        return new
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
        // Blob GC now spans collections: delete the blob only when no
        // remaining entry AND no remaining collection references its sha256.
        if !(try blobReferenced(e.sha256)) {
            try? FileManager.default.removeItem(at: blobPath(e.sha256))
        }
        try save()
    }

    /// True when any entry OR any collection references this sha256. Blob GC
    /// spans collections, so deleting the last entry that shares a blob cannot
    /// orphan a collection's occupant.
    private func blobReferenced(_ sha256: String) throws -> Bool {
        if entriesList.contains(where: { $0.sha256 == sha256 }) {
            return true
        }
        for coll in try collections() {
            if coll.slots.values.contains(where: { $0.sha256 == sha256 }) {
                return true
            }
        }
        return false
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
            // Auto-fill category from the device byte meta[7]; this is the
            // ONLY place category is derived from meta. meta is present here
            // (meta == nil records are skipped above).
            let entry = try add(Preset(name: name, blob: r.blob!, meta: meta),
                                slot: r.slot,
                                category: Category.fromDeviceByte([UInt8](meta)[7]))
            existing.insert(key)
            added.append(entry)
        }
        return added
    }

    // ---------------------------------------------------------- collections

    /// Every <root>/collections/*.json, parsed; ascending by createdAt then
    /// id. Missing dir -> [].
    public func collections() throws -> [PresetCollection] {
        let cdir = collectionsDir()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cdir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: cdir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [PresetCollection] = []
        for path in files {
            out.append(try loadCollection(path))
        }
        out.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return out
    }

    public func collection(id: String) throws -> PresetCollection {
        let path = collectionPath(id)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw FreakError.collectionNotFound(id: id)
        }
        return try loadCollection(path)
    }

    private func loadCollection(_ path: URL) throws -> PresetCollection {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: try Data(contentsOf: path))
        } catch {
            throw FreakError.libraryCorrupt(path: path.path,
                                            detail: String(describing: error))
        }
        guard let d = object as? [String: Any] else {
            throw FreakError.libraryCorrupt(path: path.path, detail: "not a JSON object")
        }
        return try CollectionCodec.fromJSON(d, path: path.path)
    }

    /// Store a preset's blob content-addressed and return the `PresetRef`
    /// that names it — WITHOUT creating a catalog entry.
    ///
    /// The blob half of `add()`, exposed for callers that edit a collection
    /// directly (adopting a device slot into an arrangement, say). Building a
    /// `PresetRef` from bytes the store never received produces a ref that
    /// `presetForRef` cannot resolve, which `planApply` then folds to SKIP
    /// forever — a silent, permanent hole in the arrangement. Going through
    /// here makes that impossible. Idempotent; safe for bytes already held.
    @discardableResult
    public func storePreset(_ preset: Preset) throws -> PresetRef {
        _ = try ensureBlob(preset.blob)
        return PresetRef(preset: preset)
    }

    public func saveCollection(_ coll: PresetCollection) throws {
        try FileManager.default.createDirectory(at: collectionsDir(),
                                                withIntermediateDirectories: true)
        try AtomicFile.write(try jsonData(CollectionCodec.toJSON(coll)),
                             to: collectionPath(coll.id))
    }

    @discardableResult
    public func renameCollection(id: String, to name: String) throws -> PresetCollection {
        let renamed = try collection(id: id).renamed(name)
        try saveCollection(renamed)
        return renamed
    }

    public func deleteCollection(id: String) throws {
        let coll = try collection(id: id)                 // .collectionNotFound
        let shas = Set(coll.slots.values.map(\.sha256))
        try? FileManager.default.removeItem(at: collectionPath(id))
        for sha in shas where !(try blobReferenced(sha)) {  // GC now the file is gone
            try? FileManager.default.removeItem(at: blobPath(sha))
        }
    }

    /// Read blobs/<ref.sha256>.bin, re-hash (.integrity on rot/missing), build
    /// ref.toPreset(blob). The standard resolver for apply.
    public func presetForRef(_ ref: PresetRef) throws -> Preset {
        let path = blobPath(ref.sha256)
        guard let blob = try? Data(contentsOf: path) else {
            throw FreakError.integrity(path: path.path, detail: "blob file missing")
        }
        if Wire.digest(blob) != ref.sha256 {
            throw FreakError.integrity(path: path.path,
                                       detail: "sha256 mismatch (bit rot?)")
        }
        return try ref.toPreset(blob: blob)
    }

    // ---------------------------------------------- collection builders

    /// Store each recorded blob (content-addressed) and build a collection of
    /// PresetRefs at each slot. Requires kept blobs + hashes. Skips records
    /// whose name read failed (meta == nil). Provenance kind = deviceSnapshot,
    /// source defaults to snapshot.takenAt. Saved before return.
    @discardableResult
    public func collectionFromSnapshot(_ snapshot: DeviceSnapshot, name: String,
                                       source: String = "") throws -> PresetCollection {
        let records = snapshot.records
        guard records.allSatisfy({ $0.blob != nil }) else {
            throw FreakError.snapshotMissingBlobs
        }
        guard snapshot.hasHashes else {
            throw FreakError.snapshotMissingHashes
        }
        var slots: [Int: PresetRef] = [:]
        for r in records {
            guard let meta = r.meta else { continue }   // name read failed: no faithful meta
            let sha = try ensureBlob(r.blob!)
            slots[r.slot] = PresetRef(sha256: sha, name: r.name ?? "",
                                      metaHex: meta.hexString)
        }
        let prov = Provenance(kind: .deviceSnapshot,
                              source: source.isEmpty ? snapshot.takenAt : source)
        let coll = PresetCollection.new(name: name, provenance: prov, slots: slots)
        try saveCollection(coll)
        return coll
    }

    /// Store blobs, add one SLOT-LESS Uncategorized library entry per placed
    /// item, build and save an importedBank collection. The arrangement lives
    /// in the collection's `slots`; the flat catalog entry claims nothing (UX
    /// spec §26.3). Skips items with no blob or no slot. Returns
    /// (collection, addedEntries).
    @discardableResult
    public func collectionFromBank(_ items: [BankItem], name: String,
                                   source: String) throws -> (PresetCollection, [LibraryEntry]) {
        var slots: [Int: PresetRef] = [:]
        var added: [LibraryEntry] = []
        for item in items {
            guard let blob = item.blob, let slot = item.slot else {
                continue     // empty/Init-only slot, or unplaceable filename
            }
            let meta = item.meta.count == 9 ? item.meta : Data(count: 9)
            let preset = try Preset(name: item.name, blob: blob, meta: meta)
            // The COLLECTION owns the arrangement (`slots` below); the library
            // entry is a catalog record and carries no slot opinion.
            let entry = try add(preset, dedupe: true)              // unique catalog
            slots[slot] = PresetRef(sha256: entry.sha256, name: preset.name,
                                    metaHex: meta.hexString)
            added.append(entry)
        }
        let prov = Provenance(kind: .importedBank, source: source)
        let coll = PresetCollection.new(name: name, provenance: prov, slots: slots)
        try saveCollection(coll)
        return (coll, added)
    }

    /// Merge another library's collections (and their presets) into this one.
    /// Collection-granular and idempotent: a collection whose id already exists
    /// here is skipped, so re-running merges nothing new; blobs are
    /// content-addressed so shared presets are stored once. Returns the number
    /// of collections newly merged. Used to fold the bundled seed into an
    /// existing user library without disturbing entries the user already has.
    @discardableResult
    public func mergeBundle(from other: Library) async throws -> Int {
        let have = Set(try collections().map(\.id))
        var merged = 0
        for coll in try await other.collections() where !have.contains(coll.id) {
            var slots: [Int: PresetRef] = [:]
            for (slot, ref) in coll.slots {
                let preset = try await other.presetForRef(ref)
                // The merged collection below carries the arrangement; the
                // catalog entry stays slot-less.
                let entry = try add(preset, dedupe: true)
                slots[slot] = PresetRef(sha256: entry.sha256, name: preset.name,
                                        metaHex: ref.metaHex)
            }
            try saveCollection(PresetCollection(
                id: coll.id, name: coll.name, createdAt: coll.createdAt,
                provenance: coll.provenance, slots: slots))
            merged += 1
        }
        return merged
    }
}
