// SlotBrowserModel.swift — the 512-row device cache (UX §5, §18.2).
//
// Owns: per-row name load-state, sha, judgment, sync badge, flags
// (torn / verifyFailed / busy), names-as-of, search text, and snapshot
// apply + per-write patching. Judgment is ALWAYS the core's content
// judgment (Analysis.findExpendable) — never a name-string match; a slot
// is only ever dimmed by evidence (UX §1.4, §10). This model never touches
// the device: intents live on AppModel and results are applied here.

import Foundation
import FreakCore

/// The §10 semantic judgment roles, rendered identically everywhere.
enum SlotJudgment: Equatable, Sendable {
    case real
    case expendable(evidence: String)   // "identical to 268 other slots" / "blank name"
    case unjudged                       // content not read yet
    case unknown                        // name read failed

    var isExpendable: Bool {
        if case .expendable = self { return true }
        return false
    }
}

struct SlotCacheRow: Identifiable, Equatable {
    let slot: SlotID
    var name: String?            // nil until the names pass lands (or failed)
    var nameFailed = false
    var sha256: String?
    var meta: Data?
    var judgment: SlotJudgment = .unjudged
    var lastConfirmed: Date?
    var torn = false             // §14 torn-slot flag, until a verified write
    var verifyFailed = false     // §14 verify-failed badge, distinct from torn
    var busy = false             // a queued/running op targets this slot

    var id: Int { slot.raw }

    /// Row display name; "— read failed" is a placeholder, never "empty".
    var displayName: String {
        if nameFailed { return "— read failed" }
        return name ?? ""
    }

    var hasKnownName: Bool { name != nil && !nameFailed }

    /// Judgment line copy for the detail view (UX §7.3) — evidence is the copy.
    var judgmentCopy: String {
        switch judgment {
        case .real: return "Preset"
        case .expendable(let evidence): return "Empty — \(evidence)"
        case .unjudged: return "Unjudged — content not read yet"
        case .unknown: return "Unknown — name read failed"
        }
    }
}

@MainActor @Observable
final class SlotBrowserModel {
    private(set) var rows: [SlotCacheRow] = SlotID.all.map {
        SlotCacheRow(slot: $0)
    }
    /// When the current names pass completed; nil = never read this session.
    private(set) var namesAsOf: Date?
    /// The last FULL hashed pass (all rows carry shas), for provenance lines.
    private(set) var hashedAsOf: Date?
    /// Provenance path of the backup that produced the hashed tier, if any.
    private(set) var hashedProvenance: String?
    /// True while the cache describes a device that is no longer connected.
    private(set) var stale = false

