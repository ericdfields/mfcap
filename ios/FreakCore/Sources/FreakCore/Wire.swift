// Wire.swift — wire constants and the pure, stateless codec.
// Port of microfreak/protocol.py. No I/O anywhere in here.
//
// Ground truth: docs/write-protocol.md (decoded and gate-verified 2026-09-01
// against firmware 5.x hardware). Frame envelope:
//
//     F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7
//
// The <len> bytes: name read 0x03, pull-next 0x01 with payload [0x00],
// chunks 0x20, long 0x52 0x23, short 0x52 0x03, go 0x00 — all gate-verified
// literals. The dump-open 0x01 is the phase-0 value (archived francoisgeorgy
// notes, proven on hardware by full 512-slot backups); MCC's own captured
// dump open carries len 0x03 (= payload length) and the device accepts both.
// Do NOT "fix" the 0x01.
//
// Address invariant, structural: no function in this namespace accepts or
// returns a slot for a chunk frame; chunk builders and parsers have no
// address parameters. A chunk payload may coincidentally begin `03 7F` —
// pattern matching an address inside a chunk is not expressible against
// this API.
//
// No checksum exists anywhere in the protocol; nothing here computes one.

import CryptoKit
import Foundation

public enum Wire {

    // MARK: constants (values identical to protocol.py)

