// WireTests.swift — pure codec unit tests beyond the golden vectors:
// bounds, masking, parse rejection of foreign traffic, name decode /
// validation edges, Preset validation order.

import Foundation
import Testing
@testable import FreakCore

@Suite("Wire codec")
struct WireTests {

    // ---------------------------------------------------------- addressing

    @Test func addressing() throws {
        let a0 = try Wire.addr(0)
        #expect(a0.bank == 0 && a0.pos == 0)
        let a511 = try Wire.addr(511)
        #expect(a511.bank == 3 && a511.pos == 127)
        let a384 = try Wire.addr(384)
        #expect(a384.bank == 3 && a384.pos == 0)
        #expect(throws: FreakError.slotOutOfRange(slot: -1)) {
            try Wire.addr(-1)
        }
        #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try Wire.addr(512)
        }
        for slot in [0, 127, 128, 383, 384, 511] {
            let (bank, pos) = try Wire.addr(slot)
            #expect(try Wire.slot(bank: bank, pos: pos) == slot)
        }
        #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try Wire.slot(bank: 4, pos: 0)
        }
        #expect(throws: FreakError.self) {
            try Wire.slot(bank: 0, pos: 128)
        }
        let e = expectFreakError { try Wire.slot(bank: 5, pos: 0) }
        #expect(e?.group == .protocolError)
    }

    // -------------------------------------------------------------- frames

    @Test func frameMasksTo7Bits() {
        let raw = Wire.frame(seq: 0x85, length: 0x83, cmd: 0x99,
                             data: [0x80, 0xFF, 0x7F] as [UInt8])
        let b = [UInt8](raw)
        #expect(b[6] == 0x05 && b[7] == 0x03 && b[8] == 0x19)
        #expect(Array(b[9..<12]) == [0x00, 0x7F, 0x7F])
        #expect(b.first == 0xF0 && b.last == 0xF7)
    }

    @Test func parseRejectsNonMicroFreakTraffic() {
        // too short
        #expect(Wire.parse(Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01, 0x00, 0xF7])) == nil)
        // not SysEx at all
        #expect(Wire.parse(Data([0x90, 0x3C, 0x40])) == nil)
        // missing F7 terminator
        var raw = [UInt8](Wire.goFrame())
        raw[raw.count - 1] = 0x00
        #expect(Wire.parse(Data(raw)) == nil)
        // wrong manufacturer (Roland, not Arturia)
        #expect(Wire.parse(Data([0xF0, 0x41, 0x10, 0x42, 0x12, 0x40,
                                 0x00, 0x7F, 0x00, 0x41, 0xF7])) == nil)
        // right length, wrong device-id byte in the 6-byte prefix
        #expect(Wire.parse(Data([0xF0, 0x00, 0x20, 0x6B, 0x06, 0x01,
                                 0x01, 0x03, 0x19, 0x00, 0x00, 0x00, 0xF7])) == nil)
        // prefix trailing byte must be 0x01 (full 6-byte match)
        #expect(Wire.parse(Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x02,
                                 0x01, 0x03, 0x19, 0x00, 0x00, 0x00, 0xF7])) == nil)
    }

    @Test func parseFields() throws {
        let raw = try Wire.readNameRequest(seq: 9, slot: 200)
        let f = try #require(Wire.parse(raw))
        #expect(f.seq == 9 && f.length == 3 && f.cmd == Wire.cmdOpen)
        #expect(f.data == Data([1, 72, 0]))
        #expect(f.raw == raw)
        #expect(!Wire.isChunk(f) && !Wire.isLastChunk(f) && !Wire.isAck(f))
    }

    @Test func frameKindPredicates() {
        let more = Wire.frame(seq: 1, length: 0x20, cmd: Wire.cmdChunkMore,
                              data: Data(count: 32))
        let last = Wire.frame(seq: 2, length: 0x20, cmd: Wire.cmdChunkLast,
                              data: Data(count: 32))
        let ack = Wire.frame(seq: 3, length: 0, cmd: Wire.cmdNext, data: Data())
        let m = Wire.parse(more)!
        let l = Wire.parse(last)!
        let a = Wire.parse(ack)!
        #expect(Wire.isChunk(m) && !Wire.isLastChunk(m) && !Wire.isAck(m))
        #expect(Wire.isChunk(l) && Wire.isLastChunk(l) && !Wire.isAck(l))
        #expect(!Wire.isChunk(a) && Wire.isAck(a))
    }

    // ------------------------------------------------------ decodeNameReply

    @Test func decodeNameReplyErrors() throws {
        // wrong cmd
        let ack = Wire.parse(Wire.frame(seq: 0, length: 0, cmd: Wire.cmdNext,
                                        data: Data()))!
        let e1 = expectFreakError { try Wire.decodeNameReply(ack) }
        #expect(e1?.group == .protocolError)
        // wrong payload length (short 0x52 open-write form)
        let short = Wire.parse(try Wire.openWriteFrame(seq: 1, slot: 3))!
        let e2 = expectFreakError { try Wire.decodeNameReply(short) }
        #expect(e2?.group == .protocolError)
        // out-of-range embedded address (bank 5 = slot 640) throws, and the
        // error is protocol-group so the session discards it as malformed
        let bogus = Wire.parse(Wire.frame(seq: 0, length: 0x23, cmd: Wire.cmdName,
                                          data: Data([5, 0, 0]) + Data(count: 32)))!
        let e3 = expectFreakError { try Wire.decodeNameReply(bogus) }
        #expect(e3 == .slotOutOfRange(slot: 640))
        #expect(e3?.group == .protocolError)
    }

    @Test func nameDecodeSplitsFiltersStrips() throws {
        // junk after the first NUL is ignored; unprintables filtered;
        // surrounding spaces stripped
        var field = [UInt8]()
        field += Array(" A\u{07}B ".utf8)          // 0x07 BEL is filtered out
        field += [0x00]
        field += Array("ZZZZ".utf8)                // after NUL: ignored
        field += [UInt8](repeating: 0x41, count: Wire.nameLength - field.count)
        let payload = Data([0, 7, 0]) + Data(count: 9) + Data(field)
        let f = Wire.parse(Wire.frame(seq: 0, length: 0x23, cmd: Wire.cmdName,
                                      data: payload))!
        let info = try Wire.decodeNameReply(f)
        #expect(info.slot == 7)
        #expect(info.name == "AB")
        #expect(info.meta == Data(count: 9))
    }

    // -------------------------------------------------------- validateName

    @Test func validateNameRules() {
        #expect(throws: Never.self) { try Wire.validateName("") }
        #expect(throws: Never.self) { try Wire.validateName("Akiko San") }
        #expect(throws: Never.self) {
            try Wire.validateName("ABCDEFGHIJKLMNOPQRSTUVW")  // 23 chars
        }
        let tooLong = expectFreakError { try Wire.validateName("ABCDEFGHIJKLMNOPQRSTUVWX") }
        guard case .invalidName = tooLong else {
            Issue.record("24 chars must be .invalidName, got \(String(describing: tooLong))")
            return
        }
        for bad in [" Foo", "Foo ", "Fo\to", "Café"] {
            let e = expectFreakError("name \(bad)") { try Wire.validateName(bad) }
            guard case .invalidName = e else {
                Issue.record("\(bad) must be .invalidName, got \(String(describing: e))")
                continue
            }
        }
    }

    // ------------------------------------------------------ nameWriteFrame

    @Test func nameWriteFrameErrors() throws {
        let goodMeta = Data([0x08, 0, 0, 0, 0, 0, 0, 0, 0x33])
        // bad name
        let e1 = expectFreakError {
            try Wire.nameWriteFrame(seq: 1, slot: 0, name: " x", meta: goodMeta)
        }
        guard case .invalidName = e1 else {
            Issue.record("expected .invalidName, got \(String(describing: e1))")
            return
        }
        // 8-byte meta
        let e2 = expectFreakError {
            try Wire.nameWriteFrame(seq: 1, slot: 0, name: "X", meta: Data(count: 8))
        }
        #expect(e2 == .protocolViolation(detail: "meta must be 9 bytes, got 8"))
        // meta byte over 0x7F
        let e3 = expectFreakError {
            try Wire.nameWriteFrame(seq: 1, slot: 0, name: "X",
                                    meta: Data([0x80, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
        #expect(e3 == .protocolViolation(detail: "meta contains non-7-bit bytes"))
        // slot out of range
        #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try Wire.nameWriteFrame(seq: 1, slot: 512, name: "X", meta: goodMeta)
        }
    }

    // --------------------------------------------------------- chunkFrames

    @Test func chunkFramesStream() throws {
        let blob = blob7(1)
        let frames = try Wire.chunkFrames(blob: blob)
        #expect(frames.count == Wire.chunkCount)
        var assembled = Data()
        for (i, raw) in frames.enumerated() {
            let f = Wire.parse(raw)!
            #expect(Int(f.seq) == (i + 1) % 128)
            #expect(f.length == 0x20 && f.data.count == 32)
            #expect(f.cmd == (i == Wire.chunkCount - 1
                ? Wire.cmdChunkLast : Wire.cmdChunkMore))
            assembled.append(f.data)
        }
        #expect(assembled == blob)
        // the stream wraps THROUGH zero: chunk 126 carries seq 127, chunk 127 seq 0
        #expect(Wire.parse(frames[126])!.seq == 127)
        #expect(Wire.parse(frames[127])!.seq == 0)
        #expect(Wire.parse(frames[128])!.seq == 1)
    }

    @Test func chunkFramesErrors() {
        #expect(throws: FreakError.blobSize(expected: 4672, actual: 4671)) {
            try Wire.chunkFrames(blob: Data(count: 4671))
        }
        var dirty = [UInt8](Data(count: Wire.blobSize))
        dirty[100] = 0x80
        let e = expectFreakError { try Wire.chunkFrames(blob: Data(dirty)) }
        guard case .protocolViolation(let detail) = e else {
            Issue.record("expected .protocolViolation, got \(String(describing: e))")
            return
        }
        #expect(detail.contains("blob byte 100"))
        #expect(detail.contains("0x80"))
    }

    @Test func assembleBlobEnforcesSize() throws {
        let chunk = Wire.parse(Wire.frame(seq: 1, length: 0x20,
                                          cmd: Wire.cmdChunkMore,
                                          data: Data(count: 32)))!
        #expect(throws: FreakError.blobSize(expected: 4672, actual: 64)) {
            try Wire.assembleBlob([chunk, chunk])
        }
    }

    @Test func digestIsLowercaseSha256Hex() {
        // sha256 of the empty string — a universally known value
        #expect(Wire.digest(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // -------------------------------------------------------------- Preset

    @Test func presetValidationOrder() throws {
        let blob = blob7(2)
        // bad name first
        let e1 = expectFreakError { try Preset(name: " x", blob: blob, meta: testMeta) }
        guard case .invalidName = e1 else {
            Issue.record("expected .invalidName, got \(String(describing: e1))")
            return
        }
        // blob size
        #expect(throws: FreakError.blobSize(expected: 4672, actual: 10)) {
            try Preset(name: "X", blob: Data(count: 10), meta: testMeta)
        }
        // meta length
        #expect(throws: FreakError.protocolViolation(detail: "meta must be 9 bytes, got 3")) {
            try Preset(name: "X", blob: blob, meta: Data(count: 3))
        }
        // blob 7-bit, naming the first bad index
        var dirty = [UInt8](blob)
        dirty[5] = 0x80
        let e2 = expectFreakError { try Preset(name: "X", blob: Data(dirty), meta: testMeta) }
        guard case .protocolViolation(let detail) = e2 else {
            Issue.record("expected .protocolViolation, got \(String(describing: e2))")
            return
        }
        #expect(detail.contains("blob byte 5") && detail.contains("0x80"))
        // meta 7-bit
        #expect(throws: FreakError.protocolViolation(detail: "meta contains non-7-bit bytes")) {
            try Preset(name: "X", blob: blob,
                       meta: Data([0xFF, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
    }

    @Test func presetShaAndRename() throws {
        let blob = blob7(3)
        let preset = try Preset(name: "Original", blob: blob, meta: testMeta)
        #expect(preset.sha256 == Wire.digest(blob))
        let renamed = try preset.renamed("New Name")
        #expect(renamed.name == "New Name")
        #expect(renamed.blob == preset.blob && renamed.meta == preset.meta)
        #expect(renamed.sha256 == preset.sha256)
        #expect(throws: FreakError.self) { try preset.renamed("bad ") }
    }
}
