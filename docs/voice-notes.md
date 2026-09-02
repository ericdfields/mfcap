# Voice notes — the two-core contract

Status: **pinned**. This document is written before any code and is the
definition of correct for BOTH cores (Swift `FreakCore`, Python `microfreak`).
Changing anything under "Pinned" here is a schema change: bump `schema`, update
`tests/fixtures/note_extraction.json`, and update both cores in the same
change.

Companion fixture: `tests/fixtures/note_extraction.json` — the shared extractor
cases. Both cores MUST load that file and pass every case.

Scope of this document:

1. The on-disk sidecar `notes/<entry_id>.json` (the interop surface).
2. The extractor: normalization, lexicons, suppression, positional rules.
3. The trust rules (verbatim text, corrections, advisory proposals).

Out of scope (implementation notes, not contract): the audio session, the
`SpeechAnalyzer` lifecycle, the UI. Those live in the app layer and in the
build notes; nothing in them may change the bytes described here.

---

## 0. Why a sidecar and not a field on `LibraryEntry`

`microfreak/library.py::_entry_to_json` builds a **fixed** dict:

```python
{"id", "name", "sha256", "meta_hex", "slot", "added_at",
 "tags", "category", "favorite", "verdict"}
```

and every Python write path rewrites *every* entry through it. A `note` field
added to `LibraryEntry` on the Swift side would therefore be **silently
destroyed** the first time any Python tooling touched the library — no error,
no diff, just gone.

Notes are therefore a **per-entry sidecar file**, mirroring the existing
`collections/<id>.json` precedent: a separate file that whole-index rewrites
cannot reach.

```
<library root>/
  index.json
  blobs/<sha256>.bin
  collections/<collection id>.json
  notes/<entry id>.json          <-- new
```

Keyed on `entry.id` (uuid4 hex), which is minted at `add()` and **survives
rename**, unlike `name` or `slot`, and is stable across re-import unlike
`sha256` (two entries may share a blob).

---

## 1. Pinned: the sidecar schema

### 1.1 File

- Path: `<library root>/notes/<entry_id>.json`, `entry_id` lowercase uuid4 hex.
- One file per entry. The `notes/` directory is created lazily on first write.
- Written with the existing atomic helpers — `AtomicFile.write` (Swift) /
  `atomic_write_text` (Python) — temp file + rename, so a reader never sees a
  torn file.
- JSON, UTF-8, 2-space indent (matches `index.json` and the collection files).
- **A missing file means zero notes.** It is never an error.
- A file that is present but unparseable raises the same error the collection
  reader raises (`LibraryCorruptError` / `FreakError.libraryCorrupt`).
- Deleting an entry deletes its sidecar. A sidecar with no matching entry is
  ignored on read and may be garbage-collected; it is never resurrected.

**Every edit to an existing sidecar goes through one indivisible call.** Both
cores expose `mutateNotes` / `mutate_notes` (read, transform, rewrite),
`moveNote` / `move_note` and `removeNote` / `remove_note`, and callers MUST use
them rather than reading a note list, mapping it, and replacing it. Read-then-
replace is two hops with a suspension in the middle — a real actor suspension
on the Swift side — and a note appended in that gap is read by nobody and then
overwritten by the stale list the caller is still holding. There is no throw
and no diagnostic, and because §1.5 keeps no audio the verbatim transcript that
disappears was the only copy that ever existed. The everyday trigger is
ordinary: the user taps a ghosted chip while the transcriber is still running.

`move_note` **appends to the destination before it removes from the source**.
The append can fail for reasons that belong entirely to the destination (the
entry was deleted, its sidecar carries a newer schema, any write error), and
removing first meant such a failure destroyed the note instead of moving it.
This order can at worst leave the note in both files, which a user can see and
fix.

### 1.2 Schema gate (forward compatibility)

`schema` is an integer, currently `1`. A core that reads a sidecar whose
`schema` is **greater than the version it knows** MUST treat that file as
read-only: it may display the notes it understands, and it MUST NOT rewrite the
file. This is the whole protection against the failure mode described in §0
happening again inside the sidecar. Unknown keys are not required to be
round-tripped; the schema gate is what makes that safe.

### 1.3 Document

```json
{
  "schema": 1,
  "entry_id": "c78e5cd14acb49b1bf08b66d609a714a",
  "notes": [ { /* note objects, see 1.4 */ } ]
}
```

| key        | type            | null? | notes |
|------------|-----------------|-------|-------|
| `schema`   | int             | no    | `1` |
| `entry_id` | string          | no    | 32 lowercase hex, equals the filename stem |
| `notes`    | array of object | no    | may be empty; ordered — see below |

`notes` is ordered ascending by `recorded_at`, ties broken ascending by
`audio_start`, ties broken by `id` lexicographically. Both cores write that
order; readers may rely on it.

### 1.4 Note object

