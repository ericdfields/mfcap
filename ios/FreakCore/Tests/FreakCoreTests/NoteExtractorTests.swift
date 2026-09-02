// NoteExtractorTests.swift — the extractor against the SHARED fixture.
//
// tests/fixtures/note_extraction.json is loaded from the repo checkout (via
// #filePath, the way App/Tests/MFProjzImportTests loads its fixture), NOT
// copied into the test bundle: it is the ONE file both cores read. Per
// docs/voice-notes.md §5.3 the fixture is the definition of correct — a
// disagreement between the Swift and Python extractors is a missing fixture
// case, never a judgement call — so a private Swift copy would defeat its only
// purpose.
//
// The rest of this suite pins what the fixture cannot see: the lexicon tables
// themselves (sizes, closure over Verdict.slug / Category.slug / the 18
// Arturia display strings, no cross-lexicon key collisions), the code-point
// spans and confidence tiers from the doc's worked examples, the tokenizer's
// two pinned offset rules, the locale gate, the segment-scope verdict rule and
// the empty-note gate.

import Foundation
import Testing
@testable import FreakCore

@Suite("NoteExtractor")
struct NoteExtractorTests {

    // ------------------------------------------------------------- fixture

    private struct FixtureCase {
        let id: String
        let transcript: String
        let verdict: String?
        let category: String?
        let tags: [String]
        let why: String
    }

