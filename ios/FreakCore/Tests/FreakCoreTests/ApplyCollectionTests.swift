// ApplyCollectionTests.swift — MicroFreakDevice.applyCollection: writes ONLY
// the changed slots (verified against the sim wire log), cancels between
// slots, and stops at the first failure with the completed reports attached to
// .applyFailed. The resolver is the standard Library.presetForRef, hopping to
// the Library actor.

import Foundation
import Testing
@testable import FreakCore

@Suite("applyCollection")
struct ApplyCollectionTests {

    private func fullHashedSnapshot(_ device: MicroFreakDevice,
                                    slots: Int) async throws -> DeviceSnapshot {
        var o = SnapshotOptions()
        o.readBlobs = true
        o.slots = Array(0..<slots)
        return try await device.snapshot(options: o, progress: nil)
    }

    /// One outbound chunk-last frame terminates each blob write, so counting
    /// them is counting write bursts.
    private func writeBursts(_ sim: SimulatedMicroFreak) async -> Int {
        await sim.wireLog().filter {
            $0.direction == .out && Wire.parse($0.raw)?.cmd == Wire.cmdChunkLast
        }.count
    }

    /// A collection targeting slots 0 and 2 of an all-Init 6-slot device:
    /// planApply says WRITE 0, WRITE 2, SKIP the rest; applyCollection writes
    /// exactly those two and leaves the others untouched.
    @Test func writesOnlyChangedSlots() async throws {
        let root = tempDir("apply-writes")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        let sim = SimulatedMicroFreak(slots: 6, replyLag: false)
        let device = makeDevice(sim, slotCount: 6)

        let alpha = try await lib.add(try Preset(name: "Alpha", blob: blob7(1), meta: testMeta))
        let beta = try await lib.add(try Preset(name: "Beta", blob: blob7(2), meta: testMeta))
        let coll = PresetCollection.new(
            name: "Set", provenance: Provenance(kind: .manual),
            slots: [
                0: PresetRef(sha256: alpha.sha256, name: "Alpha", metaHex: testMeta.hexString),
                2: PresetRef(sha256: beta.sha256, name: "Beta", metaHex: testMeta.hexString),
            ])

        let snap = try await fullHashedSnapshot(device, slots: 6)
        let plan = try planApply(collection: coll, snapshot: snap)
        #expect(plan.writeCount == 2 && plan.clearCount == 0 && plan.skipCount == 4)
        #expect(plan.totalSlots == 6)
        #expect(plan.changes().map(\.slot) == [0, 2])

        let reports = try await device.applyCollection(
            plan: plan, resolve: { try await lib.presetForRef($0) }, progress: nil)
        #expect(reports.map(\.slot) == [0, 2])
        #expect(reports.allSatisfy { $0.verified == true })
        // exactly two write bursts on the wire — SKIP slots never written
        #expect(await writeBursts(sim) == 2)
        // device now matches the collection at 0 and 2; slot 1 still Init
        #expect(try await sim.peek(slot: 0).name == "Alpha")
        #expect(try await sim.peek(slot: 0).blob == blob7(1))
        #expect(try await sim.peek(slot: 2).name == "Beta")
        #expect(try await sim.peek(slot: 1).name == "Init")
    }

    /// Re-applying a collection that already matches the device writes nothing.
    @Test func noChangesWritesNothing() async throws {
        let root = tempDir("apply-noop")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        let sim = SimulatedMicroFreak.factoryFresh(initCopies: 2, slots: 4, replyLag: false)
        let device = makeDevice(sim, slotCount: 4)
        // snapshot with kept blobs, build the collection FROM it: it equals the device
        var o = SnapshotOptions(); o.readBlobs = true; o.keepBlobs = true; o.slots = Array(0..<4)
        let snap = try await device.snapshot(options: o, progress: nil)
        let coll = try await lib.collectionFromSnapshot(snap, name: "Mirror")
        let plan = try planApply(collection: coll, snapshot: snap)
        #expect(plan.writeCount == 0 && plan.clearCount == 0)
        let reports = try await device.applyCollection(
            plan: plan, resolve: { try await lib.presetForRef($0) }, progress: nil)
        #expect(reports.isEmpty)
        #expect(await writeBursts(sim) == 0)
    }