```json
{
  "id": "9f2c4a1e7b0d4f6a8c3e5d7b9a1c2e4f",
  "recorded_at": "2026-09-02T14:03:11",
  "source": "voice",
  "text": "nice dark pad, bit too noisy, keep",
  "text_corrected": null,
  "locale": "en-US",
  "session_id": "31d0b6c58f9e4a7d8b2c1e0f4a6d8b3c",
  "audio_start": 12.48,
  "audio_end": 15.92,
  "device_identity": "hardware",
  "proposals": {
    "verdict":  {"value": "keep", "span": [30, 34], "confidence": 0.9, "accepted": true},
    "category": {"value": "pad",  "span": [10, 13], "confidence": 0.9, "accepted": false},
    "tags": [
      {"value": "Dark",  "span": [5, 9],   "confidence": 0.9, "accepted": true},
      {"value": "Noise", "span": [23, 28], "confidence": 0.7, "accepted": false}
    ]
  }
}
```

| key               | type            | null? | pinned meaning |
|-------------------|-----------------|-------|----------------|
| `id`              | string          | no    | note id, lowercase uuid4 hex, 32 chars, no hyphens |
| `recorded_at`     | string          | no    | `"yyyy-MM-dd'T'HH:mm:ss"`, **local time, no timezone suffix, no fractional seconds** — byte-identical in shape to `added_at` / `created_at` |
| `source`          | string          | no    | `"voice"` or `"typed"`. Exactly these two in schema 1 |
| `text`            | string          | no    | **verbatim, immutable** — see §3 |
| `text_corrected`  | string or null  | yes   | explicit `null` when the user has not corrected it |
| `locale`          | string          | no    | BCP-47 identifier of the transcriber locale, e.g. `"en-US"`. For `source: "typed"`, the app's current locale |
| `session_id`      | string          | no    | lowercase uuid4 hex; one value per audition session, shared by every note captured in it |
| `audio_start`     | number          | no    | seconds, session-relative — see §1.5 |
| `audio_end`       | number or null  | yes   | seconds, session-relative; `null` only for `source: "typed"` |
| `device_identity` | string          | no    | `DeviceIdentity.stamp`: `"hardware"`, `"practice:<profile>"`, or `"none"` |
| `proposals`       | object          | no    | always present, never null — see §1.6 |

Conventions inherited from the existing format, restated so there is no room
to drift: **snake_case keys**; **explicit `null`** rather than an omitted key
(the way `index.json` writes `"slot": null`); **lowercase uuid4 hex without
hyphens** for every id; timestamps in the local `"%Y-%m-%dT%H:%M:%S"` shape
produced by `time.strftime` / the Swift equivalent.

### 1.5 `audio_start` / `audio_end` — and the no-audio rule

**NO RAW AUDIO IS EVER WRITTEN TO DISK.** Not a temp file, not a ring buffer
flushed on crash, not a debug build. The microphone purpose string promises
this in the user's own words:

> "Freak Librarian listens while you audition a preset so it can write down
> what you say about it. Your words are transcribed on this iPad and attached
> to that preset. No audio is recorded or saved, and your speech is never sent
> anywhere to be recognized."

**Why the promise is scoped that way.** The first draft ended "nothing leaves
the device", and the *transcript* does not honour that: notes live under
`Documents/Library/notes/`, and `Documents` is exposed in the Files app
(`UIFileSharingEnabled`) and included in iCloud Backup like the rest of the
library — which is the whole point of the phase-0 portable format. Excluding
`notes/` from backup would have made a spoken note the one piece of library
data that does not survive restoring an iPad, which is worse. So the sentence
promises exactly the two things the code enforces and nothing more: **no audio,
anywhere, ever**, and **no speech sent away to be recognized**. The setup panel
carries the same two clauses and adds where the written notes live, so the user
can reason about a backup or a copy.

`audio_start` and `audio_end` are therefore **timeline offsets, never
pointers**. They are seconds (floating point, written with at most 3 decimal
places) measured from the moment the session's analyzer was armed, on the audio
clock the tap owns (`framesFed / sampleRate`) — the same timeline the
`SpeechTranscriber` result `CMTimeRange` values live on. They exist so a note
can be ordered against its siblings and re-attributed to a neighbouring preset,
and for nothing else. There is no file they name and no file they could name.

`audio_end` is `null` for typed notes. It is never `null` for a stored voice
note: a voice note is only persisted from a **finalized** result, which always
carries a complete range.

**Rounding is pinned to Python's `round(x, 3)`.** Both cores must write the
same number, and "three decimal places" is not enough to guarantee that:
scaling first — `(x * 1000).rounded(.toNearestOrEven) / 1000` — manufactures a
tie the true binary value does not have. `0.0685` (frame 3288 at 48 kHz) is
really `0.068500000000000005` and rounds **up** to `0.069`, but the scaled
product lands on exactly `68.5` and banker's rounding takes it **down**;
`0.2055` diverges the other way. Swift's `roundTo(_:places:)` therefore formats
to `places` decimals and re-parses, which is correctly rounded against the true
value and agrees with Python on every input.

What the two cores may still differ on is the **token** for an integral value:
Python's `json` writes `0.0`, Swift's `JSONSerialization` normalizes it to `0`.
Both parse back to the same number and no reader can tell — the same class of
cosmetic difference as key ordering, which already differs between the cores in
every shared file.