    var refreshingNames = false
    var namesError: String?
    /// Cache-only search over names and slot numbers. Never reads the device.
    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            recomputeFiltered()
        }
    }
    /// Per-slot sync badges, mirrored from SyncModel's current diff.
    private(set) var syncBadges: [Int: SlotStatus] = [:]

    // ------------------------------------------------------------ reading

    func record(_ slot: SlotID) -> SlotCacheRow? {
        guard rows.indices.contains(slot.raw) else { return nil }
        return rows[slot.raw]
    }

    /// Every row currently carries a sha — the diff precondition (UX §17).
    var hasHashedSnapshot: Bool {
        rows.allSatisfy { $0.sha256 != nil }
    }

    /// Judgments exist only while a hashed snapshot backs them (UX §10).
    var hasJudgments: Bool {
        rows.contains { $0.judgment != .unjudged && $0.judgment != .unknown }
    }

    /// Reconstruct core SlotRecords from the cache (diff, analysis, plans).
    func slotRecords() -> [SlotRecord] {
        rows.map {
            SlotRecord(slot: $0.slot.raw,
                       name: $0.nameFailed ? nil : $0.name,
                       sha256: $0.sha256,
                       meta: $0.meta,
                       blob: nil)
        }
    }

    /// A DeviceSnapshot equivalent of the fully hashed cache, or nil.
    func hashedSnapshot() -> DeviceSnapshot? {
        guard hasHashedSnapshot else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let taken = fmt.string(from: hashedAsOf ?? Date())
        return DeviceSnapshot(
            takenAt: taken,
            records: slotRecords(),
            timing: TimingReport(totalSeconds: 0, perSlotSeconds: 0,
                                 nameMsMedian: nil, dumpMsMedian: nil))
    }

    /// The core's scratch-slot suggestion for pickers (UX §8.1).
    func scratchSuggestion(excluding: Set<Int> = []) -> SlotID? {
        Analysis.pickScratchSlot(slotRecords(), preferFrom: 500,
                                 exclude: excluding).map(SlotID.init)
    }

    // -------------------------------------------------- derived, stored once
    //
    // These were computed properties read straight from the slot list's body:
    // `filteredSlots` mapped or filtered all 512 rows on EVERY access and the
    // list built a 512-element Set from it once per bank per body pass, while
    // `bankSummary` did 128 lookups plus two filters per bank per pass — with
    // one body pass per streamed name during the ~2 s names pass. They are now
    // recomputed only when their inputs actually change, and reassigned only
    // when the value actually differs (Observation has no equality check of
    // its own, so an identical reassignment still invalidates every observer).

    /// The slots matching the current search, ascending.
    private(set) var filteredSlots: [SlotID] = SlotID.all
    /// The same set already split by bank — what the list renders per section.
    private(set) var filteredByBank: [[SlotID]] =
        (0..<SlotID.Layout.banks).map { SlotID.bankSlots($0) }
    /// "97 presets · 31 empty" per bank once judged; nil before.
    private(set) var bankSummaries: [String?] =
        Array(repeating: nil, count: SlotID.Layout.banks)

    /// "97 presets · 31 empty" once judged; nil before.
    func bankSummary(_ bank: Int) -> String? {
        bankSummaries.indices.contains(bank) ? bankSummaries[bank] : nil
    }

    /// Cache-only filtering: name substring + slot number. Never reads.
    private func recomputeFiltered() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matches: [SlotID]
        if query.isEmpty {
            matches = SlotID.all
        } else {
            let lowered = query.lowercased()
            matches = rows.filter { row in
                if let name = row.name, name.lowercased().contains(lowered) {
                    return true
                }
                return String(row.slot.display).contains(query)
            }.map(\.slot)
        }
        guard matches != filteredSlots else { return }
        filteredSlots = matches
        var byBank = Array(repeating: [SlotID](),
                           count: SlotID.Layout.banks)
        for slot in matches where byBank.indices.contains(slot.bank) {
            byBank[slot.bank].append(slot)
        }
        filteredByBank = byBank
    }

    private func recomputeBankSummaries() {
        guard hasJudgments else {
            let blank = [String?](repeating: nil, count: SlotID.Layout.banks)
            if bankSummaries != blank { bankSummaries = blank }
            return
        }
        var presets = [Int](repeating: 0, count: SlotID.Layout.banks)
        var empty = [Int](repeating: 0, count: SlotID.Layout.banks)
        for row in rows {
            let bank = row.slot.bank
            guard presets.indices.contains(bank) else { continue }
            if row.judgment.isExpendable {
                empty[bank] += 1
            } else if row.judgment == .real {
                presets[bank] += 1
            }
        }
        let summaries: [String?] = (0..<SlotID.Layout.banks).map {
            "\(presets[$0]) presets · \(empty[$0]) empty"
        }
        if bankSummaries != summaries { bankSummaries = summaries }
    }

    // ------------------------------------------------------------ applying

    /// Names stream in during the names pass (~2 s shimmer, UX §5).
    func applyStreamedName(_ slot: SlotID, name: String) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].name = name
        rows[slot.raw].nameFailed = false
        rows[slot.raw].lastConfirmed = Date()
        // Only a live search can change under a streaming name; without one
        // the filter is every slot and re-deriving it 512 times would be the
        // per-render cost this stored form exists to remove.
        if !searchText.isEmpty { recomputeFiltered() }
    }

    /// A completed snapshot (names-only or hashed) lands whole.
    /// Names-only rule: a changed name drops that row's stale sha; an
    /// unchanged name keeps the hashed tier (provenance headers say its age).
    func applySnapshot(_ snapshot: DeviceSnapshot, hashed: Bool,
                       provenance: String?) {
        let now = Date()
        for record in snapshot.records {
            guard rows.indices.contains(record.slot) else { continue }
            var row = rows[record.slot]
            if let name = record.name {
                if row.name != nil && row.name != name && record.sha256 == nil {
                    row.sha256 = nil        // name changed under us — sha stale
                    row.meta = record.meta
                }
                row.name = name
                row.nameFailed = false
            } else {
                row.nameFailed = true       // read FAILED — unknown, never empty
            }
            if let meta = record.meta { row.meta = meta }
            if let sha = record.sha256 { row.sha256 = sha }
            row.lastConfirmed = now
            rows[record.slot] = row
        }
        namesAsOf = now
        if hashed {
            hashedAsOf = now
            hashedProvenance = provenance
        }
        stale = false
        recomputeFiltered()
        recomputeJudgments()
    }

    /// A single ~400 ms slot read (the lazy-blob trigger, UX §7.5).
    func applyRead(_ slot: SlotID, preset: Preset) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].name = preset.name
        rows[slot.raw].nameFailed = false
        rows[slot.raw].sha256 = preset.sha256
        rows[slot.raw].meta = preset.meta
        rows[slot.raw].lastConfirmed = Date()
        recomputeFiltered()
        recomputeJudgments()
    }

    /// Verified write → patch the cache in place, zero re-reads (UX §4).
    func applyVerifiedWrite(_ slot: SlotID, name: String, sha256: String,
                            meta: Data?) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].name = name
        rows[slot.raw].nameFailed = false
        rows[slot.raw].sha256 = sha256
        if let meta { rows[slot.raw].meta = meta }
        rows[slot.raw].lastConfirmed = Date()
        rows[slot.raw].torn = false
        rows[slot.raw].verifyFailed = false
        recomputeFiltered()
        recomputeJudgments()
    }

    /// Restore the hashed tier from a backup's records at launch/connect
    /// (UX §18.3), marked with the backup's age. Adopt a sha only where the
    /// cached name agrees (or is still unknown) — a mismatch means the slot
    /// changed since the backup.
    func adoptHashedTier(records: [SlotRecord], asOf: Date?,
                         provenance: String?) {
        for record in records {
            guard rows.indices.contains(record.slot),
                  let sha = record.sha256 else { continue }
            var row = rows[record.slot]
            guard row.sha256 == nil else { continue }
            guard row.name == nil || row.name == record.name else { continue }
            row.sha256 = sha
            if row.meta == nil { row.meta = record.meta }
            rows[record.slot] = row
        }
        if hasHashedSnapshot && hashedAsOf == nil {
            hashedAsOf = asOf
            hashedProvenance = provenance
        }
        recomputeJudgments()
    }

    /// Verified rename → patch the cached name only.
    func patchName(_ slot: SlotID, name: String) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].name = name
        rows[slot.raw].nameFailed = false
        rows[slot.raw].lastConfirmed = Date()
        recomputeFiltered()
        recomputeJudgments()
    }

    // -------------------------------------------------------------- flags

    func setBusy(_ slot: SlotID, _ busy: Bool) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].busy = busy
    }

    func setTorn(_ slot: SlotID) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].torn = true
    }

    func setVerifyFailed(_ slot: SlotID) {
        guard rows.indices.contains(slot.raw) else { return }
        rows[slot.raw].verifyFailed = true
    }

    func applySyncBadges(_ badges: [Int: SlotStatus]) {
        syncBadges = badges
    }

    /// Disconnect: cache kept, desaturated, honestly aged (UX §5).
    func markStale() {
        stale = true
    }

    /// Identity switch: the cache and judgments are dropped (UX §4, §11).
    func reset() {
        rows = SlotID.all.map { SlotCacheRow(slot: $0) }
        namesAsOf = nil
        hashedAsOf = nil
        hashedProvenance = nil
        stale = false
        namesError = nil
        syncBadges = [:]
        recomputeFiltered()
        recomputeJudgments()
    }

    // ---------------------------------------------------------- judgments

    /// The core's content judgment, applied to every row (UX §1.4):
    /// sha duplicated ≥ 3× among the read records, or a successfully-read
    /// blank name. "Init" as a string is never special. Rows without hashes
    /// stay unjudged; failed name reads are unknown.
    private func recomputeJudgments() {
        let records = slotRecords()
        let expendable = Analysis.findExpendable(records)
        let census = Analysis.shaCensus(records)
        for index in rows.indices {
            var row = rows[index]
            if row.nameFailed && row.sha256 == nil {
                row.judgment = .unknown
            } else if expendable.contains(row.slot.raw) {
                let blankName = (row.name?.trimmingCharacters(in: .whitespaces)
                    .isEmpty ?? false)
                if blankName {
                    row.judgment = .expendable(evidence: "blank name")
                } else if let sha = row.sha256, let count = census[sha],
                          count > 1 {
                    row.judgment = .expendable(
                        evidence: "identical to \(count - 1) other slots")
                } else {
                    row.judgment = .expendable(evidence: "judged empty")
                }
            } else if row.sha256 != nil {
                row.judgment = .real
            } else if row.nameFailed {
                row.judgment = .unknown
            } else {
                row.judgment = .unjudged
            }
            rows[index] = row
        }
        recomputeBankSummaries()
    }
}
