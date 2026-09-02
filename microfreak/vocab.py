"""The pinned note-extraction tables and the pure extractor over them.

Contract: docs/voice-notes.md §2. Shared proof: tests/fixtures/note_extraction.json
— BOTH cores load that same file and must pass every case. This module is the
Python half; the Swift half is
ios/FreakCore/Sources/FreakCore/NoteVocabulary.swift + NoteExtractor.swift.

Pure, table-driven, standard-library-only. No ML, no network, no tokenizer
library, no regex. Given the same input string and the same tables, this and the
Swift core produce byte-identical proposals.

Everything it emits is ADVISORY (§3): the extractor writes into
`PresetNote.proposals` and nowhere else. A transcript never changes a preset
attribute on its own — a verdict proposal pre-aims the existing verdict chips
and the user still taps.

Three closed lexicons, keyed by a 1-, 2- or 3-token NORMALIZED phrase and valued
by a canonical value the extractor can never invent:

    verdict        -> Verdict.slug     (`unrated` is never proposed)
    category       -> Category.slug    (`uncategorized` is never proposed)
    characteristic -> one of the 18 exact Arturia display strings, capitalised
                      as they already appear in LibraryEntry.tags

Plus the three suppression sets: negators and hedges (§2.5 — a strictly
preceding 3-token window; SUPPRESS ONLY, NEVER INVERT, there is no antonym table
anywhere in this design) and the carrier-phrase stoplist (§2.6, the single
biggest false-positive control, because the 18 Characteristics include very
common English words).

The pipeline, in order:

    normalize (NFC, lowercase, contractions, apostrophes deleted, non-alnum
               -> space) carrying each token's code-point range in the original
               string
    -> left-to-right scan, at each unconsumed position:
         1. carrier stoplist  (3-, then 2-, then 1-token; §2.6)
            on a hit: consume + shadow the NEXT token, no lexicon try here.
            THE CARRIER SCAN IGNORES THE SHADOW. A shadow only forbids a
            LEXICON match at that position; it must not forbid a CARRIER
            match, or one carrier disarms the next and re-exposes the very
            key that next carrier exists to protect ("cut the high pass"
            would read `pass` as the `meh` verdict).
         2. lexicons          (3-, then 2-, then 1-token, Verdict > Type >
                               Characteristic at equal length; §2.4) — SKIPPED
                               at a shadowed position
         3. suppression       (§2.5 negation/hedge window, §2.7 verdict
                               positional rule) — a suppressed candidate is
                               discarded, its tokens released, and the scan
                               resumes at i+1 WITHOUT retrying shorter keys
         4. on acceptance the matched tokens are consumed, so `string ensemble`
            yields the Type `strings` and NOT also `Ensemble`

Longest-match-wins plus consumption is the whole disambiguation story: no
scoring, no backtracking, no ambiguity resolution beyond the tie order.

Nothing here may be "improved" unilaterally: adding a key is a two-core change
plus a fixture case (§5).
"""
from __future__ import annotations

import enum
import unicodedata
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Set, Tuple

from .notes import NoteProposal, NoteProposals

# No lexicon key and no carrier is longer than this (asserted by the tests).
MAX_KEY_TOKENS = 3


# ----------------------------------------------------------- §2.1 contractions

# Whole-token expansions, applied to the lowercased token (§2.1 step 3).
# Deliberate consequence: `I'd keep this` -> `i would keep this`, and `would` is
# a hedge, so the verdict is suppressed. That is correct — it is a wish, not a
# filing decision.
CONTRACTIONS: Dict[str, str] = {
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
}


# --------------------------------------------------------------- §2.3.1 verdict

# `Verdict.slug` -> keys. `unrated` is never proposed; it is the absence of a
# verdict. Bare `yes`/`yeah`/`ok`, bare `later`, bare `maybe` and `get rid` are
# deliberately excluded (§2.3.1).
VERDICT_KEYS: Dict[str, List[str]] = {
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
}


# ------------------------------------------------------------------ §2.3.2 type

# `Category.slug` -> keys, the 12 Arturia Types from docs/arturia-taxonomy.md.
# `uncategorized` is never proposed. Bare `key`, `effect`, `pattern`, `riff`,
# `texture` and `sequencer` are deliberately excluded (§2.3.2).
TYPE_KEYS: Dict[str, List[str]] = {
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
}


# -------------------------------------------------------- §2.3.3 characteristic

# Exact Arturia display string -> keys, the 18 values from
# docs/arturia-taxonomy.md written exactly as they already appear in
# `LibraryEntry.tags` (these are the strings the filter chips match on). Bare
# `sharp`, `tight`, `dull`, `moving`, `score`, `choir` and `punchy` are
# deliberately excluded (§2.3.3).
CHARACTERISTIC_KEYS: Dict[str, List[str]] = {
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
}

