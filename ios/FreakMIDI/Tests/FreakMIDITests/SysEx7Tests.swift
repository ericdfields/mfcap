// SysEx7Tests.swift — pure UMP SysEx7 codec + reassembly tears.
// No CoreMIDI objects, no hardware; runs anywhere swift test runs.

import Foundation
import FreakCore
import Testing
@testable import FreakMIDI

// ------------------------------------------------------------ helpers

/// Feed a flat word stream through a fresh assembler pair-wise.
private func reassemble(_ words: [UInt32]) -> [Data] {
    var assembler = SysEx7Assembler()
    return assembler.consume(words: words)
}

/// Encode-then-reassemble round trip.
private func roundTrip(_ message: Data) -> [Data] {
    reassemble(SysEx7.encode(message))
}

@Suite("SysEx7 encode")
struct SysEx7EncodeTests {

    @Test func pullNextRequestExactWords() {
        // F0 00 20 6B 07 01 05 01 18 00 F7 — 9 interior bytes:
        // start [00 20 6B 07 01 05] + end [01 18 00]
        let frame = FreakProtocol.pullNextRequest(seq: 5)
        #expect(frame.count == 11)
        let words = SysEx7.encode(frame)
        #expect(words == [0x3016_0020, 0x6B07_0105,
                          0x3033_0118, 0x0000_0000])
    }

    @Test func completePacketForShortMessage() {
        // 2 interior bytes -> one complete packet, byteCount 2
        let words = SysEx7.encode(Data([0xF0, 0x01, 0x02, 0xF7]))
        #expect(words == [0x3002_0102, 0x0000_0000])
    }

    @Test func emptyBodyEncodesAsCompleteZeroCount() {
        let words = SysEx7.encode(Data([0xF0, 0xF7]))
        #expect(words == [0x3000_0000, 0x0000_0000])
    }

    @Test func sixInteriorBytesStillOneCompletePacket() {
        let words = SysEx7.encode(Data([0xF0, 1, 2, 3, 4, 5, 6, 0xF7]))
        #expect(words.count == 2)
        #expect((words[0] >> 20) & 0xF == SysEx7.Status.complete.rawValue)
        #expect((words[0] >> 16) & 0xF == 6)
    }

    @Test func sevenInteriorBytesSplitStartEnd() {
        let words = SysEx7.encode(Data([0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7]))
        #expect(words.count == 4)
        #expect((words[0] >> 20) & 0xF == SysEx7.Status.start.rawValue)
        #expect((words[0] >> 16) & 0xF == 6)
        #expect((words[2] >> 20) & 0xF == SysEx7.Status.end.rawValue)
        #expect((words[2] >> 16) & 0xF == 1)
    }

    @Test func twelveInteriorBytesEndPacketCarriesSix() {
        let words = SysEx7.encode(Data([0xF0] + (1...12).map { UInt8($0) } + [0xF7]))
        #expect(words.count == 4)
        #expect((words[2] >> 20) & 0xF == SysEx7.Status.end.rawValue)
        #expect((words[2] >> 16) & 0xF == 6)
    }

    @Test func largestFrameIs45BytesAnd8Packets() throws {
        // The long 0x52 name-write frame — the biggest thing on the wire.
        let frame = try FreakProtocol.nameWriteFrame(
            seq: 2, slot: 200, name: "Akiko San",
            meta: Data([0x08, 0, 0, 0, 0, 72, 1, 3, 0x33]))
        #expect(frame.count == 45)
        let words = SysEx7.encode(frame)
        #expect(words.count == 16)      // 43 interior bytes -> 8 packets
        let statuses = stride(from: 0, to: words.count, by: 2)
            .map { (words[$0] >> 20) & 0xF }
        #expect(statuses.first == SysEx7.Status.start.rawValue)
        #expect(statuses.last == SysEx7.Status.end.rawValue)
        #expect(statuses.dropFirst().dropLast()
            .allSatisfy { $0 == SysEx7.Status.continue.rawValue })
        #expect((words[14] >> 16) & 0xF == 1)   // 43 = 7*6 + 1
    }

    @Test func messageTypeNibbleAndGroupZeroOnEveryWord0() throws {
        let words = SysEx7.encode(try FreakProtocol.readNameRequest(seq: 1, slot: 384))
        for i in stride(from: 0, to: words.count, by: 2) {
            #expect(words[i] >> 28 == 0x3)
            #expect((words[i] >> 24) & 0xF == 0)      // group 0
        }
    }
}

@Suite("SysEx7 reassembly")
struct SysEx7AssemblerTests {

    @Test func roundTripsEveryProtocolFrameShape() throws {
        var frames: [Data] = [
            FreakProtocol.goFrame(),
            FreakProtocol.pullNextRequest(seq: 7),
            try FreakProtocol.readNameRequest(seq: 1, slot: 0),
            try FreakProtocol.openDumpRequest(seq: 2, slot: 511),
            try FreakProtocol.openWriteFrame(seq: 3, slot: 384),
            try FreakProtocol.nameWriteFrame(
                seq: 4, slot: 511, name: "Init",
                meta: Data([8, 0, 0, 0, 0, 127, 1, 0, 0x33])),
        ]
        frames += try FreakProtocol.chunkFrames(
            blob: Data((0..<FreakProtocol.blobSize).map { UInt8($0 % 0x80) })).prefix(3)
        for frame in frames {
            let out = roundTrip(frame)
            #expect(out == [frame], "round trip failed for \(frame.count)-byte frame")
        }
    }

