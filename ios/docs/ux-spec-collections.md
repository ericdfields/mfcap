# Freak Librarian — iPad UX Specification, Addendum: Attributes & Collections

**Version 1.0 — 2026-09-01.** Extends `ux-spec.md` v2.0; does not supersede it. Section numbers
continue the base spec (§21–§29); every `§N` below 21 refers to the base spec. Where this addendum
restates a base-spec rule it is for continuity only — the base spec wins.

**Scope:** three cohesive additions, specified as screens, flows, states, new view-models, and
state ownership, in the base spec's idiom and reusing its component/view-model names:

1. **Preset attributes** — Arturia **category** (editable, device-byte auto-fill), free-form
   **tags** (already in the core), and a **favorite** flag. Persisted additively in the library
   index; old indexes still load; a library written by one core still opens in the other (Python
   ⇄ Swift), per architecture-spec §10.
2. **Collections** — a named device arrangement: a slot→preset map over the content-addressed
   library. Snapshot the device into one, import a `.mfprojz` bank as one, and Apply/Switch by
   diffing against current device state and writing only the changed slots.
3. **App UI** — category chip-grid browse/filter with per-category counts, a Favorites view, tag
   filtering, and a Collections screen with an Apply pre-flight diff summary and progress/cancel.

**Invariants inherited without exception:** names-first (§1.1); the full read pass *is* a backup
(§1.2); one device transaction at a time, one status surface (§1.3, §18.2 `DeviceOperationQueue`);
emptiness is a content verdict from `Analysis.findExpendable`, never a string match (§1.4, §10);
every overwrite previews its victim through one `OverwritePlan` component (§9); verified means
verified (§1.7); the app layer talks to FreakCore types only — never frames or bytes (§14). Offline
only: everything here is reachable and honestly paced against `SimulatedMicroFreak` (§11).

---

## 21. Preset-attribute model (category, tags, favorite)

### 21.1 What is stored, and where

Three attributes hang off a **library entry** — never off a device slot. A device slot is an
observation (§4); attributes are the librarian's editorial layer and live only in the library index.

`LibraryEntry` (FreakCore, architecture-spec §10.2) gains two fields; `tags` already exists:

| Field | Type | Index key | Absent-key default | Notes |
|---|---|---|---|---|
| `category` | `PresetCategory` | `"category"` | `.uncategorized` | stable lowercase key on disk (§21.2) |
| `tags` | `[String]` | `"tags"` | `[]` | unchanged from base |
| `favorite` | `Bool` | `"favorite"` | `false` | |

**Additive-format contract (hard):** the two new keys extend the schema-1 index in place. A
pre-attribute index (no `category`, no `favorite`) loads unchanged — the reader supplies the
defaults above. The writer emits the keys for every entry going forward. `schema` stays `1`; both
cores read and write the same keys with the same encodings (architecture-spec §10 pinning:
UTF-8, `sortedKeys`, ASCII values). `category` serializes as its stable key string; `favorite` as a
JSON bool. This keeps the Python ⇄ Swift byte-interoperability guarantee (parity constraint) intact,
and `LibraryTests`' interop assertions gain: unknown/absent → defaults, round-trip of both keys, and
an old-index-without-attributes load.

**Core mutation seam the UI relies on (replaces the base `setTags` re-add hack).** The base
`LibraryModel.setTags` currently removes and re-adds the entry, minting a new id — a flagged wart.
This addendum requires **id-preserving** attribute edits, backed by core `Library` mutators that
rewrite only the index entry (blob untouched, id and `added_at` preserved), atomic index write per
edit:

```
Library.setCategory(id:, PresetCategory) -> LibraryEntry
Library.setFavorite(id:, Bool)           -> LibraryEntry
Library.setTags(id:, [String])           -> LibraryEntry     // corrected: id-stable
```

These get golden/fixture coverage like every other core behavior (parity constraint); the Swift and
Python mutators produce byte-identical index entries for the same inputs.

### 21.2 Category taxonomy — one table, hardware-confirmable

`PresetCategory` is the **documented Arturia MicroFreak set plus Uncategorized**, and nothing beyond
it (established fact — do not invent categories). It lives in exactly one table:

```
PresetCategory : String, CaseIterable, Sendable        // rawValue = stable index key
  .bass          "bass"          "Bass"
  .brass         "brass"         "Brass"
  .keys          "keys"          "Keys"
  .lead          "lead"          "Lead"
  .organ         "organ"         "Organ"
  .pad           "pad"           "Pad"
  .percussion    "percussion"    "Percussion"
  .sequence      "sequence"      "Sequence"
  .sfx           "sfx"           "SFX"               // Arturia "SFX / Sound Effects"
  .strings       "strings"       "Strings"
  .template      "template"      "Template"
  .vocoder       "vocoder"       "Vocoder"
  .uncategorized "uncategorized" "Uncategorized"     // sorts last; the auto-fill fallback
```

