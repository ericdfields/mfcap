// SyncModel.swift — the diff state machine (UX §17, §18.2).
//
// Sync compares the device against ONE BASELINE the user chose: a collection
// — a named arrangement they saved or imported. The library is a flat catalog
// of every patch owned; it does not describe where things should sit on the
// device, so it is never a baseline (diffing against it merged all 17 packs
// into one incoherent mash and reported hundreds of phantom differences).
//
// The diff computes; only explicit user actions write. This model owns the
// state machine (needsBaseline → needsSnapshot → comparing → ready/failed)
// and the filter set. Execution goes through AppModel's queue after
// confirmation — never from here; the write half of "how does my device
// differ from this collection" is the core's planApply, surfaced by
// CollectionApplyPlanSheet.

import Foundation
import FreakCore

@MainActor @Observable
final class SyncModel {
    enum State: Equatable {
        case needsBaseline
        case needsSnapshot
        case comparing
        case ready
        case failed(String)
    }

    struct Provenance: Equatable {
        let date: Date?
        let backupStamp: String?

        /// "device read 12 min ago (backup 2026-09-01-143205)"
        var line: String {
            var out = "device read "
            out += date.map { Format.relativeAge($0) } ?? "at an unknown time"
            if let backupStamp { out += " (backup \(backupStamp))" }
            return out
        }

        var isStale: Bool {
            guard let date else { return true }
            return Date().timeIntervalSince(date) > 24 * 3600
        }
    }

    private(set) var state: State = .needsBaseline
    private(set) var diff: SyncDiff?
    /// The collection the device is being compared against.
    private(set) var baseline: PresetCollection?
    private(set) var provenance: Provenance?
    /// Default filter shows only real disagreements with the chosen baseline
    /// — including the name-only ones, which carry `.inSync` (the diff is
    /// content-based) but are still written by `planApply`. `.unlisted` joins
    /// `.inSync`/`.empty` as opt-in: a slot the collection says nothing about
    /// is information, not a task (UX §17).
    var visibleStatuses: Set<SlotStatus> = [.differs, .baselineOnly]

    /// Estimate copy for the CTA state.
    let readEstimateCopy =
        "To compare, the app reads every slot (~3½ minutes) and keeps it "
        + "as a backup."

    // ------------------------------------------------------------- driving

    func beginComparing() {
        state = .comparing
    }

    func failCompare(_ message: String) {
        state = .failed(message)
    }

