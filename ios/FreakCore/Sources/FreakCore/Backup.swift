// Backup.swift — BackupSet: the phase-0 on-disk backup format, unchanged
// (port of backup.py), plus the shared on-disk helpers (AtomicFile, JSON and
// hex encodings pinned by §10 of the architecture spec).
//
//     <dest>/
//       index.json        {"created": ISO8601, "slots": N,
//                          "presets": {"<slot>": {"slot", "name", "bytes",
//                                                 "sha256", "meta_hex"}},
//                          "timing": {total_seconds, per_slot_seconds,
//                                     name_ms_median, dump_ms_median}}
//       presets/NNN.bin   the 4672-byte blob, zero-padded 3-digit slot number
//
// Interop is a hard requirement: a backup written on the iPad opens
// unchanged in the Python core and vice versa (same layout, file names,
// JSON keys, value types and encodings; key order and whitespace are free).
// `meta_hex` (18 hex chars) is additive; loading an old index without it
// yields records whose meta is nil, and preset(_:) on such a slot throws
// .integrity — old backups remain readable for diff/analysis; they only
// lack write-back capability.
//
// Creation goes through MicroFreakDevice.backup only (there is no
// BackupSet.create taking a device — one mutation/IO path).

import Foundation

enum AtomicFile {
    /// Write via temp file + atomic replace — the same guarantee as Python's
    /// mkstemp + os.replace; readers never see a torn file. Throws .integrity
    /// on failure.
    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FreakError.integrity(path: url.path,
                                       detail: "atomic write failed: \(error)")
        }
    }
}

/// JSON writing: schema-identical to the Python (same keys, null for absent
/// medians); byte order of keys may differ — both implementations' parsers
/// accept either.
func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

/// "yyyy-MM-dd'T'HH:mm:ss", local time, no fraction, no zone — matches
/// Python's time.strftime("%Y-%m-%dT%H:%M:%S").
func isoNow() -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone.current
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fmt.string(from: Date())
}

/// Median as mfcap.midi.backup computes it: sorted()[count / 2] (upper
/// median), rounded to 1 decimal. nil for an empty list.
func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    return roundTo(xs.sorted()[xs.count / 2], places: 1)
}

/// Round half-to-even (banker's), matching Python's round() — so timing
/// values written to index.json are identical to the reference core even on
/// exact .5 boundaries (round(2.25, 1) == 2.2, not 2.3).
func roundTo(_ x: Double, places: Int) -> Double {
    let f = pow(10.0, Double(places))
    return (x * f).rounded(.toNearestOrEven) / f
}

extension Data {
    /// Contiguous hex (no separators), any case; nil on malformed input.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.nibble(chars[i]), let lo = Data.nibble(chars[i + 1]) else {
                return nil
            }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30           // 0-9
        case 0x61...0x66: return c - 0x61 + 10      // a-f
        case 0x41...0x46: return c - 0x41 + 10      // A-F
        default: return nil
        }
    }

    /// Lowercase contiguous hex — matches Python bytes.hex().
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// A loaded, hash-verified phase-0 backup directory. Immutable after load.
public struct BackupSet: Sendable {
    struct Entry: Sendable, Equatable {
        let slot: Int
        let name: String?
        let bytes: Int?
        let sha256: String?
        let metaHex: String?      // 18 hex chars; nil on pre-meta phase-0 indexes
    }

    public let path: URL
    public let createdAt: String
    public let timing: TimingReport
    private let entries: [Int: Entry]

