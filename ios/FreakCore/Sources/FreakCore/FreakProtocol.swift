// FreakProtocol.swift — wire constants and the pure, stateless codec.
// Transliteration of microfreak/protocol.py. No I/O anywhere in here.
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

public enum FreakProtocol {
    // constants — values identical to protocol.py
    public static let prefix = Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01])
    public static let cmdOpen: UInt8 = 0x19       // name read (trailer 0x00) / dump open (trailer 0x01)
    public static let cmdNext: UInt8 = 0x18       // pull next chunk (reads); device's per-frame ack (writes)
    public static let cmdChunkMore: UInt8 = 0x16
    public static let cmdChunkLast: UInt8 = 0x17
    public static let cmdGo: UInt8 = 0x15         // write "go": seq 0, len 0, empty payload
    public static let cmdName: UInt8 = 0x52       // long: name+meta (35B); short [bank,pos,0x01]: open write
    public static let slots = 512
    public static let slotsPerBank = 128
    public static let highBankBoundary = 384      // REPLY payload[9]: 0 below, 1 at/above (writes: 0x06)
    public static let writePayload9: UInt8 = 0x06 // payload[9] in every captured outbound long 0x52
    public static let replyMetaFlag: UInt8 = 0x10 // payload[3] bit set by the device in replies for
                                                  // slots >= 128; clear in every captured outbound write
    public static let blobSize = 4672             // 146 x 32; the blob you write is the blob you read
    public static let chunkSize = 32
    public static let chunkCount = 146
    public static let namePayloadLen = 35         // long 0x52: 12-byte header + 23-byte name
    public static let nameOffset = 12
    public static let nameLen = 23
    public static let metaLen = 9                 // long-0x52 payload[3..11]
    public static let duplicateThreshold = 3      // content-based expendability (3, not 2)
    public static let noChecksum = true           // documented fact; nothing computes one, ever

    // ------------------------------------------------------------- addressing

    /// Slot number (0-based) -> (bank, position).
    public static func addr(_ slot: Int) throws -> (bank: UInt8, pos: UInt8) {
        guard slot >= 0 && slot < slots else {
            throw FreakError.slotOutOfRange(slot: slot)
        }
        return (UInt8(slot / slotsPerBank), UInt8(slot % slotsPerBank))
    }

    /// (bank, position) -> slot number. Inverse of addr().
    public static func slot(bank: Int, pos: Int) throws -> Int {
        guard pos >= 0 && pos < slotsPerBank && bank >= 0 else {
            throw FreakError.slotOutOfRange(slot: bank * slotsPerBank + pos)
        }
        let s = bank * slotsPerBank + pos
        guard s < slots else {
            throw FreakError.slotOutOfRange(slot: s)
        }
        return s
    }

    // ----------------------------------------------------------------- frames

    /// One complete SysEx message F0..F7. All body bytes masked to 7 bits.
    public static func frame(seq: UInt8, length: UInt8, cmd: UInt8,
                             data: Data = Data()) -> Data {
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

    // ------------------------------------------------------- request builders
    // seq is always explicit; this namespace counts nothing.

    public static func readNameRequest(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x03, cmd: cmdOpen, data: Data([bank, pos, 0x00]))
    }

    /// Dump-open request. The len byte 0x01 is the phase-0/core convention
    /// (proven on hardware by full 512-slot backups); MCC sends 0x03 and the
    /// hardware accepts both.
    public static func openDumpRequest(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x01, cmd: cmdOpen, data: Data([bank, pos, 0x01]))
    }

    public static func pullNextRequest(seq: UInt8) -> Data {
        frame(seq: seq, length: 0x01, cmd: cmdNext, data: Data([0x00]))
    }

    /// THE single composer of address-derived header bytes.
    ///
    /// The long-0x52 payload is direction-dependent (every captured MCC write
    /// in c2/c3/c4 vs. every captured reply). Outbound payload:
    ///
    ///     [0]=bank [1]=pos [2]=0x00
    ///     [3]     = meta[0] & ~0x10         (replyMetaFlag cleared: the device
    ///                                        sets 0x10 here in replies for slots
    ///                                        >= 128; no captured outbound write
    ///                                        ever carries it)
    ///     [4..7]  = meta[1..4]              (opaque, round-tripped verbatim)
    ///     [8]     = pos                     (RECOMPUTED for the target slot; meta[5] ignored)
    ///     [9]     = 0x06                    (writePayload9, constant in all captured
    ///                                        writes; meta[6] — the reply-side 0/1
    ///                                        slot-384 flag — ignored)
    ///     [10]    = meta[7]  [11] = meta[8] (category / attribute, verbatim)
    ///     [12..34]= name, ASCII, NUL-padded to 23
    public static func nameWriteFrame(seq: UInt8, slot: Int,
                                      name: String, meta: Data) throws -> Data {
        let (bank, pos) = try addr(slot)
        try validateName(name)
        let m = [UInt8](meta)
        guard m.count == metaLen else {
            throw FreakError.protocolViolation(
                detail: "meta must be \(metaLen) bytes, got \(m.count)")
        }
        guard !m.contains(where: { $0 > 0x7F }) else {
            throw FreakError.protocolViolation(detail: "meta contains non-7-bit bytes")
        }
        var field = Array(name.utf8)                 // pure ASCII after validateName
        field += [UInt8](repeating: 0x00, count: nameLen - field.count)
        var payload: [UInt8] = [bank, pos, 0x00, m[0] & ~replyMetaFlag]
        payload += m[1...4]
        payload += [pos, writePayload9, m[7], m[8]]
        payload += field
        assert(payload.count == namePayloadLen)
        return frame(seq: seq, length: 0x23, cmd: cmdName, data: Data(payload))
    }

    /// Short 0x52 [bank, pos, 0x01]: open blob write to (bank, pos).
    public static func openWriteFrame(seq: UInt8, slot: Int) throws -> Data {
        let (bank, pos) = try addr(slot)
        return frame(seq: seq, length: 0x03, cmd: cmdName, data: Data([bank, pos, 0x01]))
    }

    /// Write "go": seq 0, len 0, empty payload.
    public static func goFrame() -> Data {
        frame(seq: 0, length: 0x00, cmd: cmdGo)
    }

    /// 145 x 0x16 + 1 x 0x17, each carrying exactly 32 content bytes.
    ///
    /// Chunk seq bytes reproduce every captured write burst: the go frame
    /// carries seq 0 and the chunks continue from it — 1, 2, .., 127, 0, 1, ..
    /// (mod 128, wrapping THROUGH 0). Chunk i therefore carries (i + 1) % 128.
    /// This stream is separate from the session's addressed-request counter
    /// (which walks 1..127 and never emits 0).
    ///
    /// Chunks carry no address, by design — see the file header.
    public static func chunkFrames(blob: Data) throws -> [Data] {
        let b = [UInt8](blob)
        guard b.count == blobSize else {
            throw FreakError.blobSize(expected: blobSize, actual: b.count)
        }
        if let bad = b.firstIndex(where: { $0 > 0x7F }) {
            // frame() masks to 7 bits, so letting this through would silently
            // alter the content on the wire; reject the input instead
            throw FreakError.protocolViolation(detail: String(
                format: "blob byte %d is 0x%02X: SysEx content must be 7-bit clean",
                bad, b[bad]))
        }
        var out: [Data] = []
        out.reserveCapacity(chunkCount)
        for i in 0..<chunkCount {
            let piece = Data(b[(i * chunkSize)..<((i + 1) * chunkSize)])
            let cmd = i == chunkCount - 1 ? cmdChunkLast : cmdChunkMore
            out.append(frame(seq: UInt8((i + 1) % 128), length: 0x20, cmd: cmd, data: piece))
        }
        return out
    }

    // ---------------------------------------------------------------- parsers

    /// Parse one SysEx message; nil for non-MicroFreak traffic.
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

    /// Decode the long-0x52 payload (a reply or an outbound name write).
    public static func decodeNameReply(_ frame: Frame) throws -> NameInfo {
        let d = [UInt8](frame.data)
        guard frame.cmd == cmdName && d.count == namePayloadLen else {
            throw FreakError.protocolViolation(detail: String(
                format: "not a long 0x52 name frame: cmd=0x%02X len=%d",
                frame.cmd, d.count))
        }
        let s = try slot(bank: Int(d[0]), pos: Int(d[1]))
        return NameInfo(slot: s, name: decodeName(d),
                        meta: Data(d[3..<nameOffset]))
    }

    /// Name out of a 35-byte long-0x52 payload. Printable ASCII, trimmed.
    ///
    /// Matches mfcap.sysex.decode_name exactly (verified against hardware
    /// fixtures): data[12:] split at the first NUL, printable-filtered,
    /// stripped.
    static func decodeName(_ data: [UInt8]) -> String {
        var body = Array(data[nameOffset...])
        if let nul = body.firstIndex(of: 0x00) {
            body = Array(body[..<nul])
        }
        let chars = body.filter { $0 >= 0x20 && $0 < 0x7F }
        return String(decoding: chars, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Concatenate chunk payloads into the preset blob; must total 4672.
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

    /// SHA-256 of the blob, lowercase hex.
    public static func digest(_ blob: Data) -> String {
        SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    /// <= 23 printable-ASCII characters, no leading/trailing whitespace;
    /// returns the name unchanged.
    ///
    /// Leading/trailing spaces are rejected because name replies are decoded
    /// stripped (decodeName), so such a name can never round-trip — a
    /// verified write of "Foo " would always fail its read-back comparison
    /// even though the device write succeeded.
    @discardableResult
    public static func validateName(_ name: String) throws -> String {
        if name.unicodeScalars.count > nameLen {
            throw FreakError.invalidName(
                detail: "name is \(name.unicodeScalars.count) chars, max \(nameLen)")
        }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw FreakError.invalidName(
                detail: "name '\(name)' has leading/trailing whitespace, which "
                    + "cannot round-trip through the device (replies decode stripped)")
        }
        for scalar in name.unicodeScalars where !(scalar.value >= 0x20 && scalar.value < 0x7F) {
            throw FreakError.invalidName(
                detail: "non-printable/non-ASCII character '\(scalar)' in name")
        }
        return name
    }
}
