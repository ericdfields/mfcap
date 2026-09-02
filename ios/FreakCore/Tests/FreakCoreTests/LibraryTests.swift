// LibraryTests.swift — the content-addressed library: create/open guards,
// add/rename/remove/assign semantics, integrity re-hash, persistence
// interop (uuid4-hex ids, slot: null), and importSnapshot rules.

import Foundation
import Testing
@testable import FreakCore

@Suite("Library")
struct LibraryTests {

    private func freshLibrary(_ tag: String) throws -> (Library, URL) {
        let root = tempDir("library-\(tag)")
        return (try Library.create(at: root), root)
    }

    @Test func createRefusesExistingAndOpenRequiresIndex() throws {
        let (_, root) = try freshLibrary("create")
        defer { try? FileManager.default.removeItem(at: root) }
        let e1 = expectFreakError { try Library.create(at: root) }
        guard case .libraryExists = e1 else {
            Issue.record("expected .libraryExists, got \(String(describing: e1))")
            return
        }
        let missing = root.appendingPathComponent("nothing-here")
        let e2 = expectFreakError { try Library.open(at: missing) }
        guard case .libraryNotFound = e2 else {
            Issue.record("expected .libraryNotFound, got \(String(describing: e2))")
            return
        }
        // corrupt index
        let corrupt = tempDir("library-corrupt")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try AtomicFile.write(Data("not json at all".utf8),
                             to: corrupt.appendingPathComponent("index.json"))
        let e3 = expectFreakError { try Library.open(at: corrupt) }
        guard case .libraryCorrupt = e3 else {
            Issue.record("expected .libraryCorrupt, got \(String(describing: e3))")
            return
        }
        // wrong schema
        try AtomicFile.write(Data(#"{"schema": 99, "entries": []}"#.utf8),
                             to: corrupt.appendingPathComponent("index.json"))
        let e4 = expectFreakError { try Library.open(at: corrupt) }
        guard case .libraryCorrupt(_, let detail) = e4 else {
            Issue.record("expected .libraryCorrupt, got \(String(describing: e4))")
            return
        }
        #expect(detail.contains("unsupported schema"))
    }

    @Test func addIsContentAddressed() async throws {
        let (lib, root) = try freshLibrary("add")
        defer { try? FileManager.default.removeItem(at: root) }
        let presetA = try Preset(name: "One", blob: blob7(1), meta: testMeta)
        let presetB = try Preset(name: "Two", blob: blob7(1), meta: testMeta)  // same blob
        let a = try await lib.add(presetA, slot: 3, tags: ["pad"])
        let b = try await lib.add(presetB)
        #expect(a.id != b.id)
        #expect(a.sha256 == b.sha256, "two entries may share one blob sha")
        #expect(a.slot == 3 && b.slot == nil)
        #expect(a.tags == ["pad"])
        #expect(a.metaHex == testMeta.hexString)
        #expect(a.id.count == 32 && a.id == a.id.lowercased()
                && !a.id.contains("-"),
                "uuid4 hex, lowercase, no dashes")
        // one blob file for both entries
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("blobs").path)
        #expect(blobs == ["\(a.sha256).bin"])
        #expect(await lib.hasBlob(a.sha256))
        #expect(await lib.findBySha(a.sha256).count == 2)
        #expect(await lib.entries().count == 2)
        // out-of-range slot refused
        await #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try await lib.add(presetA, slot: 512)
        }
    }

    @Test func getRehashesEveryTime() async throws {
        let (lib, root) = try freshLibrary("get")
        defer { try? FileManager.default.removeItem(at: root) }
        let preset = try Preset(name: "Keeper", blob: blob7(2), meta: testMeta)
        let entry = try await lib.add(preset)
        let got = try await lib.get(id: entry.id)
        #expect(got == preset)
        await #expect(throws: FreakError.entryNotFound(entryID: "nope")) {
            try await lib.get(id: "nope")
        }
        // bit rot -> sha256 mismatch
        let blobPath = root.appendingPathComponent("blobs/\(entry.sha256).bin")
        var rotten = [UInt8](try Data(contentsOf: blobPath))
        rotten[0] ^= 0x01
        try Data(rotten).write(to: blobPath)
        let e1 = await expectFreakErrorAsync { try await lib.get(id: entry.id) }
        guard case .integrity(_, let detail) = e1 else {
            Issue.record("expected .integrity, got \(String(describing: e1))")
            return
        }
        #expect(detail.contains("sha256 mismatch"))
        // missing file
        try FileManager.default.removeItem(at: blobPath)
        let e2 = await expectFreakErrorAsync { try await lib.get(id: entry.id) }
        guard case .integrity(_, let detail2) = e2 else {
            Issue.record("expected .integrity, got \(String(describing: e2))")
            return
        }
        #expect(detail2.contains("blob file missing"))
    }

    @Test func renameRemoveAndSlotClaims() async throws {
        let (lib, root) = try freshLibrary("mutate")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await lib.add(try Preset(name: "A", blob: blob7(1), meta: testMeta),
                                  slot: 10)
        let b = try await lib.add(try Preset(name: "B", blob: blob7(2), meta: testMeta))
        // rename keeps the id and blob
        let renamed = try await lib.renameEntry(id: a.id, to: "A Prime")
        #expect(renamed.id == a.id && renamed.name == "A Prime")
        #expect(renamed.sha256 == a.sha256 && renamed.slot == 10)
        await #expect(throws: FreakError.self) {
            try await lib.renameEntry(id: a.id, to: " bad")
        }
        // assigning b to slot 10 clears a's claim
        try await lib.assignSlot(id: b.id, slot: 10)
        #expect(try await lib.entry(id: b.id).slot == 10)
        #expect(try await lib.entry(id: a.id).slot == nil)
        #expect(await lib.slotMap()[10]?.id == b.id)
        await #expect(throws: FreakError.slotOutOfRange(slot: -1)) {
            try await lib.assignSlot(id: b.id, slot: -1)
        }
        try await lib.assignSlot(id: b.id, slot: nil)
        #expect(await lib.slotMap().isEmpty)
        // remove: blob deleted only when unreferenced
        let sameBlob = try await lib.add(
            try Preset(name: "A Copy", blob: blob7(1), meta: testMeta))
        try await lib.remove(id: a.id)
        #expect(await lib.hasBlob(sameBlob.sha256), "still referenced by A Copy")
        try await lib.remove(id: sameBlob.id)
        #expect(!(await lib.hasBlob(sameBlob.sha256)), "unreferenced blob deleted")
        await #expect(throws: FreakError.entryNotFound(entryID: a.id)) {
            try await lib.entry(id: a.id)
        }
    }

    @Test func persistenceRoundTrip() async throws {
        let (lib, root) = try freshLibrary("persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(
            try Preset(name: "Kept", blob: blob7(4), meta: testMeta),
            slot: 7, tags: ["a", "b"])
        let reopened = try Library.open(at: root)
        #expect(await reopened.entries() == [entry])
        #expect(try await reopened.get(id: entry.id).name == "Kept")
        // entry JSON keys exactly as the Python schema; slot null explicit
        let indexRaw = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let index = try JSONSerialization.jsonObject(with: indexRaw) as! [String: Any]
        #expect((index["schema"] as? NSNumber)?.intValue == 1)
        let d = (index["entries"] as! [[String: Any]])[0]
        #expect(Set(d.keys) == ["id", "name", "sha256", "meta_hex", "slot",
                                "added_at", "tags", "category", "favorite"])
        #expect(d["category"] as? String == "uncategorized")
        #expect(d["favorite"] as? Bool == false)
        // pinned timestamp shape: "yyyy-MM-dd'T'HH:mm:ss"
        let addedAt = d["added_at"] as! String
        #expect(addedAt.count == 19 && addedAt[addedAt.index(addedAt.startIndex,
                                                             offsetBy: 10)] == "T")
        // an unassigned entry writes slot: null explicitly
        _ = try await lib.add(try Preset(name: "NoSlot", blob: blob7(5), meta: testMeta))
        let raw2 = try String(contentsOf: root.appendingPathComponent("index.json"),
                              encoding: .utf8)
        #expect(raw2.contains("\"slot\" : null") || raw2.contains("\"slot\": null"),
                "unassigned slot must serialize as an explicit null")
    }

    // ------------------------------------------------------ importSnapshot

    private func snapshotRecord(slot: Int, name: String?, blob: Data?,
                                meta: Data?) -> SlotRecord {
        SlotRecord(slot: slot, name: name,
                   sha256: blob.map { Wire.digest($0) },
                   meta: meta, blob: blob)
    }

    private func snapshot(_ records: [SlotRecord]) -> DeviceSnapshot {
        DeviceSnapshot(takenAt: "2026-09-01T00:00:00", records: records,
                       timing: TimingReport(totalSeconds: 0, perSlotSeconds: 0,
                                            nameMsMedian: nil, dumpMsMedian: nil))
    }

    @Test func importRequiresBlobs() async throws {
        let (lib, root) = try freshLibrary("import-noblobs")
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = snapshot([SlotRecord(slot: 0, name: "X", sha256: "abc",
                                        meta: testMeta, blob: nil)])
        await #expect(throws: FreakError.snapshotMissingBlobs) {
            try await lib.importSnapshot(snap)
        }
    }

    @Test func importSkipsExpendableFailedAndDuplicates() async throws {
        let (lib, root) = try freshLibrary("import")
        defer { try? FileManager.default.removeItem(at: root) }
        let initBlob = blob7(9)
        let records = [
            snapshotRecord(slot: 0, name: "User 0", blob: blob7(1), meta: testMeta),
            snapshotRecord(slot: 1, name: nil, blob: blob7(2), meta: nil),   // name read failed
            snapshotRecord(slot: 2, name: "User 2", blob: blob7(3), meta: testMeta),
            snapshotRecord(slot: 500, name: "Init", blob: initBlob, meta: testMeta),
            snapshotRecord(slot: 501, name: "Init", blob: initBlob, meta: testMeta),
            snapshotRecord(slot: 502, name: "Init", blob: initBlob, meta: testMeta),
        ]
        let added = try await lib.importSnapshot(snapshot(records))
        #expect(added.map(\.slot) == [0, 2],
                "expendable Inits skipped, failed-name skipped")
        #expect(added.map(\.name) == ["User 0", "User 2"])
        // a second import adds nothing (identical (sha, name) pairs exist)
        let again = try await lib.importSnapshot(snapshot(records))
        #expect(again.isEmpty)
        // skipExpendable: false brings the Inits in (dupe-keyed: only one)
        let withInits = try await lib.importSnapshot(snapshot(records),
                                                     skipExpendable: false)
        #expect(withInits.map(\.slot) == [500])
        #expect(withInits[0].name == "Init")
        // the second and third Init records share (sha, name): skipped
        #expect(await lib.entries().count == 3)
    }

    // ------------------------------------------------ preset attributes

    @Test func attributesPersistAndEdit() async throws {
        let (lib, root) = try freshLibrary("attrs")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(
            try Preset(name: "Pad One", blob: blob7(1), meta: testMeta),
            slot: 0, tags: ["ambient", "pad"], category: .pad, favorite: true)
        #expect(entry.category == .pad && entry.favorite && entry.tags == ["ambient", "pad"])
        // survives a reopen (additive fields round-trip)
        let reopened = try Library.open(at: root)
        let back = try await reopened.entry(id: entry.id)
        #expect(back.category == .pad && back.favorite && back.tags == ["ambient", "pad"])
        // editors rewrite the index atomically
        _ = try await lib.setCategory(id: entry.id, to: .bass)
        _ = try await lib.setFavorite(id: entry.id, to: false)
        let edited = try await lib.setTags(id: entry.id, to: ["sub"])
        #expect(edited.category == .bass && !edited.favorite && edited.tags == ["sub"])
        let reopened2 = try Library.open(at: root)
        let back2 = try await reopened2.entry(id: entry.id)
        #expect(back2.category == .bass && !back2.favorite && back2.tags == ["sub"])
    }

    @Test func oldIndexLoadsWithDefaults() async throws {
        let root = tempDir("attrs-oldindex")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        // an index predating category/favorite/tags
        let legacy = """
        {"schema": 1, "entries": [{"id": "old0", "name": "Legacy",
          "sha256": "abc", "meta_hex": "\(testMeta.hexString)", "slot": 5,
          "added_at": "2026-01-01T00:00:00"}]}
        """
        try AtomicFile.write(Data(legacy.utf8),
                             to: root.appendingPathComponent("index.json"))
        let lib = try Library.open(at: root)
        let e = try await lib.entry(id: "old0")
        #expect(e.category == .uncategorized && !e.favorite && e.tags == [])
    }

    @Test func importSnapshotAutoFillsCategoryFromDeviceByte() async throws {
        let (lib, root) = try freshLibrary("attrs-import")
        defer { try? FileManager.default.removeItem(at: root) }
        // meta[7] = 0x03 -> keys; 0x01 -> bass; 0x7F (out of table) -> uncategorized
        func metaWith(byte7: UInt8) -> Data {
            var m = [UInt8](testMeta); m[7] = byte7; return Data(m)
        }
        let records = [
            snapshotRecord(slot: 0, name: "Keys One", blob: blob7(1), meta: metaWith(byte7: 0x03)),
            snapshotRecord(slot: 1, name: "Bass One", blob: blob7(2), meta: metaWith(byte7: 0x01)),
            snapshotRecord(slot: 2, name: "Weird", blob: blob7(3), meta: metaWith(byte7: 0x7F)),
        ]
        let added = try await lib.importSnapshot(snapshot(records))
        #expect(added.map(\.category) == [.keys, .bass, .uncategorized])
        #expect(added.allSatisfy { !$0.favorite && $0.tags.isEmpty })
    }

    @Test func censusAndTagsHelpers() async throws {
        let (lib, root) = try freshLibrary("attrs-census")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await lib.add(try Preset(name: "P1", blob: blob7(1), meta: testMeta),
                              tags: ["a", "b"], category: .pad)
        _ = try await lib.add(try Preset(name: "P2", blob: blob7(2), meta: testMeta),
                              tags: ["b", "c"], category: .pad)
        _ = try await lib.add(try Preset(name: "P3", blob: blob7(3), meta: testMeta),
                              category: .bass)
        let entries = await lib.entries()
        let census = Attributes.categoryCensus(entries)
        #expect(census[.pad] == 2 && census[.bass] == 1 && census[.uncategorized] == 0)
        #expect(census.count == Category.allCases.count, "every category key present")
        #expect(Attributes.allTags(entries) == ["a", "b", "c"])
    }
}

