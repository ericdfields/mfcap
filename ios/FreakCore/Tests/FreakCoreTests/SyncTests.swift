// SyncTests.swift — the pure decision-table diff beyond the golden vectors:
// refusal on hash-less snapshots, byStatus, row ordering, the sparse-baseline
// regression, and an end-to-end snapshot -> collection -> diff pass over the
// simulated device. Plus the (c) unification proof: planApply's actions ARE
// the mapping of this diff's statuses.

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

    private func ref(_ name: String, _ sha: String) -> PresetRef {
        PresetRef(sha256: sha, name: name, metaHex: testMeta.hexString)
    }

    @Test func refusesHashlessSnapshots() {
        let snap = snapshot([record(0, "A", "sha-a"), record(1, "B", nil)])
        #expect(throws: FreakError.snapshotMissingHashes) {
            try computeDiff(snapshot: snap, baseline: [:])
        }
    }

    @Test func rowsComeBackAscendingWithByStatus() throws {
        let baseline: [Int: PresetRef] = [9: ref("A", "sha-a"),
                                          2: ref("B", "sha-other")]
        // records deliberately unsorted; unique shas so nothing is expendable
        let snap = snapshot([record(9, "A", "sha-a"),
                             record(2, "B", "sha-b"),
                             record(5, "C", "sha-c")])
        let result = try computeDiff(snapshot: snap, baseline: baseline)
        #expect(result.slots.map(\.slot) == [2, 5, 9], "one row per record, ascending")
        #expect(result.slots.map(\.status) == [.differs, .unlisted, .inSync])
        #expect(result.byStatus(.inSync).map(\.slot) == [9])
        #expect(result.byStatus(.differs).map(\.slot) == [2])
        #expect(result.byStatus(.baselineOnly).isEmpty)
        #expect(result.slots.allSatisfy { $0.device?.slot == $0.slot })
        #expect(result.slots.map { $0.baseline?.name } == ["B", nil, "A"])
        #expect(result.unreadBaselineSlots.isEmpty)
    }

    /// The reported bug: a 2-slot baseline against a full device must not
    /// report the other 510 slots as `missing`. Slots the collection is
    /// silent about are `unlisted` / `empty` — informational, never actionable.
    @Test func sparseBaselineReportsNothingMissing() throws {
        let records = (0..<8).map { record($0, "P\($0)", "sha-\($0)") }
        let baseline: [Int: PresetRef] = [0: ref("P0", "sha-0")]
        let result = try computeDiff(snapshot: snapshot(records), baseline: baseline)
        #expect(result.byStatus(.inSync).map(\.slot) == [0])
        #expect(result.byStatus(.baselineOnly).isEmpty, "silence is not `missing`")
        #expect(result.byStatus(.differs).isEmpty, "silence is not `changed`")
        #expect(result.byStatus(.unlisted).map(\.slot) == Array(1..<8))
    }

    /// A device holding exactly its collection reads as all-in-sync.
    @Test func exactMatchIsAllInSync() throws {
        let records = (0..<6).map { record($0, "P\($0)", "sha-\($0)") }
        var baseline: [Int: PresetRef] = [:]
        for r in records { baseline[r.slot] = ref(r.name!, r.sha256!) }
        let result = try computeDiff(snapshot: snapshot(records), baseline: baseline)
        #expect(result.slots.allSatisfy { $0.status == .inSync })
        #expect(result.slots.allSatisfy { !$0.nameDiffers })
    }

    /// A rename never changes the status (the diff is content-based) but it
    /// is flagged — and that flag is what makes planApply WRITE.
    @Test func nameOnlyDifferenceStaysInSyncButIsFlagged() throws {
        let snap = snapshot([record(0, "On Device", "sha-0")])
        let result = try computeDiff(snapshot: snap,
                                     baseline: [0: ref("In Collection", "sha-0")])
        #expect(result.slots.map(\.status) == [.inSync])
        #expect(result.slots.map(\.nameDiffers) == [true])
    }

    /// Baseline slots the snapshot never covered are reported as unknown,
    /// never as missing.
    @Test func unreadBaselineSlotsAreReportedSeparately() throws {
        let snap = snapshot([record(0, "A", "sha-a")])
        let result = try computeDiff(snapshot: snap,
                                     baseline: [0: ref("A", "sha-a"),
                                                7: ref("Z", "sha-z"),
                                                3: ref("Y", "sha-y")])
        #expect(result.unreadBaselineSlots == [3, 7])
        #expect(result.byStatus(.baselineOnly).isEmpty)
    }

    @Test func statusRawValuesMatchThePythonEnum() {
        #expect(SlotStatus.inSync.rawValue == "in_sync")
        #expect(SlotStatus.unlisted.rawValue == "unlisted")
        #expect(SlotStatus.baselineOnly.rawValue == "missing")
        #expect(SlotStatus.differs.rawValue == "changed")
        #expect(SlotStatus.empty.rawValue == "empty")
        #expect(SlotStatus.allCases.count == 5)
    }

    /// End to end offline: snapshot the factory sim with kept blobs, build a
    /// COLLECTION from it, then diff the device against that collection — a
    /// device matching its own arrangement is entirely in sync, Init block
    /// included (sha equality wins before expendability).
    @Test func snapshotCollectionDiffRoundTrip() async throws {
        let root = tempDir("sync-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        var opts = SnapshotOptions()
        opts.keepBlobs = true
        opts.slots = [0, 1, 2, 500, 501, 502, 503]         // 500+ are the Init block
        let snap = try await device.snapshot(options: opts)
        let lib = try Library.create(at: root)
        let coll = try await lib.collectionFromSnapshot(snap, name: "As Read")
        let added = try await lib.importSnapshot(snap)
        #expect(added.map(\.slot) == [0, 1, 2], "Init duplicates are expendable, skipped")
        let result = try computeDiff(snapshot: snap, collection: coll)
        #expect(result.slots.allSatisfy { $0.status == .inSync },
                "the device matches the collection it was snapshotted from")
        #expect(result.byStatus(.differs).isEmpty
                && result.byStatus(.unlisted).isEmpty
                && result.byStatus(.baselineOnly).isEmpty)
        #expect(result.unreadBaselineSlots.isEmpty)
    }

    /// The (c) unification, executable: every SlotPlan action is exactly the
    /// mapping of the corresponding SlotDiff's status + nameDiffers. If these
    /// ever drift, there are two decision tables again.
    @Test func planApplyAgreesWithDiff() throws {
        // slots 3, 4, 5 hold the same blob -> expendable at threshold 3
        let records = [
            record(0, "Keep", "sha-a"), record(1, "Old", "sha-b"),
            record(2, "Renamed", "sha-c"), record(3, "Init", "sha-dup"),
            record(4, "Init", "sha-dup"), record(5, "Init", "sha-dup"),
            record(6, "Solo", "sha-g"), record(7, "Other", "sha-h"),
        ]
        let coll = PresetCollection.new(
            name: "Mixed", provenance: Provenance(kind: .manual, source: ""),
            slots: [0: ref("Keep", "sha-a"),          // inSync, same name
                    1: ref("New", "sha-new"),         // differs
                    2: ref("Renamed Elsewhere", "sha-c"),  // inSync, name differs
                    3: ref("Fat Bass", "sha-fat")])   // baselineOnly (expendable)
        let snap = snapshot(records)
        let d = try computeDiff(snapshot: snap, collection: coll)
        let byslot = Dictionary(uniqueKeysWithValues: d.slots.map { ($0.slot, $0) })
        #expect(byslot[0]!.status == .inSync && !byslot[0]!.nameDiffers)
        #expect(byslot[1]!.status == .differs)
        #expect(byslot[2]!.status == .inSync && byslot[2]!.nameDiffers)
        #expect(byslot[3]!.status == .baselineOnly)

        for policy in [ApplyOptions.Unlisted.leave, .clear] {
            var options = ApplyOptions()
            options.unlisted = policy
            options.clearWith = ref("Init", "sha-dup")
            let plan = try planApply(collection: coll, snapshot: snap, options: options)
            #expect(plan.slots.count == d.slots.count)
            for (sp, row) in zip(plan.slots, d.slots) {
                #expect(sp.slot == row.slot)
                let expected: PlanAction
                switch row.status {
                case .inSync where !row.nameDiffers:
                    expected = .skip
                case .inSync, .differs, .baselineOnly:
                    expected = .write
                case .unlisted, .empty:
                    if policy == .leave {
                        expected = .skip
                    } else if row.device?.sha256 == options.clearWith!.sha256
                                && row.device?.name == options.clearWith!.name {
                        expected = .skip
                    } else {
                        expected = .clear
                    }
                }
                #expect(sp.action == expected,
                        "slot \(row.slot) \(row.status) -> \(sp.action)")
            }
        }
    }
}
