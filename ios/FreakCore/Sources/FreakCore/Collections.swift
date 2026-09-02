// Collections.swift — PresetCollection: a named device arrangement, an
// ordered slot->PresetRef map over the library's content-addressed blobs,
// plus identity and provenance. Port of microfreak/collections.py.
//
// This file is pure of device I/O: it defines the collection value types,
// their JSON codec, and the pure apply/switch PLAN (planApply). Building and
// storing collections is the Library actor (Library.swift); executing a plan
// is MicroFreakDevice.applyCollection (Device.swift).
//
// On-disk format — one file per collection under the library:
//
//     <root>/collections/<id>.json
//       {"schema": 1, "id": str, "name": str, "created_at": ISO8601,
//        "provenance": {"kind": str, "source": str},
//        "slots": {"<slot>": {"sha256": str, "name": str, "meta_hex": str}}}
//
// `slots` is keyed by the DECIMAL slot number as a string (mirrors the backup
// `presets` map). Canonical iteration is ascending by int(key); JSON key order
// is irrelevant. Referenced blobs live in the SHARED blobs/ dir; a collection
// stores no blob bytes of its own.

import Foundation

let collectionSchema = 1
private let zeroMetaHex = String(repeating: "00", count: 9)  // valid all-zero meta

// --------------------------------------------------------------- provenance

public enum ProvenanceKind: String, Sendable, Codable, Equatable {
    case deviceSnapshot = "device_snapshot"
    case importedBank   = "imported_bank"
    case manual

    /// Parse a file value. Unknown -> .manual (forward compatibility).
    public static func fromString(_ s: String) -> ProvenanceKind {
        ProvenanceKind(rawValue: s) ?? .manual
    }
}

public struct Provenance: Sendable, Equatable {
    public let kind: ProvenanceKind
    public let source: String            // filename / snapshot takenAt / ""

    public init(kind: ProvenanceKind, source: String = "") {
        self.kind = kind
        self.source = source
    }
}

public struct PresetCollection: Sendable, Equatable, Identifiable {
    public let id: String                // uuid4 hex, minted at creation
    public let name: String
    public let createdAt: String         // ISO 8601, local
    public let provenance: Provenance
    public let slots: [Int: PresetRef]   // slot -> ref; iterate slots.keys.sorted()

    public init(id: String, name: String, createdAt: String,
                provenance: Provenance, slots: [Int: PresetRef]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.provenance = provenance
        self.slots = slots
    }

    /// Mint a fresh collection (uuid4 hex id, local ISO createdAt).
    public static func new(name: String, provenance: Provenance,
                           slots: [Int: PresetRef]) -> PresetCollection {
        PresetCollection(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            name: name, createdAt: isoNow(), provenance: provenance, slots: slots)
    }

    public func coveredSlots() -> [Int] { slots.keys.sorted() }

    /// Copy with a new name (rename keeps id, createdAt, provenance, slots).
    func renamed(_ name: String) -> PresetCollection {
        PresetCollection(id: id, name: name, createdAt: createdAt,
                         provenance: provenance, slots: slots)
    }
}

// ---------------------------------------------------------------- bank input

/// Core input value type for import-.mfprojz-as-Collection. The caller
/// (orchestrator/app) runs the verified tools/mbp_import.py parser (or a Swift
/// .mfprojz reader) and adapts each parsed preset to a BankItem, keeping the
/// core free of a Boost-archive dependency.
public struct BankItem: Sendable, Equatable {
    public let slot: Int?        // 0-based MF slot from the filename, or nil
    public let name: String
    public let meta: Data        // 9 bytes, or empty for an empty/Init-only slot
    public let blob: Data?       // 4672 bytes, or nil for an empty slot

    public init(slot: Int?, name: String, meta: Data, blob: Data?) {
        self.slot = slot
        self.name = name
        self.meta = meta
        self.blob = blob
    }
}

// ------------------------------------------------------------------- codec

enum CollectionCodec {
    static func toJSON(_ coll: PresetCollection) -> [String: Any] {
        var slotsOut: [String: Any] = [:]
        for slot in coll.slots.keys.sorted() {
            let ref = coll.slots[slot]!
            slotsOut[String(slot)] = ["sha256": ref.sha256, "name": ref.name,
                                      "meta_hex": ref.metaHex]
        }
        return [
            "schema": collectionSchema,
            "id": coll.id,
            "name": coll.name,
            "created_at": coll.createdAt,
            "provenance": ["kind": coll.provenance.kind.rawValue,
                           "source": coll.provenance.source],
            "slots": slotsOut,
        ]
    }

    /// Parse a collection dictionary. An unparseable or schema != 1 document
    /// throws .libraryCorrupt(path:, detail:).
    static func fromJSON(_ d: [String: Any], path: String) throws -> PresetCollection {
        guard (d["schema"] as? NSNumber)?.intValue == collectionSchema else {
            throw FreakError.libraryCorrupt(
                path: path, detail: "unsupported schema: \(d["schema"] ?? "nil")")
        }
        guard let id = d["id"] as? String, let name = d["name"] as? String else {
            throw FreakError.libraryCorrupt(path: path, detail: "bad collection: missing id/name")
        }
        let provD = d["provenance"] as? [String: Any] ?? [:]
        let provenance = Provenance(
            kind: ProvenanceKind.fromString(provD["kind"] as? String ?? "manual"),
            source: provD["source"] as? String ?? "")
        var slots: [Int: PresetRef] = [:]
        for (k, v) in (d["slots"] as? [String: Any] ?? [:]) {
            guard let slot = Int(k), let rd = v as? [String: Any],
                  let sha = rd["sha256"] as? String,
                  let rname = rd["name"] as? String,
                  let metaHex = rd["meta_hex"] as? String else {
                throw FreakError.libraryCorrupt(path: path, detail: "bad slot ref: \(k)")
            }
            slots[slot] = PresetRef(sha256: sha, name: rname, metaHex: metaHex)
        }
        return PresetCollection(id: id, name: name,
                                createdAt: d["created_at"] as? String ?? "",
                                provenance: provenance, slots: slots)
    }
}

