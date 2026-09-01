// Sync.swift — pure two-way diff between a DeviceSnapshot and a library
// slot map (port of sync.py).
//
// Deterministic, no baseline state, computes and never writes. Executing a
// diff is the app composing write / add calls per row; the core never
// auto-writes from a diff.

import Foundation

public enum SlotStatus: String, Sendable, CaseIterable {
    case inSync = "in_sync"       // assigned entry's sha == device sha
    case deviceOnly = "added"     // non-expendable on device, no assigned entry
    case libraryOnly = "missing"  // entry assigned, device slot expendable
    case differs = "changed"      // both real, shas differ
    case empty = "empty"          // device slot expendable, nothing assigned
}

public struct SlotDiff: Sendable, Equatable {
    public let slot: Int
    public let status: SlotStatus
    public let device: SlotRecord?
    public let library: LibraryEntry?

    public init(slot: Int, status: SlotStatus, device: SlotRecord?,
                library: LibraryEntry?) {
        self.slot = slot
        self.status = status
        self.device = device
        self.library = library
    }
}

public struct SyncDiff: Sendable, Equatable {
    public let slots: [SlotDiff]                    // one per snapshot record, ascending

    public init(slots: [SlotDiff]) {
        self.slots = slots
    }

    public func byStatus(_ status: SlotStatus) -> [SlotDiff] {
        slots.filter { $0.status == status }
    }
}

/// Pure and deterministic; computes and never writes. Every considered
/// record must carry a sha256 — else .snapshotMissingHashes (refusing beats
/// guessing). Per record, with ex = slot in findExpendable(records,
/// threshold:) and lib = slotMap[slot]:
/// no lib && ex -> .empty; no lib -> .deviceOnly; sha == lib.sha256 ->
/// .inSync; ex -> .libraryOnly; else -> .differs.
public func computeDiff(snapshot: DeviceSnapshot,
                        slotMap: [Int: LibraryEntry],
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff {
    let records = snapshot.records.sorted { $0.slot < $1.slot }
    guard records.allSatisfy({ $0.sha256 != nil }) else {
        throw FreakError.snapshotMissingHashes
    }
    let expendable = Analysis.findExpendable(records, threshold: threshold)
    var out: [SlotDiff] = []
    for r in records {
        let lib = slotMap[r.slot]
        let ex = expendable.contains(r.slot)
        let status: SlotStatus
        if lib == nil {
            status = ex ? .empty : .deviceOnly
        } else if lib!.sha256 == r.sha256 {
            status = .inSync
        } else if ex {
            status = .libraryOnly
        } else {
            status = .differs
        }
        out.append(SlotDiff(slot: r.slot, status: status, device: r, library: lib))
    }
    return SyncDiff(slots: out)
}

public extension Library {
    /// Convenience: computeDiff(snapshot:, slotMap: slotMap(), threshold:).
    func diff(against snapshot: DeviceSnapshot,
              threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff {
        try computeDiff(snapshot: snapshot, slotMap: slotMap(), threshold: threshold)
    }
}
