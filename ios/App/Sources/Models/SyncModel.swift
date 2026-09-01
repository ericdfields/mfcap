// SyncModel.swift — the diff state machine (UX §17, §18.2).
//
// The diff computes; only explicit user actions write. This model owns the
// state machine (needsSnapshot → comparing → ready/failed), the filter set,
// and bulk-plan assembly. Execution goes through AppModel's queue after
// confirmation — never from here.

import Foundation
import FreakCore

/// The Apply… sheet's working set (UX §17 bulk apply). Conflicts are never
/// pre-resolved: each `changed` row requires an explicit choice, default skip.
struct BulkApplyPlan: Identifiable {
    enum ConflictChoice: String, CaseIterable, Identifiable {
        case push, pull, skip
        var id: String { rawValue }
        var title: String {
            switch self {
            case .push: return "Push"
            case .pull: return "Pull"
            case .skip: return "Skip"
            }
        }
    }

    let id = UUID()
    let imports: [SlotDiff]                  // added → import (pre-checked)
    let sends: [SlotDiff]                    // missing → send (pre-checked)
    let conflicts: [SlotDiff]                // changed → explicit choice
}

@MainActor @Observable
final class SyncModel {
    enum State: Equatable {
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

    private(set) var state: State = .needsSnapshot
    private(set) var diff: SyncDiff?
    private(set) var provenance: Provenance?
    /// Default filter shows everything except in-sync and empty (UX §17).
    var visibleStatuses: Set<SlotStatus> = [.deviceOnly, .libraryOnly, .differs]

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

    /// Recompute the pure diff from the cached hashed snapshot + library.
    /// No hashed snapshot → the honest CTA state.
    func recompute(snapshot: DeviceSnapshot?, library: Library?,
                   provenance: Provenance?) async {
        guard let snapshot, let library else {
            if state != .comparing {
                state = .needsSnapshot
                diff = nil
            }
            return
        }
        do {
            let slotMap = await library.slotMap()
            let computed = try computeDiff(snapshot: snapshot, slotMap: slotMap)
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
        state = .needsSnapshot
        diff = nil
        provenance = nil
    }

    // -------------------------------------------------------------- reads

    var counts: [SlotStatus: Int] {
        guard let diff else { return [:] }
        return Dictionary(grouping: diff.slots, by: \.status)
            .mapValues(\.count)
    }

    var visibleRows: [SlotDiff] {
        guard let diff else { return [] }
        return diff.slots.filter { visibleStatuses.contains($0.status) }
    }

    func row(for slot: SlotID) -> SlotDiff? {
        diff?.slots.first { $0.slot == slot.raw }
    }

    /// Per-slot badges for the browser rows (only while a diff exists).
    var badges: [Int: SlotStatus] {
        guard let diff else { return [:] }
        return Dictionary(uniqueKeysWithValues: diff.slots.map {
            ($0.slot, $0.status)
        })
    }

    /// "Device and library match — 223 in sync, 269 empty"
    var allInSyncSummary: String? {
        guard let diff else { return nil }
        let actionable = diff.slots.filter {
            $0.status == .deviceOnly || $0.status == .libraryOnly
                || $0.status == .differs
        }
        guard actionable.isEmpty else { return nil }
        let inSync = counts[.inSync] ?? 0
        let empty = counts[.empty] ?? 0
        return "Device and library match — \(inSync) in sync, \(empty) empty"
    }

    // ------------------------------------------------------- plan building

    /// Assemble the Apply… sheet's sections from the current diff.
    func buildBulkPlan() -> BulkApplyPlan? {
        guard let diff else { return nil }
        return BulkApplyPlan(imports: diff.byStatus(.deviceOnly),
                             sends: diff.byStatus(.libraryOnly),
                             conflicts: diff.byStatus(.differs))
    }
}