// ---------------------------------------------------------- apply / switch plan

public enum PlanAction: String, Sendable, Equatable {
    case write                        // content OR name differs -> full verified write
    case skip = "skip"                // device already matches (sha AND name equal)
    case clear                        // not in collection; overwrite with clearWith
}

public struct ApplyOptions: Sendable {
    public enum Unlisted: Sendable, Equatable { case leave, clear }
    public var unlisted: Unlisted = .leave
    public var clearWith: PresetRef? = nil      // REQUIRED when unlisted == .clear
    public var secondsPerWrite: Double = 1.0    // ~0.5 s write + ~0.4 s verify

    public init() {}
}

public struct SlotPlan: Sendable, Equatable {
    public let slot: Int
    public let action: PlanAction
    public let incoming: PresetRef?    // ref to write (WRITE/CLEAR); nil for SKIP
    public let victim: SlotRecord?     // the device record being replaced (UI framing)

    public init(slot: Int, action: PlanAction, incoming: PresetRef?, victim: SlotRecord?) {
        self.slot = slot
        self.action = action
        self.incoming = incoming
        self.victim = victim
    }
}

public struct ApplyPlan: Sendable, Equatable {
    public let slots: [SlotPlan]       // one per device slot, ascending
    public let writeCount: Int
    public let clearCount: Int
    public let skipCount: Int
    public let totalSlots: Int         // == slots.count (the device's slot count)
    public let estimatedSeconds: Double

    public init(slots: [SlotPlan], writeCount: Int, clearCount: Int,
                skipCount: Int, totalSlots: Int, estimatedSeconds: Double) {
        self.slots = slots
        self.writeCount = writeCount
        self.clearCount = clearCount
        self.skipCount = skipCount
        self.totalSlots = totalSlots
        self.estimatedSeconds = estimatedSeconds
    }

    /// The changed slots only (WRITE + CLEAR) — what applyCollection writes.
    public func changes() -> [SlotPlan] {
        slots.filter { $0.action == .write || $0.action == .clear }
    }
}

/// Pure. Requires a FULL hashed snapshot: every slot 0..N-1 present and
/// snapshot.hasHashes, else it throws. If options.unlisted == .clear,
/// options.clearWith is required, else it throws. A collection slot beyond the
/// snapshot's range makes the plan undecidable and throws.
///
/// Per device record (ascending), ref = collection.slots[slot]:
///   ref present:
///     record.sha256 == ref.sha256 && record.name == ref.name -> SKIP_UNCHANGED
///     else                                                     -> WRITE (incoming=ref)
///   ref absent:
///     unlisted == .clear:
///       record already equals clearWith (sha AND name) -> SKIP_UNCHANGED
///       else                                           -> CLEAR (incoming=clearWith)
///     unlisted == .leave:                              -> SKIP_UNCHANGED
///
/// A name-only difference (sha equal, name differing) is a WRITE, folded into
/// the full verified write for the three-action model.
public func planApply(collection: PresetCollection, snapshot: DeviceSnapshot,
                      options: ApplyOptions = ApplyOptions()) throws -> ApplyPlan {
    let records = snapshot.records.sorted { $0.slot < $1.slot }
    let total = records.count
    let slotSet = Set(records.map(\.slot))
    guard slotSet == Set(0..<total) else {
        throw FreakError.protocolViolation(
            detail: "planApply requires a FULL snapshot: every slot 0..N-1 present")
    }
    guard snapshot.hasHashes else {
        throw FreakError.snapshotMissingHashes
    }
    if options.unlisted == .clear, options.clearWith == nil {
        throw FreakError.protocolViolation(
            detail: "unlisted == .clear requires options.clearWith")
    }
    if let maxSlot = collection.slots.keys.max(), maxSlot >= total {
        throw FreakError.protocolViolation(
            detail: "collection references slot \(maxSlot) beyond the "
                + "snapshot's \(total) slots")
    }

    var plans: [SlotPlan] = []
    var writeCount = 0, clearCount = 0, skipCount = 0
    for r in records {
        if let ref = collection.slots[r.slot] {
            if r.sha256 == ref.sha256 && r.name == ref.name {
                plans.append(SlotPlan(slot: r.slot, action: .skip, incoming: nil, victim: nil))
                skipCount += 1
            } else {
                plans.append(SlotPlan(slot: r.slot, action: .write, incoming: ref, victim: r))
                writeCount += 1
            }
        } else if options.unlisted == .clear {
            let cw = options.clearWith!
            if r.sha256 == cw.sha256 && r.name == cw.name {
                plans.append(SlotPlan(slot: r.slot, action: .skip, incoming: nil, victim: nil))
                skipCount += 1
            } else {
                plans.append(SlotPlan(slot: r.slot, action: .clear, incoming: cw, victim: r))
                clearCount += 1
            }
        } else {   // leave
            plans.append(SlotPlan(slot: r.slot, action: .skip, incoming: nil, victim: nil))
            skipCount += 1
        }
    }

    let estimated = roundTo(Double(writeCount + clearCount) * options.secondsPerWrite,
                            places: 1)
    return ApplyPlan(slots: plans, writeCount: writeCount, clearCount: clearCount,
                     skipCount: skipCount, totalSlots: total, estimatedSeconds: estimated)
}
