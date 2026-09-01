// SimulatedFidelityTests.swift — the five fidelity requirements of the
// SimulatedMicroFreak (§3.11 points 1-5), plus the factoryFresh shape and
// the back-door bounds (test_simulated_fidelity.py transliterated).

import Foundation
import Testing
@testable import FreakCore

@Suite("Simulated device fidelity")
struct SimulatedFidelityTests {

    // ---- 1. full 35-byte long-0x52 name reply payload --------------------

    @Test func point1NameReplyPayloadShape() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        try sim.send(FreakProtocol.readNameRequest(seq: 1, slot: 200))
        let replies = try recvAll(sim)
        #expect(replies.count == 1)
        let f = try #require(FreakProtocol.parse(replies[0]))
        #expect(f.cmd == FreakProtocol.cmdName && f.length == 0x23)
        #expect(f.seq == 1, "name reply echoes its request's seq (every capture)")
        let d = [UInt8](f.data)
        #expect(d.count == FreakProtocol.namePayloadLen)
        #expect(d[0] == 1 && d[1] == 72 && d[2] == 0x00)   // bank, pos, 0
        #expect(d[8] == 72)                                 // pos again
        #expect(d[9] == 0)                                  // slot < 384
        #expect(d[3] & FreakProtocol.replyMetaFlag != 0,
                "slots >= 128 carry the reply-only 0x10 flag")
        #expect(d[11] == 0x32 || d[11] == 0x33,
                "printable attribute byte — the header-leak trap is armed")
        var nameField = Array(d[12...])
        #expect(nameField.count == 23)
        if let nul = nameField.firstIndex(of: 0) {
            nameField = Array(nameField[..<nul])
        }
        #expect(nameField == Array("Patch 200".utf8))

        try sim.send(FreakProtocol.readNameRequest(seq: 2, slot: 400))
        let f400 = try #require(FreakProtocol.parse(try recvAll(sim)[0]))
        let d400 = [UInt8](f400.data)
        #expect(d400[9] == 1, "slot >= 384: the flag flips")
        #expect(d400[8] == UInt8(400 % 128))
    }

    // ---- 2. reply-lag: held one behind, resolved by the Session ----------

    @Test func point2ReplyLagHeldOneBehind() throws {
        let sim = SimulatedMicroFreak.factoryFresh()            // lag ON (default)
        try sim.send(FreakProtocol.readNameRequest(seq: 1, slot: 5))
        #expect(try recvAll(sim).isEmpty, "first name read must yield nothing")
        try sim.send(FreakProtocol.readNameRequest(seq: 2, slot: 6))
        let lagged = try recvAll(sim)
        #expect(lagged.count == 1)
        let lf = try #require(FreakProtocol.parse(lagged[0]))
        #expect(try FreakProtocol.decodeNameReply(lf).slot == 5,
                "reply is for the PREVIOUS request")
        #expect(lf.seq == 1, "the lagged reply carries ITS OWN request's seq")
    }

    @Test func point2SessionResolvesEverySlotUnderLag() throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let session = makeSession(sim)
        for slot in [0, 1, 127, 128, 383, 384, 511] {
            let info = try session.readName(slot: slot)
            #expect(info.slot == slot)
            #expect(info.name == (try sim.peek(slot: slot)).name, "slot \(slot)")
        }
    }

    /// The lagged reply is rendered at EMISSION time — slow, not wrong.
    @Test func point2HeldReplyRendersCurrentState() throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        try sim.send(FreakProtocol.readNameRequest(seq: 1, slot: 8))   // held
        // rename slot 8 while its reply is still held
        let meta = try sim.peek(slot: 8).meta
        try sim.send(try FreakProtocol.nameWriteFrame(seq: 2, slot: 8,
                                                      name: "Fresh", meta: meta))
        _ = try recvAll(sim)                                    // drop the write ack
        try sim.send(FreakProtocol.readNameRequest(seq: 3, slot: 9))   // releases
        let released = try recvAll(sim)
        #expect(released.count == 1)
        let info = try FreakProtocol.decodeNameReply(FreakProtocol.parse(released[0])!)
        #expect(info.slot == 8)
        #expect(info.name == "Fresh", "held reply rendered from state at emission time")
    }

    // ---- 3. dump: 145 x 0x16 + 1 x 0x17, 32 bytes each, pull-paced -------

    @Test func point3PullPacedDump() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        try sim.send(FreakProtocol.openDumpRequest(seq: 1, slot: 40))
        #expect(try recvAll(sim).isEmpty, "chunks are pull-paced by 0x18")
        var chunks: [Frame] = []
        for i in 0..<FreakProtocol.chunkCount {
            try sim.send(FreakProtocol.pullNextRequest(seq: UInt8((i + 1) % 128)))
            let got = try recvAll(sim)
            #expect(got.count == 1, "one chunk per pull (lockstep)")
            let f = FreakProtocol.parse(got[0])!
            #expect(Int(f.seq) == (i + 1) % 128, "chunk echoes its pull's seq")
            chunks.append(f)
        }
        #expect(chunks.allSatisfy { $0.data.count == 32 && $0.length == 0x20 })
        #expect(chunks.dropLast().allSatisfy { $0.cmd == FreakProtocol.cmdChunkMore })
        #expect(chunks.last?.cmd == FreakProtocol.cmdChunkLast)
        #expect(try FreakProtocol.assembleBlob(chunks) == (try sim.peek(slot: 40)).blob)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    // ---- 4. write semantics ----------------------------------------------

    /// 4a. The long 0x52 alone is a rename: name+meta change, blob does not,
    /// and the device acks it with a device-shape 0x18.
    @Test func point4aLong52AloneRenames() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let before = try sim.peek(slot: 8)
        try sim.send(try FreakProtocol.nameWriteFrame(seq: 5, slot: 8,
                                                      name: "Renamed",
                                                      meta: before.meta))
        let got = try recvAll(sim)
        #expect(got.count == 1, "the long 0x52 is acked with exactly one 0x18")
        let ack = FreakProtocol.parse(got[0])!
        #expect(ack.cmd == FreakProtocol.cmdNext && ack.length == 0x00 && ack.data.isEmpty)
        #expect(ack.seq == 5, "device acks echo the acked frame's seq")
        let after = try sim.peek(slot: 8)
        #expect(after.name == "Renamed" && after.blob == before.blob)
        #expect(after.meta == before.meta)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    /// Inbound long-0x52 validation: reply-form header bytes are faults.
    @Test func point4InboundWriteValidation() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let meta = try sim.peek(slot: 200).meta
        // hand-build a REPLY-form payload instead of using the builder —
        // the sim must flag all three deviant header bytes
        let (bank, pos) = try FreakProtocol.addr(200)
        var payload = [bank, pos, 0x00] + [UInt8](meta) + Array("X".utf8)
            + [UInt8](repeating: 0, count: 22)
        payload[8] = 0x55                              // not pos
        payload[9] = 0x01                              // reply-form flag, not 0x06
        // payload[3] already carries 0x10: slot 200's reply-form meta[0]
        try sim.send(FreakProtocol.frame(seq: 1, length: 0x23,
                                         cmd: FreakProtocol.cmdName,
                                         data: Data(payload)))
        let faults = sim.faults
        #expect(faults.contains { $0.contains("payload[8]") })
        #expect(faults.contains { $0.contains("payload[9]") })
        #expect(faults.contains { $0.contains("0x10") })
    }

    /// 4b. Chunks without an open+armed write: fault, slot untouched, no ack.
    @Test func point4bOrphanChunks() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let before = try sim.peek(slot: 0).blob
        let donor = try sim.peek(slot: 3)
        try sim.send(try FreakProtocol.chunkFrames(blob: donor.blob)[0])
        #expect(try recvAll(sim).isEmpty, "no ack for an orphan chunk")
        #expect(try sim.peek(slot: 0).blob == before)
        #expect(try sim.peek(slot: 3).blob == donor.blob)
        #expect(sim.faults.contains { $0.contains("without an open") }, "\(sim.faults)")
    }

    /// 4c. Committed total != 4672: fault, slot untouched.
    @Test func point4cShortCommitRejected() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let donor = try sim.peek(slot: 3)
        let before = try sim.peek(slot: 9).blob
        try sim.send(try FreakProtocol.openWriteFrame(seq: 1, slot: 9))
        try sim.send(FreakProtocol.goFrame())
        let frames = try FreakProtocol.chunkFrames(blob: donor.blob)
        for fr in frames[..<10] {
            try sim.send(fr)
        }
        // forge an early "last" chunk: total 11 x 32 = 352 bytes, not 4672
        let piece = FreakProtocol.parse(frames[10])!.data
        try sim.send(FreakProtocol.frame(seq: 0, length: 0x20,
                                         cmd: FreakProtocol.cmdChunkLast, data: piece))
        #expect(try sim.peek(slot: 9).blob == before, "short commit must not land")
        #expect(sim.faults.contains { $0.contains("untouched") }, "\(sim.faults)")
    }

    /// 4d. A full, correct burst carries no checksum and still commits; the
    /// name frame, the open and the go are each acked too (149 total).
    @Test func point4dRawBurstAckAccounting() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let donor = try sim.peek(slot: 3)
        try sim.send(try FreakProtocol.nameWriteFrame(seq: 1, slot: 9,
                                                      name: donor.name,
                                                      meta: donor.meta))
        try sim.send(try FreakProtocol.openWriteFrame(seq: 2, slot: 9))
        try sim.send(FreakProtocol.goFrame())
        let controlAcks = try recvAll(sim).map { FreakProtocol.parse($0)! }
        #expect(controlAcks.map(\.cmd) == [UInt8](repeating: FreakProtocol.cmdNext, count: 3),
                "long 0x52, open and go are each acked with 0x18")
        #expect(controlAcks.allSatisfy { $0.length == 0x00 && $0.data.isEmpty })
        var acked = 0
        for fr in try FreakProtocol.chunkFrames(blob: donor.blob) {
            try sim.send(fr)
            acked += try recvAll(sim).filter { FreakProtocol.parse($0)!.isAck }.count
        }
        #expect(acked == 146, "every chunk acked with 0x18")
        #expect(try sim.peek(slot: 9).blob == donor.blob)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
    }

    // ---- 5. failChunkAt --------------------------------------------------

    @Test func point5FailChunkAtCumulative() throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false, failChunkAt: 3)
        let donor = try sim.peek(slot: 3)
        let before = try sim.peek(slot: 9).blob
        try sim.send(try FreakProtocol.openWriteFrame(seq: 1, slot: 9))
        try sim.send(FreakProtocol.goFrame())
        #expect(try recvAll(sim).count == 2)                  // open + go acks
        var ackPattern: [Int] = []
        for fr in try FreakProtocol.chunkFrames(blob: donor.blob)[..<6] {
            try sim.send(fr)
            ackPattern.append(try recvAll(sim).count)
        }
        #expect(ackPattern == [1, 1, 1, 0, 0, 0])
        #expect(try sim.peek(slot: 9).blob == before)
    }

    // ---- factory shape and back doors ------------------------------------

    @Test func factoryFreshShape() throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        // 512 - 269 = 243 named slots, then the Init block
        #expect(try sim.peek(slot: 0).name == "Patch 000")
        #expect(try sim.peek(slot: 242).name == "Patch 242")
        #expect(try sim.peek(slot: 243).name == "Init")
        #expect(try sim.peek(slot: 511).name == "Init")
        // 269 identical Init blobs; the named slots are all distinct
        let initSha = try sim.peek(slot: 243).sha256
        for s in [300, 400, 511] {
            #expect(try sim.peek(slot: s).sha256 == initSha)
        }
        #expect(try sim.peek(slot: 0).sha256 != initSha)
        #expect(try sim.peek(slot: 0).sha256 != (try sim.peek(slot: 1)).sha256)
        // meta positional correctness at the boundaries
        let m127 = [UInt8](try sim.peek(slot: 127).meta)
        let m128 = [UInt8](try sim.peek(slot: 128).meta)
        #expect(m127[0] & 0x10 == 0 && m128[0] & 0x10 != 0,
                "0x10 flag flips at slot 128")
        let m383 = [UInt8](try sim.peek(slot: 383).meta)
        let m384 = [UInt8](try sim.peek(slot: 384).meta)
        #expect(m383[6] == 0 && m384[6] == 1, "payload[9]-equivalent flips at 384")
        #expect(m383[5] == 127 && m384[5] == 0, "meta[5] is pos")
        // attribute bytes printable, alternating on named slots
        #expect([UInt8](try sim.peek(slot: 0).meta)[8] == 0x32)
        #expect([UInt8](try sim.peek(slot: 1).meta)[8] == 0x33)
        // deterministic: two factory sims are identical
        let sim2 = SimulatedMicroFreak.factoryFresh()
        for s in [0, 1, 242, 243, 511] {
            #expect(try sim.peek(slot: s) == (try sim2.peek(slot: s)))
        }
        // a different seed changes blob content, not the shape
        let seeded = SimulatedMicroFreak.factoryFresh(seed: 7)
        #expect(try seeded.peek(slot: 0).name == "Patch 000")
        #expect(try seeded.peek(slot: 0).blob != (try sim.peek(slot: 0)).blob)
    }

    @Test func backDoorsThrowSlotOutOfRange() throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try sim.peek(slot: 512)
        }
        #expect(throws: FreakError.slotOutOfRange(slot: -1)) {
            try sim.load(slot: -1, preset: try Preset(name: "X", blob: blob7(1),
                                                      meta: testMeta))
        }
    }
}