    /// Cancelling the task before applyCollection runs throws
    /// .applyFailed(underlying: .operationCancelled(done: 0), completed: []).
    @Test func wrapsCancellation() async throws {
        let root = tempDir("apply-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        let sim = SimulatedMicroFreak(slots: 6, replyLag: false)
        let device = makeDevice(sim, slotCount: 6)
        let a = try await lib.add(try Preset(name: "A", blob: blob7(1), meta: testMeta))
        let b = try await lib.add(try Preset(name: "B", blob: blob7(2), meta: testMeta))
        let coll = PresetCollection.new(
            name: "S", provenance: Provenance(kind: .manual),
            slots: [0: PresetRef(sha256: a.sha256, name: "A", metaHex: testMeta.hexString),
                    2: PresetRef(sha256: b.sha256, name: "B", metaHex: testMeta.hexString)])
        let plan = try planApply(collection: coll, snapshot: try await fullHashedSnapshot(device, slots: 6))

        let task = Task { () throws -> [WriteReport] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.applyCollection(
                plan: plan, resolve: { try await lib.presetForRef($0) }, progress: nil)
        }
        await #expect(throws: FreakError.applyFailed(
            underlying: .operationCancelled(done: 0, total: 2), completed: [])) {
            try await task.value
        }
        #expect(await writeBursts(sim) == 0, "cancelled before any write")
    }

    /// A failing write path stops applyCollection at the first failure and
    /// attaches the completed reports to .applyFailed.
    @Test func stopsAtFirstFailure() async throws {
        let root = tempDir("apply-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        // 146 chunks per blob write: first change writes chunks 0..145,
        // the second change's chunk 5 (cumulative 151) goes unacked.
        let sim = SimulatedMicroFreak(slots: 6, replyLag: false, failChunkAt: 146 + 5)
        let device = makeDevice(sim, slotCount: 6)
        let a = try await lib.add(try Preset(name: "Alpha", blob: blob7(1), meta: testMeta))
        let b = try await lib.add(try Preset(name: "Beta", blob: blob7(2), meta: testMeta))
        let coll = PresetCollection.new(
            name: "S", provenance: Provenance(kind: .manual),
            slots: [0: PresetRef(sha256: a.sha256, name: "Alpha", metaHex: testMeta.hexString),
                    2: PresetRef(sha256: b.sha256, name: "Beta", metaHex: testMeta.hexString)])
        let plan = try planApply(collection: coll, snapshot: try await fullHashedSnapshot(device, slots: 6))

        let e = await expectFreakErrorAsync {
            try await device.applyCollection(
                plan: plan, resolve: { try await lib.presetForRef($0) }, progress: nil)
        }
        guard case .applyFailed(let underlying, let completed) = e else {
            Issue.record("expected .applyFailed, got \(String(describing: e))")
            return
        }
        #expect(underlying == .chunkNotAcked(slot: 2, chunkIndex: 5))
        #expect(completed.map(\.slot) == [0], "only the first changed slot completed")
        #expect(completed.allSatisfy { $0.verified == true })
        // slot 0 fully written; slot 2's torn blob write did NOT commit (the
        // name frame lands first in the protocol, so only the blob is proof).
        #expect(try await sim.peek(slot: 0).name == "Alpha")
        #expect(try await sim.peek(slot: 0).blob == blob7(1))
        #expect(try await sim.peek(slot: 2).blob == Data(count: Wire.blobSize),
                "torn blob write must not commit")
    }

    /// Progress events count only the changed slots (the pre-flight N-of-512
    /// comes from the ApplyPlan counts, not the progress total).
    @Test func progressCountsChangedSlotsOnly() async throws {
        let root = tempDir("apply-progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        let sim = SimulatedMicroFreak(slots: 6, replyLag: false)
        let device = makeDevice(sim, slotCount: 6)
        let a = try await lib.add(try Preset(name: "A", blob: blob7(1), meta: testMeta))
        let b = try await lib.add(try Preset(name: "B", blob: blob7(2), meta: testMeta))
        let coll = PresetCollection.new(
            name: "S", provenance: Provenance(kind: .manual),
            slots: [1: PresetRef(sha256: a.sha256, name: "A", metaHex: testMeta.hexString),
                    4: PresetRef(sha256: b.sha256, name: "B", metaHex: testMeta.hexString)])
        let plan = try planApply(collection: coll, snapshot: try await fullHashedSnapshot(device, slots: 6))
        let (reporter, collector) = collectingReporter()
        _ = try await device.applyCollection(
            plan: plan, resolve: { try await lib.presetForRef($0) }, progress: reporter)
        let got = await collector.value
        #expect(got.map(\.done) == [1, 2])
        #expect(got.allSatisfy { $0.total == 2 }, "total == number of changed slots")
        #expect(got.map(\.slot) == [1, 4])
        #expect(got.last?.etaSeconds == 0)
    }
}