**Malformed numbers fall back; they do not raise and they do not truncate.**
`id` and `text` are the only required keys (§1.4); every other key falls back
the way the index reader's do. A `span` that is not a pair of integers reads as
`[0, 0]` (which addresses nothing, so nothing is underlined), and an
`audio_start` / `audio_end` / `confidence` that is not a number — a string, an
object, a JSON `true` — falls back to `0.0` / `null` / `0.0`. Both cores do
exactly this, so a hand-edited or foreign sidecar reads the same on either
side.

### 1.6 `proposals`

```json
"proposals": {
  "verdict":  null | {"value": <Verdict.slug>,  "span": [int, int], "confidence": <float>, "accepted": <bool>},
  "category": null | {"value": <Category.slug>, "span": [int, int], "confidence": <float>, "accepted": <bool>},
  "tags":     [ {"value": <Arturia characteristic display string>, "span": [int, int], "confidence": <float>, "accepted": <bool>} ]
}
```

- `proposals` is always an object with all three keys present.
- `verdict` and `category` are single-valued: an object or explicit `null`.
- `tags` is always an array; empty when there are no tag proposals. Entries are
  unique by `value` and ordered by **first appearance** in `text`.
- `value` is drawn from a **closed set** (§2.3). The extractor is table-driven
  and can never invent a value: `Verdict.slug`, `Category.slug`, or one of the
  18 exact Arturia characteristic display strings.
- `span` is `[start, end)` **Unicode scalar (code point) offsets into
  `text`** — the verbatim string, not the normalized one, and not
  `text_corrected`. Code points are pinned rather than UTF-16 units or bytes
  because both `str` indices in Python and `String.unicodeScalars` offsets in
  Swift are code points natively.
- `confidence` is a float in `[0, 1]` from the fixed table in §2.8. It is a
  match-strength tier, not a probability, and never comes from a model.
- `accepted` is `false` at write time. It becomes `true` at the moment the user
  taps to confirm the proposal **and** the canonical setter succeeds. It is
  never flipped back: a later user change to the entry does not rewrite history
  in the sidecar. `accepted` records what the user confirmed, not what the
  entry currently says.

### 1.7 Worked example — full file

```json
{
  "schema": 1,
  "entry_id": "c78e5cd14acb49b1bf08b66d609a714a",
  "notes": [
    {
      "id": "9f2c4a1e7b0d4f6a8c3e5d7b9a1c2e4f",
      "recorded_at": "2026-09-02T14:03:11",
      "source": "voice",
      "text": "nice dark pad, bit too noisy, keep",
      "text_corrected": null,
      "locale": "en-US",
      "session_id": "31d0b6c58f9e4a7d8b2c1e0f4a6d8b3c",
      "audio_start": 12.48,
      "audio_end": 15.92,
      "device_identity": "hardware",
      "proposals": {
        "verdict": {"value": "keep", "span": [30, 34], "confidence": 0.9, "accepted": true},
        "category": {"value": "pad", "span": [10, 13], "confidence": 0.9, "accepted": false},
        "tags": [
          {"value": "Dark", "span": [5, 9], "confidence": 0.9, "accepted": true},
          {"value": "Noise", "span": [23, 28], "confidence": 0.7, "accepted": false}
        ]
      }
    },
    {
      "id": "5b1e8d3c7a094f2b6d8e0c4a2f7b9d13",
      "recorded_at": "2026-09-02T14:07:44",
      "source": "typed",
      "text": "revisit with the filter opened up",
      "text_corrected": null,
      "locale": "en-US",
      "session_id": "31d0b6c58f9e4a7d8b2c1e0f4a6d8b3c",
      "audio_start": 285.0,
      "audio_end": null,
      "device_identity": "hardware",
      "proposals": {
        "verdict": {"value": "try_later", "span": [0, 7], "confidence": 0.7, "accepted": false},
        "category": null,
        "tags": []
      }
    }
  ]
}
```

---

## 2. Pinned: the extractor

The extractor is **pure, table-driven, Foundation-only** (`import Foundation`
in Swift; the standard library only in Python). No ML, no network, no
tokenizer library, no regex engine features beyond simple character
classification. Given the same input string and the same tables, both cores
produce byte-identical proposals. That property is what
`tests/fixtures/note_extraction.json` tests.

### 2.0 Unit of work, and the two scopes

`extract(_ utterance: String, locale:) -> Proposals` operates on **one
utterance** — the text of **one finalized `SpeechTranscriber.Result`**, or one
typed note. That is the unit the fixture defines.

There is a second, larger scope: a **segment** is the run of utterances
attributed to one preset (see §4). Segment scope adds exactly one rule, in
§2.7. Everything else in §2 is utterance scope.

**Locale gate:** the v1 lexicons are English. If `locale` does not begin with
`en`, `extract` returns empty proposals (`verdict: null`, `category: null`,
`tags: []`). Transcription still runs and the note is still stored verbatim —
only the advisory layer is skipped.

### 2.1 Normalization

Applied in this order, exactly:

1. Unicode **NFC**.
2. Locale-independent **lowercase** (`str.lower()` / `String.lowercased()`).
3. **Contraction expansion** against the fixed table below, matched on
   whitespace-delimited tokens.
4. Any remaining apostrophe (`'`, `’`) is **deleted**, joining the token
   (`synth's` -> `synths`).
5. Every character that is not a Unicode letter or a decimal digit is replaced
   by a single space. (Digits are kept: `303`, `808`, `8 bit`.)
