// Backup.swift — BackupSet: the phase-0 on-disk backup format, unchanged
// (backup.py).
//
//     <dest>/
//       index.json        {"created": ISO8601, "slots": N,
//                          "presets": {"<slot>": {"slot", "name", "bytes",
//                                                 "sha256", "meta_hex"}},
//                          "timing": {total_seconds, per_slot_seconds,
//                                     name_ms_median, dump_ms_median}}
//       presets/NNN.bin   the 4672-byte blob, zero-padded 3-digit slot number
//
// Byte-role-compatible with what `mfcap backup` writes today, so existing
// backups open unchanged. `meta_hex` (18 hex chars) is additive; loading an
// old index without it yields records whose meta is nil, and preset(slot:) on
// such a slot throws .integrity — old backups remain readable for
// diff/analysis; they only lack write-back capability.
//
// Creation goes through MicroFreakDevice.backup only (there is no
// BackupSet.create taking a device — one mutation/IO path).

import Foundation

/// Write text via Data.write(options: .atomic) — temp file + rename, the
/// same guarantee as Python's mkstemp + os.replace; readers never see a
/// torn file.
func atomicWriteText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

/// JSON writing: schema-identical to the Python (same keys, null for absent
/// medians); byte order of keys may differ — both implementations read
/// either (§10 deviation 10).
func jsonText(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// A loaded, hash-verified phase-0 backup directory. Immutable after load —
/// a Sendable struct (it crosses the actor boundary in backup/restore).
public struct BackupSet: Sendable {
    public struct Entry: Sendable, Equatable {
        public let slot: Int
        public let name: String?
        public let bytes: Int?
        public let sha256: String?
        public let metaHex: String?      // 18 hex chars; nil on pre-meta phase-0 indexes
    }

    public let path: URL
    public let createdAt: String
    public let timing: TimingReport
    private let entries: [Int: Entry]

    /// Load and verify: re-hashes every blob file against the index sha256,
    /// ascending slot order; .integrity names the first bad slot (missing
    /// file or sha mismatch). .libraryCorrupt on an unparseable index.
    public static func load(from path: URL) throws -> BackupSet {
        let indexPath = path.appendingPathComponent("index.json")
        let object: Any
        do {
            let raw = try Data(contentsOf: indexPath)
            object = try JSONSerialization.jsonObject(with: raw)
        } catch let e as FreakError {
            throw e
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
                if FreakProtocol.digest(blob) != sha {
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
    public func covers(slot: Int) -> Bool {
        guard let v = entries[slot], let sha = v.sha256 else { return false }
        return !sha.isEmpty
    }

    public func coveredSlots() -> [Int] {
        entries.keys.filter { covers(slot: $0) }.sorted()
    }

    public func preset(slot: Int) throws -> Preset {
        guard covers(slot: slot) else {
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

    /// name + sha + meta per entry; blob nil (lazy).
    public func records() -> [SlotRecord] {
        entries.keys.sorted().map { slot in
            let v = entries[slot]!
            let meta = v.metaHex.flatMap { $0.isEmpty ? nil : Data(hexString: $0) }
            return SlotRecord(slot: slot, name: v.name, sha256: v.sha256,
                              meta: meta, blob: nil)
        }
    }
}
