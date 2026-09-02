// NoteExtractor.swift — the pure, table-driven, Foundation-only extractor
// pinned by docs/voice-notes.md §2. No ML, no network, no tokenizer library,
// no regex. Given the same input string and the same NoteVocabulary tables,
// this and the Python core produce byte-identical proposals; that property is
// what tests/fixtures/note_extraction.json tests (both cores load the SAME
// file).
//
// Everything it emits is ADVISORY (§3): the extractor writes into
// `PresetNote.proposals` and nowhere else. A transcript never changes a preset
// attribute on its own — a verdict proposal pre-aims the existing VerdictChips
// and the user still taps.
//
// The pipeline, in order:
//
//   normalize (NFC, lowercase, contractions, apostrophes deleted, non-alnum
//              -> space) carrying each token's code-point range in the
//              original string
//   -> left-to-right scan, at each unconsumed position:
//        1. carrier stoplist  (3-, then 2-, then 1-token; §2.6)
//           on a hit: consume + shadow the NEXT token, no lexicon try here.
//           THE CARRIER SCAN IGNORES THE SHADOW. A shadow only forbids a
//           LEXICON match at that position; it must not forbid a CARRIER
//           match, or one carrier disarms the next and re-exposes the very
//           key that next carrier exists to protect ("cut the high pass"
//           would read `pass` as the `meh` verdict).
//        2. lexicons          (3-, then 2-, then 1-token, Verdict > Type >
//                              Characteristic at equal length; §2.4) — SKIPPED
//                              at a shadowed position
//        3. suppression       (§2.5 negation/hedge window, §2.7 verdict
//                              positional rule) — a suppressed candidate is
//                              discarded, its tokens released, and the scan
//                              resumes at i+1 WITHOUT retrying shorter keys
//        4. on acceptance the matched tokens are consumed, so `string
//           ensemble` yields the Type `strings` and NOT also `Ensemble`
//
// Longest-match-wins plus consumption is the whole disambiguation story: no
// scoring, no backtracking, no ambiguity resolution beyond the tie order.

import Foundation

/// One normalized token plus the `[start, end)` **Unicode scalar (code point)
/// range in the original text** that produced it (§2.2). The mapping is
/// carried THROUGH normalization and is never re-derived by searching the
/// original for the normalized token.
///
/// Two pinned details: leading/trailing characters dropped by normalization
/// are not part of the span (`pad,` spans `[10, 13)`, not `[10, 14)`); and a
/// contraction that expands to several tokens gives every piece the range of
/// the single original token (`don't` -> `do` and `not` both span `[0, 5)`).
///
/// Offsets are into the NFC form of the input. For text that is already NFC —
/// everything a transcriber emits — that is the input string itself.
public struct NoteToken: Sendable, Equatable {
    public let text: String        // normalized: lowercase letters/digits only
    public let start: Int          // code point offset, inclusive
    public let end: Int            // code point offset, exclusive

    public init(text: String, start: Int, end: Int) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum NoteExtractor {

    // ------------------------------------------------------------- scalars

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .decimalNumber
    }

