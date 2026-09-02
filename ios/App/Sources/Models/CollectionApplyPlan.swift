// CollectionApplyPlan.swift — the app-side presentation wrapper around the
// core `ApplyPlan` (UX addendum §27; data-model spec §6.3).
//
// The core owns the decision (`planApply` → `ApplyPlan`: per-slot WRITE /
// SKIP / CLEAR, counts, estimate) and the execution (`applyCollection`). The
// app never re-derives any of that. This wrapper carries just what the
// pre-flight sheet renders: the summary numbers straight off `ApplyPlan`, an
// `OverwritePlan` for the §9 victim previews + BatchRunState + confirm label,
// the pre-resolved bytes for the changed slots (so the verified-write
// resolver is a pure lookup, never a mid-apply actor hop), and the list of
// slots whose bytes aren't on disk (pre-disabled, excluded from the count).

import Foundation
import FreakCore

struct CollectionApplyPlan: Identifiable {
    let id = UUID()
    let collectionID: String
    let collectionName: String
    /// The pure core plan — the source of truth for counts + estimate.
    let plan: ApplyPlan
    /// App framing: items are the WRITE/CLEAR slots with victim previews.
    let overwrite: OverwritePlan
    /// Bytes for each changed ref, keyed by `refKey` — a pure resolver map.
    let resolved: [String: Preset]
    /// Changed slots whose bytes could not be resolved on disk (pre-disabled).
    let unresolvableSlots: [Int]
    let isPractice: Bool

    /// The changed-slot count the pre-flight and estimate reflect.
    var changeCount: Int { plan.writeCount + plan.clearCount }
    var writableCount: Int { changeCount - unresolvableSlots.count }

    /// "changes 41 of 512 slots: 41 writes, 471 unchanged · ~41 s"
    /// (UX addendum §27.2; data-model spec §6.3). The seconds figure is the
    /// core `ApplyPlan.estimatedSeconds` — ~1 s/write (≈0.5 s write + ≈0.4 s
    /// verify), the honest cost of a VERIFIED switch, not a write-only rate.
    var summaryLine: String {
        let unchanged = plan.totalSlots - changeCount
        return "changes \(changeCount) of \(plan.totalSlots) slots: "
            + "\(changeCount) write\(changeCount == 1 ? "" : "s"), "
            + "\(unchanged) unchanged · "
            + "~\(Int(plan.estimatedSeconds.rounded())) s"
    }

    /// Stable key identifying the Preset a PresetRef resolves to (content +
    /// the exact name/meta written), so two refs sharing a blob but differing
    /// in name never collide.
    static func refKey(_ ref: PresetRef) -> String {
        "\(ref.sha256)|\(ref.name)|\(ref.metaHex)"
    }
}
