// SessionTests.swift — the reply-lag defense proven over 512 rapid reads,
// timeout paths, persistent mismatch, seq discipline, malformed-reply
// discard, drain-before-transact, and the runaway-dump guard — all with
// TestClock, zero wall time.

import Foundation
import Testing
@testable import FreakCore

@Suite("FreakSession")
struct SessionTests {

    /// The reply-lag defense, proven across every slot (the Python proof
    /// ported): 512 rapid readNames against the lagged factoryFresh sim,
    /// every slot labeled correctly.
    @Test func replyLagDefenseAcrossAllSlots() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()      // 512 slots, lag ON
        #expect(sim.replyLag, "lag must be the default")
        let session = makeSession(sim)
        for slot in 0..<512 {
            let info = try await session.readName(slot: slot)
            let expected = try await sim.peek(slot: slot)
            #expect(info.slot == slot)
            #expect(info.name == expected.name, "slot \(slot)")
            #expect(info.meta == expected.meta, "slot \(slot)")
        }
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")
        // the lag was real: the sim held replies, so retries happened
        let outboundReads = await sim.wireLog().filter {
            $0.direction == .out && Wire.parse($0.raw)?.cmd == Wire.cmdOpen
        }.count
        #expect(outboundReads > 512, "retries prove the defense actually engaged")

        // blob read over the same lagged sim (dumps are unaffected by lag)
        let blob = try await session.readBlob(slot: 3)
        #expect(blob == (try await sim.peek(slot: 3)).blob)
        #expect(blob.count == Wire.blobSize)
        #expect(await sim.faults().isEmpty)
    }

    @Test func silenceTimesOut() async {
        let session = makeSession(DeadTransport())
        await #expect(throws: FreakError.deviceTimeout(stage: .nameRead, slot: 7)) {
            try await session.readName(slot: 7)
        }
        await #expect(throws: FreakError.deviceTimeout(stage: .dump, slot: 7)) {
            try await session.readBlob(slot: 7)
        }
    }

    @Test func persistentWrongSlotRepliesRaiseReplyMismatch() async {
        let wrong = WrongSlotTransport(wrongSlot: 500)
        let session = makeSession(wrong)
        await #expect(throws: FreakError.replyMismatch(requestedSlot: 5,
                                                       repliedSlot: 500,
                                                       attempts: 3)) {
            try await session.readName(slot: 5)
        }
        #expect(await wrong.sends == 3)
    }

    /// Seq discipline: 1..127, never 0 (seq 0 belongs to the go frame only).
    @Test func seqCounterSkipsZero() async throws {
        let sim = SimulatedMicroFreak(replyLag: false)
        let session = makeSession(sim)
        for i in 0..<300 {
            _ = try await session.readName(slot: i % sim.slots)
        }
        let seqs = await sim.wireLog().filter { $0.direction == .out }
            .map { Int(Wire.parse($0.raw)!.seq) }
        #expect(!seqs.contains(0), "seq 0 must appear only in the go frame")
        #expect(seqs.max() == 127 && seqs.min() == 1)
    }

    /// A 0x52 with an out-of-range embedded address is discarded like any
    /// other unrelated frame, not escaped as .slotOutOfRange.
    @Test func malformedAddressRepliesAreDiscarded() async throws {
        let session = makeSession(BadAddressThenGoodTransport(goodSlot: 7))
        let info = try await session.readName(slot: 7)
        #expect(info.slot == 7 && info.name == "Good")
    }

    /// Runaway dump: endless 0x16 chunks, never a 0x17 terminator.
    @Test func runawayDumpRaisesProtocolViolation() async {
        let session = makeSession(RunawayDumpTransport())
        let e = await expectFreakErrorAsync { try await session.readBlob(slot: 3) }
        guard case .protocolViolation(let detail) = e else {
            Issue.record("expected .protocolViolation, got \(String(describing: e))")
            return
        }
        #expect(detail.contains("0x17") && detail.contains("slot 3"))
    }

    /// Stale frames left over from a previous conversation are drained
    /// before a new addressed transaction sends anything.
    @Test func drainBeforeTransact() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        // seed a stale reply into the outbox by asking for another slot raw
        try await sim.send(Wire.readNameRequest(seq: 9, slot: 3))
        let session = makeSession(sim)
        let info = try await session.readName(slot: 8)
        #expect(info.slot == 8 && info.name == "Patch 008",
                "the stale slot-3 reply must be drained, not matched")
    }

    @Test func closeClosesTransport() async {
        actor ClosableTransport: FreakTransport {
            private(set) var closed = 0
            func send(_ message: Data) async throws {}
            func receive(timeout: TimeInterval) async throws -> Data? { nil }
            func close() async { closed += 1 }
        }
        let transport = ClosableTransport()
        let session = makeSession(transport)
        await session.close()
        #expect(await transport.closed == 1)
    }
}