@Suite("Library merge")
struct LibraryMergeTests {
    private func blob(_ tag: UInt8) -> Data { Data(repeating: tag, count: 4672) }

    @Test func mergeIsIdempotentAndPreservesUserData() async throws {
        let seedRoot = tempDir("merge-seed")
        let userRoot = tempDir("merge-user")
        defer { try? FileManager.default.removeItem(at: seedRoot)
                try? FileManager.default.removeItem(at: userRoot) }
        let seed = try Library.create(at: seedRoot)
        _ = try await seed.collectionFromBank(
            [BankItem(slot: 0, name: "A", meta: Data(count: 9), blob: blob(1)),
             BankItem(slot: 1, name: "B", meta: Data(count: 9), blob: blob(2))],
            name: "Bank One", source: "one")
        _ = try await seed.collectionFromBank(
            [BankItem(slot: 5, name: "C", meta: Data(count: 9), blob: blob(3))],
            name: "Bank Two", source: "two")

        let user = try Library.create(at: userRoot)
        _ = try await user.add(try Preset(name: "MyOwn", blob: blob(9), meta: Data(count: 9)),
                               slot: 100)
        let before = await user.entries().count

        let n1 = try await user.mergeBundle(from: seed)
        #expect(n1 == 2)
        #expect(try await user.collections().count == 2)
        #expect(await user.entries().count == before + 3)
        #expect(await user.entries().contains { $0.name == "MyOwn" })

        let n2 = try await user.mergeBundle(from: seed)   // idempotent
        #expect(n2 == 0)
        #expect(try await user.collections().count == 2)
        #expect(await user.entries().count == before + 3)

        // every merged ref still resolves after reopen
        let reopened = try Library.open(at: userRoot)
        for c in try await reopened.collections() {
            for ref in c.slots.values { _ = try await reopened.presetForRef(ref) }
        }
    }
}

