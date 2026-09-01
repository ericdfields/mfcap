// Analysis.swift — pure content-analysis functions over SlotRecords from
// anywhere (snapshot, backup). Port of analysis.py.
//
// Emptiness is a content judgement: the MicroFreak ships every unused slot
// as a factory Init preset with the name "Init", so a blank name never
// happens on a stock device and the string "Init" is never matched. Unknown
// disqualifies its own rule only: sha256 nil (content unread) can never
// satisfy the duplicate rule, and name nil (the name read FAILED — a
// swallowed timeout in snapshot — not a blank slot) can never satisfy the
// blank-name rule. The rules stay independent: a name-read-failed slot
// whose blob IS mass-duplicated is still expendable.

import Foundation

public enum Analysis {
    /// How many slots hold each blob hash; records without a hash are skipped.
    public static func shaCensus(_ records: [SlotRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            if let sha = r.sha256 {
                counts[sha, default: 0] += 1
            }
        }
        return counts
    }

    /// Expendable = successfully-read blank/whitespace name, OR sha256
    /// occurring >= threshold times among `records` (3, not 2, so a user's
    /// own single duplicated preset is never chosen). NEVER a name == "Init"
    /// match.
    public static func findExpendable(_ records: [SlotRecord],
                                      threshold: Int = Wire.duplicateThreshold) -> Set<Int> {
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

    /// The safest slot to write into: the highest expendable slot >=
    /// preferFrom, else the highest expendable overall, else nil (the caller
    /// asks the human). Exactly the proven phase-0
    /// mfcap.verify.pick_scratch_slot semantics.
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
