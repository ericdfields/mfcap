// WriteSequenceTests.swift — the gate-verified 7-frame write on the wire:
// order and ack accounting via the sim's wireLog, the .writeAborted stage /
// chunksSent bookkeeping, torn writes via failChunkAt, cancellation
// mid-burst, and rename-without-blob-traffic.

import Foundation
import os
import Testing
@testable import FreakCore

private let writePreset = try! Preset(name: "Akiko San", blob: blob7(3), meta: testMeta)

@Suite("Write sequence")
struct WriteSequenceTests {

    /// The exact 7-frame sequence, in order (lag off for determinism).
    @Test func sevenFrameSequenceVerbatim() async throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        let info = try await session.writePreset(slot: 509, preset: writePreset)
        #expect(info.slot == 509 && info.name == "Akiko San")
        let wireLog = await sim.wireLog()
        let out = wireLog.filter { $0.direction == .out }.map { Wire.parse($0.raw)! }
        let kinds: [[Int]] = out.map { [Int($0.cmd), $0.data.count] }
        var expected: [[Int]] = [[0x19, 3]]                       // 1: name read
        expected.append([0x52, 35])                               // 2: name + meta
        expected.append([0x52, 3])                                // 3: open blob write
        expected.append([0x15, 0])                                // 4: go
        expected.append(contentsOf: Array(repeating: [0x16, 32], count: 145))  // 5
        expected.append([0x17, 32])                               // 6: last chunk
        expected.append([0x19, 3])                                // 7: read back
        #expect(kinds.count == 151)
        #expect(kinds == expected, "write is not the verbatim 7-frame sequence")
        // addresses only in 0x19/0x52 frames
        #expect(out[0].data == Data([3, 125, 0]))
        #expect(out[2].data == Data([3, 125, 1]))
        #expect(out[3].data.isEmpty && out[3].seq == 0)           // go: seq 0, len 0
        // chunks carry content only — reassembling them yields the blob
        var sentBlob = Data()
        for f in out where f.isChunk {
            sentBlob.append(f.data)
        }
        #expect(sentBlob == writePreset.blob)
        // captured ack traffic: name 0x52 + open 0x52 + go + 146 chunks = 149
        let acks = wireLog.filter { $0.direction == .in && Wire.parse($0.raw)!.isAck }
        #expect(acks.count == 149)
        // device-shape acks: len 0x00, empty payload
        for a in acks {
            let f = Wire.parse(a.raw)!
            #expect(f.length == 0 && f.data.isEmpty)
        }
        #expect((try await sim.peek(slot: 509)).blob == writePreset.blob)
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")
    }

    /// Chunk seqs continue from the go frame's 0 and wrap THROUGH 0 — a
    /// stream separate from the addressed counter (which skips 0).
    @Test func chunkSeqStreamIsSeparateFromAddressedCounter() async throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        _ = try await session.writePreset(slot: 3, preset: writePreset)
        let out = await sim.wireLog().filter { $0.direction == .out }
            .map { Wire.parse($0.raw)! }
        let chunkSeqs = out.filter(\.isChunk).map { Int($0.seq) }
        #expect(chunkSeqs == (0..<146).map { ($0 + 1) % 128 })
        #expect(chunkSeqs.contains(0), "the chunk stream wraps THROUGH 0")
        let addressedSeqs = out.filter { !$0.isChunk && $0.cmd != Wire.cmdGo }
            .map { Int($0.seq) }
        #expect(!addressedSeqs.contains(0), "the addressed counter never emits 0")
        #expect(addressedSeqs == [1, 2, 3, 4])
    }

    // ----------------------------------------------- writeAborted bookkeeping

    @Test func sendFailureAtEachControlStage() async throws {
        let judges: [(WriteStage, @Sendable (Frame) -> Bool)] = [
            (.nameWrite, { $0.cmd == Wire.cmdName && $0.data.count == 35 }),
            (.open, { $0.cmd == Wire.cmdName && $0.data.count == 3 }),
            (.go, { $0.cmd == Wire.cmdGo }),
        ]
        for (stage, judge) in judges {
            let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
            let session = makeSession(FailingSendTransport(sim, judge: judge))
            await #expect(throws: FreakError.writeAborted(stage: stage, slot: 509,
                                                          chunksSent: 0),
                          "stage \(stage)") {
                try await session.writePreset(slot: 509, preset: writePreset)
            }
        }
    }

    @Test func sendFailureMidChunkStream() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let counter = Counter()
        let session = makeSession(FailingSendTransport(sim) { f in
            guard f.isChunk else { return false }
            return counter.increment() == 6          // fail sending chunk index 5
        })
        let before = try await sim.peek(slot: 509).blob
        await #expect(throws: FreakError.writeAborted(stage: .chunk, slot: 509,
                                                      chunksSent: 5)) {
            try await session.writePreset(slot: 509, preset: writePreset)
        }
        #expect(try await sim.peek(slot: 509).blob == before, "torn write must not commit")
    }

    @Test func missingControlFrameAck() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let wire = AckDroppingTransport(sim)
        let session = makeSession(wire)
        await wire.dropAcks(true)
        await #expect(throws: FreakError.writeAborted(stage: .nameWrite, slot: 509,
                                                      chunksSent: 0)) {
            try await session.writePreset(slot: 509, preset: writePreset)
        }
    }

    @Test func failingFinalReadBack() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(ReplyDroppingTransport(sim))
        await #expect(throws: FreakError.writeAborted(stage: .finalRead, slot: 509,
                                                      chunksSent: Wire.chunkCount)) {
            try await session.writePreset(slot: 509, preset: writePreset)
        }
        // the write itself completed: the blob is committed on the device
        #expect(try await sim.peek(slot: 509).blob == writePreset.blob)
    }

    // ---------------------------------------------------------- torn write

    @Test func tornWriteFailChunkAt() async throws {
        let sim = SimulatedMicroFreak(replyLag: false, failChunkAt: 3)
        let session = makeSession(sim)
        let before = try await sim.peek(slot: 5).blob
        await #expect(throws: FreakError.chunkNotAcked(slot: 5, chunkIndex: 3)) {
            try await session.writePreset(slot: 5, preset: writePreset)
        }
        #expect(try await sim.peek(slot: 5).blob == before, "no commit, slot untouched")
    }

    /// Torn write, then a fresh verified write of the same slot succeeds —
    /// recovery is "write again".
    @Test func rewriteAfterTornWriteRecovers() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false, failChunkAt: 4)
        let device = makeDevice(sim)
        await #expect(throws: FreakError.chunkNotAcked(slot: 40, chunkIndex: 4)) {
            try await device.write(slot: 40, preset: writePreset)
        }
        // failChunkAt is CUMULATIVE (every later chunk goes unacked too), so
        // a rewrite on THIS sim would fail as well — use a fresh sim per
        // torn scenario (the documented rule) and prove the rewrite there.
        let fresh = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let freshDevice = makeDevice(fresh)
        let report = try await freshDevice.write(slot: 40, preset: writePreset)
        #expect(report.verified == true)
        #expect(try await fresh.peek(slot: 40).blob == writePreset.blob)
    }

    /// Cancelling mid-write tears the slot; done/total say how far it got.
    @Test func cancelledMidWrite() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        // cancel the running task right after chunk index 9 goes out; the
        // poll before chunk 10 throws
        let counter = Counter()
        let wire = SelfCancellingTransport(sim) { f in
            f.isChunk && counter.increment() == 10
        }
        let session = makeSession(wire)
        let task = Task {
            try await session.writePreset(slot: 100, preset: writePreset)
        }
        await #expect(throws: FreakError.operationCancelled(done: 10, total: 146)) {
            try await task.value
        }
        // torn: the sim never saw a 0x17, slot untouched
        #expect(try await sim.peek(slot: 100).blob != writePreset.blob)
        // rewrite recovers (same sim: no failChunkAt in play)
        let report = try await makeDevice(sim).write(slot: 100, preset: writePreset)
        #expect(report.verified == true)
        #expect(try await sim.peek(slot: 100).blob == writePreset.blob)
    }

    /// A write on an already-cancelled task stops at chunk 0.
    @Test func preCancelledWriteStopsAtChunkZero() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(sim)
        let before = try await sim.peek(slot: 100).blob
        let task = Task { () throws -> NameInfo in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.writePreset(slot: 100, preset: writePreset)
        }
        await #expect(throws: FreakError.operationCancelled(done: 0,
                                                            total: Wire.chunkCount)) {
            try await task.value
        }
        #expect(try await sim.peek(slot: 100).blob == before)
    }

    // --------------------------------------------------------------- rename

    /// writeName is a rename: one long 0x52 + one refresh read; zero blob
    /// traffic; the device ack is awaited (missing -> .deviceTimeout).
    @Test func renameIsLong52PlusRefreshOnly() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(sim)
        let before = try await sim.peek(slot: 42)
        let info = try await session.writeName(slot: 42, name: "New Name",
                                               meta: before.meta)
        #expect(info.slot == 42 && info.name == "New Name")
        #expect(try await sim.peek(slot: 42).name == "New Name")
        #expect(try await sim.peek(slot: 42).blob == before.blob)
        let sent = await sim.wireLog().filter { $0.direction == .out }
            .map { Wire.parse($0.raw)! }
        #expect(sent.allSatisfy { $0.cmd != Wire.cmdGo && !$0.isChunk },
                "rename must never send go/chunk frames")
        #expect(sent.filter { $0.cmd == Wire.cmdName && $0.data.count == 35 }.count == 1)
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")
    }

    @Test func renameWithoutAckTimesOut() async {
        let session = makeSession(DeadTransport())
        await #expect(throws: FreakError.deviceTimeout(stage: .nameWriteAck, slot: 8)) {
            try await session.writeName(slot: 8, name: "X", meta: testMeta)
        }
    }
}

/// Tiny sendable counter for judge closures.
final class Counter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    func increment() -> Int {
        lock.withLock { value in
            value += 1
            return value
        }
    }
}