Display order in every chip grid and picker follows this order (Uncategorized always last). The
`displayName` is the only user-facing string; `rawValue` is the on-disk/interop key.

**Device-byte auto-fill.** The device stores a category in **meta byte 7** (long-0x52 payload[10];
core-api §"payload map" line "category = meta[7]"). The decode is one table with a standing caveat:

```
// CategoryByte.decode(_ byte: UInt8) -> PresetCategory
// The documented MicroFreak taxonomy, index-ordered. NOT fully proven against
// ground truth (established fact): SimulatedMicroFreak assigns categories 0…11
// (factoryFresh uses `category = slot % 0x0C`), so this table is asserted by the
// simulator and its vectors, and is CONFIRMABLE against hardware. A wrong auto-fill
// is always user-correctable (§22.3) — that is why category is editable.
//   0 uncategorized · 1 bass · 2 brass · 3 keys · 4 lead · 5 organ · 6 pad
//   7 percussion · 8 sequence · 9 sfx · 10 strings · 11 template · 12 vocoder
//   anything else -> .uncategorized
```

The table above lists categories in **display** order (Uncategorized last); the **device-byte index**
puts `uncategorized` at 0, matching `collections-categories-spec.md` §1.1, both cores' one
`deviceByteTable`, and the `category.json` golden vector (ground truth: slot 200's byte `0x03` →
`keys`, byte `0x09` → `sfx`). The interop slug is `"sfx"` (display `"SFX"`), not `"sound_effects"`
— that is the single stable wire key both cores read and write.

This replaces the base spec's empty `CategoryByte.verifiedLabels` (§7.4) and its "display-only, v1
never edits" stance: category is now first-class and editable. The base spec's honesty note stays in
spirit — an unconfirmed mapping is *correctable*, not *hidden*.

**Auto-fill rule.** A category is derived, never guessed silently:

- **Read off the MicroFreak** (Save to Library, Pull, Import Device): the new entry's category =
  `CategoryByte.decode(meta[7])`. This is the *only* automatic category assignment.
- **Downloaded packs** (`.mfprojz` import): pack meta is all-zero (established fact — category is not
  in exported files). Byte `0x00` decodes to `.uncategorized`, but import does not lean on that
  coincidence — it **forces** `.uncategorized` for pack-sourced entries regardless of the meta byte,
  and the Collections import
  sheet states "arrives Uncategorized — tag it after import" (§26.3). No network, no web fetch,
  ever (established fact).
- **File import** (`.mfpreset`, raw blob): `.uncategorized` unless the file's meta byte 7 is
  non-zero, in which case decode it (same rule as a device read).

Editing the library category **does not alter the entry's stored `meta`** (meta round-trips verbatim
per protocol law; the blob sha is unaffected either way, but leaving meta untouched keeps device
round-trip byte-exact). Whether a confirmed mapping should later offer "also write this category
into the preset's meta so the synth shows it" is deferred (§29, open question 3).

### 21.3 `LibraryModel` intents and derived state (UI seam)

`LibraryModel` (base §18.2) gains attribute intents and faceted-filter state. It still never touches
the device.

```
// mutations (id-stable, backed by §21.1 core mutators; each awaits refresh())
func setCategory(id:, _ PresetCategory) async
func setCategory(ids: [String], _ PresetCategory) async     // bulk (§22.4)
func toggleFavorite(id:) async
func addTag(id:, _ String) async
func removeTag(id:, _ String) async
func setTags(id:, _ [String]) async                          // corrected, id-stable

// faceted-filter state (all @Observable; drive LibraryListView + chip grid)
var categoryFilter: PresetCategory?          // nil = all categories
var tagFilter: Set<String>                   // AND across selected tags
var favoritesOnly: Bool                      // set by the Favorites selection (§24)
// searchText, sort — unchanged (base §6)

// derived
func filtered(tag legacyTag: String?) -> [LibraryEntry]   // now ANDs category+tags+favorite+search
var categoryCounts: [PresetCategory: Int]                 // faceted (§22.2)
var favorites: [LibraryEntry]                             // favorite == true, current sort
func favoritedSha(_ sha256: String) -> Bool               // for the device-row heart (§24.2)
```

`filtered` composes every active facet (category ∧ tags ∧ favorite ∧ search) so the browser and its
sidebar-tag entry point (base §3) agree. The base `library(tag:)` sidebar children keep working: a
sidebar tag selection seeds `tagFilter = [tag]`.

---

## 22. Category browse & filter

### 22.1 The chip grid (`CategoryFilterBar`, `CategoryChip`)

