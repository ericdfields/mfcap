// DeviceTests.swift — MicroFreakDevice: verified writes (with a lying wire
// caught by verification), the verify opt-out, torn writes through the
// actor, rename, snapshot semantics and cancellation
// (test_device_write.py + test_core_write_verify.py transliterated).

import Foundation
import Testing
@testable import FreakCore

private let devicePreset = try! Preset(name: "Akiko San", blob: blob7(7), meta: testMeta)

@Suite("MicroFreakDevice")
struct DeviceTests {

    /// Happy path: write + verify under reply lag (the default).
    @Test func verifiedWriteUnderReplyLag() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let device = makeDevice(sim)
        #expect(try sim.peek(slot: 509).blob != devicePreset.blob)
        let report = try await device.write(slot: 509, preset: devicePreset)
        #expect(report.verified == true)
        #expect(report.slot == 509 && report.name == "Akiko San")
        #expect(report.sha256 == devicePreset.sha256)
        let after = try sim.peek(slot: 509)
        #expect(after.blob == devicePreset.blob && after.name == "Akiko San")
        #expect(after.sha256 == devicePreset.sha256)
        #expect(sim.faults.isEmpty, "\(sim.faults)")   // payload[8]/[9] recomputed right
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
        #expect(m.expectedLen == FreakProtocol.blobSize && m.actualLen == FreakProtocol.blobSize)
        // the device really holds the corrupted byte
        let stored = [UInt8](try sim.peek(slot: 509).blob)
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
        #expect(try sim.peek(slot: 509).blob != devicePreset.blob)  // the lie went undetected
    }

    @Test func missingAckThroughTheActor() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false, failChunkAt: 10)
        let device = makeDevice(sim)
        let before = try sim.peek(slot: 400).blob
        await #expect(throws: FreakError.chunkNotAcked(slot: 400, chunkIndex: 10)) {
            try await device.write(slot: 400, preset: devicePreset)
        }
        #expect(try sim.peek(slot: 400).blob == before, "torn write must not commit")
    }

    /// Rename preserves meta and blob; sha256 is "" (no blob traffic).
    @Test func renamePreservesMetaAndBlob() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // lag ON
        let device = makeDevice(sim)
        let before = try sim.peek(slot: 40)
        let report = try await device.rename(slot: 40, name: "Trapped II")
        #expect(report.verified == true && report.sha256 == "" && report.name == "Trapped II")
        let after = try sim.peek(slot: 40)
        #expect(after.name == "Trapped II")
        #expect(after.blob == before.blob, "rename must not touch the blob")
        #expect(after.meta == before.meta, "rename must round-trip meta verbatim")
        let chunks = sim.wireLog.filter {
            $0.direction == .out && FreakProtocol.parse($0.raw)!.isChunk
        }
        #expect(chunks.isEmpty, "rename must produce no blob traffic")
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    @Test func renameValidatesNameFirst() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        await #expect(throws: FreakError.self) {
            try await device.rename(slot: 0, name: "way too long a name for this device")
        }
        #expect(sim.wireLog.isEmpty, "an invalid name must be rejected before any traffic")
    }

    // ------------------------------------------------------------ reads

    @Test func nameAndReadRoundTrip() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        #expect(try await device.name(slot: 200) == "Patch 200")
        let preset = try await device.read(slot: 200)
        let expected = try sim.peek(slot: 200)
        #expect(preset.name == expected.name)
        #expect(preset.blob == expected.blob)
        #expect(preset.meta == expected.meta)
    }

    @Test func snapshotNamesOnly() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // lag ON
        let device = makeDevice(sim)
        let snap = try await device.snapshot(readBlobs: false,
                                             slots: [0, 200, 384, 511])
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
        let snap = try await device.snapshot(slots: [3, 5])   // readBlobs default true
        #expect(snap.hasHashes)
        #expect(snap.record(slot: 3)?.sha256 == (try sim.peek(slot: 3)).sha256)
        #expect(snap.records.allSatisfy { $0.blob == nil }, "blobs kept only on request")
        let kept = try await device.snapshot(keepBlobs: true, slots: [3])
        #expect(kept.record(slot: 3)?.blob == (try sim.peek(slot: 3)).blob)
    }

    /// A swallowed name-read failure leaves name/meta nil on the record; the
    /// snapshot itself survives.
    @Test func snapshotSwallowsNameReadFailures() async throws {
        let device = makeDevice(DeadTransport())
        let snap = try await device.snapshot(readBlobs: false, slots: [1, 2])
        #expect(snap.records.count == 2)
        #expect(snap.records.allSatisfy { $0.name == nil && $0.meta == nil })
    }

    /// Requested slots come back sorted ascending regardless of input order.
    @Test func snapshotSortsRequestedSlots() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let snap = try await device.snapshot(readBlobs: false, slots: [9, 2, 300])
        #expect(snap.records.map(\.slot) == [2, 9, 300])
    }

    // ------------------------------------------------------- cancellation

    @Test func preCancelledWrite() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let token = CancelToken()
        token.cancel()
        let before = try sim.peek(slot: 100).blob
        await #expect(throws: FreakError.cancelled(done: 0, total: FreakProtocol.chunkCount)) {
            try await device.write(slot: 100, preset: devicePreset, cancel: token)
        }
        #expect(try sim.peek(slot: 100).blob == before)
    }

    @Test func cancelledSnapshotMidway() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let token = CancelToken()
        let seen = LockedBox([Int]())
        let progress: ProgressFn = { event in
            seen.withLock { $0.append(event.slot) }
            if event.done == 3 {
                token.cancel()
            }
        }
        await #expect(throws: FreakError.cancelled(done: 3, total: 10)) {
            try await device.snapshot(readBlobs: false, slots: Array(0..<10),
                                      progress: progress, cancel: token)
        }
        #expect(seen.value == [0, 1, 2])
    }

    @Test func progressEventsCarryMedianEta() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let events = LockedBox([ProgressEvent]())
        _ = try await device.snapshot(readBlobs: false, slots: Array(0..<5),
                                      progress: { e in events.withLock { $0.append(e) } })
        let got = events.value
        #expect(got.map(\.done) == [1, 2, 3, 4, 5])
        #expect(got.allSatisfy { $0.total == 5 })
        #expect(got.last?.etaSeconds == 0, "nothing remains after the last slot")
        #expect(got.map(\.name) == ["Patch 000", "Patch 001", "Patch 002",
                                    "Patch 003", "Patch 004"])
    }
}
