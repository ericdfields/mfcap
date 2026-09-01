// AnalysisTests.swift — shaCensus, findExpendable edges beyond the golden
// vectors, and the pickScratchSlot preference rules (test_analysis.py +
// test_scratch.py intent).

import Foundation
import Testing
@testable import FreakCore

@Suite("Analysis")
struct AnalysisTests {

    private func record(_ slot: Int, _ name: String?, _ sha: String?) -> SlotRecord {
        SlotRecord(slot: slot, name: name, sha256: sha, meta: nil, blob: nil)
    }

    @Test func shaCensusCountsAndSkipsNil() {
        let counts = Analysis.shaCensus([
            record(0, "A", "x"), record(1, "B", "x"), record(2, "C", "y"),
            record(3, nil, nil),
        ])
        #expect(counts == ["x": 2, "y": 1])
    }

    @Test func defaultThresholdIsThree() {
        #expect(FreakProtocol.duplicateThreshold == 3)
        let two = [record(0, "D", "d"), record(1, "D", "d"), record(2, "S", "s")]
        #expect(Analysis.findExpendable(two).isEmpty)
        let three = two + [record(3, "D", "d")]
        #expect(Analysis.findExpendable(three) == [0, 1, 3])
    }

    @Test func scratchPrefersHighSlots() {
        // expendables at 100 (blank name), 505/510/511 (duplicate content)
        let records = [
            record(100, "", "u1"),
            record(200, "Keeper", "u2"),
            record(505, "Init", "dup"), record(510, "Init", "dup"),
            record(511, "Init", "dup"),
        ]
        #expect(Analysis.pickScratchSlot(records) == 511)
        #expect(Analysis.pickScratchSlot(records, exclude: [511]) == 510)
        #expect(Analysis.pickScratchSlot(records, exclude: [505, 510, 511]) == 100,
                "fallback to the highest expendable below preferFrom")
        #expect(Analysis.pickScratchSlot(records, preferFrom: 506) == 511)
        #expect(Analysis.pickScratchSlot([record(0, "Keeper", "u")]) == nil,
                "nothing qualifies: the caller asks the human")
        #expect(Analysis.pickScratchSlot([]) == nil)
    }

    @Test func scratchNeverPicksUnknownOrUnique() {
        let records = [
            record(509, nil, "unique"),        // name read failed, unique content
            record(510, "Solo", nil),          // content unread
            record(511, "My Best Patch", "u"), // unique user preset
        ]
        #expect(Analysis.pickScratchSlot(records) == nil)
    }
}
