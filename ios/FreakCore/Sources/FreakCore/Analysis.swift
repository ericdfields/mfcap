// Analysis.swift — pure content-analysis functions (analysis.py). Accept
// SlotRecords from snapshots, backups, anywhere.
//
// Emptiness is a content judgement: the MicroFreak ships every unused slot
// as a factory Init preset with the name "Init", so a blank name never
// happens on a stock device and the string "Init" is never matched. A slot
// is expendable when its exact bytes occur at least duplicateThreshold
// times (3, not 2, so a user's own single duplicated preset is never
// chosen), or its successfully-read name is blank/whitespace-only (the
// phase-0 scratch rule). Unknown disqualifies its own rule: a record whose
// sha256 is nil (content unread) can never satisfy the duplicate rule, and
// a record whose name is nil — the name read FAILED, not a blank slot —
// can never satisfy the blank-name rule. The rules stay independent: a
// name-read-failed slot whose blob IS mass-duplicated is still expendable,
// because the content judgement doesn't need the name.

import Foundation

public enum Analysis {
    /// How many slots hold each blob hash. Records without a hash are
    /// skipped.
    public static func shaCensus(_ records: [SlotRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            if let sha = r.sha256 {
                counts[sha, default: 0] += 1
            }
        }
        return counts
    }

    /// Slots whose content is expendable: a successfully-read blank name,
    /// OR sha256 occurring >= threshold times. Never a name == "Init"
    /// string match. Unknown is never expendable.
    public static func findExpendable(_ records: [SlotRecord],
                                      threshold: Int = FreakProtocol.duplicateThreshold)
                                      -> Set<Int> {
        let counts = shaCensus(records)
        var out: Set<Int> = []
        for r in records {
            guard let sha = r.sha256 else {
                continue
            }
            if let name = r.name,
               name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.insert(r.slot)
            } else if counts[sha, default: 0] >= threshold {
                out.insert(r.slot)
            }
        }
        return out
    }

    /// The safest slot to write into: the highest-numbered expendable slot
    /// >= preferFrom, else the highest expendable slot overall; nil if
    /// nothing qualifies (the caller asks the human). Preserves the proven
    /// mfcap.verify.pick_scratch_slot semantics exactly.
    public static func pickScratchSlot(_ records: [SlotRecord],
                                      preferFrom: Int = 500,
                                      exclude: Set<Int> = []) -> Int? {
        let expendable = findExpendable(records)
        for floor in [preferFrom, 0] {
            let picks = records.map(\.slot).filter {
                $0 >= floor && !exclude.contains($0) && expendable.contains($0)
            }
            if let best = picks.max() {
                return best
            }
        }
        return nil
    }
}
