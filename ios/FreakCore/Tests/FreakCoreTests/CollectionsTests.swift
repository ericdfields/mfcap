// CollectionsTests.swift — PresetCollection JSON round-trip (against the
// authoritative collections.json vectors), the pure planApply decision table
// (same vectors), the collectionFromSnapshot / collectionFromBank builders
// (blob dedupe, entry creation, provenance, skip rules), and blob GC spanning
// collections. Expected values are consumed from the Python-generated
// fixtures — never hand-derived here.

import Foundation
import Testing
@testable import FreakCore

@Suite("PresetCollection")
struct CollectionsTests {

    private func freshLibrary(_ tag: String) throws -> (Library, URL) {
        let root = tempDir("collections-\(tag)")
        return (try Library.create(at: root), root)
    }

    private func snapshotRecord(slot: Int, name: String?, blob: Data?,
                                meta: Data?) -> SlotRecord {
        SlotRecord(slot: slot, name: name,
                   sha256: blob.map { Wire.digest($0) }, meta: meta, blob: blob)
    }

    private func snapshot(_ records: [SlotRecord],
                          takenAt: String = "2026-09-01T00:00:00") -> DeviceSnapshot {
        DeviceSnapshot(takenAt: takenAt, records: records,
                       timing: TimingReport(totalSeconds: 0, perSlotSeconds: 0,
                                            nameMsMedian: nil, dumpMsMedian: nil))
    }

    // ----------------------------------------------------- JSON round-trip

    /// Every provenance-kind round-trip case in collections.json: parse the
    /// collection JSON, assert slots (keyed by int, refs decoded) and
    /// provenance, then re-serialize and parse again for a byte-stable cycle.
    @Test func jsonRoundTripAgainstVectors() throws {
        let cases = try Vectors.cases("collections.json")
        var seenRoundTrips = 0
        for c in cases where (c["name"] as! String).hasPrefix("roundtrip_") {
            seenRoundTrips += 1
            let dict = c["collection"] as! [String: Any]
            let coll = try CollectionCodec.fromJSON(dict, path: "<vector>")

            // provenance
            let ep = c["expected_provenance"] as! [String: Any]
            #expect(coll.provenance.kind.rawValue == ep["kind"] as! String)
            #expect(coll.provenance.source == ep["source"] as! String)

            // slots decoded, ascending by int key
            let expectedSlots = c["expected_slots"] as! [[String: Any]]
            #expect(coll.coveredSlots() == expectedSlots.map { int($0, "slot") })
            for es in expectedSlots {
                let ref = coll.slots[int(es, "slot")]!
                #expect(ref.sha256 == str(es, "sha256"))
                #expect(ref.name == str(es, "name"))
                #expect(ref.metaHex == str(es, "meta_hex"))
            }

            // re-serialize -> reparse: stable cycle, id/name/createdAt preserved
            let reparsed = try CollectionCodec.fromJSON(
                CollectionCodec.toJSON(coll), path: "<cycle>")
            #expect(reparsed == coll)
            #expect(reparsed.id == dict["id"] as! String)
            #expect(reparsed.createdAt == dict["created_at"] as! String)
        }
        #expect(seenRoundTrips == 3, "one round-trip case per provenance kind")
    }

    // ------------------------------------------------------ planApply table

    /// The plan_apply decision table in collections.json: each case's
    /// synthetic collection vs. its synthetic full hashed snapshot must yield
    /// exactly the per-slot actions and the write/clear/skip/estimate the
    /// Python reference produced.
    @Test func planApplyDecisionTableAgainstVectors() throws {
        let cases = try Vectors.cases("collections.json")
        var seenTables = 0
        for c in cases {
            let name = c["name"] as! String
            guard name == "clear_policy" || name == "leave_policy" else { continue }
            seenTables += 1

            let records = (c["snapshot"] as! [[String: Any]]).map {
                SlotRecord(slot: int($0, "slot"), name: str($0, "name"),
                           sha256: $0["sha256"] as? String, meta: nil, blob: nil)
            }
            let snap = snapshot(records)

            var slots: [Int: PresetRef] = [:]
            for (k, v) in (c["collection_slots"] as! [String: Any]) {
                let rd = v as! [String: Any]
                slots[Int(k)!] = PresetRef(sha256: str(rd, "sha256"),
                                           name: str(rd, "name"),
                                           metaHex: str(rd, "meta_hex"))
            }
            let coll = PresetCollection(id: "test", name: "T",
                                        createdAt: "2026-09-01T00:00:00",
                                        provenance: Provenance(kind: .manual),
                                        slots: slots)

            let optD = c["options"] as! [String: Any]
            var options = ApplyOptions()
            options.unlisted = (str(optD, "unlisted") == "clear") ? .clear : .leave
            if let cw = optD["clear_with"] as? [String: Any] {
                options.clearWith = PresetRef(sha256: str(cw, "sha256"),
                                              name: str(cw, "name"),
                                              metaHex: str(cw, "meta_hex"))
            }
            options.secondsPerWrite = (optD["seconds_per_write"] as! NSNumber).doubleValue

            let plan = try planApply(collection: coll, snapshot: snap, options: options)

            let expected = c["expected"] as! [[String: Any]]
            #expect(plan.slots.map(\.slot) == expected.map { int($0, "slot") })
            #expect(plan.slots.map(\.action.rawValue) == expected.map { str($0, "action") })
            #expect(plan.writeCount == int(c, "write_count"))
            #expect(plan.clearCount == int(c, "clear_count"))
            #expect(plan.skipCount == int(c, "skip_count"))
            #expect(plan.totalSlots == int(c, "total_slots"))
            #expect(plan.estimatedSeconds == (c["estimated_seconds"] as! NSNumber).doubleValue)

            // changes() is exactly the WRITE + CLEAR rows, incoming populated
            let changes = plan.changes()
            #expect(changes.count == plan.writeCount + plan.clearCount)
            #expect(changes.allSatisfy { $0.incoming != nil })
            #expect(plan.slots.filter { $0.action == .skip }.allSatisfy { $0.incoming == nil })
        }
        #expect(seenTables == 2)
    }