    @Test func roundTripsInteriorLengths0Through13() {
        for n in 0...13 {
            let message = Data([0xF0] + (0..<n).map { UInt8($0 + 1) } + [0xF7])
            #expect(roundTrip(message) == [message], "length \(n)")
        }
    }

    @Test func multipleMessagesInOneWordStreamArriveInOrder() {
        let a = Data([0xF0, 0x11, 0x22, 0xF7])
        let b = FreakProtocol.pullNextRequest(seq: 9)
        let out = reassemble(SysEx7.encode(a) + SysEx7.encode(b))
        #expect(out == [a, b])
    }

    @Test func splitAcrossConsumeCallsAssembles() {
        // start in one handler call, end in the next (packet boundary)
        let message = FreakProtocol.pullNextRequest(seq: 3)
        let words = SysEx7.encode(message)
        var assembler = SysEx7Assembler()
        #expect(assembler.consume(words: Array(words[0..<2])) == [])
        #expect(assembler.consume(words: Array(words[2...])) == [message])
    }

    // ------------------------------------------------------------ tear rules

    @Test func startWhilePartialPendingDropsTornPartial() {
        let torn = SysEx7.encode(Data([0xF0] + (1...9).map { UInt8($0) } + [0xF7]))
        let fresh = Data([0xF0] + (20...30).map { UInt8($0) } + [0xF7])
        var assembler = SysEx7Assembler()
        _ = assembler.consume(words: Array(torn[0..<2]))     // start only, no end
        let out = assembler.consume(words: SysEx7.encode(fresh))
        #expect(out == [fresh])                              // torn partial gone
    }

    @Test func completeWhilePartialPendingDropsTornPartial() {
        let torn = SysEx7.encode(Data([0xF0] + (1...9).map { UInt8($0) } + [0xF7]))
        let small = Data([0xF0, 0x55, 0xF7])
        var assembler = SysEx7Assembler()
        _ = assembler.consume(words: Array(torn[0..<2]))
        #expect(assembler.consume(words: SysEx7.encode(small)) == [small])
        // and the stale end of the torn message finds no partial: dropped
        #expect(assembler.consume(words: Array(torn[2...])) == [])
    }

    @Test func continueWithNoPendingPartialIsDropped() {
        let w0: UInt32 = (0x3 << 28) | (SysEx7.Status.continue.rawValue << 20) | (2 << 16) | 0x0102
        var assembler = SysEx7Assembler()
        #expect(assembler.consume(word0: w0, word1: 0) == nil)
        // assembler still healthy afterwards
        let message = Data([0xF0, 0x01, 0xF7])
        #expect(assembler.consume(words: SysEx7.encode(message)) == [message])
    }

    @Test func endWithNoPendingPartialIsDropped() {
        let w0: UInt32 = (0x3 << 28) | (SysEx7.Status.end.rawValue << 20) | (1 << 16) | (0x42 << 8)
        var assembler = SysEx7Assembler()
        #expect(assembler.consume(word0: w0, word1: 0) == nil)
    }

    @Test func nonType3MessagesAreIgnoredWithoutTearing() {
        let message = FreakProtocol.pullNextRequest(seq: 4)
        let words = SysEx7.encode(message)
        var assembler = SysEx7Assembler()
        // interleave: start pair, then a 1-word MIDI 1.0 note-on (type 2),
        // then a 4-word type-5 message, then the end pair
        var stream = Array(words[0..<2])
        stream.append(0x2090_3C40)                            // type 2: 1 word
        stream += [0x5000_0000, 0, 0, 0]                      // type 5: 4 words
        stream += Array(words[2...])
        #expect(assembler.consume(words: stream) == [message])
    }

    @Test func reservedStatusAndOversizedCountAreIgnored() {
        var assembler = SysEx7Assembler()
        let reserved: UInt32 = (0x3 << 28) | (0x9 << 20) | (2 << 16)      // status 0x9
        let oversized: UInt32 = (0x3 << 28) | (SysEx7.Status.complete.rawValue << 20) | (0x9 << 16)
        #expect(assembler.consume(word0: reserved, word1: 0) == nil)
        #expect(assembler.consume(word0: oversized, word1: 0) == nil)
        // neither disturbed the (empty) partial state
        let message = Data([0xF0, 0x7F, 0xF7])
        #expect(assembler.consume(words: SysEx7.encode(message)) == [message])
    }

    @Test func truncatedTrailingMessageIsDropped() {
        let message = Data([0xF0, 0x01, 0x02, 0xF7])
        var stream = SysEx7.encode(message)
        stream.append((0x3 << 28) | (SysEx7.Status.complete.rawValue << 20) | (1 << 16))
        // second word of the trailing SysEx7 message is missing
        var assembler = SysEx7Assembler()
        #expect(assembler.consume(words: stream) == [message])
    }

    @Test func wordCountTableCoversAllMessageTypes() {
        let expected: [UInt32: Int] = [
            0x0: 1, 0x1: 1, 0x2: 1, 0x3: 2, 0x4: 2, 0x5: 4, 0x6: 1, 0x7: 1,
            0x8: 2, 0x9: 2, 0xA: 2, 0xB: 3, 0xC: 3, 0xD: 4, 0xE: 4, 0xF: 4,
        ]
        for (type, count) in expected {
            #expect(SysEx7.wordCount(firstWord: type << 28) == count, "type \(type)")
        }
    }
}
