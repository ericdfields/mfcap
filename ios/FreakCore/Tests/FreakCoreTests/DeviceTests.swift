// DeviceTests.swift — MicroFreakDevice: verified writes (with a lying wire
// caught by verification), the verify opt-out, torn writes, rename
// (name-frame-only), snapshot semantics, cancellation and progress.

import Foundation
import Testing
@testable import FreakCore

private let devicePreset = try! Preset(name: "Akiko San", blob: blob7(7), meta: testMeta)

private func options(readBlobs: Bool = true, keepBlobs: Bool = false,
                     slots: [Int]? = nil) -> SnapshotOptions {
    var o = SnapshotOptions()
    o.readBlobs = readBlobs
    o.keepBlobs = keepBlobs
    o.slots = slots
    return o
}

@Suite("MicroFreakDevice")
struct DeviceTests {

    /// Happy path: write + verify under reply lag (the default).
    @Test func verifiedWriteUnderReplyLag() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let device = makeDevice(sim)
        #expect(try await sim.peek(slot: 509).blob != devicePreset.blob)
        let report = try await device.write(slot: 509, preset: devicePreset)
        #expect(report.verified == true)
        #expect(report.slot == 509 && report.name == "Akiko San")
        #expect(report.sha256 == devicePreset.sha256)
        let after = try await sim.peek(slot: 509)
        #expect(after.blob == devicePreset.blob && after.name == "Akiko San")
        #expect(after.sha256 == devicePreset.sha256)
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")   // payload[8]/[9] recomputed right
    }

    /// One flipped bit in transit -> .verifyMismatch with the exact byte
    /// index — verification caught a write the ack stream alone would have
    /// called successful.
    @Test func corruptedWriteFailsVerification() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let wire = ChunkCorruptingTransport(sim, chunkIndex: 10, byteOffset: 5)
        let device = makeDevice(wire)
        let e = await expectFreakErrorAsync {
            try await device.write(slot: 509, preset: devicePreset)
        }
        guard case .verifyMismatch(let m) = e else {
            Issue.record("expected .verifyMismatch, got \(String(describing: e))")
            return
        }
        #expect(m.slot == 509)
        #expect(m.expectedSha256 == devicePreset.sha256)
        #expect(m.actualSha256 != nil && m.actualSha256 != devicePreset.sha256)
        #expect(m.firstDifference == 10 * 32 + 5)
        #expect(m.expectedLength == Wire.blobSize && m.actualLength == Wire.blobSize)
        // the device really holds the corrupted byte
        let stored = [UInt8](try await sim.peek(slot: 509).blob)
        let sent = [UInt8](devicePreset.blob)
        #expect(stored[325] == sent[325] ^ 0x01)
        #expect(Array(stored[..<325]) == Array(sent[..<325]))
        #expect(Array(stored[326...]) == Array(sent[326...]))
    }

    /// verify: false is the explicit opt-out — nothing was checked.
    @Test func verifyFalseSkipsReadBack() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let wire = ChunkCorruptingTransport(sim, chunkIndex: 0, byteOffset: 0)
        let device = makeDevice(wire)
        let report = try await device.write(slot: 509, preset: devicePreset, verify: false)
        #expect(report.verified == nil)                 // not true: nothing was checked
        #expect(try await sim.peek(slot: 509).blob != devicePreset.blob)  // the lie went undetected
    }

    @Test func missingAckThroughTheDevice() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false, failChunkAt: 10)
        let device = makeDevice(sim)
        let before = try await sim.peek(slot: 400).blob
        await #expect(throws: FreakError.chunkNotAcked(slot: 400, chunkIndex: 10)) {
            try await device.write(slot: 400, preset: devicePreset)
        }
        #expect(try await sim.peek(slot: 400).blob == before, "torn write must not commit")
    }

    /// Rename preserves meta and blob; sha256 is "" (no blob traffic).
    @Test func renamePreservesMetaAndBlob() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // lag ON
        let device = makeDevice(sim)
        let before = try await sim.peek(slot: 40)
        let report = try await device.rename(slot: 40, name: "Trapped II")
        #expect(report.verified == true && report.sha256 == "" && report.name == "Trapped II")
        let after = try await sim.peek(slot: 40)
        #expect(after.name == "Trapped II")
        #expect(after.blob == before.blob, "rename must not touch the blob")
        #expect(after.meta == before.meta, "rename must round-trip meta verbatim")
        let chunks = await sim.wireLog().filter {
            $0.direction == .out && Wire.parse($0.raw)!.isChunk
        }
        #expect(chunks.isEmpty, "rename must produce no blob traffic")
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")
    }

    @Test func renameValidatesNameFirst() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        await #expect(throws: FreakError.self) {
            try await device.rename(slot: 0, name: "way too long a name for this device")
        }
        #expect(await sim.wireLog().isEmpty,
                "an invalid name must be rejected before any traffic")
    }

    // ------------------------------------------------------------ reads

    @Test func nameAndReadRoundTrip() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        #expect(try await device.name(slot: 200) == "Patch 200")
        let preset = try await device.read(slot: 200)
        let expected = try await sim.peek(slot: 200)
        #expect(preset.name == expected.name)
        #expect(preset.blob == expected.blob)
        #expect(preset.meta == expected.meta)
    }

    @Test func snapshotNamesOnly() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // lag ON
        let device = makeDevice(sim)
        let snap = try await device.snapshot(
            options: options(readBlobs: false, slots: [0, 200, 384, 511]))
        #expect(snap.records.map(\.slot) == [0, 200, 384, 511])
        #expect(snap.records.map(\.name) == ["Patch 000", "Patch 200", "Init", "Init"])
        #expect(snap.records.allSatisfy { $0.sha256 == nil && $0.blob == nil })
        #expect(snap.records.allSatisfy { $0.meta != nil })
        #expect(!snap.hasHashes)
        #expect(snap.record(slot: 200)?.name == "Patch 200")
        #expect(snap.record(slot: 5) == nil)
        #expect(snap.timing.dumpMsMedian == nil)          // no dumps happened
    }

    @Test func snapshotWithBlobsAndHashes() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let snap = try await device.snapshot(options: options(slots: [3, 5]))
        #expect(snap.hasHashes)
        #expect(snap.record(slot: 3)?.sha256 == (try await sim.peek(slot: 3)).sha256)
        #expect(snap.records.allSatisfy { $0.blob == nil }, "blobs kept only on request")
        let kept = try await device.snapshot(options: options(keepBlobs: true, slots: [3]))
        #expect(kept.record(slot: 3)?.blob == (try await sim.peek(slot: 3)).blob)
    }

    /// A swallowed name-read failure leaves name/meta nil on the record; the
    /// snapshot itself survives.
    @Test func snapshotSwallowsNameReadFailures() async throws {
        let device = makeDevice(DeadTransport())
        let snap = try await device.snapshot(
            options: options(readBlobs: false, slots: [1, 2]))
        #expect(snap.records.count == 2)
        #expect(snap.records.allSatisfy { $0.name == nil && $0.meta == nil })
    }

    /// Requested slots come back sorted ascending regardless of input order.
    @Test func snapshotSortsRequestedSlots() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let snap = try await device.snapshot(
            options: options(readBlobs: false, slots: [9, 2, 300]))
        #expect(snap.records.map(\.slot) == [2, 9, 300])
    }

    // ------------------------------------------------------- cancellation

    /// Task cancellation mid-snapshot: the poll before the next slot throws
    /// .operationCancelled and no partial snapshot is returned.
    @Test func cancelledSnapshotMidway() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        // cancel right after the 3rd slot's name read goes out; slot index 3's
        // loop-top poll throws with done = 3
        let counter = Counter()
        let wire = SelfCancellingTransport(sim) { f in
            f.cmd == Wire.cmdOpen && f.data.last == 0 && counter.increment() == 3
        }
        let device = makeDevice(wire)
        let task = Task {
            try await device.snapshot(
                options: options(readBlobs: false, slots: Array(0..<10)))
        }
        await #expect(throws: FreakError.operationCancelled(done: 3, total: 10)) {
            try await task.value
        }
    }

    @Test func progressEventsCarryMedianEta() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let (reporter, collector) = collectingReporter()
        _ = try await device.snapshot(
            options: options(readBlobs: false, slots: Array(0..<5)),
            progress: reporter)
        let got = await collector.value
        #expect(got.map(\.done) == [1, 2, 3, 4, 5])
        #expect(got.allSatisfy { $0.total == 5 })
        #expect(got.last?.etaSeconds == 0, "nothing remains after the last slot")
        #expect(got.map(\.name) == ["Patch 000", "Patch 001", "Patch 002",
                                    "Patch 003", "Patch 004"])
    }
}