# The 18 Arturia characteristics, alphabetical — the closed set every tag
# proposal is drawn from.
CHARACTERISTICS: List[str] = sorted(CHARACTERISTIC_KEYS)


# ---------------------------------------------------------------- §2.6 carriers

# Checked BEFORE the lexicons at every position, longest first. On a hit a
# carrier consumes its own tokens and shadows the immediately following token,
# which may not start a LEXICON match — but may still start another CARRIER,
# so `cut the` + `high pass` chain instead of the first disarming the second.
# The shadow is exactly ONE token wide,
# deliberately: `turn down the brightness` still yields `Bright`. When a phrase
# proves noisy in use the fix is a longer carrier plus a fixture case — never a
# wider shadow.
CARRIERS: Set[str] = {
    # Hard
    "hard to", "hard time", "hard for", "hard work", "hard drive", "hard on",
    # Short
    "short of", "in short", "short on", "cut short", "falls short",
    "for short", "short while",
    # Long
    "long time", "not long", "as long as", "how long", "so long",
    "long story", "long way", "before long",
    # Simple
    "simple as", "simple to", "simply put",
    # Quiet
    "quiet down", "be quiet", "keep quiet",
    # verdict `keep`
    "keep the", "keep it in", "keep going", "keep up", "keep an eye",
    "keeps the",
    # requests, not descriptions
    "cut the", "lose the", "dial back", "back off", "turn down", "turn up",
    "rid of the",
    # verdict `pass`
    "high pass", "low pass", "band pass", "pass filter", "pass through",
    # verdict `never`
    "never mind",
    # keys / lead
    "key of", "the key", "lead to", "leads to", "lead into",
}


# --------------------------------------------------------- §2.5 negation / hedge

# Suppress only, never invert.
NEGATORS: Set[str] = {
    "not", "no", "nor", "none", "nothing", "never", "without", "barely",
    "hardly", "lacks", "lacking", "stop", "remove", "reduce", "less",
}

# `never` is deliberately in BOTH `NEGATORS` and the verdict lexicon: in
# `I would never keep this` it matches the verdict AND suppresses the following
# `keep`, which is the right reading.
HEDGES: Set[str] = {
    "maybe", "might", "perhaps", "possibly", "could", "would", "should",
    "if", "unless", "almost", "wish", "want", "wanted", "needs", "need",
    "trying",
}

# Explicitly NOT blockers (§2.5): `bit`, `a bit`, `kinda`, `kind`, `sort`,
# `slightly`, `quite`, `pretty`, `very`, `really`, `too`, `way`. They are
# intensity qualifiers and the attribute is still being asserted —
# `nice dark pad, bit too noisy, keep` must yield `Noise`.
BLOCKERS: Set[str] = NEGATORS | HEDGES


# ------------------------------------------------------------------- lookup

class MatchKind(enum.Enum):
    """Which lexicon a key came from. The value is the §2.4 tie order: at equal
    key length, Verdict beats Type beats Characteristic."""
    VERDICT = 0
    CATEGORY = 1
    CHARACTERISTIC = 2


@dataclass(frozen=True)
class Match:
    """A resolved lexicon hit: which table, and the canonical value."""
    kind: MatchKind
    value: str


def _build_lexicon() -> Dict[str, Match]:
    """Flattened key -> Match over all three lexicons. Keys are unique across
    the three tables (asserted by the tests); the §2.4 Verdict > Type >
    Characteristic tie order is applied here anyway so a future additive key can
    never make the scan order-dependent."""
    out: Dict[str, Match] = {}
    tables = ((MatchKind.VERDICT, VERDICT_KEYS),
              (MatchKind.CATEGORY, TYPE_KEYS),
              (MatchKind.CHARACTERISTIC, CHARACTERISTIC_KEYS))
    for kind, table in tables:
        for value in sorted(table):
            for key in table[value]:
                existing = out.get(key)
                if existing is not None and existing.kind.value <= kind.value:
                    continue
                out[key] = Match(kind=kind, value=value)
    return out


LEXICON: Dict[str, Match] = _build_lexicon()


# ------------------------------------------------------------ §2.1 / §2.2