A wrapping grid of category chips, mirroring Arturia's site, pinned as the header of
`LibraryListView` (content column) via `safeAreaInset(edge: .top)` so it stays put while the list
scrolls. Each chip: `displayName · count`. Order per §21.2; a chip with a zero count is dimmed and
non-tappable (present, so the taxonomy reads consistently), never hidden.

```
CategoryFilterBar (LazyVGrid, adaptive; collapses to a horizontal scroller under Dynamic Type XL)
  [ All 312 ] [ Bass 41 ] [ Keys 38 ] [ Pad 33 ] [ Lead 22 ] [ Sequence 18 ]
  [ Percussion 15 ] [ SFX 11 ] [ Strings 9 ] … [ Uncategorized 96 ]
```

- **Tap a chip → filters the browser.** Sets `categoryFilter`; the chip renders selected (filled
  tint, `accessibilityAddTraits(.isSelected)`). Tapping the selected chip, or the leading **All**
  chip, clears `categoryFilter`.
- Selection is single (one category at a time), matching Arturia; tag and favorite facets stack on
  top of it (AND).
- `CategoryChip` reuses the visual weight of `TagChip` (base Components) but carries a trailing count
  and a selected state; color is never the sole carrier of selection (fill + `.isSelected` trait +
  a checkmark on VoiceOver focus).

### 22.2 Counts are faceted and truthful

`categoryCounts` is computed over entries passing **every active facet except the category filter
itself** (standard faceted search), so a musician can see how many Bass presets exist *within* the
current tag/favorite/search scope and still switch categories freely. The **All** chip's count is the
total under those same non-category facets. Counts recompute on any library mutation (the existing
`LibraryModel.onChange` path) and on facet changes; no device traffic (names-first: this is all
local index data).

### 22.3 Category in preset detail — shown and editable

- **Library entry** (`LibraryEntryDetailView`): a `CategoryPickerRow` — a `Menu`/`Picker` over
  `PresetCategory.allCases` showing the current `displayName`, committing via
  `libraryModel.setCategory(id:_:)` (instant, local). This is where a wrong auto-fill is corrected.
  A small `CategoryBadge` (label chip) also appears on the entry row (`LibraryRowView`) beside the
  tag chips.
