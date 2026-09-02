// Sync.swift — pure two-way diff between a DeviceSnapshot and a BASELINE
// arrangement (port of sync.py).
//
// A baseline is a `[Int: PresetRef]` map — normally a PresetCollection's
// `slots`. It answers exactly one question: how does the device differ from
// this named arrangement?
//
// The library is deliberately NOT a baseline. It is a flat catalog of unique
// patches and carries no slot opinion of its own (a `LibraryEntry.slot` is a
// deliberate user pin, not an arrangement), so diffing a device against the
// whole library merges every imported bank into one incoherent mash. Compare
// against a collection the user chose instead.
//
// Deterministic, no baseline state, computes and never writes. Executing a
// diff is the app composing write / add calls per row; the core never
// auto-writes from a diff.
//
// This file is the SINGLE definition of device-vs-collection difference:
// `planApply` (Collections.swift) is this same decision table plus the
// unlisted policy and write bookkeeping, so the Sync screen and Apply can
// never disagree.

import Foundation

public enum SlotStatus: String, Sendable, CaseIterable {
    case inSync = "in_sync"        // baseline ref's sha == device sha
    case unlisted = "unlisted"     // non-expendable on device, baseline silent
    case baselineOnly = "missing"  // baseline places a preset, device slot expendable
    case differs = "changed"       // both real, shas differ
    case empty = "empty"           // device slot expendable, baseline silent
}

public struct SlotDiff: Sendable, Equatable {
    public let slot: Int
    public let status: SlotStatus
    public let device: SlotRecord?
    /// What the chosen baseline places here — nil when it says nothing.
    public let baseline: PresetRef?
    /// Shas equal, names differ. Never changes the status (the diff is
    /// content-based) but it does drive `planApply` to WRITE.
    public let nameDiffers: Bool

    public init(slot: Int, status: SlotStatus, device: SlotRecord?,
                baseline: PresetRef?, nameDiffers: Bool = false) {
        self.slot = slot
        self.status = status
        self.device = device
        self.baseline = baseline
        self.nameDiffers = nameDiffers
    }
}

public struct SyncDiff: Sendable, Equatable {
    public let slots: [SlotDiff]                // one per snapshot record, ascending
    /// Baseline slots the snapshot never covered — the honest "we don't know".
    public let unreadBaselineSlots: [Int]

    public init(slots: [SlotDiff], unreadBaselineSlots: [Int] = []) {
        self.slots = slots
        self.unreadBaselineSlots = unreadBaselineSlots
    }

    public func byStatus(_ status: SlotStatus) -> [SlotDiff] {
        slots.filter { $0.status == status }
    }
}

/// Pure and deterministic; computes and never writes. Every considered
/// record must carry a sha256 — else .snapshotMissingHashes (refusing beats
/// guessing). Per record, with ex = slot in findExpendable(records,
/// threshold:) and b = baseline[slot]:
/// no b && ex -> .empty; no b -> .unlisted; sha == b.sha256 -> .inSync;
/// ex -> .baselineOnly; else -> .differs.
///
/// A slot the baseline says nothing about can only land in .unlisted or
/// .empty: both mean "this collection has no opinion here", neither is
/// actionable, and neither is `missing`.
public func computeDiff(snapshot: DeviceSnapshot,
                        baseline: [Int: PresetRef],
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff {
    let records = snapshot.records.sorted { $0.slot < $1.slot }
    guard records.allSatisfy({ $0.sha256 != nil }) else {
        throw FreakError.snapshotMissingHashes
    }
    let expendable = Analysis.findExpendable(records, threshold: threshold)
    var out: [SlotDiff] = []
    for r in records {
        let b = baseline[r.slot]
        let ex = expendable.contains(r.slot)
        let status: SlotStatus
        if b == nil {
            status = ex ? .empty : .unlisted
        } else if b!.sha256 == r.sha256 {
            status = .inSync
        } else if ex {
            status = .baselineOnly
        } else {
            status = .differs
        }
        out.append(SlotDiff(slot: r.slot, status: status, device: r,
                            baseline: b,
                            nameDiffers: b != nil && r.name != b!.name))
    }
    let read = Set(records.map(\.slot))
    let unread = baseline.keys.filter { !read.contains($0) }.sorted()
    return SyncDiff(slots: out, unreadBaselineSlots: unread)
}

/// Convenience: computeDiff(snapshot:, baseline: collection.slots, threshold:).
public func computeDiff(snapshot: DeviceSnapshot,
                        collection: PresetCollection,
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff {
    try computeDiff(snapshot: snapshot, baseline: collection.slots,
                    threshold: threshold)
}