    /// The refuses_partial_snapshot vector: a hash-less / partial snapshot
    /// must make planApply throw rather than guess.
    @Test func planApplyRefusesPartialSnapshotVector() throws {
        let cases = try Vectors.cases("collections.json")
        let c = cases.first { $0["name"] as! String == "refuses_partial_snapshot" }!
        let records = (c["snapshot"] as! [[String: Any]]).map {
            SlotRecord(slot: int($0, "slot"), name: str($0, "name"),
                       sha256: $0["sha256"] as? String, meta: nil, blob: nil)
        }
        var slots: [Int: PresetRef] = [:]
        for (k, v) in (c["collection_slots"] as! [String: Any]) {
            let rd = v as! [String: Any]
            slots[Int(k)!] = PresetRef(sha256: str(rd, "sha256"), name: str(rd, "name"),
                                       metaHex: str(rd, "meta_hex"))
        }
        let coll = PresetCollection(id: "t", name: "T", createdAt: "",
                                    provenance: Provenance(kind: .manual), slots: slots)
        #expect(throws: FreakError.self) {
            try planApply(collection: coll, snapshot: snapshot(records))
        }
    }

    /// planApply guards: clear policy without clearWith, and a collection slot
    /// beyond the snapshot's range.
    @Test func planApplyGuards() throws {
        let records = (0..<3).map { snapshotRecord(slot: $0, name: "N\($0)",
                                                    blob: blob7($0 + 1), meta: testMeta) }
        let snap = snapshot(records)
        // clear policy requires clearWith
        var badClear = ApplyOptions(); badClear.unlisted = .clear
        let empty = PresetCollection(id: "a", name: "A", createdAt: "",
                                     provenance: Provenance(kind: .manual), slots: [:])
        #expect(throws: FreakError.self) {
            try planApply(collection: empty, snapshot: snap, options: badClear)
        }
        // a slot beyond the snapshot range is undecidable
        let beyond = PresetCollection(
            id: "b", name: "B", createdAt: "", provenance: Provenance(kind: .manual),
            slots: [9: PresetRef(sha256: "x", name: "Y", metaHex: testMeta.hexString)])
        #expect(throws: FreakError.self) {
            try planApply(collection: beyond, snapshot: snap)
        }
    }

    // ----------------------------------------------- collectionFromSnapshot

    @Test func collectionFromSnapshotBuildsRefsAndStoresBlobs() async throws {
        let (lib, root) = try freshLibrary("from-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedBlob = blob7(1)
        let records = [
            snapshotRecord(slot: 0, name: "Alpha", blob: sharedBlob, meta: testMeta),
            snapshotRecord(slot: 1, name: nil, blob: blob7(2), meta: nil),   // read failed
            snapshotRecord(slot: 2, name: "Gamma", blob: sharedBlob, meta: testMeta), // dupe blob
        ]
        let coll = try await lib.collectionFromSnapshot(
            snapshot(records, takenAt: "2026-09-01T12:00:00"), name: "Live Set")
        // slot 1 (failed name read) skipped; 0 and 2 present
        #expect(coll.coveredSlots() == [0, 2])
        #expect(coll.slots[0]?.name == "Alpha" && coll.slots[2]?.name == "Gamma")
        #expect(coll.slots[0]?.sha256 == coll.slots[2]?.sha256, "same blob, same sha")
        #expect(coll.slots[0]?.metaHex == testMeta.hexString)
        // provenance kind + source defaults to takenAt
        #expect(coll.provenance.kind == .deviceSnapshot)
        #expect(coll.provenance.source == "2026-09-01T12:00:00")
        // deduped: one blob file on disk
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("blobs").path)
        #expect(blobs == ["\(coll.slots[0]!.sha256).bin"])
        // saved and reloadable
        let reloaded = try await lib.collection(id: coll.id)
        #expect(reloaded == coll)
        #expect(try await lib.collections().map(\.id) == [coll.id])
        // explicit source overrides takenAt
        let coll2 = try await lib.collectionFromSnapshot(
            snapshot(records), name: "Named", source: "my-source")
        #expect(coll2.provenance.source == "my-source")
    }

    @Test func collectionFromSnapshotRequiresBlobsAndHashes() async throws {
        let (lib, root) = try freshLibrary("from-snapshot-guards")
        defer { try? FileManager.default.removeItem(at: root) }
        // no kept blobs
        let noBlobs = snapshot([SlotRecord(slot: 0, name: "X", sha256: "abc",
                                           meta: testMeta, blob: nil)])
        await #expect(throws: FreakError.snapshotMissingBlobs) {
            try await lib.collectionFromSnapshot(noBlobs, name: "N")
        }
    }

    // --------------------------------------------------- collectionFromBank

    @Test func collectionFromBankAddsEntriesAndSkips() async throws {
        let (lib, root) = try freshLibrary("from-bank")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = [
            BankItem(slot: 0, name: "Voltage Forms", meta: testMeta, blob: blob7(1)),
            BankItem(slot: 1, name: "Voltage Forms", meta: Data(), blob: blob7(2)), // repeat name, empty meta
            BankItem(slot: nil, name: "Unplaceable", meta: testMeta, blob: blob7(3)), // no slot -> skip
            BankItem(slot: 5, name: "Empty", meta: testMeta, blob: nil),             // no blob -> skip
        ]
        let (coll, added) = try await lib.collectionFromBank(
            items, name: "Ambient Peaks", source: "Ambient Peaks.mfprojz")
        #expect(coll.coveredSlots() == [0, 1])
        #expect(coll.provenance.kind == .importedBank)
        #expect(coll.provenance.source == "Ambient Peaks.mfprojz")
        // one entry per placed item, repeated name kept (no dedupe)
        #expect(added.count == 2)
        #expect(added.map(\.name) == ["Voltage Forms", "Voltage Forms"])
        #expect(added.allSatisfy { $0.category == .uncategorized && !$0.favorite })
        // The COLLECTION owns the arrangement; the flat catalog entries claim
        // nothing (UX spec §26.3 "no slot claim"). Importing a second pack
        // that also covers 0…1 must not steal this one's slots.
        #expect(added.allSatisfy { $0.slot == nil })
        #expect(await lib.slotMap().isEmpty)
        // empty meta became the zero meta (writable)
        #expect(coll.slots[1]?.metaHex == String(repeating: "00", count: 9))
        #expect(await lib.entries().count == 2)
    }

    // ----------------------------------------------------- blob GC + CRUD

    @Test func blobGCSpansCollections() async throws {
        let (lib, root) = try freshLibrary("gc")
        defer { try? FileManager.default.removeItem(at: root) }
        // an entry and a collection both reference the same blob
        let preset = try Preset(name: "Shared", blob: blob7(1), meta: testMeta)
        let entry = try await lib.add(preset)
        let coll = try await lib.collectionFromSnapshot(
            snapshot([snapshotRecord(slot: 0, name: "Shared", blob: blob7(1),
                                     meta: testMeta)]),
            name: "Holds It")
        #expect(coll.slots[0]?.sha256 == entry.sha256)
        // removing the entry must NOT delete the blob: the collection still refs it
        try await lib.remove(id: entry.id)
        #expect(await lib.hasBlob(entry.sha256), "collection still references the blob")
        // deleting the collection now GCs the unreferenced blob
        try await lib.deleteCollection(id: coll.id)
        #expect(!(await lib.hasBlob(entry.sha256)), "unreferenced blob deleted with collection")
        #expect(try await lib.collections().isEmpty)
    }

    @Test func renameAndDeleteAndNotFound() async throws {
        let (lib, root) = try freshLibrary("crud")
        defer { try? FileManager.default.removeItem(at: root) }
        let coll = try await lib.collectionFromBank(
            [BankItem(slot: 0, name: "A", meta: testMeta, blob: blob7(1))],
            name: "Original", source: "src").0
        let renamed = try await lib.renameCollection(id: coll.id, to: "Renamed")
        #expect(renamed.name == "Renamed" && renamed.id == coll.id)
        #expect(renamed.slots == coll.slots, "rename keeps slots and identity")
        #expect(try await lib.collection(id: coll.id).name == "Renamed")
        await #expect(throws: FreakError.collectionNotFound(id: "nope")) {
            try await lib.collection(id: "nope")
        }
        await #expect(throws: FreakError.collectionNotFound(id: "nope")) {
            try await lib.deleteCollection(id: "nope")
        }
    }

    @Test func presetForRefRehashes() async throws {
        let (lib, root) = try freshLibrary("resolve")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await lib.add(try Preset(name: "R", blob: blob7(4), meta: testMeta))
        let ref = PresetRef(sha256: entry.sha256, name: "R", metaHex: testMeta.hexString)
        let resolved = try await lib.presetForRef(ref)
        #expect(resolved.name == "R" && resolved.sha256 == entry.sha256)
        // missing blob -> integrity
        let ghost = PresetRef(sha256: String(repeating: "0", count: 64), name: "G",
                              metaHex: testMeta.hexString)
        let e = await expectFreakErrorAsync { try await lib.presetForRef(ghost) }
        guard case .integrity = e else {
            Issue.record("expected .integrity, got \(String(describing: e))")
            return
        }
    }
}