@dataclass(frozen=True)
class NoteToken:
    """One normalized token plus the `[start, end)` code point range in the
    original text that produced it (§2.2). The mapping is carried THROUGH
    normalization and is never re-derived by searching the original for the
    normalized token.

    Two pinned details: leading/trailing characters dropped by normalization are
    not part of the span (`pad,` spans `[10, 13)`, not `[10, 14)`); and a
    contraction that expands to several tokens gives every piece the range of
    the single original token (`don't` -> `do` and `not` both span `[0, 5)`).

    Offsets are into the NFC form of the input. For text that is already NFC —
    everything a transcriber emits — that is the input string itself.
    """
    text: str      # normalized: lowercase letters/digits only
    start: int     # code point offset, inclusive
    end: int       # code point offset, exclusive


def _is_alphanumeric(ch: str) -> bool:
    """Step 5 keeps exactly Unicode letters (Lu/Ll/Lt/Lm/Lo — `str.isalpha`)
    and decimal digits (Nd — `str.isdecimal`, NOT `isdigit`, which also admits
    superscripts). Digits are kept deliberately: `303`, `808`, `8 bit`."""
    return ch.isalpha() or ch.isdecimal()


def _is_apostrophe(ch: str) -> bool:
    return ch == "'" or ch == "’"


def tokenize(text: str) -> List[NoteToken]:
    """Normalize and tokenize, carrying code-point offsets (§2.1, §2.2).

    Per whitespace-delimited run: trim the leading/trailing characters that
    normalization would drop, lowercase (character by character so offsets
    survive a one-to-many case mapping), expand a whole-token contraction,
    delete any remaining apostrophe (joining the token: `synth's` -> `synths`),
    then split what is left on every non-alphanumeric character.
    """
    chars = unicodedata.normalize("NFC", text)
    n = len(chars)
    out: List[NoteToken] = []
    i = 0
    while i < n:
        while i < n and chars[i].isspace():
            i += 1
        if i >= n:
            break
        j = i
        while j < n and not chars[j].isspace():
            j += 1
        _append_tokens(chars, i, j, out)
        i = j
    return out


def _append_tokens(chars: str, lo: int, hi: int, out: List[NoteToken]) -> None:
    # The span the doc pins excludes leading/trailing characters that step 5
    # would drop; an apostrophe is keepable here so `'em` and `don't` trim to
    # themselves before the contraction lookup.
    a, b = lo, hi
    while a < b and not _is_alphanumeric(chars[a]) and not _is_apostrophe(chars[a]):
        a += 1
    while b > a and not _is_alphanumeric(chars[b - 1]) and not _is_apostrophe(chars[b - 1]):
        b -= 1
    if a >= b:
        return

    # Lowercase character by character, each lowered character tagged with the
    # offset of the source character it came from, so a one-to-many mapping
    # (e.g. `İ`) cannot shift any later span.
    lowered: List[Tuple[str, int]] = []
    for k in range(a, b):
        for c in chars[k].lower():
            lowered.append((c, k))

    # §2.1 step 3: whole-token contraction expansion. Every expanded piece
    # carries the range of the single original token.
    whole = "".join(c for c, _ in lowered)
    expansion = CONTRACTIONS.get(whole)
    if expansion is not None:
        for piece in expansion.split(" "):
            out.append(NoteToken(text=piece, start=a, end=b))
        return

    # §2.1 steps 4 + 5: apostrophes deleted (joining), everything else
    # non-alphanumeric splits.
    cur: List[str] = []
    cur_start = 0
    cur_end = 0
    for c, offset in lowered:
        if _is_apostrophe(c):
            continue
        if _is_alphanumeric(c):
            if not cur:
                cur_start = offset
            cur.append(c)
            cur_end = offset + 1
        elif cur:
            out.append(NoteToken(text="".join(cur), start=cur_start, end=cur_end))
            cur = []
    if cur:
        out.append(NoteToken(text="".join(cur), start=cur_start, end=cur_end))


# ------------------------------------------------------------------- §2.8

def confidence(key: str, value: str) -> float:
    """The fixed tier table. A match-strength tier, not a probability, and never
    from a model: 0.9 when the key IS the canonical value, 0.8 for a multi-token
    synonym, 0.7 for a single-token synonym."""
    if key == value.lower():
        return 0.9
    return 0.8 if " " in key else 0.7


# ------------------------------------------------------------------- §2.0