- **Device slot** (`SlotDetailView`): the base `CategoryByteRow` (§7.4) is upgraded from raw-hex to
  the decoded `displayName` with the raw byte in parentheses — `Keys (0x03)` — plus the standing
  info popover (`CategoryByte` caveat copy, reworded: "Category as stored by the synth. Confirmable
  against hardware; correct it after you save the preset to the library."). It stays **read-only on
  the device slot** — the device slot has no editable index entry; the value shown is exactly what
  will auto-fill when the slot is saved to the library. Editing happens on the library copy.

### 22.4 Multi-select bulk category assignment

`LibraryListView` gains Edit-mode multi-select (the base browser's `Select` affordance, §5, applied
to the library — checkboxes, no held modifiers, §13.3):

- Toolbar in Edit mode: **Set Category…** (a `Menu` over the taxonomy) · **Add Tag…** · **Favorite /
  Unfavorite** · **Send N to Slot…** (existing multi-send path, §8.1).
- **Set Category…** calls `libraryModel.setCategory(ids:_:)` over the selection — one atomic-per-entry
  index rewrite each, all local and instant, then a toast: "Set 24 presets to Keys." No confirmation
  dialog: it is local and reversible by re-selecting (nothing touches the device, so the §9 guard
  rails do not apply — those are for device writes only).

---

## 23. Tags

Tags exist in the core already (base §6); this section upgrades the *editing* and *filtering*, it
adds no persistence.

### 23.1 Tag editor (`TagEditor`) — add/remove, not comma-soup

The base spec's comma-string alert (`LibraryRowView`) is replaced by a `TagEditor` in
`LibraryEntryDetailView` and in a row's **Tags…** context action:

- Existing tags render as removable `TagChip`s (each with a trailing "×"); removing calls
  `libraryModel.removeTag(id:_:)`.
- A single-line field adds a tag on Return via `libraryModel.addTag(id:_:)`; input is trimmed,
  de-duplicated case-insensitively, and rejects empty/whitespace. Tags are plain strings (base §6);
  no hierarchy, no rename-in-bulk in v1.
- All edits are id-stable (§21.1) — a tag change no longer changes the entry id or its slot claim.

### 23.2 Filtering by tag

- **Sidebar** (base §3): selecting a tag child still filters — it seeds `tagFilter = [tag]` and
  routes to `.library(tag:)`.
- **In-content** (optional multi-tag): a **Tags** menu in the `LibraryListView` toolbar toggles
  entries in `tagFilter` (AND semantics). Active tag facets show as removable chips under the
  `CategoryFilterBar`. This composes with the category filter (§21.3): "Bass ∧ #live-set."
- Search (base §6, name+tag substring) is unchanged and ANDs on top.

---

## 24. Favorites

### 24.1 The heart toggle (`FavoriteToggle`)

One component, used on rows and in detail. A heart: filled/tinted when favorited, outline when not;
44 pt target; `accessibilityLabel` "favorite" / "not a favorite", toggled as a trait, never
color-only (§19).

- **Library row / detail** (`LibraryRowView`, `LibraryEntryDetailView`): toggles
  `libraryModel.toggleFavorite(id:)` — instant, local, no device traffic.
- **Device slot row / detail** (`SlotRowView`, `SlotDetailView`): §24.2.

### 24.2 Favoriting a device slot (honest, priced)

Favorite is a *library* attribute, so a device slot's heart mirrors the library:

- **Filled** when the slot's current sha matches a favorited entry (`libraryModel.favoritedSha`).
  Requires the slot to be hashed; on a names-only row the heart is shown **disabled** with the reason
  ("read this slot to favorite it") — consistent with §1.1 (no silent blob reads) and §4's tiers.
- **Tapping a filled heart** unfavorites the matching entry (local, instant).
- **Tapping an empty heart** when a library entry already holds these bytes → favorites that entry
  (local, instant). When **no** entry holds them, the tap runs **Save to Library** first
  (`saveToLibrary`, auto-category from the device byte, §21.2), then favorites the new entry — priced
  exactly like save (instant if the bytes are already on disk from a backup; otherwise the stated
  ~400 ms read, never silent). A toast confirms: "Saved 'Weird Organ' and added it to Favorites."

### 24.3 Favorites view (`FavoritesListView`)

A sidebar LIBRARY child **Favorites** selects `.favorites` (§28.1); the content column shows
`FavoritesListView` — favorited entries "across library and device":

- Rows reuse `LibraryRowView` in a favorites-scoped mode (`favoritesOnly` set), each annotated with
  its **device presence**: the slot-claim chip ("→ 413") and the live sync hint from
  `slots.syncBadges` ("in sync" / "differs" / "not on device"), so the list reads as spanning both
  the library and what is currently on the synth.
- The `CategoryFilterBar` and tag facets apply here too (favorites ∧ category ∧ tags), with faceted
  counts scoped to favorites.
- **Empty state:** teaching copy — "Tap the heart on any preset — in the library or on the device —
  to keep it here." with a button jumping to the device browser.
- Favorites are device-independent (library-side), so the view survives identity switches (§11);
  the per-row device annotations simply clear when no device is connected (desaturated, base §5
  disconnected treatment).

---

## 25. Collections — model & persistence

### 25.1 What a Collection is

A **Collection** is a named device arrangement: a slot→preset map over the **content-addressed**
library. It stores *references* (by sha), not blobs — the bytes live once in the library's
content-addressed store (and/or a backup), exactly as 269 factory Inits cost one blob file
(architecture-spec §10.2).

Core value type (byte-interoperable Python ⇄ Swift, same pinning as §10):

```
Collection : Sendable, Identifiable
  id          String            // uuid4 hex, 32 lowercase, no hyphens (as LibraryEntry)
  name        String
  provenance  Provenance        // .device(identity) | .bank(fileName) | .manual
  createdAt   String            // "yyyy-MM-dd'T'HH:mm:ss", local (as everywhere)
  slots       [CollectionSlot]  // occupied slots only, ascending

CollectionSlot : Sendable
  slot     Int        // 0…511
  sha256   String     // content reference into the library / backups
  name     String     // the arrangement's name for this slot (may differ from any entry's)
  metaHex  String     // 18 hex chars — needed to reconstruct a faithful Preset on Apply
```

Empty/expendable slots are simply **absent** from `slots`; `presetCount = slots.count`.

**Persistence** — one JSON file per collection under `Documents/Collections/<id>.json` (folder
sibling to `Documents/Library/` and `Documents/Backups/`, so it moves between iPad and Mac via the
existing `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`, architecture-spec §10.2). Keys:
`{"schema":1,"id","name","provenance":{"kind","detail"},"created","slots":[{"slot","sha256","name",
"meta_hex"}]}`. Atomic writes via the same `AtomicFile` helper. Creation and mutation go through a
single core `CollectionStore` actor (mirroring `Library`): `list()`, `get(id:)`, `save(_:)`,
`rename(id:,to:)`, `delete(id:)`. A collection referencing a sha the store cannot resolve is not
corrupt — it is *incomplete*, surfaced honestly at Apply time (§27.4).

### 25.2 Byte resolution (content-addressed, cheapest honest source)

Applying a collection needs real `Preset`s. Bytes for a `CollectionSlot` resolve, in order — never
guessing, never touching frames:

1. a **library** blob whose sha matches (`Library.hasBlob` / `findBySha`) — instant, on disk;
2. a **backup** holding that sha at any slot (`BackupsModel.backupHolding`-style lookup) — instant,
   on disk;
3. otherwise **unresolvable** → that slot is pre-disabled in the Apply plan with the core's sentence
   "bytes not in the library or any backup — re-import or re-snapshot" (§27.4). The device is never
   read to fill a collection (a Collection is a plan, not a live read).

The reconstructed `Preset` uses the collection slot's `name` + `metaHex` with the resolved blob, so
the arrangement writes the intended name/category even when the blob is shared with other entries.

---

## 26. Collections screen

### 26.1 Placement & list (`CollectionsListView`, `CollectionRowView`)

A new top-level sidebar section **COLLECTIONS** (§28.1) with a static **All Collections** row and one
child per collection. Selecting the section (or All Collections) shows `CollectionsListView` in the
content column; selecting a collection shows `CollectionDetailView` in the detail column
(`DetailSelection.collection(id:)`).

`CollectionRowView` (≥ 52 pt): name · provenance line · preset count · identity chip when the
provenance identity is `practice:*`.

```
Ambient Peaks                        from bank "Ambient Peaks.mfprojz" · 128 presets
Live Set — Nov                       from this MicroFreak · 2026-09-01 · 312 presets   [Practice]
```

- **Toolbar:** **Create from Device…** · **Import Bank…** (`.mfprojz`) · sort (name / date / count).
- **Row context menu / swipe:** Apply/Switch… · Rename (inline `RenameField`, unrestricted length —
  a collection name is not a preset name, so the §8.3 23-char rule does not apply) · Duplicate ·
  Delete (guard names it; states that the referenced library bytes are untouched — deleting a
  collection never deletes presets).
- **Empty state:** three CTAs mirroring the library empty state (§6) — "Snapshot the current device,"
  "Import a bank (.mfprojz)," and a one-line explainer that a collection is just a saved slot layout.

### 26.2 Create from current device

**Create from Device…** captures all 512 slots as an arrangement. Because a faithful map needs each
slot's sha + meta, this **requires a full hashed pass**, which *is* a backup (§1.2):

- If a current hashed snapshot exists (`slots.hasHashedSnapshot`), build immediately from
  `slots.hashedSnapshot()` records.
- Otherwise offer **Read Device & Snapshot (~3½ min)** — reuses `runFullBackup` (the one
  read-everything op, progress-barred, cancellable, resumable); on completion the hashed tier lands
  (base §16.1) and the collection is built from it.

Flow: a name prompt (`NewCollectionSheet` — default "Snapshot 2026-09-01", the unrestricted name
field, Practice banner when simulated) → build → the `CollectionStore.save`. Occupied, non-expendable
slots become `CollectionSlot`s (name/sha/meta from the records); expendable/empty slots are omitted
(judged via `Analysis.findExpendable`, §10 — never a string match). Provenance = `.device(identity)`.
Toast: "Saved 'Live Set — Nov' — 312 presets from this MicroFreak." The library is *not* modified;
byte resolution at Apply time leans on the backup produced by the snapshot pass (§25.2).

### 26.3 Import a bank as a Collection

**Import Bank…** opens the file importer for `.mfprojz` (and single `.mbp`). Parsing uses the Swift
port of the **verified** `tools/mbp_import.py` (do not re-derive the Boost parsing) — a pure,
offline, headless-testable `MFProjzImport` yielding `(name, meta, blob, slot)` per preset, with slot
position from the filename (`_slot_from_name`: `A/B/C/D` sub-bank + index → 0…511). Import runs
entirely on disk; no device needed.

Per bank:
1. Each non-empty preset's blob is added to the **library** (content-addressed — `Library.add`
   dedupes the blob file; a shared blob costs nothing new). Category is forced **Uncategorized**
   (established fact: pack meta is all-zero; §21.2), tags empty, no slot claim. Duplicate
   (sha, name) pairs are not re-added.
