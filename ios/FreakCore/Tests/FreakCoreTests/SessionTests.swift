// SessionTests.swift — the reply-lag defense proven over 512 rapid reads,
// timeout paths, persistent mismatch, seq discipline, malformed-reply
// discard, and the runaway-dump guard (test_session.py transliterated).

import Foundation
import Testing
@testable import FreakCore

@Suite("FreakSession")
struct SessionTests {

    /// The reply-lag defense, proven across every slot (the Python proof
    /// ported): 512 rapid readNames against the lagged factoryFresh sim,
    /// every slot labeled correctly.
    @Test func replyLagDefenseAcrossAllSlots() throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // 512 slots, lag ON
        #expect(sim.replyLag, "lag must be the default")
        let session = makeSession(sim)
        for slot in 0..<512 {
            let info = try session.readName(slot: slot)
            let expected = try sim.peek(slot: slot)
            #expect(info.slot == slot)
            #expect(info.name == expected.name, "slot \(slot)")
            #expect(info.meta == expected.meta, "slot \(slot)")
        }
        #expect(sim.faults.isEmpty, "\(sim.faults)")
        // the lag was real: the sim held replies, so retries happened
        let outboundReads = sim.wireLog.filter {
            $0.direction == .out
                && FreakProtocol.parse($0.raw)?.cmd == FreakProtocol.cmdOpen
        }.count
        #expect(outboundReads > 512, "retries prove the defense actually engaged")

        // blob read over the same lagged sim (dumps are unaffected by lag)
        let blob = try session.readBlob(slot: 3)
        #expect(blob == (try sim.peek(slot: 3)).blob)
        #expect(blob.count == FreakProtocol.blobSize)
        #expect(sim.faults.isEmpty)
    }

    @Test func silenceTimesOut() {
        let session = makeSession(DeadTransport())
        #expect(throws: FreakError.deviceTimeout(stage: .nameRead, slot: 7)) {
            try session.readName(slot: 7)
        }
        #expect(throws: FreakError.deviceTimeout(stage: .dump, slot: 7)) {
            try session.readBlob(slot: 7)
        }
    }

    @Test func persistentWrongSlotRepliesRaiseReplyMismatch() {
        let wrong = WrongSlotTransport(wrongSlot: 500)
        let session = makeSession(wrong)
        #expect(throws: FreakError.replyMismatch(requestedSlot: 5,
                                                 repliedSlot: 500,
                                                 attempts: 3)) {
            try session.readName(slot: 5)
        }
        #expect(wrong.sends == 3)
    }

    /// Seq discipline: 1..127, never 0 (seq 0 belongs to the go frame only).
    @Test func seqCounterSkipsZero() throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        for i in 0..<300 {
            _ = try session.readName(slot: i % sim.slots)
        }
        let seqs = sim.wireLog.filter { $0.direction == .out }
            .map { Int(FreakProtocol.parse($0.raw)!.seq) }
        #expect(!seqs.contains(0), "seq 0 must appear only in the go frame")
        #expect(seqs.max() == 127 && seqs.min() == 1)
    }

    /// A 0x52 with an out-of-range embedded address is discarded like any
    /// other unrelated frame, not escaped as .slotOutOfRange.
    @Test func malformedAddressRepliesAreDiscarded() throws {
        let session = makeSession(BadAddressThenGoodTransport(goodSlot: 7))
        let info = try session.readName(slot: 7)
        #expect(info.slot == 7 && info.name == "Good")
    }

    /// Runaway dump: endless 0x16 chunks, never a 0x17 terminator.
    @Test func runawayDumpRaisesProtocolViolation() {
        let session = makeSession(RunawayDumpTransport())
        let e = expectFreakError { try session.readBlob(slot: 3) }
        guard case .protocolViolation(let detail) = e else {
            Issue.record("expected .protocolViolation, got \(String(describing: e))")
            return
        }
        #expect(detail.contains("0x17") && detail.contains("slot 3"))
    }

    @Test func closeClosesTransport() {
        final class ClosableTransport: Transport, @unchecked Sendable {
            // @unchecked Sendable: Transport impl (§4-sanctioned), NSLock-guarded
            private let lock = NSLock()
            private var closedCount = 0
            var closed: Int {
                lock.lock()
                defer { lock.unlock() }
                return closedCount
            }
            func send(_ message: Data) throws {}
            func receive(timeout: TimeInterval) throws -> Data? { nil }
            func close() {
                lock.lock()
                closedCount += 1
                lock.unlock()
            }
        }
        let transport = ClosableTransport()
        let session = makeSession(transport)
        session.close()
        #expect(transport.closed == 1)
    }
}