6. Collapse runs of whitespace; trim.

Contraction table (pinned; matched whole-token, longest first):

| in | out | | in | out |
|---|---|---|---|---|
| `isn't` | `is not` | | `i'm` | `i am` |
| `wasn't` | `was not` | | `i've` | `i have` |
| `aren't` | `are not` | | `i'll` | `i will` |
| `weren't` | `were not` | | `i'd` | `i would` |
| `don't` | `do not` | | `you're` | `you are` |
| `doesn't` | `does not` | | `you've` | `you have` |
| `didn't` | `did not` | | `you'll` | `you will` |
| `can't` | `can not` | | `you'd` | `you would` |
| `cannot` | `can not` | | `we're` | `we are` |
| `won't` | `will not` | | `we've` | `we have` |
| `wouldn't` | `would not` | | `we'll` | `we will` |
| `shouldn't` | `should not` | | `they're` | `they are` |
| `couldn't` | `could not` | | `it's` | `it is` |
| `haven't` | `have not` | | `that's` | `that is` |
| `hasn't` | `has not` | | `there's` | `there is` |
| `hadn't` | `had not` | | `let's` | `let us` |
| `ain't` | `is not` | | `thats` | `that is` |

Note the deliberate consequence: `I'd keep this` becomes `i would keep this`,
and `would` is a hedge (§2.5), which suppresses the verdict. That is correct —
it is a wish, not a filing decision.

### 2.2 Tokenization and offsets

Tokens are the whitespace-delimited runs of the normalized string. Each token
carries the `[start, end)` **code point range in the original verbatim
string** that produced it. The mapping is carried *through* normalization; it
is never re-derived by searching the original for the normalized token.

Two pinned details, because spans are compared across cores:

- **Leading and trailing characters dropped by step 5 are not part of the
  span.** In `nice dark pad, bit too noisy, keep` the token `pad` spans
  `[10, 13)`, not `[10, 14)` — the comma is excluded. Punctuation *interior*
  to a token is a different matter: it splits the token, and each piece carries
  its own range.
- A contraction that expands to several tokens gives every piece the range of
  the single original token (`don't` -> `do` and `not` both span `[0, 5)`).

A multi-token match's span runs from the start of its first token to the end of
its last.

Token positions in this document are **1-based** when counting for the
positional rules, and matches are described by the 0-based token index of their
first token; both cores may use whatever indexing they like as long as the
rules below hold.

### 2.3 The three lexicons — canonical values

A lexicon is a map from a 1-, 2-, or 3-token **key** (already normalized) to a
canonical value. The canonical values are the only things the extractor can
ever emit.

#### 2.3.1 Verdict — canonical value is `Verdict.slug`

`unrated` is **never** proposed; it is the absence of a verdict.

| canonical | keys |
|---|---|
| `keep` | `keep`, `keeper`, `a keeper`, `definite keeper`, `real keeper`, `keep it`, `keep this`, `keep that`, `keeping this`, `keeping it`, `save it`, `save this`, `love it`, `love this`, `i love it`, `i like it`, `like it`, `winner`, `yes keep` |
| `try_later` | `try later`, `try it later`, `maybe later`, `come back`, `come back to`, `revisit`, `revisit later`, `not now`, `another time`, `some other time`, `park it`, `shortlist`, `shortlist it`, `bookmark it`, `hold on to` |
| `meh` | `meh`, `nah`, `pass`, `boring`, `not interesting`, `nothing special`, `so so`, `not for me`, `not feeling it`, `underwhelming`, `forgettable`, `bit dull`, `not doing it` |
| `never` | `never`, `never again`, `delete it`, `delete this`, `bin it`, `bin this`, `trash it`, `trash this`, `no way`, `hate it`, `hate this`, `awful`, `terrible`, `horrible`, `useless`, `junk`, `rubbish`, `garbage` |

Deliberate **exclusions**, and why:

- bare `yes` / `yeah` / `yep` / `ok` — they answer questions, they do not file
  presets, and they are common enough that the trailing-6 window does not save
  them.
- bare `later` and bare `maybe` — `maybe too noisy` is three tokens, so the
  `<= 4` clause (§2.7) would fire on `maybe`. `maybe later` is safe; `maybe`
  is not.
- `pass` is included but is protected by the `high pass` / `low pass` /
  `band pass` / `pass filter` carriers in §2.6. Without those it would be a
  disaster in a synth vocabulary.
- `get rid` — `get rid of the noise` is a request to reduce noise, not a
  decision to bin the preset. The unambiguous forms (`bin it`, `trash it`,
  `delete it`) carry that meaning without the ambiguity, and the `rid of the`
  carrier suppresses the tag in the request form.

#### 2.3.2 Type — canonical value is `Category.slug`

The 12 Arturia Types, from `docs/arturia-taxonomy.md`. `uncategorized` is never
proposed.