    /// Load and verify: re-hashes EVERY blob file against its recorded
    /// sha256, ascending slot order. First bad slot -> .integrity naming it;
    /// missing blob file -> .integrity; unparseable index / missing
    /// "presets" table -> .libraryCorrupt. Synchronous file IO; callers off
    /// the main thread wrap it in a Task.
    public static func load(_ path: URL) throws -> BackupSet {
        let indexPath = path.appendingPathComponent("index.json")
        let object: Any
        do {
            let raw = try Data(contentsOf: indexPath)
            object = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw FreakError.libraryCorrupt(path: indexPath.path,
                                            detail: String(describing: error))
        }
        guard let data = object as? [String: Any],
              let presets = data["presets"] as? [String: Any] else {
            throw FreakError.libraryCorrupt(path: indexPath.path,
                                            detail: "no 'presets' table")
        }
        var entries: [Int: Entry] = [:]
        let orderedKeys: [(Int, String)] = try presets.keys.map { key in
            guard let n = Int(key) else {
                throw FreakError.libraryCorrupt(path: indexPath.path,
                                                detail: "bad slot key: \(key)")
            }
            return (n, key)
        }.sorted { $0.0 < $1.0 }
        for (slot, key) in orderedKeys {
            let v = (presets[key] as? [String: Any]) ?? [:]
            let sha = v["sha256"] as? String
            if let sha, !sha.isEmpty {
                let binPath = path.appendingPathComponent("presets")
                    .appendingPathComponent(String(format: "%03d.bin", slot))
                guard let blob = try? Data(contentsOf: binPath) else {
                    throw FreakError.integrity(path: binPath.path,
                                               detail: "slot \(slot): blob file missing")
                }
                if Wire.digest(blob) != sha {
                    throw FreakError.integrity(path: binPath.path,
                                               detail: "slot \(slot): sha256 mismatch")
                }
            }
            entries[slot] = Entry(slot: slot,
                                  name: v["name"] as? String,
                                  bytes: (v["bytes"] as? NSNumber)?.intValue,
                                  sha256: sha,
                                  metaHex: v["meta_hex"] as? String)
        }
        let t = (data["timing"] as? [String: Any]) ?? [:]
        let timing = TimingReport(
            totalSeconds: (t["total_seconds"] as? NSNumber)?.doubleValue ?? 0.0,
            perSlotSeconds: (t["per_slot_seconds"] as? NSNumber)?.doubleValue ?? 0.0,
            nameMsMedian: (t["name_ms_median"] as? NSNumber)?.doubleValue,
            dumpMsMedian: (t["dump_ms_median"] as? NSNumber)?.doubleValue)
        return BackupSet(path: path,
                         createdAt: data["created"] as? String ?? "",
                         timing: timing,
                         entries: entries)
    }

    /// Entry exists AND has a sha256.
    public func covers(_ slot: Int) -> Bool {
        guard let v = entries[slot], let sha = v.sha256 else { return false }
        return !sha.isEmpty
    }

    /// Ascending.
    public func coveredSlots() -> [Int] {
        entries.keys.filter { covers($0) }.sorted()
    }

    /// Reads NNN.bin lazily. .slotOutOfRange when not covered; .integrity
    /// when meta_hex is absent (a pre-meta phase-0 index — re-backup to
    /// restore). name nil in the index -> "".
    public func preset(_ slot: Int) throws -> Preset {
        guard covers(slot) else {
            throw FreakError.slotOutOfRange(slot: slot)
        }
        let v = entries[slot]!
        let binPath = path.appendingPathComponent("presets")
            .appendingPathComponent(String(format: "%03d.bin", slot))
        guard let metaHex = v.metaHex, !metaHex.isEmpty else {
            throw FreakError.integrity(
                path: binPath.path,
                detail: "no meta recorded; re-backup to restore this slot")
        }
        guard let meta = Data(hexString: metaHex) else {
            throw FreakError.integrity(path: binPath.path,
                                       detail: "unparseable meta_hex: \(metaHex)")
        }
        let blob = try Data(contentsOf: binPath)
        return try Preset(name: v.name ?? "", blob: blob, meta: meta)
    }

    /// name + sha + meta per indexed slot; blob always nil (lazy).
    public func records() -> [SlotRecord] {
        entries.keys.sorted().map { slot in
            let v = entries[slot]!
            let meta = v.metaHex.flatMap { $0.isEmpty ? nil : Data(hexString: $0) }
            return SlotRecord(slot: slot, name: v.name, sha256: v.sha256,
                              meta: meta, blob: nil)
        }
    }
}
