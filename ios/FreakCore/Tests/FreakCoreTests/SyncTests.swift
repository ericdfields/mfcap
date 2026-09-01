// SyncTests.swift — the pure decision-table diff beyond the golden vectors:
// refusal on hash-less snapshots, by(status:), row ordering, and an
// end-to-end snapshot -> import -> diff pass over the simulated device.

import Foundation
import Testing
@testable import FreakCore

@Suite("Sync diff")
struct SyncTests {

    private func record(_ slot: Int, _ name: String?, _ sha: String?) -> SlotRecord {
        SlotRecord(slot: slot, name: name, sha256: sha, meta: nil, blob: nil)
    }

    private func snapshot(_ records: [SlotRecord]) -> DeviceSnapshot {
        DeviceSnapshot(takenAt: "2026-09-01T00:00:00", records: records,
                       timing: TimingReport(totalSeconds: 0, perSlotSeconds: 0,
                                            nameMsMedian: nil, dumpMsMedian: nil))
    }

    private func entry(_ i: Int, name: String, sha: String, slot: Int?) -> LibraryEntry {
        LibraryEntry(id: "e\(i)", name: name, sha256: sha,
                     metaHex: testMeta.hexString, slot: slot,
                     addedAt: "2026-09-01T00:00:00", tags: [])
    }

    @Test func refusesHashlessSnapshots() {
        let lib = Library(root: URL(fileURLWithPath: "/unused"), entries: [])
        let snap = snapshot([record(0, "A", "sha-a"), record(1, "B", nil)])
        #expect(throws: FreakError.snapshotMissingHashes) {
            try FreakCore.diff(snap, lib)
        }
    }

    @Test func rowsComeBackAscendingWithByStatus() throws {
        let entries = [entry(0, name: "A", sha: "sha-a", slot: 9),
                       entry(1, name: "B", sha: "sha-other", slot: 2)]
        let lib = Library(root: URL(fileURLWithPath: "/unused"), entries: entries)
        // records deliberately unsorted; unique shas so nothing is expendable
        let snap = snapshot([record(9, "A", "sha-a"),
                             record(2, "B", "sha-b"),
                             record(5, "C", "sha-c")])
        let result = try FreakCore.diff(snap, lib)
        #expect(result.slots.map(\.slot) == [2, 5, 9], "one row per record, ascending")
        #expect(result.slots.map(\.status) == [.differs, .deviceOnly, .inSync])
        #expect(result.by(status: .inSync).map(\.slot) == [9])
        #expect(result.by(status: .differs).map(\.slot) == [2])
        #expect(result.by(status: .libraryOnly).isEmpty)
        // SlotDiff.device is always populated (tightened; §10 deviation 5)
        #expect(result.slots.allSatisfy { $0.device.slot == $0.slot })
        #expect(result.slots.map { $0.library?.id } == ["e1", nil, "e0"])
    }

    @Test func statusRawValuesMatchThePythonEnum() {
        #expect(SlotStatus.inSync.rawValue == "in_sync")
        #expect(SlotStatus.deviceOnly.rawValue == "added")
        #expect(SlotStatus.libraryOnly.rawValue == "missing")
        #expect(SlotStatus.differs.rawValue == "changed")
        #expect(SlotStatus.empty.rawValue == "empty")
        #expect(SlotStatus.allCases.count == 5)
    }

    /// End to end offline: snapshot the factory sim with kept blobs, import
    /// into a fresh library, then diff — named slots in sync, Init slots
    /// empty.
    @Test func snapshotImportDiffRoundTrip() async throws {
        let root = tempDir("sync-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let slots = [0, 1, 2, 500, 501, 502, 503]         // 500+ are the Init block
        let snap = try await device.snapshot(keepBlobs: true, slots: slots)
        let lib = try Library.create(at: root)
        let added = try lib.importSnapshot(snap)
        #expect(added.map(\.slot) == [0, 1, 2], "Init duplicates are expendable, skipped")
        let result = try FreakCore.diff(snap, lib)
        #expect(result.by(status: .inSync).map(\.slot) == [0, 1, 2])
        #expect(result.by(status: .empty).map(\.slot) == [500, 501, 502, 503])
        #expect(result.by(status: .differs).isEmpty && result.by(status: .deviceOnly).isEmpty)
    }
}