| canonical | keys |
|---|---|
| `bass` | `bass`, `bassline`, `bass line`, `sub bass`, `bass sound`, `bass patch`, `bass note` |
| `brass` | `brass`, `brass section`, `horn`, `horns`, `horn section`, `trumpet`, `trombone` |
| `keys` | `keys`, `piano`, `electric piano`, `rhodes`, `wurli`, `clav`, `clavinet`, `keyboard sound` |
| `lead` | `lead`, `lead sound`, `lead line`, `lead patch`, `solo sound`, `top line` |
| `organ` | `organ`, `hammond`, `tonewheel`, `church organ`, `b3` |
| `pad` | `pad`, `pads`, `pad sound`, `pad patch`, `string pad` |
| `percussion` | `percussion`, `percussion hit`, `drum`, `drums`, `drum sound`, `drum hit`, `kick`, `snare`, `hi hat`, `hihat`, `clap`, `rimshot`, `tom` |
| `sequence` | `sequence`, `sequenced`, `sequence patch`, `seq`, `arp`, `arpeggio`, `arpeggiator`, `arpeggiated` |
| `sfx` | `sfx`, `sound effect`, `sound effects`, `fx`, `riser`, `downlifter`, `whoosh`, `impact`, `sound design`, `noise sweep` |
| `strings` | `strings`, `string section`, `string ensemble`, `violin`, `violins`, `cello`, `orchestral strings` |
| `template` | `template`, `init patch`, `init`, `blank patch`, `starting point`, `starter patch` |
| `vocoder` | `vocoder`, `vocoded`, `vocoder patch`, `talk box`, `talkbox`, `robot voice` |

Arturia's website surfaces `percussion` as "Drums" and `sfx` as "Sound
Effects"; those are display aliases of the same canonical slugs, which is why
both wordings appear as keys above.

Deliberate exclusions: bare `key` (`the key of C`, `key clatter`), bare
`effect` (`the effect is nice`, `reverb effect`), bare `pattern`, bare `riff`,
bare `texture`, bare `sequencer`.

#### 2.3.3 Characteristic — canonical value is the **exact Arturia display string**

The 18 values from `docs/arturia-taxonomy.md`, written exactly as they already
appear in `entry.tags`: `Acid`, `Aggressive`, `Ambient`, `Bizarre`, `Bright`,
`Complex`, `Dark`, `Digital`, `Ensemble`, `Funky`, `Hard`, `Long`, `Noise`,
`Quiet`, `Short`, `Simple`, `Soft`, `Soundtrack`. **Capitalized exactly as
shown** — these are the strings the filter chips match on.

| canonical | keys |
|---|---|
| `Acid` | `acid`, `acidy`, `acidic`, `303`, `tb 303`, `squelchy`, `squelch` |
| `Aggressive` | `aggressive`, `aggressively`, `aggro`, `angry`, `nasty`, `brutal`, `vicious`, `savage`, `mean`, `in your face` |
| `Ambient` | `ambient`, `atmospheric`, `atmosphere`, `dreamy`, `ethereal`, `floaty`, `airy`, `spacey`, `washy`, `wash` |
| `Bizarre` | `bizarre`, `weird`, `strange`, `odd`, `freaky`, `wonky`, `alien`, `otherworldly`, `unhinged`, `bonkers` |
| `Bright` | `bright`, `brighter`, `brightness`, `brilliant`, `sparkly`, `sparkling`, `shiny`, `crisp`, `glassy`, `zingy` |
| `Complex` | `complex`, `complicated`, `intricate`, `layered`, `evolving`, `busy`, `dense` |
| `Dark` | `dark`, `darker`, `darkness`, `murky`, `gloomy`, `moody`, `brooding`, `shadowy`, `somber`, `sombre` |
| `Digital` | `digital`, `dx`, `fm`, `8 bit`, `eight bit`, `bitcrushed`, `bit crushed`, `lo fi`, `chiptune`, `plasticky`, `computery` |
| `Ensemble` | `ensemble`, `unison`, `chorused`, `chorusy`, `wide`, `stacked`, `detuned stack` |
| `Funky` | `funky`, `funk`, `funked up`, `groovy`, `groove`, `syncopated` |
| `Hard` | `hard`, `hard edged`, `harsh`, `edgy`, `biting`, `gritty`, `abrasive`, `rough` |
| `Long` | `long`, `long release`, `long tail`, `sustained`, `drawn out`, `lingering` |
| `Noise` | `noise`, `noisy`, `hiss`, `hissy`, `static`, `crackle`, `crackly`, `white noise`, `fizzy` |
| `Quiet` | `quiet`, `quietly`, `low volume`, `subdued`, `understated`, `hushed`, `whispery`, `faint` |
| `Short` | `short`, `short release`, `plucky`, `pluck`, `staccato`, `snappy`, `clipped`, `stab`, `stabby` |
| `Simple` | `simple`, `basic`, `plain`, `minimal`, `bare bones`, `straightforward`, `uncomplicated`, `stripped back` |
| `Soft` | `soft`, `softer`, `gentle`, `mellow`, `smooth`, `warm`, `velvety`, `silky`, `round`, `muffled` |
| `Soundtrack` | `soundtrack`, `cinematic`, `filmic`, `film score`, `movie score`, `epic`, `trailer music`, `scoring` |

Deliberate exclusions: bare `sharp` (tuning), bare `tight`, bare `dull`, bare
`moving`, bare `score`, bare `choir`, bare `punchy`.

### 2.4 The scan

Left to right over the token stream. At each position `i` that is not already
consumed:

1. **Carrier stoplist first** (§2.6): try 3-, then 2-, then 1-token keys. On a
   hit, consume those tokens, shadow the next token, and advance past them.
   *No lexicon match is attempted at this position.* This step runs **even at a
   shadowed position** — see §2.6, "carriers chain".
2. **Lexicons**: skipped entirely at a shadowed position (§2.6). Otherwise try
   3-, then 2-, then 1-token keys, across all three lexicons at each length.
   Ties at the same length break in the order **Verdict, Type,
   Characteristic**.
3. On a lexicon hit, apply §2.5 (negation/hedge) and, for a Verdict hit, §2.7
   (positional rule). If suppressed, the candidate is **discarded and its
   tokens are released** — the scan resumes at `i + 1` and shorter keys are not
   retried at `i`.
4. On an accepted hit, the matched tokens are **consumed**: they cannot
   contribute to another match. This is what makes `string ensemble` produce
   the Type `strings` and *not* also the Characteristic `Ensemble`.

Longest-match-wins plus consumption is the whole disambiguation story. There is
no scoring, no backtracking, no ambiguity resolution beyond the tie order
above.

### 2.5 Negation and hedge window — **suppress only, never invert**

A lexicon candidate whose first token is at index `i` is **suppressed** if any
of the tokens at `i-1`, `i-2`, `i-3` is in the set below. The window is
**strictly preceding** and does not include the match's own tokens (so
`nothing special` is not suppressed by its own `nothing`). The window is
evaluated over the raw normalized token stream and ignores consumption and
shadowing.

**Three tokens, no more.** `maybe too bright` suppresses `Bright`; `maybe a bit
too bright` does not, because `maybe` is four tokens back. That boundary is
deliberate and is fixed by two fixture cases.

Negators: `not`, `no`, `nor`, `none`, `nothing`, `never`, `without`, `barely`,
`hardly`, `lacks`, `lacking`, `stop`, `remove`, `reduce`, `less`.

Hedges: `maybe`, `might`, `perhaps`, `possibly`, `could`, `would`, `should`,
`if`, `unless`, `almost`, `wish`, `want`, `wanted`, `needs`, `need`, `trying`.

Explicitly **not** hedges — they are intensity qualifiers and the attribute is
still being asserted: `bit`, `a bit`, `kinda`, `kind`, `sort`, `slightly`,
`quite`, `pretty`, `very`, `really`, `too`, `way`.

> `nice dark pad, bit too noisy, keep` must yield `Noise`. If `bit` or `too`
> were hedges it would not. That is why they are not.

**Suppression never inverts.** `not dark` yields *nothing* — it does not yield
`Bright`. There is no antonym table anywhere in this design. The absence of an
attribute is not the presence of its opposite, and a librarian that guesses
otherwise is worse than one that stays quiet.

`never` appears in both the negator set and the Verdict lexicon. That is
intentional: in `I would never keep this`, `never` matches the Verdict `never`
*and* suppresses the following `keep` — which is the right reading.

### 2.6 Carrier-phrase stoplist

This is **the single biggest false-positive control in the design**, because
the 18 Arturia Characteristics include very common English words — Hard, Long,
Short, Simple, Quiet, Bright, Dark, Complex, Noise.

A carrier is a 1–3 token key checked **before** the lexicons at every position
(§2.4 step 1), longest first. On a hit it (a) consumes its own tokens and (b)
**shadows the immediately following token**, which may not start a lexicon
match. The shadow is what makes `cut the noise` — a request to reduce noise —
produce no `Noise` tag.

The shadow is **exactly one token wide**, and that is a deliberate limit:
`turn down the brightness` still yields `Bright`, because `brightness` is two
tokens past the carrier. Widening the shadow would start swallowing real
descriptions. When a specific phrase proves noisy in use, the fix is a longer
carrier plus a fixture case — never a wider shadow.

**Carriers chain.** A shadow forbids a **lexicon** match at that position; it
must *not* forbid a **carrier** match there. Both cores got this wrong at
first, identically, and the result was that one carrier disarmed the next and
re-exposed the very key the next carrier existed to protect:

```
cut the high pass on this one
 └───┬──┘ └───┬──┘
 carrier   carrier — never fired, because `high` was shadowed
                     …so bare `pass` matched the `meh` verdict
```

`high pass` / `low pass` / `band pass` are in the table precisely so `pass`
cannot read as the `meh` verdict in synth vocabulary. A request to *cut the
high pass* must therefore not pre-aim a verdict chip. Fixture cases
`carrier_chain_cut_the_high_pass`, `carrier_chain_lose_the_low_pass` and
`shadow_still_blocks_a_lexicon_key` pin both halves: carriers chain, and the
shadow itself still blocks the lexicon.

The ten marked **[required]** are fixed by this contract and by the fixture;
the rest are v1 additions and may be extended, but only additively and only
with a fixture case.