    public static let prefix = Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01])
    public static let cmdOpen: UInt8 = 0x19       // name read (trailer 0x00) / dump open (0x01)
    public static let cmdNext: UInt8 = 0x18       // pull next (reads); device per-frame ack (writes)
    public static let cmdChunkMore: UInt8 = 0x16
    public static let cmdChunkLast: UInt8 = 0x17
    public static let cmdGo: UInt8 = 0x15         // seq 0, len 0, empty payload
    public static let cmdName: UInt8 = 0x52       // long: name+meta (35B); short [bank,pos,0x01]: open write

    public static let slots = 512
    public static let slotsPerBank = 128
    public static let highBankBoundary = 384      // REPLY payload[9]: 0 below, 1 at/above
    public static let writePayload9: UInt8 = 0x06 // payload[9] in every captured outbound long 0x52
    public static let replyMetaFlag: UInt8 = 0x10 // payload[3] bit, device replies only (slots >= 128)
    public static let blobSize = 4672             // 146 x 32
    public static let chunkSize = 32
    public static let chunkCount = 146
    public static let namePayloadLength = 35      // 12-byte header + 23-byte name
    public static let nameOffset = 12
    public static let nameLength = 23
    public static let metaLength = 9              // long-0x52 payload[3..11]
    public static let duplicateThreshold = 3      // content-based expendability (3, not 2)
    // NO_CHECKSUM: no checksum exists; nothing in this module computes one, ever.

    public struct Frame: Sendable, Equatable {
        public let raw: Data
        public let seq: UInt8
        public let length: UInt8
        public let cmd: UInt8
        public let data: Data                     // payload bytes (between cmd and F7)

        public init(raw: Data, seq: UInt8, length: UInt8, cmd: UInt8, data: Data) {
            self.raw = raw
            self.seq = seq
            self.length = length
            self.cmd = cmd
            self.data = data
        }
    }

    // MARK: addressing

    /// slot (0-based) -> (bank, pos). Throws .slotOutOfRange outside 0..<512.
    public static func addr(_ slot: Int) throws -> (bank: UInt8, pos: UInt8) {
        guard slot >= 0 && slot < slots else {
            throw FreakError.slotOutOfRange(slot: slot)
        }
        return (UInt8(slot / slotsPerBank), UInt8(slot % slotsPerBank))
    }

    /// Inverse of addr. Throws .slotOutOfRange when the pair names no valid slot.
    public static func slot(bank: UInt8, pos: UInt8) throws -> Int {
        let s = Int(bank) * slotsPerBank + Int(pos)
        guard Int(pos) < slotsPerBank, s < slots else {
            throw FreakError.slotOutOfRange(slot: s)
        }
        return s
    }

    // MARK: frame assembly

    /// One complete SysEx message F0..F7. Every body byte is masked & 0x7F.
    public static func frame(seq: UInt8, length: UInt8, cmd: UInt8,
                             data: some Sequence<UInt8>) -> Data {
        var out = prefix
        out.append(seq & 0x7F)
        out.append(length & 0x7F)
        out.append(cmd & 0x7F)
        for b in data {
            out.append(b & 0x7F)
        }
        out.append(0xF7)
        return out
    }

    // MARK: request builders (seq explicit, always — this namespace counts nothing)

    /// len 0x03, payload [bank, pos, 0x00].
    public static func readNameRequest(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x03, cmd: cmdOpen, data: [bank, pos, 0x00])
    }

    /// len 0x01 (the phase-0 literal, hardware-proven), payload [bank, pos, 0x01].
    public static func openDumpRequest(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x01, cmd: cmdOpen, data: [bank, pos, 0x01])
    }

    /// Host pull-next: len 0x01, payload [0x00] — distinct from the device's
    /// empty-payload ack shape.
    public static func pullNextRequest(seq: UInt8) -> Data {
        frame(seq: seq, length: 0x01, cmd: cmdNext, data: [0x00])
    }

    /// THE single composer of address-derived header bytes. Outbound payload:
    ///
    ///     [0]=bank [1]=pos [2]=0x00
    ///     [3]     = meta[0] & ~replyMetaFlag  (reply-only 0x10 bit cleared —
    ///                                          no captured outbound write carries it)
    ///     [4..7]  = meta[1..4]                (opaque, round-tripped verbatim)
    ///     [8]     = pos                       (RECOMPUTED; meta[5] ignored)
    ///     [9]     = writePayload9 = 0x06      (constant in every captured write;
    ///                                          meta[6], the reply-side 0/1 slot-384
    ///                                          flag, ignored)
    ///     [10]    = meta[7]  [11] = meta[8]   (category / attribute, verbatim)
    ///     [12..34]= name, ASCII, NUL-padded to 23
    ///
    /// Throws .invalidName, .slotOutOfRange, .protocolViolation (meta not 9
    /// bytes / not 7-bit).
    public static func nameWriteFrame(seq: UInt8, slot: Int,
                                      name: String, meta: Data) throws -> Data {
        let (bank, pos) = try addr(slot)
        try validateName(name)
        let m = [UInt8](meta)
        guard m.count == metaLength else {
            throw FreakError.protocolViolation(
                detail: "meta must be \(metaLength) bytes, got \(m.count)")
        }
        guard !m.contains(where: { $0 > 0x7F }) else {
            throw FreakError.protocolViolation(detail: "meta contains non-7-bit bytes")
        }
        var field = Array(name.utf8)               // pure ASCII after validateName
        field += [UInt8](repeating: 0x00, count: nameLength - field.count)
        var payload: [UInt8] = [bank, pos, 0x00, m[0] & ~replyMetaFlag]
        payload += m[1...4]
        payload += [pos, writePayload9, m[7], m[8]]
        payload += field
        assert(payload.count == namePayloadLength)
        return frame(seq: seq, length: 0x23, cmd: cmdName, data: payload)
    }

    /// Short 0x52 [bank, pos, 0x01]: open blob write to (bank, pos). len 0x03.
    public static func openWriteFrame(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x03, cmd: cmdName, data: [bank, pos, 0x01])
    }

    /// Write "go": seq 0, len 0, empty payload — always.
    public static func goFrame() -> Data {
        frame(seq: 0, length: 0x00, cmd: cmdGo, data: EmptyCollection<UInt8>())
    }

    /// 145 x 0x16 + 1 x 0x17, 32 content bytes each, chunk i carrying seq
    /// (i + 1) % 128 — wrapping THROUGH 0 (this function owns the write-burst
    /// seq stream; it continues from the go frame's 0). No address parameter,
    /// by design. Throws .blobSize on length != 4672; .protocolViolation on
    /// any byte > 0x7F (masking would silently alter content on the wire —
    /// reject instead).
    public static func chunkFrames(blob: Data) throws -> [Data] {
        let b = [UInt8](blob)
        guard b.count == blobSize else {
            throw FreakError.blobSize(expected: blobSize, actual: b.count)
        }
        if let bad = b.firstIndex(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: String(
                format: "blob byte %d is 0x%02X: SysEx content must be 7-bit clean",
                bad, b[bad]))
        }
        var out: [Data] = []
        out.reserveCapacity(chunkCount)
        for i in 0..<chunkCount {
            let piece = b[(i * chunkSize)..<((i + 1) * chunkSize)]
            let cmd = i == chunkCount - 1 ? cmdChunkLast : cmdChunkMore
            out.append(frame(seq: UInt8((i + 1) % 128), length: 0x20, cmd: cmd, data: piece))
        }
        return out
    }

    // MARK: parsers / helpers

    /// nil for non-MicroFreak traffic (short, wrong prefix, no F0/F7). Never throws.
    public static func parse(_ raw: Data) -> Frame? {
        let b = [UInt8](raw)
        guard b.count >= 10, b.first == 0xF0, b.last == 0xF7 else {
            return nil
        }
        guard b.prefix(6).elementsEqual(prefix) else {
            // full 6-byte prefix, incl. the trailing 0x01 — matches phase-0
            // Frame.is_microfreak exactly
            return nil
        }
        return Frame(raw: Data(b), seq: b[6], length: b[7], cmd: b[8],
                     data: Data(b[9..<(b.count - 1)]))
    }

    /// Decode a long-0x52 payload (reply or outbound). Throws
    /// .protocolViolation-group errors on wrong cmd/length or an out-of-range
    /// embedded address.
    public static func decodeNameReply(_ frame: Frame) throws -> NameInfo {
        let d = [UInt8](frame.data)
        guard frame.cmd == cmdName && d.count == namePayloadLength else {
            throw FreakError.protocolViolation(detail: String(
                format: "not a long 0x52 name frame: cmd=0x%02X len=%d",
                frame.cmd, d.count))
        }
        let s = try slot(bank: d[0], pos: d[1])
        return NameInfo(slot: s, name: decodeNameField(d), meta: Data(d[3..<nameOffset]))
    }

    /// Name out of a 35-byte long-0x52 payload. Matches mfcap.sysex.decode_name
    /// exactly (verified against hardware fixtures): data[12:] split at the
    /// first NUL, printable-ASCII filtered, stripped.
    static func decodeNameField(_ data: [UInt8]) -> String {
        var body = Array(data[nameOffset...])
        if let nul = body.firstIndex(of: 0x00) {
            body = Array(body[..<nul])
        }
        let chars = body.filter { $0 >= 0x20 && $0 < 0x7F }
        return String(decoding: chars, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func isChunk(_ f: Frame) -> Bool {
        f.cmd == cmdChunkMore || f.cmd == cmdChunkLast
    }

    public static func isLastChunk(_ f: Frame) -> Bool {
        f.cmd == cmdChunkLast
    }

    public static func isAck(_ f: Frame) -> Bool {
        f.cmd == cmdNext
    }

    /// Concatenate chunk payloads; throws .blobSize unless the total is
    /// exactly 4672.
    public static func assembleBlob(_ chunks: [Frame]) throws -> Data {
        var out = Data()
        for c in chunks {
            out.append(c.data)
        }
        guard out.count == blobSize else {
            throw FreakError.blobSize(expected: blobSize, actual: out.count)
        }
        return out
    }

    /// Lowercase hex SHA-256 (CryptoKit).
    public static func digest(_ blob: Data) -> String {
        SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    /// <= 23 printable-ASCII chars, no leading/trailing whitespace (replies
    /// decode stripped, so such a name can never round-trip). Throws
    /// .invalidName. Returns nothing.
    public static func validateName(_ name: String) throws {
        if name.unicodeScalars.count > nameLength {
            throw FreakError.invalidName(
                reason: "name is \(name.unicodeScalars.count) chars, max \(nameLength)")
        }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw FreakError.invalidName(
                reason: "name '\(name)' has leading/trailing whitespace, which "
                    + "cannot round-trip through the device (replies decode stripped)")
        }
        for scalar in name.unicodeScalars where !(scalar.value >= 0x20 && scalar.value < 0x7F) {
            throw FreakError.invalidName(
                reason: "non-printable/non-ASCII character '\(scalar)' in name")
        }
    }
}

// Internal conveniences (tests and the session use these; the public API is
// the Wire.isChunk family above).
extension Wire.Frame {
    var isChunk: Bool { Wire.isChunk(self) }
    var isLastChunk: Bool { Wire.isLastChunk(self) }
    var isAck: Bool { Wire.isAck(self) }
}