2. A `Collection` is created whose `slots` map the filename-derived positions to the imported shas
   (name/meta from the archive). Empty/Init entries in the bank (short archives, `blob == nil`) →
   absent slots.
3. Provenance = `.bank(fileName)`.

The import sheet states, before running: "Adds N presets to your library (Uncategorized — tag them
after) and creates a collection mapping M slots. Offline; the device is not touched." Toast on
completion with both counts. A malformed archive surfaces the §14 file-import line ("Not a MicroFreak
bank …"); a bank with unreadable members imports the readable ones and reports the skip count.

### 26.4 Collection detail (`CollectionDetailView`)

Detail column for `.collection(id:)`:

- Header: name (tap to rename), provenance line, preset count, created date, identity chip when
  `practice:*`.
- **Slot map**: a compact 512-slot view (bank sections, base §5 idiom, `SlotNumberLabel`), each
  occupied slot showing its name and a `CategoryBadge` (decoded from the slot's meta); empty slots
  shown dimmed with the base `JudgmentDot` unjudged/empty language. Rows are read-only here (a
  collection is a saved plan; editing attributes happens on the library copies).
- Primary action bottom-anchored (§13.1): **Apply / Switch…** → §27. Secondary: Rename · Duplicate ·
  Delete · Export folder (share sheet, the collection JSON).
- A live **readiness line** when a device is connected and hashed: "Switching now changes N of 512
  slots (~M s)." — the same number the pre-flight will show, computed from the current diff so the
  detail and the sheet never disagree.

---

## 27. Apply / Switch a Collection

The point of collections: switch the synth to a saved arrangement **fast**, by writing only what
differs. It reuses the sync-diff idea (§17) and the verified-write path (§8, §9) end to end — the
diff computes; only the user writes.

### 27.1 Pre-flight diff (`CollectionApplyPlanSheet`)

Modeled on `RestorePlanSheet` (§16.2) and `BulkApplyPlanSheet` (§17): a modal sheet, Practice banner
when simulated, bottom-anchored confirm/cancel.

**Precondition (honest gate).** An accurate, minimal switch needs current device shas
(`slots.hasHashedSnapshot`). Three cases, in the sheet header:

- **Hashed snapshot present** → the exact diff renders (§27.2). Provenance line, as Sync: "Compared
  against device read 12 min ago (backup …) · 3 writes since."
- **Names only / stale** → a CTA identical to Sync's precondition (§17): **Read Device & Compare
  (~3½ min)** for the fewest writes; plus a secondary **Diff by name (may over-write)** that treats
  any slot whose sha is unknown as *will-write* (safe, not minimal).
- **No device** → the sheet is not offered (Apply is disabled with "connect a device to switch").

### 27.2 The diff and the summary line

For each `CollectionSlot`, compare its sha against the device row's sha:

| Device row | Result | Counted |
|---|---|---|
| sha known, **equal** | **unchanged** — skipped | Y |
| sha known, **differs** (or slot empty/expendable) | **write** | X |
| sha **unknown** (unhashed, in "diff by name") | **write (unread)** | X, flagged |

Slots **not** in the collection are left as-is — Apply never erases a slot the collection does not
define (v1; stated in the sheet). The mandatory summary line, top of the sheet:

> **changes N of 512 slots:** X writes, Y unchanged · **~M s** (0.5 s per write)

where `N = X`, `M = round(X × 0.5)` (via a `Format`-style helper). The **0.5 s per write** rate is
the burst-time framing the mission specifies for a fast switch; it is the floor — verified writes add
a read-back — so the sheet appends, in caption weight, "verification adds a read-back per slot" and
the status-bar ETA during execution uses the running median (§8.2, §16.1), the same as every other
long op. (The reconciliation of the 0.5 s pre-flight rate with the app's ~1 s verified-write estimate
is flagged in §29, open question 4.)

### 27.3 The plan is an `OverwritePlan` — same guard rails

The sheet builds a standard `OverwritePlan` (base §9), so every victim preview, expendability
verdict, recoverability sentence, and the backup-freshness footer are exactly those used everywhere —
no new confirmation vocabulary:

- `OverwritePlan.Kind` gains `.applyCollection`; `OverwritePlan.Incoming` gains
  `.collectionSlot(collectionID:, slot:)` resolved at execution via §25.2 (never eagerly — a
  512-write switch does not load 512 blobs into memory up front).
- Each changed slot is a plan `Item` from the existing `makePlanItem` / `victimFacts` — the victim's
  name, `Analysis`-judged expendability with evidence, and recoverability (library sha match → backup
  sha match → "not recoverable, it will be lost") come for free.
- `severity`: a single-slot apply is `.dialog`/`.popover` like any send; a multi-slot switch is
  `.planSheet`; a switch that overwrites **every** occupied slot inherits the same
  `.planSheetPlusFinalAlert` treatment as a full restore ("This overwrites every preset the
  collection defines — X slots").
- `confirmLabel` for `.applyCollection`: **"Switch — Write X Slots"** (never "OK").
- Rows whose bytes are unresolvable (§25.2) are **pre-disabled** with the core's sentence, and the
  summary states "K slots can't be written — their bytes aren't on disk" with a jump to re-import /
  re-snapshot. They are excluded from `writeCount`, so the estimate stays truthful.

Plan rows list `[413] ← "Bass Prophet" (collection) — replaces "Old Bass" (on device, in library)`,
identical in shape to the restore plan rows (§16.2).

### 27.4 Execution — verified, progress, cancel, stop-on-first-failure

Confirm dismisses the sheet and runs `AppModel.executeCollectionApply(_:)`, modeled exactly on
`executeRestore` (§16.2) so the semantics are the proven ones:

- One **long** op on the `DeviceOperationQueue` (kind `.long`), so it blocks other device ops and
  owns the single status surface (§1.3). The status bar mirrors it; a `BatchRunState` drives the
  in-sheet/inline row ticks.
- **Verified by default** — every write is `device.write(slot:preset:)` (the verified overload; no
  opt-out anywhere, §1.7). Recommended core surface for parity and testing:
  `FreakDeviceProtocol.applyPresets(_ pairs: [(Int, Preset)], verify:, progress:)` mirroring
  `restore` (per-slot cancel poll, `ProgressEvent` per slot, **stops at the first failure** carrying
  `.completed` reports) — so the app keeps handing the core typed `Preset`s and never iterates the
  wire itself. If the core team prefers zero new surface, the app loops `device.write` inside the one
  long op replicating those exact semantics.
- **Determinate progress**: done/total, current slot + name streaming by, median ETA (§16.1 display
  rules), cancel. **Cancel is between slots** (§9.8) — the 7-frame burst is never interrupted
  (tearing risk). A cancel resolves to the completed set standing (never a red surface, §14
  `OperationCancelledError`): "Switch stopped — 41 of 96 slots written."
- **Failure** is the base spec's machinery verbatim: a `VerifyMismatchError` raises the designed
  moment (§14) with the batch context line "Switch stopped here — 41 of 96 written" and **Retry From
  Slot N**; a torn slot (`ChunkNotAckedError` / `WriteAborted`) gets its badge and recovery actions.
  Each verified write patches the slot cache in place (§4), so the collection's readiness line and
  the Sync diff stay live without a re-read.
- On success: toast "Switched to 'Live Set — Nov' — 41 slots written, all verified," slot-history
  events per slot ("Applied from collection 'Live Set — Nov'"), `freshness.noteWrite()` per write.

### 27.5 Identity honesty

A collection carries its provenance identity. Applying a `practice:*`-provenance collection to
hardware (or vice versa) raises the same cross-identity warning as a cross-identity restore
(§11, `requestRestore`'s "Continue Anyway" gate) before the pre-flight sheet opens — routed through
one entry point so it cannot be bypassed. Switching devices mid-apply is refused until the op
finishes or is cancelled (`canSwitchDevice`, §11/§12).

---

## 28. App-structure deltas

### 28.1 Navigation

`SidebarSelection` (base §3, in `AppModel`) gains cases; `DetailSelection` gains one:

```
enum SidebarSelection { case device; case library(tag:); case favorites;   // NEW: favorites
                        case collections; case collection(id:)               // NEW: section + child
                        case sync; case backups }
enum DetailSelection  { … ; case collection(id: String) }                    // NEW
```

Sidebar layout (base §3 diagram, additions marked):

```
DEVICE            All Slots · Bank 1–4 (jump targets)
LIBRARY           All Presets · Favorites (NEW) · <tag> …
COLLECTIONS       All Collections · <collection> …                (NEW section)
SYNC
BACKUPS
[freshness footer · settings]
```

- **Favorites** selects `.favorites` → `FavoritesListView` (§24.3).
- **Category** is **not** a sidebar entry — it is the `CategoryFilterBar` header on the library and
  favorites browsers (§22.1), matching Arturia's chip-grid model rather than a nav tree.
- **COLLECTIONS** rows follow the base sidebar-row idiom (`sidebarRow`); a collection child sets both
  `sidebar = .collection(id:)` and `detail = .collection(id:)` (content stays the list; detail shows
  the collection). Selection persists via `SceneStorage` exactly as base §3 (selection only, never a
  resumed op).

### 28.2 View inventory delta (base §18.1)

```
Content column
  ├─ LibraryListView         + CategoryFilterBar → CategoryChip, tag-facet chips, Edit-mode multi-select
  ├─ FavoritesListView       → LibraryRowView (favorites mode) + device-presence annotations   (NEW)
  └─ CollectionsListView     → CollectionRowView, ProvenanceLabel                               (NEW)
Detail column
  ├─ LibraryEntryDetailView  + CategoryPickerRow, TagEditor, FavoriteToggle
  ├─ SlotDetailView          + upgraded CategoryByteRow (decoded, read-only), FavoriteToggle
  └─ CollectionDetailView    → collection slot map, Apply/Switch, ProvenanceLabel               (NEW)
Sheets
  ├─ NewCollectionSheet       (create-from-device name prompt)                                  (NEW)
  └─ CollectionApplyPlanSheet (pre-flight diff → progress/cancel; modeled on RestorePlanSheet)  (NEW)
Components (Components.swift)
  CategoryChip · CategoryFilterBar · CategoryBadge · CategoryPickerRow ·
  FavoriteToggle · TagEditor · CollectionRowView · ProvenanceLabel                              (NEW)
```

### 28.3 View-models & state ownership (base §18.2/§18.3)

| Model | Owns (additions) | Persistence | Never does |
|---|---|---|---|
| `LibraryModel` | `categoryFilter`, `tagFilter`, `favoritesOnly`; `categoryCounts` (faceted); attribute intents `setCategory`/`toggleFavorite`/`addTag`/`removeTag`/id-stable `setTags`; bulk `setCategory(ids:)` | index keys `category`, `favorite`, `tags` (additive, §21.1) | touch the device; write category into preset meta (v1) |
| `CollectionsModel` (NEW `@MainActor @Observable`) | the collection catalog (`[Collection]` summaries), scan/load state, load failures; intents `snapshotFromDevice(name:)`, `importBank(url:name:)`, `rename`, `delete`, `duplicate`; builds the Apply `OverwritePlan` by diffing `slots.hashedSnapshot()` vs the collection (reusing `makePlanItem`) | mirrors core `CollectionStore` at `Documents/Collections/*.json` | execute a write itself — Apply runs through `AppModel`'s queue after §9 confirmation, exactly like Sync (§18.2) |
| `SlotBrowserModel` | (reads only) exposes shas/judgments the collection diff and the device-row heart consume | in-memory (base) | — |
| `AppModel` | new presentation state: `newCollectionRequest`, `collectionApplyRequest`, `collectionRun: BatchRunState`; intents `buildCollectionApplyPlan`, `executeCollectionApply` (modeled on restore); routes the §27.5 cross-identity gate | — | new device semantics — reuses queue, `OverwritePlan`, `BatchRunState`, `presentWriteFailure` |
| `CategoryByte` / `PresetCategory` (value) | the one taxonomy table + `decode` (§21.2) | — | invent categories beyond the Arturia set |

**Threading contract unchanged (base §18.2):** view models write only their own state; every device
write — including a collection Apply — is enqueued on `AppModel`'s single queue, hops to the FreakCore
device actor, and re-dispatches `ProgressEvent`s to `@MainActor` via `ProgressBridge`; UI Cancel maps
to `task.cancel()` (§6). `CollectionStore` is a core actor like `Library`; the app awaits it off the
main actor and mirrors summaries into `CollectionsModel`.

---

## 29. Accessibility, reachability, and open questions

**Accessibility (base §19 extended).** Category chips carry `.isSelected`; their count is part of the
label ("Bass, 41 presets, selected"). The heart's favorite state is a trait, not color. `TagEditor`
chips expose a "remove tag <x>" action to the rotor. The collection Apply plan rows read like restore
rows ("slot 413, write Bass Prophet, replaces Old Bass, in library"). Chip grid and slot map reflow
under Dynamic Type XL (grid → horizontal scroller; the slot-number column stays fixed-width numeric).

**Reachability (base §13).** Chip grid, heart toggles, and the Apply confirm honor the lower-half /
tap-only rules: the pre-flight confirm is bottom-anchored; the heart and chips are ≥ 44 pt; multi-
select uses Edit-mode checkboxes; nothing requires two touches or a specific edge.

**Open questions (flagged, not blocking):**

1. **Category-byte mapping** is confirmable, not confirmed (§21.2); the simulator asserts the 0…11
   order, so the UI and vectors are internally consistent, and every auto-fill is user-correctable —
   the honest default until a hardware session verifies the indices.
2. **Erase-on-switch.** v1 Apply writes only the changed slots the collection defines and leaves
   undefined slots untouched (§27.2). A future "make the device match this collection exactly"
   (writing Init to slots the collection omits) would be strictly more destructive and needs its own
   full-device §9 treatment; deferred.
3. **Category → meta write.** Editing a library category does not alter stored meta (§21.2). Once the
   mapping is hardware-confirmed, an opt-in "also write the category to the preset's meta so the
   synth shows it after sending" could be added; deferred.
4. **Apply estimate rate.** The pre-flight shows 0.5 s/write (burst floor, per the mission) while the
   rest of the app estimates verified writes at ~1 s (`OverwritePlan.estimatedDuration`,
   `RestorePlanSheet`). Both are labeled honestly, but the two constants should be unified once
   per-slot verified-write timing is measured on hardware; until then the live status-bar ETA (median
   of real writes) is the source of truth during execution.
5. **`.mfprojz` parser port.** The Swift `MFProjzImport` must be a semantics-faithful port of the
   verified `tools/mbp_import.py` (Boost archive header, `<bloblen>=4672` blob, sub-bank slot
   mapping), with a golden fixture per the parity constraint — not a fresh implementation.
