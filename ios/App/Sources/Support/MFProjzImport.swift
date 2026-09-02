// MFProjzImport.swift — the app-side reader for Arturia MCC exports
// (.mbp / .mfprojz), producing FreakCore `BankItem`s for
// `Library.collectionFromBank` (data-model spec §5.2; UX addendum §26.3).
//
// This is a semantics-faithful port of the VERIFIED `tools/mbp_import.py`
// (open question 5): the Boost text-serialization parse and the sub-bank slot
// mapping are line-for-line the same logic. The blob it yields is byte-
// identical to a device SysEx dump (verified 2026-09-01); the app hands these
// bytes straight to the core and never interprets them further.
//
// A `.mbp` is one Boost archive. A `.mfprojz` is a Zip of `.mbp` members; the
// Zip container is read here (local headers + DEFLATE via the Compression
// framework) — orthogonal to the Boost parsing, which is not re-derived.

import Foundation
import Compression
import FreakCore

enum MFProjzImport {
    static let blobSize = 4672

    /// Parse an MCC export into `BankItem`s, ascending by filename (the
    /// order `read_mfprojz` uses). Throws `.protocolViolation` when the file
    /// is neither a `.mbp` archive nor a readable `.mfprojz` Zip.
    static func parse(data: Data, filename: String) throws -> [BankItem] {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mbp":
            return [try parseMbp(text: latin1(data), source: filename)]
        case "mfprojz":
            let members = try Zip.mbpMembers(in: data)
            guard !members.isEmpty else {
                throw FreakError.protocolViolation(
                    detail: "no .mbp presets found in \(filename)")
            }
            return try members.map { member in
                try parseMbp(text: latin1(member.data), source: member.name)
            }
        default:
            throw FreakError.protocolViolation(
                detail: "unsupported bank file: .\(ext)")
        }
    }

    // ---------------------------------------------------- Boost text parse

    private static let headerRegex = try! NSRegularExpression(
        pattern: #"serialization::archive\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s"#)
    // MCC names every file "<slot>-<project>-<subbank><slot>.mbp"; the leading
    // number is the GLOBAL 1-based slot (1...512). The sub-bank letter is
    // display only — reading it as a 128-slot offset wrongly dropped any
    // index > 128 (most of a full-device dump). Parity with mbp_import.py.
    private static let namePrefixRegex = try! NSRegularExpression(
        pattern: #"^(\d+)-"#)

    /// Faithful port of `parse_mbp_text` + `_slot_from_name`.
    private static func parseMbp(text: String, source: String) throws
        -> BankItem {
        let ns = text as NSString
        guard let m = headerRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else {
            throw FreakError.protocolViolation(
                detail: "not a MicroFreak Boost archive: \(source)")
        }
        let nameLen = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let afterHeader = ns.substring(from: m.range.location + m.range.length)
        let restChars = Array(afterHeader)
        let name = String(restChars.prefix(nameLen))
            .trimmingCharacters(in: .whitespaces)
        let tokens = String(restChars.dropFirst(nameLen))
            .split(whereSeparator: { $0 == " " || $0 == "\n"
                || $0 == "\r" || $0 == "\t" })
            .map(String.init)

        // toks: a b c metalen metahex d e itemver [bloblen bytes...]
        var meta = Data()
        if tokens.count >= 5, let metaLen = Int(tokens[3]) {
            let metaHex = tokens[4]
            if metaHex.count == metaLen, metaLen % 2 == 0,
               let parsed = hexData(metaHex) {
                meta = parsed
            }
        }
        // Locate the blob: the token "4672" followed by that many byte ints.
        var blob: Data?
        let target = String(blobSize)
        for i in tokens.indices where tokens[i] == target
            && tokens.count - i - 1 >= blobSize {
            var bytes = Data(capacity: blobSize)
            var ok = true
            for j in (i + 1)...(i + blobSize) {
                guard let v = Int(tokens[j]), (0...255).contains(v) else {
                    ok = false; break
                }
                bytes.append(UInt8(v))
            }
            if ok { blob = bytes; break }
        }
        return BankItem(slot: slotFromName(source), name: name,
                        meta: meta, blob: blob)
    }

    private static func slotFromName(_ fname: String) -> Int? {
        let base = (fname as NSString).lastPathComponent
        let ns = base as NSString
        guard let m = namePrefixRegex.firstMatch(
            in: base, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let n = Int(ns.substring(with: m.range(at: 1))),
              (1...512).contains(n) else { return nil }
        return n - 1
    }

    // ------------------------------------------------------------- helpers

    /// Latin-1 decode: each byte becomes one scalar (matches Python
    /// `.decode("latin-1")`), so name chars and decimal tokens survive intact.
    private static func latin1(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    private static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let hi = it.next() {
            guard let lo = it.next(),
                  let byte = UInt8("\(hi)\(lo)", radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

// ================================================================= Zip

/// A minimal read-only Zip extractor for `.mfprojz` banks: it walks the
/// central directory, then inflates each `.mbp` member (STORED or DEFLATE).
/// Deliberately small and offline — no external dependency, no writing.
private enum Zip {
    struct Member { let name: String; let data: Data }

    enum ZipError: Error { case malformed(String) }

    static func mbpMembers(in data: Data) throws -> [Member] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else {
            throw ZipError.malformed("no end-of-central-directory record")
        }
        let count = readU16(bytes, eocd + 10)
        var offset = readU32(bytes, eocd + 16)
        var members: [(name: String, data: Data)] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count,
                  readU32(bytes, offset) == 0x0201_4b50 else {
                throw ZipError.malformed("bad central directory entry")
            }
            let method = readU16(bytes, offset + 10)
            let compSize = readU32(bytes, offset + 20)
            let uncompSize = readU32(bytes, offset + 24)
            let nameLen = readU16(bytes, offset + 28)
            let extraLen = readU16(bytes, offset + 30)
            let commentLen = readU16(bytes, offset + 32)
            let localOffset = readU32(bytes, offset + 42)
            let name = latin1(bytes, offset + 46, nameLen)
            offset += 46 + nameLen + extraLen + commentLen
            guard name.lowercased().hasSuffix(".mbp") else { continue }
            let payload = try inflate(bytes, at: localOffset, method: method,
                                      compSize: compSize,
                                      uncompSize: uncompSize)
            members.append((name, payload))
        }
        return members.sorted { $0.name < $1.name }
            .map { Member(name: $0.name, data: $0.data) }
    }

    /// Read a local file header at `localOffset` and return its member bytes.
    private static func inflate(_ bytes: [UInt8], at localOffset: Int,
                                method: Int, compSize: Int,
                                uncompSize: Int) throws -> Data {
        guard localOffset + 30 <= bytes.count,
              readU32(bytes, localOffset) == 0x0403_4b50 else {
            throw ZipError.malformed("bad local file header")
        }
        let nameLen = readU16(bytes, localOffset + 26)
        let extraLen = readU16(bytes, localOffset + 28)
        let start = localOffset + 30 + nameLen + extraLen
        guard start + compSize <= bytes.count else {
            throw ZipError.malformed("member overruns file")
        }
        let comp = Array(bytes[start..<(start + compSize)])
        if method == 0 { return Data(comp) }                 // STORED
        guard method == 8 else {                              // only DEFLATE
            throw ZipError.malformed("unsupported compression \(method)")
        }
        var out = Data(count: max(uncompSize, 1))
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            comp.withUnsafeBufferPointer { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, uncompSize,
                    src.baseAddress!, comp.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == uncompSize else {
            throw ZipError.malformed("inflate size mismatch")
        }
        return out.prefix(produced)
    }

    // ------------------------------------------------------- byte helpers

    private static func findEOCD(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let low = max(0, b.count - 22 - 0xFFFF)
        while i >= low {
            if readU32(b, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func readU16(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 2 <= b.count else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
            | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    private static func latin1(_ b: [UInt8], _ start: Int, _ len: Int) -> String {
        guard start + len <= b.count else { return "" }
        return String(String.UnicodeScalarView(
            b[start..<(start + len)].map { Unicode.Scalar($0) }))
    }
}
