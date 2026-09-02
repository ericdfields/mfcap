// NoteVocabulary.swift — the pinned tables behind NoteExtractor.
//
// Every table here is a VERBATIM transcription of docs/voice-notes.md §2.1,
// §2.3, §2.5 and §2.6. It is the contract, not a tuning knob: the Python core
// carries the identical tables, and tests/fixtures/note_extraction.json is the
// shared proof that both cores read them the same way. Adding a key is a
// two-core change plus a fixture case (§5); nothing here may be "improved"
// unilaterally.
//
// Three closed lexicons, keyed by a 1-, 2- or 3-token NORMALIZED phrase and
// valued by a canonical value the extractor can never invent:
//
//   verdict        -> Verdict.slug     (`unrated` is never proposed)
//   category       -> Category.slug    (`uncategorized` is never proposed)
//   characteristic -> one of the 18 exact Arturia display strings, capitalised
//                     as they already appear in LibraryEntry.tags
//
// Plus the three suppression sets: negators and hedges (§2.5, a strictly
// preceding 3-token window; suppress only, NEVER invert — there is no antonym
// table anywhere in this design) and the carrier-phrase stoplist (§2.6, the
// single biggest false-positive control, because the 18 Characteristics
// include very common English words).

import Foundation

public enum NoteVocabulary {

    /// Which lexicon a key came from. The raw value is the §2.4 tie order:
    /// at equal key length, Verdict beats Type beats Characteristic.
    public enum Kind: Int, Sendable, Equatable, CaseIterable {
        case verdict = 0
        case category = 1
        case characteristic = 2
    }

    /// A resolved lexicon hit: which table, and the canonical value.
    public struct Match: Sendable, Equatable {
        public let kind: Kind
        public let value: String

        public init(kind: Kind, value: String) {
            self.kind = kind
            self.value = value
        }
    }

    /// No lexicon key and no carrier is longer than this (asserted by tests).
    public static let maxKeyTokens = 3

    // ------------------------------------------------------- §2.1 contractions

    /// Whole-token expansions, applied to the lowercased token (§2.1 step 3).
    /// Deliberate consequence: `I'd keep this` -> `i would keep this`, and
    /// `would` is a hedge, so the verdict is suppressed. That is correct — it
    /// is a wish, not a filing decision.
    public static let contractions: [String: String] = [
        "isn't": "is not", "wasn't": "was not", "aren't": "are not",
        "weren't": "were not", "don't": "do not", "doesn't": "does not",
        "didn't": "did not", "can't": "can not", "cannot": "can not",
        "won't": "will not", "wouldn't": "would not", "shouldn't": "should not",
        "couldn't": "could not", "haven't": "have not", "hasn't": "has not",
        "hadn't": "had not", "ain't": "is not",
        "i'm": "i am", "i've": "i have", "i'll": "i will", "i'd": "i would",
        "you're": "you are", "you've": "you have", "you'll": "you will",
        "you'd": "you would", "we're": "we are", "we've": "we have",
        "we'll": "we will", "they're": "they are", "it's": "it is",
        "that's": "that is", "there's": "there is", "let's": "let us",
        "thats": "that is",
    ]

    // ----------------------------------------------------- §2.3.1 verdict

    /// `Verdict.slug` -> keys. `unrated` is never proposed; it is the absence
    /// of a verdict. Bare `yes`/`yeah`/`ok`, bare `later`, bare `maybe` and
    /// `get rid` are deliberately excluded (§2.3.1).
    public static let verdictKeys: [String: [String]] = [
        "keep": ["keep", "keeper", "a keeper", "definite keeper", "real keeper",
                 "keep it", "keep this", "keep that", "keeping this", "keeping it",
                 "save it", "save this", "love it", "love this", "i love it",
                 "i like it", "like it", "winner", "yes keep"],
        "try_later": ["try later", "try it later", "maybe later", "come back",
                      "come back to", "revisit", "revisit later", "not now",
                      "another time", "some other time", "park it", "shortlist",
                      "shortlist it", "bookmark it", "hold on to"],
        "meh": ["meh", "nah", "pass", "boring", "not interesting",
                "nothing special", "so so", "not for me", "not feeling it",
                "underwhelming", "forgettable", "bit dull", "not doing it"],
        "never": ["never", "never again", "delete it", "delete this", "bin it",
                  "bin this", "trash it", "trash this", "no way",
                  "hate it", "hate this", "awful", "terrible", "horrible",
                  "useless", "junk", "rubbish", "garbage"],
    ]

