// Sync.swift — pure two-way diff between a DeviceSnapshot and a Library
// (sync.py).
//
// Deterministic, no baseline state, computes and never writes. Executing a
// diff is the caller composing MicroFreakDevice.write / Library.add calls
// per row; the core never auto-writes from a diff. `diff` is synchronous
// and runs wherever the Library lives.

import Foundation

public enum SlotStatus: String, Sendable, CaseIterable {
    case inSync = "in_sync"        // assigned entry's sha == device sha
    case deviceOnly = "added"      // non-expendable on device, no assigned entry
    case libraryOnly = "missing"   // entry assigned, device slot expendable
    case differs = "changed"       // entry assigned, device non-expendable, shas differ
    case empty = "empty"           // device slot expendable, no assigned entry
}

public struct SlotDiff: Sendable {
    public let slot: Int
    public let status: SlotStatus
    public let device: SlotRecord         // always the snapshot record (tightened; §10)
    public let library: LibraryEntry?

    public init(slot: Int, status: SlotStatus, device: SlotRecord,
                library: LibraryEntry?) {
        self.slot = slot
        self.status = status
        self.device = device
        self.library = library
    }
}

public struct SyncDiff: Sendable {
    public let slots: [SlotDiff]          // one per snapshot record, ascending

    public init(slots: [SlotDiff]) {
        self.slots = slots
    }

    public func by(status: SlotStatus) -> [SlotDiff] {
        slots.filter { $0.status == status }
    }
}

/// Per snapshot record: ex = expendable on device, lib = entry assigned to
/// that slot. Then: no lib and ex -> .empty; no lib, not ex -> .deviceOnly;
/// lib and shas equal -> .inSync; lib and ex -> .libraryOnly; else
/// .differs. Requires every considered record to carry sha256 — refusing
/// beats guessing.
public func diff(_ snapshot: DeviceSnapshot, _ library: Library,
                 threshold: Int = FreakProtocol.duplicateThreshold) throws -> SyncDiff {
    let records = snapshot.records.sorted { $0.slot < $1.slot }
    guard records.allSatisfy({ $0.sha256 != nil }) else {
        throw FreakError.snapshotMissingHashes
    }
    let expendable = Analysis.findExpendable(records, threshold: threshold)
    let slotMap = library.slotMap()
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