    /// Recompute the pure diff from the cached hashed snapshot + the chosen
    /// baseline collection. No baseline → the picker state; no hashed
    /// snapshot → the honest read CTA.
    func recompute(snapshot: DeviceSnapshot?, baseline: PresetCollection?,
                   provenance: Provenance?) {
        self.baseline = baseline
        guard let baseline else {
            state = .needsBaseline
            diff = nil
            return
        }
        guard let snapshot else {
            if state != .comparing {
                state = .needsSnapshot
                diff = nil
            }
            return
        }
        do {
            let computed = try computeDiff(snapshot: snapshot,
                                           collection: baseline)
            diff = computed
            self.provenance = provenance
            state = .ready
        } catch let error as FreakError {
            if case .snapshotMissingHashes = error {
                state = .needsSnapshot
                diff = nil
            } else {
                state = .failed(error.userMessage)
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func reset() {
        state = baseline == nil ? .needsBaseline : .needsSnapshot
        diff = nil
        provenance = nil
    }

    // -------------------------------------------------------------- reads

    var counts: [SlotStatus: Int] {
        guard let diff else { return [:] }
        return Dictionary(grouping: diff.slots, by: \.status)
            .mapValues(\.count)
    }

    /// Shas equal, names differ. The core keeps `status` content-based (a
    /// name never changes it), but `planApply` WRITES such a slot, so the
    /// screen must treat it as a disagreement or it contradicts the plan.
    static func isNameOnly(_ row: SlotDiff) -> Bool {
        row.status == .inSync && row.nameDiffers
    }

    /// Exactly the rows `planApply` would write: the two disagreeing statuses
    /// plus the name-only ones. This is the invariant the core's docstring
    /// claims ("the read-only diff and the write plan can never disagree") —
    /// it has to hold at the UI level too.
    static func isActionable(_ row: SlotDiff) -> Bool {
        row.status == .differs || row.status == .baselineOnly
            || isNameOnly(row)
    }

    var actionableRows: [SlotDiff] {
        diff?.slots.filter(Self.isActionable) ?? []
    }

    private var nameOnlyCount: Int {
        diff?.slots.filter(Self.isNameOnly).count ?? 0
    }

    /// A name-only row rides the `.differs` chip, not the opt-in `.inSync`
    /// one: it is a real disagreement with the baseline, and hiding it behind
    /// a filter the user must discover is how the screen came to show an
    /// empty list while Apply offered a write.
    var visibleRows: [SlotDiff] {
        guard let diff else { return [] }
        return diff.slots.filter { row in
            Self.isNameOnly(row) ? visibleStatuses.contains(.differs)
                                 : visibleStatuses.contains(row.status)
        }
    }

    /// The count a filter chip shows — equal to the number of rows that chip
    /// actually reveals, so the bar still totals every read slot.
    func filterCount(_ status: SlotStatus) -> Int {
        let raw = counts[status] ?? 0
        switch status {
        case .differs: return raw + nameOnlyCount
        case .inSync:  return raw - nameOnlyCount
        default:       return raw
        }
    }

    func row(for slot: SlotID) -> SlotDiff? {
        diff?.slots.first { $0.slot == slot.raw }
    }

    /// Per-slot badges for the browser rows (only while a diff exists). Only
    /// the three statuses that mean something about the chosen collection —
    /// mirroring `.unlisted`/`.empty` would tattoo 480 grey chips onto the
    /// browser for slots the collection never mentions.
    var badges: [Int: SlotStatus] {
        guard let diff else { return [:] }
        var out: [Int: SlotStatus] = [:]
        for row in diff.slots
        where [.inSync, .differs, .baselineOnly].contains(row.status) {
            out[row.slot] = row.status
        }
        return out
    }

    /// Content-keyed sync hints for library rows: the catalog has no slot
    /// opinion, so an entry's relationship to the device is found by its
    /// bytes, not by a slot claim.
    var statusBySha: [String: SlotStatus] {
        guard let diff else { return [:] }
        var out: [String: SlotStatus] = [:]
        for row in diff.slots {
            guard let sha = row.baseline?.sha256 else { continue }
            // in-sync wins over any other verdict for the same bytes
            if out[sha] == .inSync { continue }
            out[sha] = row.status
        }
        return out
    }

    /// "Device matches 'Ambient Peaks' — 32 of 32 slots in sync.
    ///  480 slots aren't part of this collection."
    var allInSyncSummary: String? {
        guard let diff, let baseline else { return nil }
        // A name-only row is actionable (planApply writes it), so it must
        // suppress the all-clear — otherwise the screen says "Device matches"
        // while the toolbar's Apply offers a write.
        guard actionableRows.isEmpty else { return nil }
        let inSync = filterCount(.inSync)
        // `diff.slots` covers only the slots the snapshot READ, so the
        // baseline slots that went unread are not in it and must not be
        // subtracted — they are reported separately two lines below.
        let coveredBaseline = baseline.slots.count
            - diff.unreadBaselineSlots.count
        let outside = diff.slots.count - coveredBaseline
        var out = "Device matches '\(baseline.name)' — \(inSync) of "
            + "\(baseline.slots.count) slots in sync."
        if outside > 0 {
            out += " \(outside) slot\(outside == 1 ? "" : "s") "
                + "\(outside == 1 ? "isn't" : "aren't") part of this collection."
        }
        if !diff.unreadBaselineSlots.isEmpty {
            let n = diff.unreadBaselineSlots.count
            out += " \(n) slot\(n == 1 ? "" : "s") this collection defines "
                + "\(n == 1 ? "wasn't" : "weren't") read."
        }
        return out
    }
}