    // ------------------------------------------------------- §2.3.2 type

    /// `Category.slug` -> keys, the 12 Arturia Types from
    /// docs/arturia-taxonomy.md. `uncategorized` is never proposed. Bare `key`,
    /// `effect`, `pattern`, `riff`, `texture` and `sequencer` are deliberately
    /// excluded (§2.3.2).
    public static let typeKeys: [String: [String]] = [
        "bass": ["bass", "bassline", "bass line", "sub bass", "bass sound",
                 "bass patch", "bass note"],
        "brass": ["brass", "brass section", "horn", "horns", "horn section",
                  "trumpet", "trombone"],
        "keys": ["keys", "piano", "electric piano", "rhodes", "wurli", "clav",
                 "clavinet", "keyboard sound"],
        "lead": ["lead", "lead sound", "lead line", "lead patch", "solo sound",
                 "top line"],
        "organ": ["organ", "hammond", "tonewheel", "church organ", "b3"],
        "pad": ["pad", "pads", "pad sound", "pad patch", "string pad"],
        "percussion": ["percussion", "percussion hit", "drum", "drums",
                       "drum sound", "drum hit", "kick", "snare", "hi hat",
                       "hihat", "clap", "rimshot", "tom"],
        "sequence": ["sequence", "sequenced", "sequence patch", "seq", "arp",
                     "arpeggio", "arpeggiator", "arpeggiated"],
        "sfx": ["sfx", "sound effect", "sound effects", "fx", "riser",
                "downlifter", "whoosh", "impact", "sound design", "noise sweep"],
        "strings": ["strings", "string section", "string ensemble", "violin",
                    "violins", "cello", "orchestral strings"],
        "template": ["template", "init patch", "init", "blank patch",
                     "starting point", "starter patch"],
        "vocoder": ["vocoder", "vocoded", "vocoder patch", "talk box", "talkbox",
                    "robot voice"],
    ]

    // ------------------------------------------------ §2.3.3 characteristic

    /// Exact Arturia display string -> keys, the 18 values from
    /// docs/arturia-taxonomy.md written exactly as they already appear in
    /// `LibraryEntry.tags` (these are the strings the filter chips match on).
    /// Bare `sharp`, `tight`, `dull`, `moving`, `score`, `choir` and `punchy`
    /// are deliberately excluded (§2.3.3).
    public static let characteristicKeys: [String: [String]] = [
        "Acid": ["acid", "acidy", "acidic", "303", "tb 303", "squelchy", "squelch"],
        "Aggressive": ["aggressive", "aggressively", "aggro", "angry", "nasty",
                       "brutal", "vicious", "savage", "mean", "in your face"],
        "Ambient": ["ambient", "atmospheric", "atmosphere", "dreamy", "ethereal",
                    "floaty", "airy", "spacey", "washy", "wash"],
        "Bizarre": ["bizarre", "weird", "strange", "odd", "freaky", "wonky",
                    "alien", "otherworldly", "unhinged", "bonkers"],
        "Bright": ["bright", "brighter", "brightness", "brilliant", "sparkly",
                   "sparkling", "shiny", "crisp", "glassy", "zingy"],
        "Complex": ["complex", "complicated", "intricate", "layered", "evolving",
                    "busy", "dense"],
        "Dark": ["dark", "darker", "darkness", "murky", "gloomy", "moody",
                 "brooding", "shadowy", "somber", "sombre"],
        "Digital": ["digital", "dx", "fm", "8 bit", "eight bit", "bitcrushed",
                    "bit crushed", "lo fi", "chiptune", "plasticky", "computery"],
        "Ensemble": ["ensemble", "unison", "chorused", "chorusy", "wide",
                     "stacked", "detuned stack"],
        "Funky": ["funky", "funk", "funked up", "groovy", "groove", "syncopated"],
        "Hard": ["hard", "hard edged", "harsh", "edgy", "biting", "gritty",
                 "abrasive", "rough"],
        "Long": ["long", "long release", "long tail", "sustained", "drawn out",
                 "lingering"],
        "Noise": ["noise", "noisy", "hiss", "hissy", "static", "crackle",
                  "crackly", "white noise", "fizzy"],
        "Quiet": ["quiet", "quietly", "low volume", "subdued", "understated",
                  "hushed", "whispery", "faint"],
        "Short": ["short", "short release", "plucky", "pluck", "staccato",
                  "snappy", "clipped", "stab", "stabby"],
        "Simple": ["simple", "basic", "plain", "minimal", "bare bones",
                   "straightforward", "uncomplicated", "stripped back"],
        "Soft": ["soft", "softer", "gentle", "mellow", "smooth", "warm",
                 "velvety", "silky", "round", "muffled"],
        "Soundtrack": ["soundtrack", "cinematic", "filmic", "film score",
                       "movie score", "epic", "trailer music", "scoring"],
    ]

