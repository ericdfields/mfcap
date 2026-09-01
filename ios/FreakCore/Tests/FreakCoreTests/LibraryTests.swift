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
                                "added_at", "tags"])
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
}
