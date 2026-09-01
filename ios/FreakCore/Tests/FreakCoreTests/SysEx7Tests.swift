// SysEx7Tests.swift — the pure UMP SysEx7 layer, exhaustively:
// fragmentation at every payload size boundary, the assembler state table
// (orphans, interleaved start, runaway guard), and round-trips of every
// Wire builder's output. No CoreMIDI anywhere.

import Foundation
import Testing
@testable import FreakCore

private func status(_ word0: UInt32) -> UInt32 { (word0 >> 20) & 0xF }
private func byteCount(_ word0: UInt32) -> Int { Int((word0 >> 16) & 0xF) }

@Suite("SysEx7")
struct SysEx7Tests {

    // ------------------------------------------------------------- encode

    @Test func encodeRejectsUnframedOrDirtyInput() {
        #expect(throws: FreakError.self) { try SysEx7.encode(Data()) }
        #expect(throws: FreakError.self) { try SysEx7.encode(Data([0x01, 0x02])) }
        #expect(throws: FreakError.self) { try SysEx7.encode(Data([0xF0, 0x01])) }
        #expect(throws: FreakError.self) { try SysEx7.encode(Data([0x01, 0xF7])) }
        #expect(throws: FreakError.self) {
            try SysEx7.encode(Data([0xF0, 0x80, 0xF7]))   // 8-bit payload byte
        }
    }

    @Test func encodeSingleGroupIsComplete() throws {
        for n in 0...6 {
            let payload = (0..<n).map { UInt8($0 + 1) }
            let words = try SysEx7.encode(Data([0xF0] + payload + [0xF7]))
            #expect(words.count == 2, "payload \(n): one packet")
            #expect(status(words[0]) == 0x0, "payload \(n): complete")
            #expect(byteCount(words[0]) == n)
        }
    }

    @Test func encodeFragmentsAtEveryBoundary() throws {
        for n in 7...20 {
            let payload = (0..<n).map { UInt8($0 % 0x60 + 1) }
            let words = try SysEx7.encode(Data([0xF0] + payload + [0xF7]))
            let packetCount = words.count / 2
            #expect(packetCount == (n + 5) / 6, "payload \(n)")
            #expect(status(words[0]) == 0x1, "payload \(n): starts with start")
            for p in 1..<(packetCount - 1) {
                #expect(status(words[p * 2]) == 0x2, "payload \(n) packet \(p): continue")
                #expect(byteCount(words[p * 2]) == 6)
            }
            #expect(status(words[(packetCount - 1) * 2]) == 0x3, "payload \(n): ends with end")
            let counts = (0..<packetCount).map { byteCount(words[$0 * 2]) }
            #expect(counts.reduce(0, +) == n, "payload \(n): every byte carried")
        }
    }

    // -------------------------------------------------------- reassembly

    @Test func roundTripsEveryWireBuilderOutput() throws {
        var messages: [Data] = [
            try Wire.readNameRequest(seq: 1, slot: 0),
            try Wire.openDumpRequest(seq: 2, slot: 511),
            Wire.pullNextRequest(seq: 3),
            try Wire.nameWriteFrame(seq: 4, slot: 509, name: "Akiko San", meta: testMeta),
            try Wire.openWriteFrame(seq: 5, slot: 384),
            Wire.goFrame(),
        ]
        messages += try Wire.chunkFrames(blob: blob7(3)).prefix(3)
        var assembler = SysEx7.Assembler()
        for message in messages {
            let words = try SysEx7.encode(message)
            var got: [Data] = []
            for i in stride(from: 0, to: words.count, by: 2) {
                if let m = assembler.consume(word0: words[i], word1: words[i + 1]) {
                    got.append(m)
                }
            }
            #expect(got == [message], "round trip failed for \(spacedHex(message))")
        }
    }

    @Test func orphanContinueAndEndAreDropped() throws {
        var assembler = SysEx7.Assembler()
        let cont = SysEx7.pack(status: 0x2, bytes: [1, 2, 3])
        #expect(assembler.consume(word0: cont[0], word1: cont[1]) == nil)
        let end = SysEx7.pack(status: 0x3, bytes: [4, 5])
        #expect(assembler.consume(word0: end[0], word1: end[1]) == nil)
        // still functional afterwards
        let complete = SysEx7.pack(status: 0x0, bytes: [9])
        #expect(assembler.consume(word0: complete[0], word1: complete[1])
                == Data([0xF0, 9, 0xF7]))
    }

    @Test func interleavedStartDiscardsOldBuffer() throws {
        var assembler = SysEx7.Assembler()
        let start1 = SysEx7.pack(status: 0x1, bytes: [1, 2, 3, 4, 5, 6])
        #expect(assembler.consume(word0: start1[0], word1: start1[1]) == nil)
        let start2 = SysEx7.pack(status: 0x1, bytes: [7, 8])
        #expect(assembler.consume(word0: start2[0], word1: start2[1]) == nil)
        let end = SysEx7.pack(status: 0x3, bytes: [9])
        #expect(assembler.consume(word0: end[0], word1: end[1])
                == Data([0xF0, 7, 8, 9, 0xF7]),
                "the second start replaces the first buffer")
    }

    @Test func completeDuringAssemblyDiscardsPartial() throws {
        var assembler = SysEx7.Assembler()
        let start = SysEx7.pack(status: 0x1, bytes: [1, 2, 3])
        _ = assembler.consume(word0: start[0], word1: start[1])
        let complete = SysEx7.pack(status: 0x0, bytes: [7])
        #expect(assembler.consume(word0: complete[0], word1: complete[1])
                == Data([0xF0, 7, 0xF7]))
        // the discarded partial does not leak into the next message
        let end = SysEx7.pack(status: 0x3, bytes: [9])
        #expect(assembler.consume(word0: end[0], word1: end[1]) == nil,
                "orphan end after a complete: dropped")
    }

    @Test func nonSysEx7PacketsAreIgnoredMidAssembly() throws {
        var assembler = SysEx7.Assembler()
        let start = SysEx7.pack(status: 0x1, bytes: [1, 2])
        _ = assembler.consume(word0: start[0], word1: start[1])
        // a channel-voice UMP (mt 0x2) mid-assembly is ignored
        #expect(assembler.consume(word0: 0x2090_3C40, word1: 0) == nil)
        let end = SysEx7.pack(status: 0x3, bytes: [3])
        #expect(assembler.consume(word0: end[0], word1: end[1])
                == Data([0xF0, 1, 2, 3, 0xF7]),
                "assembly survives interleaved non-SysEx7 traffic")
    }

    @Test func outOfRangeByteCountDropsPacket() throws {
        var assembler = SysEx7.Assembler()
        // byte-count nibble 7 is invalid
        let bogus: UInt32 = (0x3 << 28) | (0x0 << 20) | (7 << 16)
        #expect(assembler.consume(word0: bogus, word1: 0) == nil)
    }

    @Test func runawayGuardDropsBuffer() throws {
        var assembler = SysEx7.Assembler()
        let start = SysEx7.pack(status: 0x1, bytes: [1, 2, 3, 4, 5, 6])
        _ = assembler.consume(word0: start[0], word1: start[1])
        let cont = SysEx7.pack(status: 0x2, bytes: [1, 2, 3, 4, 5, 6])
        for _ in 0..<(SysEx7.maxAssembly / 6 + 2) {
            _ = assembler.consume(word0: cont[0], word1: cont[1])
        }
        let end = SysEx7.pack(status: 0x3, bytes: [9])
        #expect(assembler.consume(word0: end[0], word1: end[1]) == nil,
                "runaway assembly must have been dropped")
        // and the assembler is reusable
        let complete = SysEx7.pack(status: 0x0, bytes: [5])
        #expect(assembler.consume(word0: complete[0], word1: complete[1])
                == Data([0xF0, 5, 0xF7]))
    }

    @Test func emptyPayloadRoundTrip() throws {
        let words = try SysEx7.encode(Data([0xF0, 0xF7]))
        #expect(words.count == 2 && status(words[0]) == 0x0 && byteCount(words[0]) == 0)
        var assembler = SysEx7.Assembler()
        #expect(assembler.consume(word0: words[0], word1: words[1])
                == Data([0xF0, 0xF7]))
    }
}