@Suite("Library dedupe")
struct LibraryDedupeTests {
    private func blob(_ t: UInt8) -> Data { Data(repeating: t, count: 4672) }

    @Test func dedupeAddReusesAndRepairCollapses() async throws {
        let root = tempDir("dedupe"); defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        // dedupe:true add reuses same (sha,name)
        for _ in 0..<3 {
            _ = try await lib.add(try Preset(name: "Dup", blob: blob(7), meta: Data(count: 9)),
                                  dedupe: true)
        }
        #expect(await lib.entries().count == 1)
        _ = try await lib.add(try Preset(name: "Other", blob: blob(7), meta: Data(count: 9)),
                              dedupe: true)     // same blob, different name -> kept
        #expect(await lib.entries().count == 2)

        // repair: plain adds create exact dups, dedupe() collapses + merges attrs
        let root2 = tempDir("dedupe2"); defer { try? FileManager.default.removeItem(at: root2) }
        let lib2 = try Library.create(at: root2)
        let a = try await lib2.add(try Preset(name: "X", blob: blob(1), meta: Data(count: 9)),
                                   slot: 5)
        _ = try await lib2.setFavorite(id: a.id, to: true)
        _ = try await lib2.add(try Preset(name: "X", blob: blob(1), meta: Data(count: 9)),
                               tags: ["pad"])       // exact dup, no dedupe
        #expect(await lib2.entries().count == 2)
        let removed = try await lib2.dedupe()
        #expect(removed == 1)
        let e = try #require(await lib2.entries().first)
        #expect(await lib2.entries().count == 1)
        #expect(e.favorite && e.tags.contains("pad") && e.slot == 5)
    }
}