    /// <repo>/tests/fixtures/note_extraction.json — four levels up from
    /// .../ios/FreakCore/Tests/FreakCoreTests/.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FreakCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // FreakCore
            .deletingLastPathComponent()          // ios
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("tests/fixtures/note_extraction.json")
    }

    private func fixtureCases() throws -> [FixtureCase] {
        let url = Self.fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("shared fixture missing at \(url.path)")
            return []
        }
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        guard let list = raw as? [[String: Any]] else {
            Issue.record("\(url.path): expected a top-level array of cases")
            return []
        }
        return list.map { c in
            let expected = c["expected"] as? [String: Any] ?? [:]
            return FixtureCase(
                id: c["id"] as? String ?? "<unnamed>",
                transcript: c["transcript"] as? String ?? "",
                verdict: expected["verdict"] as? String,
                category: expected["category"] as? String,
                tags: expected["tags"] as? [String] ?? [],
                why: c["why"] as? String ?? "")
        }
    }

    /// THE parity test. Every case in the shared fixture, verdict + category +
    /// tags (tags compared in first-appearance order, which §5 requires both
    /// cores to PRODUCE even though it permits set comparison).
    @Test func everyFixtureCasePasses() throws {
        let cases = try fixtureCases()
        #expect(cases.count >= 70, "the fixture lost cases: \(cases.count)")
        var ids = Set<String>()
        for c in cases {
            #expect(ids.insert(c.id).inserted, "duplicate fixture case id \(c.id)")
            let got = NoteExtractor.extract(c.transcript)
            #expect(got.verdict?.value == c.verdict,
                    "\(c.id): verdict — \(c.why)\n  in: \(c.transcript)")
            #expect(got.category?.value == c.category,
                    "\(c.id): category — \(c.why)\n  in: \(c.transcript)")
            #expect(got.tagValues == c.tags,
                    "\(c.id): tags — \(c.why)\n  in: \(c.transcript)")
        }
    }

    /// The fixture may only ever name values the closed lexicons can emit.
    @Test func fixtureExpectationsStayInsideTheClosedSets() throws {
        let verdicts = Set(Verdict.allCases.map(\.slug))
        let categories = Set(Category.allCases.map(\.slug))
        let characteristics = Set(NoteVocabulary.characteristics)
        for c in try fixtureCases() {
            if let v = c.verdict {
                #expect(verdicts.contains(v), "\(c.id): unknown verdict \(v)")
                #expect(v != Verdict.unrated.slug, "\(c.id): unrated is never proposed")
            }
            if let k = c.category {
                #expect(categories.contains(k), "\(c.id): unknown category \(k)")
                #expect(k != Category.uncategorized.slug,
                        "\(c.id): uncategorized is never proposed")
            }
            for t in c.tags {
                #expect(characteristics.contains(t), "\(c.id): unknown characteristic \(t)")
            }
        }
    }

    // -------------------------------------------------------- the tables

    /// Table sizes are pinned by the contract; a silent edit shows up here.
    @Test func lexiconTablesMatchTheContract() {
        let verdictKeyCount = NoteVocabulary.verdictKeys.values.map(\.count).reduce(0, +)
        let typeKeyCount = NoteVocabulary.typeKeys.values.map(\.count).reduce(0, +)
        let charKeyCount = NoteVocabulary.characteristicKeys.values.map(\.count).reduce(0, +)
        #expect(NoteVocabulary.verdictKeys.count == 4)
        #expect(verdictKeyCount == 65)
        #expect(NoteVocabulary.typeKeys.count == 12)
        #expect(typeKeyCount == 88)
        #expect(NoteVocabulary.characteristicKeys.count == 18)
        #expect(charKeyCount == 154)
        #expect(NoteVocabulary.carriers.count == 51)
        #expect(NoteVocabulary.contractions.count == 34)
        #expect(NoteVocabulary.negators.count == 15)
        #expect(NoteVocabulary.hedges.count == 16)
        // every key is unique across the three lexicons, so the §2.4 tie order
        // never actually has to break a tie
        #expect(NoteVocabulary.lexicon.count
                    == verdictKeyCount + typeKeyCount + charKeyCount)
    }

    /// The canonical values are exactly `Verdict.slug` minus unrated,
    /// `Category.slug` minus uncategorized, and the 18 Arturia display strings.
    @Test func canonicalValuesAreTheClosedSets() {
        #expect(Set(NoteVocabulary.verdictKeys.keys)
                    == Set(Verdict.allCases.map(\.slug)).subtracting([Verdict.unrated.slug]))
        #expect(Set(NoteVocabulary.typeKeys.keys)
                    == Set(Category.allCases.map(\.slug))
                        .subtracting([Category.uncategorized.slug]))
        #expect(NoteVocabulary.characteristics == [
            "Acid", "Aggressive", "Ambient", "Bizarre", "Bright", "Complex",
            "Dark", "Digital", "Ensemble", "Funky", "Hard", "Long", "Noise",
            "Quiet", "Short", "Simple", "Soft", "Soundtrack",
        ])
    }

    /// The scan only ever looks 1, 2 or 3 tokens ahead; a longer key would be
    /// unreachable dead weight.
    @Test func noKeyIsLongerThanThreeTokens() {
        for key in NoteVocabulary.lexicon.keys {
            #expect(key.split(separator: " ").count <= NoteVocabulary.maxKeyTokens,
                    "lexicon key too long: \(key)")
        }
        for carrier in NoteVocabulary.carriers {
            #expect(carrier.split(separator: " ").count <= NoteVocabulary.maxKeyTokens,
                    "carrier too long: \(carrier)")
        }
        // and the keys are already normalized: lowercase alphanumerics + space
        for key in Set(NoteVocabulary.lexicon.keys).union(NoteVocabulary.carriers) {
            #expect(NoteExtractor.tokenize(key).map(\.text)
                        == key.split(separator: " ").map(String.init),
                    "key is not already normalized: \(key)")
        }
    }

    // ------------------------------------------------- spans + confidence

    /// The worked example in docs/voice-notes.md §1.4 / §1.7. These spans and
    /// confidences are in the pinned document, so they are asserted literally.
    @Test func workedExampleSpansAndConfidences() {
        let text = "nice dark pad, bit too noisy, keep"
        let p = NoteExtractor.extract(text)

        let verdict = p.verdict
        #expect(verdict?.value == "keep")
        #expect(verdict?.spanStart == 30 && verdict?.spanEnd == 34)
        #expect(verdict?.confidence == 0.9)
        #expect(verdict?.span(in: text) == "keep")

        let category = p.category
        #expect(category?.value == "pad")
        // the comma is NOT part of the span: [10, 13), not [10, 14)
        #expect(category?.spanStart == 10 && category?.spanEnd == 13)
        #expect(category?.confidence == 0.9)
        #expect(category?.span(in: text) == "pad")

        #expect(p.tags.count == 2)
        #expect(p.tags.first?.value == "Dark")
        #expect(p.tags.first?.spanStart == 5 && p.tags.first?.spanEnd == 9)
        #expect(p.tags.first?.confidence == 0.9)
        #expect(p.tags.last?.value == "Noise")
        #expect(p.tags.last?.spanStart == 23 && p.tags.last?.spanEnd == 28)
        // "noisy" is a 1-token synonym, not the canonical value
        #expect(p.tags.last?.confidence == 0.7)
        #expect(p.tags.last?.span(in: text) == "noisy")

        // typed-note half of the same worked example
        let typed = NoteExtractor.extract("revisit with the filter opened up")
        #expect(typed.verdict?.value == "try_later")
        #expect(typed.verdict?.spanStart == 0 && typed.verdict?.spanEnd == 7)
        #expect(typed.verdict?.confidence == 0.7)
        #expect(typed.category == nil)
        #expect(typed.tags.isEmpty)
    }

    /// The three §2.8 tiers: exact 0.9, multi-token synonym 0.8, single-token
    /// synonym 0.7.
    @Test func confidenceTiers() {
        #expect(NoteExtractor.extract("dark").tags.first?.confidence == 0.9)
        #expect(NoteExtractor.extract("long release").tags.first?.confidence == 0.8)
        #expect(NoteExtractor.extract("murky").tags.first?.confidence == 0.7)
        #expect(NoteExtractor.extract("a keeper").verdict?.confidence == 0.8)
        #expect(NoteExtractor.extract("keep").verdict?.confidence == 0.9)
        #expect(NoteExtractor.extract("winner").verdict?.confidence == 0.7)
    }

    /// A tag's recorded span is its FIRST appearance, and tags stay unique.
    @Test func tagSpanIsTheFirstAppearance() {
        let p = NoteExtractor.extract("murky bass, very dark")
        #expect(p.tagValues == ["Dark"])
        #expect(p.tags.first?.spanStart == 0 && p.tags.first?.spanEnd == 5)
        #expect(p.tags.first?.confidence == 0.7, "the FIRST match's tier, not the later one")
    }

    // ------------------------------------------------------- tokenization

    /// §2.2's two pinned details: trimmed punctuation is outside the span, and
    /// a contraction's pieces all carry the original token's range.
    @Test func tokenOffsetRules() {
        let trimmed = NoteExtractor.tokenize("nice dark pad, bit too noisy, keep")
        #expect(trimmed.map(\.text) == ["nice", "dark", "pad", "bit", "too", "noisy", "keep"])
        #expect(trimmed[2].start == 10 && trimmed[2].end == 13)

        let contracted = NoteExtractor.tokenize("don't keep it")
        #expect(contracted.map(\.text) == ["do", "not", "keep", "it"])
        #expect(contracted[0].start == 0 && contracted[0].end == 5)
        #expect(contracted[1].start == 0 && contracted[1].end == 5,
                "both expansion pieces carry the single original token's range")

        // apostrophes that survive expansion are DELETED, joining the token
        #expect(NoteExtractor.tokenize("the synth's tail").map(\.text)
                    == ["the", "synths", "tail"])
        // CONTRACT GAP, pinned here so it cannot change silently: §2.1 step 3
        // matches the contraction table (whose keys are written with U+0027)
        // against the whole token, and step 4 deletes `'` AND `’` only
        // AFTERWARDS. So a token carrying a TYPOGRAPHIC apostrophe misses the
        // table and collapses to one word instead of expanding. Both cores
        // must behave identically, and the doc pins this order, so Swift does
        // not fold `’` to `'` on its own — see the report accompanying this
        // change for the recommended two-core fix.
        #expect(NoteExtractor.tokenize("don\u{2019}t").map(\.text) == ["dont"])
        #expect(NoteExtractor.tokenize("don't").map(\.text) == ["do", "not"])
        // digits survive; interior punctuation splits
        #expect(NoteExtractor.tokenize("8-bit 303 hi-hat").map(\.text)
                    == ["8", "bit", "303", "hi", "hat"])
        // empty and whitespace-only inputs are simply no tokens
        #expect(NoteExtractor.tokenize("").isEmpty)
        #expect(NoteExtractor.tokenize("   \n\t ").isEmpty)
    }

    /// Lowercasing is locale-independent and does not consult the caller's
    /// locale (`DARK. Pad!! Keep.` is in the fixture; this pins the mechanism).
    @Test func normalizationIsCaseAndPunctuationInsensitive() {
        let a = NoteExtractor.extract("DARK. Pad!! Keep.")
        let b = NoteExtractor.extract("dark pad keep")
        #expect(a.verdict?.value == b.verdict?.value)
        #expect(a.category?.value == b.category?.value)
        #expect(a.tagValues == b.tagValues)
    }

    // -------------------------------------------------------- locale gate

    /// The v1 lexicons are English. A non-`en` locale skips the ADVISORY layer
    /// only — the note is still captured and stored verbatim by the caller.
    @Test func localeGateSkipsTheAdvisoryLayer() {
        let english = NoteExtractor.extract("dark pad, keep", locale: "en-GB")
        #expect(english.verdict?.value == "keep")
        for locale in ["fr-FR", "de-DE", "ja-JP", "es-419"] {
            let p = NoteExtractor.extract("dark pad, keep", locale: locale)
            #expect(p.isEmpty, "\(locale) must yield empty proposals")
            #expect(p.verdict == nil && p.category == nil && p.tags.isEmpty)
        }
        // the prefix test is on the language subtag, not the whole identifier
        #expect(!NoteExtractor.extract("dark pad, keep", locale: "en").isEmpty)
        #expect(!NoteExtractor.extract("dark pad, keep", locale: "en_US").isEmpty)
    }

    // ------------------------------------------------- typed value bridges

    /// `verdictValue` / `categoryValue` never surface the "absence" cases.
    @Test func typedValuesNeverSurfaceTheAbsenceCases() {
        let p = NoteExtractor.extract("dark pad, keep")
        #expect(p.verdictValue == .keep)
        #expect(p.categoryValue == .pad)
        #expect(NoteProposals.empty.verdictValue == nil)
        #expect(NoteProposals.empty.categoryValue == nil)
        // a value outside the closed set (a foreign file) reads as nil, never
        // as a false .unrated / .uncategorized
        let foreign = NoteProposals(
            verdict: NoteProposal(value: "unrated", spanStart: 0, spanEnd: 1, confidence: 0.9),
            category: NoteProposal(value: "nonsense", spanStart: 0, spanEnd: 1, confidence: 0.9))
        #expect(foreign.verdictValue == nil)
        #expect(foreign.categoryValue == nil)
    }

    // ------------------------------------------------ §2.7 segment scope

    /// Within a segment the verdict comes from the LAST utterance, or from any
    /// utterance of 4 tokens or fewer — whichever is later.
    @Test func segmentScopeVerdict() {
        // a bare `keep` said early in a long segment still counts
        #expect(NoteExtractor.segmentVerdict([
            "keep",
            "the filter sweep in the second half is the interesting part here",
        ])?.value == "keep")

        // the last utterance wins when it has one
        #expect(NoteExtractor.segmentVerdict([
            "keep",
            "actually this one is meh",
        ])?.value == "meh")

        // a verdict buried mid-sentence in a long utterance never counts —
        // the utterance-scope positional rule already rejected it
        #expect(NoteExtractor.segmentVerdict([
            "I would keep the filter setting but cut the noise",
            "the pad underneath is nice and wide across the whole range",
        ]) == nil)

        #expect(NoteExtractor.segmentVerdict([]) == nil)
        #expect(NoteExtractor.segmentVerdict(["dark pad"]) == nil)
        // the locale gate applies to the segment rule too
        #expect(NoteExtractor.segmentVerdict(["keep"], locale: "fr-FR") == nil)
    }

    // ------------------------------------------------ §2.9 empty-note gate

    /// Fewer than two ALPHABETIC tokens is not persisted. The gate lives in
    /// the capture path, never inside `extract` — `extract("dark")` still
    /// returns the tag.
    @Test func emptyNoteGateIsSeparateFromExtraction() {
        #expect(!NoteExtractor.meetsContentGate(""))
        #expect(!NoteExtractor.meetsContentGate("   "))
        #expect(!NoteExtractor.meetsContentGate("dark"))
        #expect(!NoteExtractor.meetsContentGate("hmm"))
        #expect(!NoteExtractor.meetsContentGate("303 808"), "digits are not alphabetic")
        #expect(!NoteExtractor.meetsContentGate("303 dark"), "only one alphabetic token")
        #expect(NoteExtractor.meetsContentGate("dark pad"))
        #expect(NoteExtractor.meetsContentGate("don't"), "expands to two tokens")
        #expect(NoteExtractor.alphabeticTokenCount("nice dark pad, bit too noisy, keep") == 7)

        // and the gate does not change what extract() sees
        #expect(NoteExtractor.extract("dark").tagValues == ["Dark"])
    }
}