    /// Step 5 keeps exactly Unicode letters and decimal digits. Digits are
    /// kept deliberately: `303`, `808`, `8 bit`.
    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        isLetter(s) || isDigit(s)
    }

    private static func isApostrophe(_ s: Unicode.Scalar) -> Bool {
        s == "'" || s == "\u{2019}"
    }

    // ---------------------------------------------------------- §2.1 / §2.2

    /// Normalize and tokenize, carrying code-point offsets (§2.1, §2.2).
    ///
    /// Per whitespace-delimited run: trim the leading/trailing characters that
    /// normalization would drop, lowercase (locale-independent, scalar by
    /// scalar so offsets survive a one-to-many case mapping), expand a
    /// whole-token contraction, delete any remaining apostrophe (joining the
    /// token: `synth's` -> `synths`), then split what is left on every
    /// non-alphanumeric character.
    public static func tokenize(_ text: String) -> [NoteToken] {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var out: [NoteToken] = []
        var i = 0
        while i < scalars.count {
            while i < scalars.count, scalars[i].properties.isWhitespace { i += 1 }
            guard i < scalars.count else { break }
            var j = i
            while j < scalars.count, !scalars[j].properties.isWhitespace { j += 1 }
            appendTokens(from: scalars, run: i..<j, into: &out)
            i = j
        }
        return out
    }

    private static func appendTokens(from scalars: [Unicode.Scalar],
                                     run: Range<Int>,
                                     into out: inout [NoteToken]) {
        // The span the doc pins excludes leading/trailing characters that
        // step 5 would drop; an apostrophe is keepable here so `'em` and
        // `don't` trim to themselves before the contraction lookup.
        var a = run.lowerBound
        var b = run.upperBound
        while a < b, !isAlphanumeric(scalars[a]), !isApostrophe(scalars[a]) { a += 1 }
        while b > a, !isAlphanumeric(scalars[b - 1]), !isApostrophe(scalars[b - 1]) { b -= 1 }
        guard a < b else { return }

        // Lowercase scalar by scalar, each lowered scalar tagged with the
        // offset of the source scalar it came from, so a one-to-many mapping
        // (e.g. `İ`) cannot shift any later span.
        var lowered: [(scalar: Unicode.Scalar, offset: Int)] = []
        for k in a..<b {
            for s in String(scalars[k]).lowercased().unicodeScalars {
                lowered.append((s, k))
            }
        }

        // §2.1 step 3: whole-token contraction expansion. Every expanded piece
        // carries the range of the single original token.
        var view = String.UnicodeScalarView()
        view.append(contentsOf: lowered.map(\.scalar))
        if let expansion = NoteVocabulary.contractions[String(view)] {
            for piece in expansion.split(separator: " ") {
                out.append(NoteToken(text: String(piece), start: a, end: b))
            }
            return
        }

        // §2.1 steps 4 + 5: apostrophes deleted (joining), everything else
        // non-alphanumeric splits.
        var current = String.UnicodeScalarView()
        var curStart = 0
        var curEnd = 0
        func flush() {
            guard !current.isEmpty else { return }
            out.append(NoteToken(text: String(current), start: curStart, end: curEnd))
            current = String.UnicodeScalarView()
        }
        for (scalar, offset) in lowered {
            if isApostrophe(scalar) { continue }
            if isAlphanumeric(scalar) {
                if current.isEmpty { curStart = offset }
                current.append(scalar)
                curEnd = offset + 1
            } else {
                flush()
            }
        }
        flush()
    }

    // --------------------------------------------------------------- §2.8

    /// The fixed tier table. A match-strength tier, not a probability, and
    /// never from a model: 0.9 when the key IS the canonical value, 0.8 for a
    /// multi-token synonym, 0.7 for a single-token synonym.
    static func confidence(key: String, value: String) -> Double {
        if key == value.lowercased() { return 0.9 }
        return key.contains(" ") ? 0.8 : 0.7
    }

    // --------------------------------------------------------------- §2.0

    /// Extract advisory proposals from ONE utterance — the text of one
    /// finalized transcription result, or one typed note.
    ///
    /// Locale gate: the v1 lexicons are English, so a `locale` that does not
    /// begin with `en` yields empty proposals. Transcription still runs and
    /// the note is still stored verbatim; only the advisory layer is skipped.
    public static func extract(_ utterance: String,
                               locale: String = "en-US") -> NoteProposals {
        guard locale.lowercased().hasPrefix("en") else { return .empty }
        let tokens = tokenize(utterance)
        let n = tokens.count
        guard n > 0 else { return .empty }
        let words = tokens.map(\.text)

        var consumed = [Bool](repeating: false, count: n)
        var shadowed = [Bool](repeating: false, count: n)
        var verdict: NoteProposal?
        var category: NoteProposal?
        var tags: [NoteProposal] = []
        var seenTags = Set<String>()

        var i = 0
        while i < n {
            if consumed[i] {
                i += 1
                continue
            }

            // 1. carrier stoplist first — longest first. No lexicon match is
            //    attempted at this position (§2.4 step 1).
            //
            //    Deliberately BEFORE the shadow check: a shadowed token may
            //    not START a lexicon match, but it must still be allowed to
            //    start a CARRIER. Without that, a carrier whose shadow lands
            //    on the first token of another carrier disarms it — `cut the`
            //    shadows `high`, `high pass` can then never fire, and the bare
            //    `pass` that carrier exists to hide is read as the `meh`
            //    verdict ("cut the high pass on this one").
            var carrierLength = 0
            for length in stride(from: NoteVocabulary.maxKeyTokens, through: 1, by: -1)
            where i + length <= n {
                if NoteVocabulary.carriers.contains(words[i..<(i + length)].joined(separator: " ")) {
                    carrierLength = length
                    break
                }
            }
            if carrierLength > 0 {
                for j in i..<(i + carrierLength) { consumed[j] = true }
                if i + carrierLength < n { shadowed[i + carrierLength] = true }
                i += carrierLength
                continue
            }

            // The shadow itself: no LEXICON match may start here.
            if shadowed[i] {
                i += 1
                continue
            }

            // 2. lexicons — longest first, Verdict > Type > Characteristic.
            var matchedLength = 0
            for length in stride(from: NoteVocabulary.maxKeyTokens, through: 1, by: -1)
            where i + length <= n {
                let key = words[i..<(i + length)].joined(separator: " ")
                guard let match = NoteVocabulary.lexicon[key] else { continue }

                // §2.5 — the window is STRICTLY preceding and three tokens
                // wide, evaluated over the raw normalized stream (consumption
                // and shadowing are ignored), so `nothing special` is not
                // suppressed by its own `nothing`.
                let windowStart = max(0, i - 3)
                if (windowStart..<i).contains(where: { NoteVocabulary.blockers.contains(words[$0]) }) {
                    break      // discarded, tokens released, resume at i + 1
                }
                // §2.7 — tags and types may appear anywhere; a verdict may not.
                if match.kind == .verdict, !(i >= n - 6 || n <= 4) {
                    break
                }

                let proposal = NoteProposal(
                    value: match.value,
                    spanStart: tokens[i].start,
                    spanEnd: tokens[i + length - 1].end,
                    confidence: confidence(key: key, value: match.value),
                    accepted: false)
                switch match.kind {
                case .verdict:
                    verdict = proposal          // single-valued: last wins
                case .category:
                    category = proposal         // single-valued: last wins
                case .characteristic:
                    // Tags accumulate: unique by value, ordered by first
                    // appearance, and the span recorded is the FIRST one.
                    if seenTags.insert(match.value).inserted { tags.append(proposal) }
                }
                for j in i..<(i + length) { consumed[j] = true }
                matchedLength = length
                break
            }
            i += matchedLength > 0 ? matchedLength : 1
        }
        return NoteProposals(verdict: verdict, category: category, tags: tags)
    }

    // ---------------------------------------------------- §2.7 segment scope

    /// The verdict that pre-aims the chips for a whole SEGMENT — the run of
    /// utterances attributed to one preset (§4).
    ///
    /// Candidates are the verdict proposal of the LAST utterance plus the
    /// verdict proposal of every utterance of 4 tokens or fewer; the latest
    /// candidate wins. So a bare `keep` said early in a long segment still
    /// counts, while a `keep` buried in the middle of a long sentence does not
    /// (the utterance-scope positional rule already rejected it).
    public static func segmentVerdict(_ utterances: [String],
                                      locale: String = "en-US") -> NoteProposal? {
        var winner: NoteProposal?
        for (index, utterance) in utterances.enumerated() {
            guard let candidate = extract(utterance, locale: locale).verdict else { continue }
            let isLast = index == utterances.count - 1
            let isShort = tokenize(utterance).count <= 4
            if isLast || isShort { winner = candidate }
        }
        return winner
    }

    // -------------------------------------------------------------- §2.9

    /// Tokens containing at least one Unicode letter. `303` is a token but not
    /// an alphabetic one.
    public static func alphabeticTokenCount(_ text: String) -> Int {
        tokenize(text).filter { $0.text.unicodeScalars.contains(where: isLetter) }.count
    }

    /// The empty-note gate: an utterance with fewer than TWO alphabetic tokens
    /// is not persisted as a note. Key clatter, headphone bleed and breath
    /// mostly transcribe to exactly that.
    ///
    /// This gate belongs to the CAPTURE path, not to `extract` — the
    /// separation is deliberate, and both cores apply it at the same boundary.
    /// `extract("dark")` correctly returns the tag `Dark`; the note is simply
    /// never written.
    public static func meetsContentGate(_ text: String) -> Bool {
        alphabeticTokenCount(text) >= 2
    }
}