| protects | carriers |
|---|---|
| `Hard` | `hard to` **[required]**, `hard time` **[required]**, `hard for`, `hard work`, `hard drive`, `hard on` |
| `Short` | `short of` **[required]**, `in short`, `short on`, `cut short`, `falls short`, `for short`, `short while` |
| `Long` | `long time` **[required]**, `not long` **[required]**, `as long as`, `how long`, `so long`, `long story`, `long way`, `before long` |
| `Simple` | `simple as` **[required]**, `simple to`, `simply put` |
| `Quiet` | `quiet down` **[required]**, `be quiet`, `keep quiet` |
| verdict `keep` | `keep the` **[required]**, `keep it in` **[required]**, `keep going`, `keep up`, `keep an eye`, `keeps the` |
| requests, not descriptions | `cut the` **[required]**, `lose the`, `rid of the`, `dial back`, `back off`, `turn down`, `turn up` |
| verdict `pass` | `high pass`, `low pass`, `band pass`, `pass filter`, `pass through` |
| verdict `never` | `never mind` |
| `keys` / `lead` | `key of`, `the key`, `lead to`, `leads to`, `lead into` |

`not long` is redundant with the negator window and is listed anyway, because
the contract names it and redundant defence is cheap.

### 2.7 The verdict positional rule

Tags and types may appear anywhere in an utterance. **A verdict may not.**
`I would keep the filter setting but cut the noise` is a sentence about a
filter, not a decision to file the preset.

**Utterance scope.** A verdict candidate is accepted only if:

- its first token lies within the **trailing 6 tokens** of the utterance, **or**
- the whole utterance is **4 tokens or fewer**.

At utterance scope the second clause is subsumed by the first (any token of a
≤4-token utterance is within the trailing 6). It is stated anyway because it is
load-bearing at the next scope.

**Segment scope** (§4). Within a segment — the run of utterances attributed to
one preset — the verdict that pre-aims the chips is taken from:

- the verdict proposal of the **last** utterance in the segment, or
- the verdict proposal of any utterance in the segment that is **4 tokens or
  fewer**, which wins over the last-utterance one if both exist and the short
  one is later.

So a bare `keep` said early in a long segment still counts; a `keep` buried in
the middle of a long sentence does not.

**Single-valued proposals are last-wins.** If an utterance yields two verdict
candidates, or two type candidates, the **later** one wins — a speaker
correcting themselves (`sounds like a bass, actually more of a lead`) means the
second thing. Tags accumulate instead: unique by value, ordered by first
appearance, and the span recorded is the **first** one.

**Order of operations matters and is pinned:** suppression (§2.5, §2.6, and the
positional rule above) is applied at match time, and last-wins operates only
over the candidates that *survived*. In `honestly this is meh, actually no,
keep it`, `keep it` is killed by the negator `no`, so the earlier `meh` stands
— last-wins does not resurrect a suppressed candidate.

### 2.8 Confidence

A fixed tier table. Not a probability, never from a model:

| tier | value | condition |
|---|---|---|
| exact | `0.9` | the matched key **is** the canonical value, case-insensitively (`dark` -> `Dark`, `keep` -> `keep`, `pad` -> `pad`) |
| phrase | `0.8` | the matched key is a 2- or 3-token synonym (`long release`, `a keeper`, `string ensemble`) |
| synonym | `0.7` | the matched key is a 1-token synonym (`murky`, `keeper`, `arp`) |

### 2.9 The empty-note gate — the caller's job, not the extractor's

A captured utterance is **not persisted as a note** if it contains fewer than
**two alphabetic tokens** (a token containing at least one Unicode letter).
Key clatter, headphone bleed and breath mostly transcribe to exactly that.

This gate belongs to the capture path, not to `extract`. `extract("dark")`
correctly returns the tag `Dark`; the note is simply never written. The
separation is deliberate — the fixture tests `extract` alone, and both cores
apply the gate at the same boundary.

---

## 3. Pinned: the trust rules

These three rules are the reason this feature can exist without making the
library less trustworthy. They are not negotiable.

**1. `text` is verbatim and immutable.** What the transcriber finalized is
what is stored, forever. It is never cleaned, never re-cased, never
punctuation-fixed, never regenerated by a later model. A user correction is a
**sibling** field, `text_corrected`, and the original stays. A note therefore
always shows what was actually heard, which is the only way a user can tell a
mishearing from a mistake they made.

**2. Proposals are advisory. A transcript never changes a preset attribute on
its own.** The extractor writes into `proposals` and nowhere else. In the UI:

- a **verdict** proposal *pre-aims* the existing `VerdictChips` — the matching
  chip is highlighted and captioned `heard "keep"` — and the user still taps.
  A mishear costs one glance and no data.
- **type** and **characteristic** proposals render as ghosted chips that a tap
  promotes.
- an end-of-session review sheet is the catch-all for anything not tapped in
  the moment.

The optional "let voice file verdicts after a countdown" idea is **out of scope
for v1**. The loop is already one tap; a countdown only adds a way to be wrong
while the user's hands are on the keys.

**3. The sidecar is provenance, never a second source of truth.** When the user
accepts a proposal, the value is written to its **canonical home** through the
existing library setters —

| proposal | canonical setter (Swift / Python) |
|---|---|
| verdict | `Library.setVerdict(id:to:)` / `Library.set_verdict` |
| category | `Library.setCategory(id:to:)` / `Library.set_category` |
| tags | `Library.setTags(id:to:)` / `Library.set_tags` |

