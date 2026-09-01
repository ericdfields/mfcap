// WriteSequenceTests.swift — the gate-verified 7-frame write on the wire:
// order and ack accounting via the sim's wireLog, the WriteAborted stage /
// chunksSent bookkeeping, torn writes, and rename-without-blob-traffic
// (test_core_write_verify.py + test_write_aborted.py transliterated).

import Foundation
import Testing
@testable import FreakCore

private let writePreset = try! Preset(name: "Akiko San", blob: blob7(3), meta: testMeta)

@Suite("Write sequence")
struct WriteSequenceTests {

    /// The exact 7-frame sequence, in order (lag off for determinism).
    @Test func sevenFrameSequenceVerbatim() throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        let info = try session.writePreset(slot: 509, writePreset)
        #expect(info.slot == 509 && info.name == "Akiko San")
        let out = sim.wireLog.filter { $0.direction == .out }
            .map { FreakProtocol.parse($0.raw)! }
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
        let acks = sim.wireLog.filter {
            $0.direction == .in && FreakProtocol.parse($0.raw)!.isAck
        }
        #expect(acks.count == 149)
        // device-shape acks: len 0x00, empty payload
        for a in acks {
            let f = FreakProtocol.parse(a.raw)!
            #expect(f.length == 0 && f.data.isEmpty)
        }
        #expect((try sim.peek(slot: 509)).blob == writePreset.blob)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    /// Chunk seqs continue from the go frame's 0 and wrap THROUGH 0 — a
    /// stream separate from the addressed counter (which skips 0).
    @Test func chunkSeqStreamIsSeparateFromAddressedCounter() throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        _ = try session.writePreset(slot: 3, writePreset)
        let out = sim.wireLog.filter { $0.direction == .out }
            .map { FreakProtocol.parse($0.raw)! }
        let chunkSeqs = out.filter(\.isChunk).map { Int($0.seq) }
        #expect(chunkSeqs == (0..<146).map { ($0 + 1) % 128 })
        #expect(chunkSeqs.contains(0), "the chunk stream wraps THROUGH 0")
        let addressedSeqs = out.filter { !$0.isChunk && $0.cmd != FreakProtocol.cmdGo }
            .map { Int($0.seq) }
        #expect(!addressedSeqs.contains(0), "the addressed counter never emits 0")
        #expect(addressedSeqs == [1, 2, 3, 4])
    }

    // ----------------------------------------------- WriteAborted bookkeeping

    @Test func sendFailureAtEachControlStage() throws {
        let judges: [(WriteStage, @Sendable (Frame) -> Bool)] = [
            (.nameWrite, { $0.cmd == FreakProtocol.cmdName && $0.data.count == 35 }),
            (.open, { $0.cmd == FreakProtocol.cmdName && $0.data.count == 3 }),
            (.go, { $0.cmd == FreakProtocol.cmdGo }),
        ]
        for (stage, judge) in judges {
            let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
            let session = makeSession(FailingSendTransport(sim, judge: judge))
            let e = expectFreakError("stage \(stage)") {
                try session.writePreset(slot: 509, writePreset)
            }
            guard case .writeAborted(let s, let slot, let chunksSent, let underlying) = e else {
                Issue.record("expected .writeAborted at \(stage), got \(String(describing: e))")
                continue
            }
            #expect(s == stage && slot == 509 && chunksSent == 0)
            #expect(underlying?.contains("wire pulled") == true)
        }
    }

    @Test func sendFailureMidChunkStream() throws {
        let counter = LockedBox(0)
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(FailingSendTransport(sim) { f in
            guard f.isChunk else { return false }
            return counter.withLock { chunks in
                chunks += 1
                return chunks == 6          // fail sending chunk index 5
            }
        })
        let before = try sim.peek(slot: 509).blob
        let e = expectFreakError { try session.writePreset(slot: 509, writePreset) }
        guard case .writeAborted(let stage, let slot, let chunksSent, _) = e else {
            Issue.record("expected .writeAborted, got \(String(describing: e))")
            return
        }
        #expect(stage == .chunk && slot == 509 && chunksSent == 5)
        #expect(try sim.peek(slot: 509).blob == before, "torn write must not commit")
    }

    @Test func missingControlFrameAck() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let wire = AckDroppingTransport(sim)
        let session = makeSession(wire)
        wire.dropAcks = true
        let e = expectFreakError { try session.writePreset(slot: 509, writePreset) }
        guard case .writeAborted(let stage, let slot, let chunksSent, let underlying) = e else {
            Issue.record("expected .writeAborted, got \(String(describing: e))")
            return
        }
        #expect(stage == .nameWrite && slot == 509 && chunksSent == 0)
        #expect(underlying == nil)
    }

    @Test func failingFinalReadBack() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(ReplyDroppingTransport(sim))
        let e = expectFreakError { try session.writePreset(slot: 509, writePreset) }
        guard case .writeAborted(let stage, let slot, let chunksSent, let underlying) = e else {
            Issue.record("expected .writeAborted, got \(String(describing: e))")
            return
        }
        #expect(stage == .finalRead && slot == 509)
        #expect(chunksSent == FreakProtocol.chunkCount)
        #expect(underlying?.contains("device timeout") == true)
        // the write itself completed: the blob is committed on the device
        #expect(try sim.peek(slot: 509).blob == writePreset.blob)
    }

    // ---------------------------------------------------------- torn write

    @Test func tornWriteFailChunkAt() throws {
        let sim = SimulatedMicroFreak(replyLag: false, failChunkAt: 3)
        let session = makeSession(sim)
        let before = try sim.peek(slot: 5).blob
        #expect(throws: FreakError.chunkNotAcked(slot: 5, chunkIndex: 3)) {
            try session.writePreset(slot: 5, writePreset)
        }
        #expect(try sim.peek(slot: 5).blob == before, "no commit, slot untouched")
    }

    /// Cancelling mid-write tears the slot; done/total say how far it got.
    @Test func cancelledMidWrite() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(sim)
        let token = CancelToken()
        token.cancel()
        #expect(throws: FreakError.cancelled(done: 0, total: 146)) {
            try session.writePreset(slot: 100, writePreset, cancel: token)
        }
    }

    // --------------------------------------------------------------- rename

    /// writeName is a rename: one long 0x52 + one refresh read; zero blob
    /// traffic; the device ack is awaited (missing -> .deviceTimeout).
    @Test func renameIsLong52PlusRefreshOnly() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let session = makeSession(sim)
        let before = try sim.peek(slot: 42)
        let info = try session.writeName(slot: 42, name: "New Name", meta: before.meta)
        #expect(info.slot == 42 && info.name == "New Name")
        #expect(try sim.peek(slot: 42).name == "New Name")
        #expect(try sim.peek(slot: 42).blob == before.blob)
        let sent = sim.wireLog.filter { $0.direction == .out }
            .map { FreakProtocol.parse($0.raw)! }
        #expect(sent.allSatisfy { $0.cmd != FreakProtocol.cmdGo && !$0.isChunk },
                "rename must never send go/chunk frames")
        #expect(sent.filter { $0.cmd == FreakProtocol.cmdName && $0.data.count == 35 }.count == 1)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    @Test func renameWithoutAckTimesOut() {
        let session = makeSession(DeadTransport())
        #expect(throws: FreakError.deviceTimeout(stage: .nameWriteAck, slot: 8)) {
            try session.writeName(slot: 8, name: "X", meta: testMeta)
        }
    }
}