    /// The 18 Arturia characteristics, alphabetical — the closed set every tag
    /// proposal is drawn from.
    public static let characteristics: [String] = characteristicKeys.keys.sorted()

    // ------------------------------------------------------- §2.6 carriers

    /// Checked BEFORE the lexicons at every position, longest first. On a hit a
    /// carrier consumes its own tokens and shadows the immediately following
    /// token, which may not start a LEXICON match — but may still start
    /// another CARRIER, so `cut the` + `high pass` chain instead of the first
    /// disarming the second. The shadow is exactly ONE
    /// token wide, deliberately: `turn down the brightness` still yields
    /// `Bright`. When a phrase proves noisy in use the fix is a longer carrier
    /// plus a fixture case — never a wider shadow.
    public static let carriers: Set<String> = [
        // Hard
        "hard to", "hard time", "hard for", "hard work", "hard drive", "hard on",
        // Short
        "short of", "in short", "short on", "cut short", "falls short",
        "for short", "short while",
        // Long
        "long time", "not long", "as long as", "how long", "so long",
        "long story", "long way", "before long",
        // Simple
        "simple as", "simple to", "simply put",
        // Quiet
        "quiet down", "be quiet", "keep quiet",
        // verdict `keep`
        "keep the", "keep it in", "keep going", "keep up", "keep an eye",
        "keeps the",
        // requests, not descriptions
        "cut the", "lose the", "dial back", "back off", "turn down", "turn up",
        "rid of the",
        // verdict `pass`
        "high pass", "low pass", "band pass", "pass filter", "pass through",
        // verdict `never`
        "never mind",
        // keys / lead
        "key of", "the key", "lead to", "leads to", "lead into",
    ]

    // ------------------------------------------------ §2.5 negation / hedge

    /// Suppress only, never invert.
    public static let negators: Set<String> = [
        "not", "no", "nor", "none", "nothing", "never", "without", "barely",
        "hardly", "lacks", "lacking", "stop", "remove", "reduce", "less",
    ]

    /// `never` is deliberately in BOTH `negators` and the verdict lexicon: in
    /// `I would never keep this` it matches the verdict AND suppresses the
    /// following `keep`, which is the right reading.
    public static let hedges: Set<String> = [
        "maybe", "might", "perhaps", "possibly", "could", "would", "should",
        "if", "unless", "almost", "wish", "want", "wanted", "needs", "need",
        "trying",
    ]

    /// Explicitly NOT blockers (§2.5): `bit`, `a bit`, `kinda`, `kind`, `sort`,
    /// `slightly`, `quite`, `pretty`, `very`, `really`, `too`, `way`. They are
    /// intensity qualifiers and the attribute is still being asserted —
    /// `nice dark pad, bit too noisy, keep` must yield `Noise`.
    public static let blockers: Set<String> = negators.union(hedges)

    // ------------------------------------------------------------- lookup

    /// Flattened key -> Match over all three lexicons. Keys are unique across
    /// the three tables (asserted by NoteExtractorTests); the §2.4 Verdict >
    /// Type > Characteristic tie order is applied here anyway so a future
    /// additive key can never make the scan order-dependent.
    public static let lexicon: [String: Match] = {
        var out: [String: Match] = [:]
        let tables: [(Kind, [String: [String]])] = [
            (.verdict, verdictKeys),
            (.category, typeKeys),
            (.characteristic, characteristicKeys),
        ]
        for (kind, table) in tables {
            for value in table.keys.sorted() {
                for key in table[value]! {
                    if let existing = out[key], existing.kind.rawValue <= kind.rawValue {
                        continue
                    }
                    out[key] = Match(kind: kind, value: value)
                }
            }
        }
        return out
    }()
}