— so that every filter, every census, every Python consumer and every
`.mfpreset` export sees it unchanged, with no knowledge that a microphone was
involved. The sidecar then records `accepted: true` and nothing more. **No
reader anywhere may consult `notes/` to determine an entry's verdict, category
or tags.** If the sidecar directory were deleted, the library would be exactly
as correct as before; only the provenance would be gone.

`accepted` is **scoped to the session the user was in**. An acceptance marks
the proposals on notes from *this* session only. Stamping it onto a note from
an audition weeks ago — one whose identical proposal the user deliberately did
not tap — would make the sidecar assert a confirmation that never happened,
which is the one thing a provenance record may not do.

**4. The listening indicator may never disagree with the hardware.** App Review
2.5.14 requires the app's own indication that the microphone is in use, and an
indicator that pulses while nothing is being heard is worse than none: it
teaches the user that the light means nothing. So the pill is drawn from
`isCapturing` (armed **and** actually reading the mic), never from `isListening`
(armed). Every way capture can stop without the user asking — an audio
interface taking the one input route, an interruption, a tap that could not be
rebuilt, backgrounding — reports itself, clears the pill, and puts a sentence
naming the fix under the preset name. The mute control is a real mute
(`AVAudioApplication.isInputMuted`), and because that flag is **process-global
and outlives a session** it is set explicitly at both ends of every session
rather than assumed.

**One input route per process.** The built-in mic and an attached USB interface
cannot both be captured, and the interface is carrying the synth. The live
route is read back after pinning, and if it is not the built-in mic capture is
**suspended and explained** — never started, never rebuilt onto the interface.
The route cannot be read before a recording session exists, so the pre-flight
row says "not yet known" rather than guessing; enforcement happens in the
session, where the route is real, and lifts by itself when the interface is
unplugged.

---

## 4. Attribution (how a note gets its `entry_id`)

Recorded here because it determines which file a note lands in, which makes it
part of the interop contract.

One analyzer runs for the **whole audition session** — never one per preset
(risking `insufficientResources`, and losing the first words of every preset
during the analyzer's start-up write). Attribution is therefore by **timeline**,
not by restarting the recognizer.

The session keeps segments `[(entry_id, start: CMTime, end: CMTime?)]` on the
same audio clock as `audio_start` / `audio_end`.

**That clock counts only audio the analyzer actually received**, by the frame
count and sample rate it received it at — not what the tap delivered. The two
timelines that have to agree are this clock (read at every boundary tap) and
the transcriber's own result ranges (which advance on the audio it consumed).
Advancing the clock for a buffer that was dropped — a failed allocation, a
converter error — adds a permanent forward offset to every later boundary, and
that misattribution never self-corrects: it gets worse the longer the session
runs.

The user advances **manually** — there is no timer and no auto-advance — so
every boundary is a deliberate tap. Two rules still apply:

- **Deferred boundary.** A boundary requested at `T_tap` does not commit while
  an utterance is in flight — that is, while any volatile result has
  `range.end > T_tap`. It commits at the end of that utterance, capped at
  **3 seconds**, after which it commits regardless. This stops a sentence being
  cut in half when the user taps mid-phrase.
- **Midpoint assignment.** A finalized result belongs to the segment containing
  the **midpoint** of its `CMTimeRange`, not its start and not its end.

The live transcript renders directly under the preset name, so a misattribution
is visible within a second, and a one-tap **"move to previous preset"** action
rewrites the note into the neighbouring entry's sidecar (§1.1's `move_note`:
append to the destination first, then remove from the source; `audio_start` /
`audio_end` are unchanged, because they are session-relative, not
entry-relative).

---

## 5. Parity obligations

Both cores must:

1. Read and write `notes/<entry_id>.json` byte-compatibly: a file written by
   one core round-trips through the other with no field loss and no reordering
   beyond §1.3's defined order.
2. Honour the schema gate in §1.2 (never rewrite a newer schema).
3. Load `tests/fixtures/note_extraction.json` and pass every case. The fixture
   is the definition of correct; a disagreement between the cores is a fixture
   case that is missing, not a judgement call.
4. Never write audio, and never add a field that could hold audio or a path to
   audio.
5. Round `audio_start` / `audio_end` to the same value (§1.5), and fall back
   the same way on a malformed number or span (§1.5).
6. Offer, and use, the indivisible sidecar edits in §1.1 — no caller may
   read a note list and replace it as two separate steps.

Fixture case shape:

```json
{
  "id": "short_stable_slug",
  "transcript": "the utterance text, verbatim",
  "expected": {
    "verdict": "keep" | "try_later" | "meh" | "never" | null,
    "category": "<Category.slug>" | null,
    "tags": ["<exact Arturia display string>", ...]
  },
  "why": "one line explaining which rule this case pins"
}
```

`tags` is listed in **first-appearance order**; a core may compare it as a set,
but must *produce* first-appearance order in `proposals.tags`. `id` and `why`
are for humans and test output; only `transcript` and `expected` are load-
bearing.

Because `SpeechTranscriber` is hardware-gated and does **not** run in the iOS
Simulator, the Swift tests drive the extractor directly from this fixture, and
the session-level tests drive a `ScriptedTranscriber` stub — mirroring the
existing `SimulatedMicroFreak` pattern. No test opens a real microphone.