def extract(utterance: str, locale: str = "en-US") -> NoteProposals:
    """Extract advisory proposals from ONE utterance — the text of one finalized
    transcription result, or one typed note.

    Locale gate: the v1 lexicons are English, so a `locale` that does not begin
    with `en` yields empty proposals. Transcription still runs and the note is
    still stored verbatim; only the advisory layer is skipped.
    """
    if not locale.lower().startswith("en"):
        return NoteProposals.EMPTY
    tokens = tokenize(utterance)
    n = len(tokens)
    if n == 0:
        return NoteProposals.EMPTY
    words = [t.text for t in tokens]

    consumed = [False] * n
    shadowed = [False] * n
    verdict: Optional[NoteProposal] = None
    category: Optional[NoteProposal] = None
    tags: List[NoteProposal] = []
    seen_tags: Set[str] = set()

    i = 0
    while i < n:
        if consumed[i]:
            i += 1
            continue

        # 1. carrier stoplist first — longest first. No lexicon match is
        #    attempted at this position (§2.4 step 1).
        #
        #    Deliberately BEFORE the shadow check: a shadowed token may not
        #    START a lexicon match, but it must still be allowed to start a
        #    CARRIER. Without that, a carrier whose shadow lands on the first
        #    token of another carrier disarms it — `cut the` shadows `high`,
        #    `high pass` can then never fire, and the bare `pass` that carrier
        #    exists to hide is read as the `meh` verdict ("cut the high pass
        #    on this one").
        carrier_length = 0
        for length in range(MAX_KEY_TOKENS, 0, -1):
            if i + length > n:
                continue
            if " ".join(words[i:i + length]) in CARRIERS:
                carrier_length = length
                break
        if carrier_length:
            for j in range(i, i + carrier_length):
                consumed[j] = True
            if i + carrier_length < n:
                shadowed[i + carrier_length] = True
            i += carrier_length
            continue

        # The shadow itself: no LEXICON match may start here.
        if shadowed[i]:
            i += 1
            continue

        # 2. lexicons — longest first, Verdict > Type > Characteristic.
        matched_length = 0
        for length in range(MAX_KEY_TOKENS, 0, -1):
            if i + length > n:
                continue
            key = " ".join(words[i:i + length])
            match = LEXICON.get(key)
            if match is None:
                continue

            # §2.5 — the window is STRICTLY preceding and three tokens wide,
            # evaluated over the raw normalized stream (consumption and
            # shadowing are ignored), so `nothing special` is not suppressed by
            # its own `nothing`.
            if any(words[k] in BLOCKERS for k in range(max(0, i - 3), i)):
                break      # discarded, tokens released, resume at i + 1
            # §2.7 — tags and types may appear anywhere; a verdict may not.
            if match.kind is MatchKind.VERDICT and not (i >= n - 6 or n <= 4):
                break

            proposal = NoteProposal(
                value=match.value,
                span_start=tokens[i].start,
                span_end=tokens[i + length - 1].end,
                confidence=confidence(key, match.value),
                accepted=False)
            if match.kind is MatchKind.VERDICT:
                verdict = proposal            # single-valued: last wins
            elif match.kind is MatchKind.CATEGORY:
                category = proposal           # single-valued: last wins
            else:
                # Tags accumulate: unique by value, ordered by first appearance,
                # and the span recorded is the FIRST one.
                if match.value not in seen_tags:
                    seen_tags.add(match.value)
                    tags.append(proposal)
            for j in range(i, i + length):
                consumed[j] = True
            matched_length = length
            break
        i += matched_length if matched_length else 1

    return NoteProposals(verdict=verdict, category=category, tags=tuple(tags))


# -------------------------------------------------------- §2.7 segment scope

def segment_verdict(utterances: Sequence[str],
                    locale: str = "en-US") -> Optional[NoteProposal]:
    """The verdict that pre-aims the chips for a whole SEGMENT — the run of
    utterances attributed to one preset (§4).

    Candidates are the verdict proposal of the LAST utterance plus the verdict
    proposal of every utterance of 4 tokens or fewer; the latest candidate wins.
    So a bare `keep` said early in a long segment still counts, while a `keep`
    buried in the middle of a long sentence does not (the utterance-scope
    positional rule already rejected it).
    """
    winner: Optional[NoteProposal] = None
    last = len(utterances) - 1
    for index, utterance in enumerate(utterances):
        candidate = extract(utterance, locale=locale).verdict
        if candidate is None:
            continue
        if index == last or len(tokenize(utterance)) <= 4:
            winner = candidate
    return winner


# ------------------------------------------------------------------- §2.9

def alphabetic_token_count(text: str) -> int:
    """Tokens containing at least one Unicode letter. `303` is a token but not
    an alphabetic one."""
    return sum(1 for t in tokenize(text) if any(c.isalpha() for c in t.text))


def meets_content_gate(text: str) -> bool:
    """The empty-note gate: an utterance with fewer than TWO alphabetic tokens
    is not persisted as a note. Key clatter, headphone bleed and breath mostly
    transcribe to exactly that.

    This gate belongs to the CAPTURE path, not to `extract` — the separation is
    deliberate, and both cores apply it at the same boundary. `extract("dark")`
    correctly returns the tag `Dark`; the note is simply never written.
    """
    return alphabetic_token_count(text) >= 2
