# Collections & Categories — data-model and cross-core architecture spec

**Version 1.0 — 2026-09-01.** Additive specification over
[`core-api.md`](../../docs/core-api.md),
[`swift-architecture.md`](swift-architecture.md), and
[`ux-spec.md`](ux-spec.md). It pins three cohesive additions — **preset
attributes** (category, tags, favorite), **collections** (named slot→preset
arrangements), and the **apply/switch** algorithm — as exact Python *and*
Swift declarations, kept in byte-interoperable parity.

Normative sources, in order of authority (unchanged):

1. `docs/write-protocol.md` — wire ground truth (hardware-verified).
2. `docs/core-api.md` — the core API contract.
3. `microfreak/` — the Python reference implementation.
4. `ios/docs/swift-architecture.md` — the Swift port contract (§10 interop
   encodings and §14 app seam are extended, never contradicted, here).

Where this doc and those could ever disagree, they win in that order. This
doc decides only the new surfaces.

## 0. Invariants this spec does not touch

These hold exactly as before; the additions are layered on top and must not
weaken them:

- **Meta round-trips verbatim.** The 9-byte `meta` is opaque device state;
  `name_write_frame` recomputes only payload[3]/[8]/[9]. **v1 never writes
  the category byte to the device** — category lives in the library index as
  an editable *librarian* attribute, decoded *from* `meta[7]` on import but
  never re-encoded into `meta`. A library category edit and the device's
  `meta[7]` may therefore diverge; that is intended (the index is the
  librarian's organization, the device byte is the synth's own state).
- **Content-addressed blobs.** Collections reference blobs by sha256; no new
  blob storage scheme is introduced.
- **Verified writes only.** Apply/switch executes through the existing
  `MicroFreak.write` / `write(slot:preset:)` verified path. No verification
  opt-out is added anywhere.
- **Offline only.** Every new path is exercised against `SimulatedMicroFreak`
  and fixtures. No network, no web-fetch, no real MIDI, no device deploy.
- **Old indexes still load.** Every new field is additive with a sensible
  default; an index or collection written by one core loads in the other.
- **Byte-interop encodings** from `swift-architecture.md` §10 apply to every
  new field and file: UTF-8 JSON; Swift writes
  `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`; ids are uuid4 hex
  (lowercase, 32 chars, no hyphens); timestamps `"yyyy-MM-dd'T'HH:mm:ss"`
  local; `sha256`/`meta_hex` lowercase hex; explicit `null` for absent
  optionals.

---

## 1. Category (`microfreak/model.py`, `FreakCore/Model.swift`)

`Category` is a closed enum over Arturia's documented MicroFreak taxonomy
plus `uncategorized`. It carries a **stable wire representation** — a
lowercase ASCII slug used verbatim in JSON by both cores — and the **one**
device-byte→category table.

### 1.1 The device-byte table (hardware-confirmable)

The MicroFreak's name-reply carries a category byte at `meta[7]`
(= long-0x52 `payload[10]`). The **index→category map below is NOT proven
against hardware ground truth** — the Ambient Peaks pack ships all-zero meta,
so no exported file confirms it, and only one captured device reply
(slot 200, `meta[7] = 0x03`) touches it. It is the single documented starting
point: kept in exactly one table, doc-commented as confirmable, and category
is user-editable so a wrong auto-fill is always correctable.

| byte | slug | display |
|---|---|---|
| 0x00 | `uncategorized` | Uncategorized |
| 0x01 | `bass` | Bass |
| 0x02 | `brass` | Brass |
| 0x03 | `keys` | Keys |
| 0x04 | `lead` | Lead |
| 0x05 | `organ` | Organ |
| 0x06 | `pad` | Pad |
| 0x07 | `percussion` | Percussion |
| 0x08 | `sequence` | Sequence |
| 0x09 | `sfx` | SFX |
| 0x0A | `strings` | Strings |
| 0x0B | `template` | Template |
| 0x0C | `vocoder` | Vocoder |

Any byte outside `0x00..0x0C` decodes to `uncategorized` (unknown). The raw
byte is never lost — it stays in `meta`, which round-trips verbatim.

### 1.2 Python

```python
# microfreak/model.py  (Category has NO import from library/collections —
# it is a leaf value type both of those import)
import enum
from typing import List


class Category(enum.Enum):
    """Arturia MicroFreak preset category — the librarian's editable
    attribute. Values are the stable wire slug used in the library index and
    collection files by BOTH cores. Do NOT add categories beyond this
    documented Arturia set."""
    UNCATEGORIZED = "uncategorized"
    BASS = "bass"
    BRASS = "brass"
    KEYS = "keys"
    LEAD = "lead"
    ORGAN = "organ"
    PAD = "pad"
    PERCUSSION = "percussion"
    SEQUENCE = "sequence"
    SFX = "sfx"
    STRINGS = "strings"
    TEMPLATE = "template"
    VOCODER = "vocoder"

    # THE one device-byte -> Category table. index == the device category
    # byte (meta[7] == long-0x52 payload[10]). HARDWARE-CONFIRMABLE: this
    # index map is NOT proven against ground truth (only slot-200's 0x03 is
    # observed). Confirm against a device, then correct here in ONE place;
    # category is user-editable so a wrong auto-fill is always fixable.
    _DEVICE_BYTE_TABLE: List["Category"] = []   # filled below

    @classmethod
    def from_device_byte(cls, byte: int) -> "Category":
        """Decode meta[7]. Bytes outside the table -> UNCATEGORIZED."""
        if 0 <= byte < len(cls._DEVICE_BYTE_TABLE):
            return cls._DEVICE_BYTE_TABLE[byte]
        return cls.UNCATEGORIZED

    @classmethod
    def from_slug(cls, slug: str) -> "Category":
        """Parse an index/file slug. Unknown slug -> UNCATEGORIZED (forward
        compatibility: a future core's category loads as uncategorized here,
        never a crash)."""
        try:
            return cls(slug)
        except ValueError:
            return cls.UNCATEGORIZED

    @property
    def slug(self) -> str:
        return self.value

    @property
    def display_name(self) -> str:
        return "SFX" if self is Category.SFX else self.name.title().replace("_", " ")


Category._DEVICE_BYTE_TABLE = [
    Category.UNCATEGORIZED, Category.BASS, Category.BRASS, Category.KEYS,
    Category.LEAD, Category.ORGAN, Category.PAD, Category.PERCUSSION,
    Category.SEQUENCE, Category.SFX, Category.STRINGS, Category.TEMPLATE,
    Category.VOCODER,
]
```

### 1.3 Swift

```swift
// FreakCore/Model.swift  (leaf value type; Library & PresetCollection import it)
public enum Category: String, Sendable, CaseIterable, Codable {
    case uncategorized, bass, brass, keys, lead, organ, pad, percussion,
         sequence, sfx, strings, template, vocoder

    /// THE one device-byte -> Category table. Index == the device category
    /// byte (meta[7] == long-0x52 payload[10]). HARDWARE-CONFIRMABLE: this
    /// index map is NOT proven against ground truth (only slot-200's 0x03 is
    /// observed). Confirm against a device, then correct here in ONE place;
    /// category is user-editable so a wrong auto-fill is always fixable.
    public static let deviceByteTable: [Category] = [
        .uncategorized, .bass, .brass, .keys, .lead, .organ, .pad,
        .percussion, .sequence, .sfx, .strings, .template, .vocoder,
    ]

    /// Decode meta[7]. Bytes outside the table -> .uncategorized.
    public static func fromDeviceByte(_ byte: UInt8) -> Category {
        let i = Int(byte)
        return i < deviceByteTable.count ? deviceByteTable[i] : .uncategorized
    }

    /// Parse an index/file slug. Unknown slug -> .uncategorized (forward
    /// compatibility with a future core's categories).
    public static func fromSlug(_ slug: String) -> Category {
        Category(rawValue: slug) ?? .uncategorized
    }

    public var slug: String { rawValue }

    public var displayName: String {
        self == .sfx ? "SFX"
            : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}
```

`allCases`/`_DEVICE_BYTE_TABLE` order is the device-byte order; the UI orders
chips itself (§7). The category byte source for auto-fill is `meta[7]`:
Python `preset.meta[7]`; Swift `Array(preset.meta)[7]` (Data may be sliced —
index from the array copy, never `meta[7]` on a non-zero-based slice).

---

## 2. Preset attributes on the library index

`LibraryEntry` gains **`category`** (a `Category`) and **`favorite`**
(a `Bool`). `tags` already exists (a list of strings) — no shape change, only
formalized as the free-form multi-tag field. Old indexes lacking any of these
load with defaults: `category = uncategorized`, `favorite = false`,
`tags = []`.

### 2.1 Index JSON (schema stays `1`, additively extended)

```
<root>/
  index.json          {"schema": 1, "entries": [{
                         "id": str, "name": str, "sha256": str,
                         "meta_hex": str, "slot": int|null,
                         "added_at": str, "tags": [str],
                         "category": str,          // NEW — Category slug; absent -> "uncategorized"
                         "favorite": bool          // NEW — absent -> false
                       }]}
  blobs/<sha256>.bin  content-addressed 4672-byte blobs
  collections/<id>.json   // NEW — §4
```

`schema` remains `1`: the fields are additive and a `schema != 1` guard would
break the interop promise. A reader that predates these keys ignores them; a
reader that expects them supplies the defaults. Writers always emit
`category` and `favorite` (and `tags`, already), so a re-saved old index gains
the keys with defaults.

### 2.2 Python — `LibraryEntry` and codec

```python
# microfreak/library.py
from dataclasses import dataclass
from typing import Optional, Tuple
from .model import Category

@dataclass(frozen=True)
class LibraryEntry:
    id: str
    name: str
    sha256: str
    meta_hex: str
    slot: Optional[int]
    added_at: str
    tags: Tuple[str, ...]
    category: Category = Category.UNCATEGORIZED   # NEW
    favorite: bool = False                        # NEW


def _entry_to_json(e: LibraryEntry) -> dict:
    return {"id": e.id, "name": e.name, "sha256": e.sha256,
            "meta_hex": e.meta_hex, "slot": e.slot, "added_at": e.added_at,
            "tags": list(e.tags),
            "category": e.category.slug, "favorite": bool(e.favorite)}


def _entry_from_json(d: dict) -> LibraryEntry:
    return LibraryEntry(
        id=d["id"], name=d["name"], sha256=d["sha256"],
        meta_hex=d["meta_hex"], slot=d.get("slot"),
        added_at=d.get("added_at", ""), tags=tuple(d.get("tags") or ()),
        category=Category.from_slug(d.get("category", "uncategorized")),
        favorite=bool(d.get("favorite", False)))
```

### 2.3 Swift — `LibraryEntry` and codec

```swift
// FreakCore/Library.swift
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sha256: String
    public let metaHex: String
    public let slot: Int?
    public let addedAt: String
    public let tags: [String]
    public let category: Category      // NEW
    public let favorite: Bool          // NEW

    public init(id: String, name: String, sha256: String, metaHex: String,
                slot: Int?, addedAt: String, tags: [String],
                category: Category = .uncategorized, favorite: Bool = false) {
        self.id = id; self.name = name; self.sha256 = sha256
        self.metaHex = metaHex; self.slot = slot; self.addedAt = addedAt
        self.tags = tags; self.category = category; self.favorite = favorite
    }

    fileprivate func with(name: String? = nil, slot: Int?? = nil,
                          tags: [String]? = nil, category: Category? = nil,
                          favorite: Bool? = nil) -> LibraryEntry {
        LibraryEntry(id: id, name: name ?? self.name, sha256: sha256,
                     metaHex: metaHex, slot: slot ?? self.slot,
                     addedAt: addedAt, tags: tags ?? self.tags,
                     category: category ?? self.category,
                     favorite: favorite ?? self.favorite)
    }
}
```

`saveIndex` adds `"category": e.category.slug` and `"favorite": e.favorite` to
each entry dictionary. `open` decodes them with defaults:

```swift
// inside the entry loop in Library.open:
category: Category.fromSlug(d["category"] as? String ?? "uncategorized"),
favorite: (d["favorite"] as? NSNumber)?.boolValue ?? false
// tags unchanged: d["tags"] as? [String] ?? []
```

### 2.4 Write API (both cores)

`add` takes `category`/`favorite` as additive keyword/default args (existing
call sites keep compiling). Three focused editors rewrite the index
atomically and return the updated entry. `tags` is replace-whole (the UI owns
add/remove; the core stores the final set).

Python (`Library`):

```python
def add(self, preset: Preset, *, slot: Optional[int] = None,
        tags: Sequence[str] = (),
        category: Category = Category.UNCATEGORIZED,
        favorite: bool = False) -> LibraryEntry: ...

def set_category(self, entry_id: str, category: Category) -> LibraryEntry: ...
def set_favorite(self, entry_id: str, favorite: bool) -> LibraryEntry: ...
def set_tags(self, entry_id: str, tags: Sequence[str]) -> LibraryEntry: ...
```

Swift (`Library` actor):

```swift
public func add(_ preset: Preset, slot: Int? = nil, tags: [String] = [],
                category: Category = .uncategorized,
                favorite: Bool = false) throws -> LibraryEntry
public func setCategory(id: String, to category: Category) throws -> LibraryEntry
public func setFavorite(id: String, to favorite: Bool) throws -> LibraryEntry
public func setTags(id: String, to tags: [String]) throws -> LibraryEntry
```

### 2.5 Auto-fill on device import

`import_snapshot` / `importSnapshot` auto-fill each added entry's category
from the device byte; favorite stays false; tags stay empty. Downloaded packs
(§5) arrive `uncategorized`. This is the only place category is derived from
`meta`.

- Python: in the `add(...)` call inside `import_snapshot`, pass
  `category=Category.from_device_byte(r.meta[7])`.
- Swift: pass `category: Category.fromDeviceByte(Array(meta)[7])`.

`r.meta`/`meta` is guaranteed present here (records with `meta == nil` are
already skipped — a failed name read has no category byte).

### 2.6 Read helpers (pure, so the UI stays UI-only)

Category counts (the Arturia-site-style chip counts), favorites, and the tag
universe are computed in the core, not the view layer:

Python (module functions in `library.py`):

```python
def category_census(entries: Iterable[LibraryEntry]) -> Dict[Category, int]:
    """Count entries per Category. Every Category key present (0 when none),
    so the UI renders a stable chip row."""

def all_tags(entries: Iterable[LibraryEntry]) -> List[str]:
    """Sorted unique tag set across entries."""
```

Swift (static on an `Attributes` caseless enum in `Library.swift`):

```swift
public enum Attributes {
    public static func categoryCensus(_ entries: [LibraryEntry]) -> [Category: Int]
    public static func allTags(_ entries: [LibraryEntry]) -> [String]  // sorted, unique
}
```

Favorites and tag filtering are plain predicates over `entries()`
(`e.favorite`, `tags.contains(_:)`) — no dedicated core call needed; the UI
filters the already-loaded `[LibraryEntry]`.

---

## 3. `PresetRef` — a self-contained slot occupant (`model.py`, `Model.swift`)

A collection maps a slot to a **`PresetRef`**: the minimum needed to write the
preset back faithfully, resolvable against the content-addressed blob store.
It is content-keyed (not entry-id-keyed), so it survives entry rename/delete
and captures the exact name+meta of the arrangement.

```python
# microfreak/model.py
@dataclass(frozen=True)
class PresetRef:
    """A slot occupant inside a PresetCollection: content (sha256) + the name
    and meta needed to write it faithfully. Resolvable to a Preset given the
    blob (Library.preset_for_ref)."""
    sha256: str        # 64 lowercase hex; addresses blobs/<sha256>.bin
    name: str          # validated printable ASCII (<= 23), as it should be written
    meta_hex: str      # 18 lowercase hex chars (9 bytes), round-tripped verbatim

    def to_preset(self, blob: bytes) -> Preset:
        return Preset(name=self.name, blob=blob, meta=bytes.fromhex(self.meta_hex))
```

```swift
// FreakCore/Model.swift
public struct PresetRef: Sendable, Equatable {
    public let sha256: String
    public let name: String
    public let metaHex: String
    public init(sha256: String, name: String, metaHex: String) {
        self.sha256 = sha256; self.name = name; self.metaHex = metaHex
    }
    /// Resolve to a Preset given the blob bytes. Throws Preset's validations.
    public func toPreset(blob: Data) throws -> Preset {
        guard let meta = Data(hexString: metaHex) else {
            throw FreakError.protocolViolation(detail: "unparseable meta_hex: \(metaHex)")
        }
        return try Preset(name: name, blob: blob, meta: meta)
    }
}
```

JSON shape (used in collection files): `{"sha256": str, "name": str,
"meta_hex": str}`.

---

## 4. `PresetCollection` — a named device arrangement

A **`PresetCollection`** is an ordered slot→`PresetRef` map over the library's
content-addressed blobs, plus identity and provenance. It is the unit that
`snapshot`, `import-bank`, and `apply` produce and consume. (Named
`PresetCollection` in **both** cores — a bare `Collection` would shadow the
Swift standard-library protocol.)

### 4.1 On-disk format — one file per collection under the library

```
<root>/collections/<id>.json
```

```json
{
  "schema": 1,
  "id": "5f2c…(uuid4 hex, 32, no hyphens)",
  "name": "Ambient Live Set",
  "created_at": "2026-09-01T14:32:00",
  "provenance": { "kind": "imported_bank", "source": "Ambient Peaks.mfprojz" },
  "slots": {
    "0":   { "sha256": "…", "name": "Voltage Forms", "meta_hex": "080000000000000933" },
    "128": { "sha256": "…", "name": "Tokyo88 V3",    "meta_hex": "18000000000000032f" }
  }
}
```

- `slots` is a JSON object keyed by the **decimal slot number as a string**
  (mirrors the backup `presets` map). Canonical iteration is **ascending by
  `int(key)`** — that ordering *is* the "ordered" map; JSON key order is
  irrelevant.
- `provenance.kind` ∈ `"device_snapshot" | "imported_bank" | "manual"`;
  `source` is free text (a filename, a snapshot `taken_at`, or `""`).
- Referenced blobs live in the **shared** `blobs/` dir; a collection stores no
  blob bytes of its own.
- Per-file atomic writes (temp + rename), same helper as the index.
- An old library simply has no `collections/` dir → zero collections. Creating
  the first collection creates the dir.

### 4.2 Python types (`microfreak/collections.py`)

New module. Imports `model` and `library` only (never `device`), so planning
stays pure and importable everywhere.

```python
# microfreak/collections.py
import enum, time, uuid
from dataclasses import dataclass
from typing import Dict, Optional, Tuple
from .model import PresetRef

_COLLECTION_SCHEMA = 1


class ProvenanceKind(enum.Enum):
    DEVICE_SNAPSHOT = "device_snapshot"
    IMPORTED_BANK = "imported_bank"
    MANUAL = "manual"


@dataclass(frozen=True)
class Provenance:
    kind: ProvenanceKind
    source: str = ""            # filename / snapshot taken_at / ""


@dataclass(frozen=True)
class PresetCollection:
    id: str                          # uuid4 hex, minted at creation
    name: str
    created_at: str                  # ISO 8601, local
    provenance: Provenance
    slots: Dict[int, PresetRef]      # slot -> ref; iterate sorted(slots)

    @classmethod
    def new(cls, name: str, provenance: Provenance,
            slots: Dict[int, PresetRef]) -> "PresetCollection":
        return cls(id=uuid.uuid4().hex, name=name,
                   created_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
                   provenance=provenance, slots=dict(slots))

    def covered_slots(self) -> Tuple[int, ...]:
        return tuple(sorted(self.slots))
```

JSON codec (`_collection_to_json` / `_collection_from_json`) lives in this
module; `slots` keys are `str(slot)`, refs serialize per §3. An unparseable or
`schema != 1` file raises `LibraryCorruptError(path, detail)`.

### 4.3 Swift types (`FreakCore/Collections.swift`)

```swift
// FreakCore/Collections.swift
public enum ProvenanceKind: String, Sendable, Codable {
    case deviceSnapshot = "device_snapshot"
    case importedBank   = "imported_bank"
    case manual
}

public struct Provenance: Sendable, Equatable {
    public let kind: ProvenanceKind
    public let source: String            // filename / snapshot takenAt / ""
    public init(kind: ProvenanceKind, source: String = "") {
        self.kind = kind; self.source = source
    }
}

public struct PresetCollection: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: String
    public let provenance: Provenance
    public let slots: [Int: PresetRef]   // iterate slots.keys.sorted()

    public init(id: String, name: String, createdAt: String,
                provenance: Provenance, slots: [Int: PresetRef]) {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.provenance = provenance; self.slots = slots
    }

    /// Mint a fresh collection (uuid4 hex id, local ISO createdAt).
    public static func new(name: String, provenance: Provenance,
                           slots: [Int: PresetRef]) -> PresetCollection
    public func coveredSlots() -> [Int] { slots.keys.sorted() }
}
```

### 4.4 Store operations on `Library`

Collections are owned by the library folder, so `Library` (the single writer
of that folder) owns their CRUD. All reads re-parse the file; all writes are
atomic.

Python (`Library`):

```python
def collections(self) -> List[PresetCollection]:
    """Every <root>/collections/*.json, parsed; ascending by created_at then
    id. Missing dir -> []."""
def collection(self, coll_id: str) -> PresetCollection:      # CollectionNotFoundError
def save_collection(self, coll: PresetCollection) -> None:   # atomic write; create dir if needed
def rename_collection(self, coll_id: str, name: str) -> PresetCollection:
def delete_collection(self, coll_id: str) -> None:           # then GC unreferenced blobs
def preset_for_ref(self, ref: PresetRef) -> Preset:
    """Read blobs/<ref.sha256>.bin, re-hash (IntegrityError on rot/missing),
    build ref.to_preset(blob). The standard resolver for apply."""
```

Swift (`Library` actor):

```swift
public func collections() throws -> [PresetCollection]
public func collection(id: String) throws -> PresetCollection      // .collectionNotFound
public func saveCollection(_ coll: PresetCollection) throws
public func renameCollection(id: String, to name: String) throws -> PresetCollection
public func deleteCollection(id: String) throws
public func presetForRef(_ ref: PresetRef) throws -> Preset
```

### 4.5 Blob lifetime — refcount now spans collections

`remove(entry_id)` / `remove(id:)` and `delete_collection` delete a blob file
**only when no remaining entry AND no remaining collection references its
sha256**. This is the one change to blob GC and it is mandatory — without it,
deleting the last entry that shares a blob would orphan a collection's
occupant.

- New internal predicate `_blob_referenced(sha) -> bool` = any entry has that
  sha, OR any collection has a ref with that sha (scan `collections/*.json`).
- `remove` and `delete_collection` both consult it before unlinking.
- Swift mirrors with `blobReferenced(_ sha:) throws -> Bool`.

### 4.6 New error cases

Python: add `CollectionNotFoundError(LibraryError)` with `.collection_id`,
alongside `EntryNotFoundError`. Export it from `__init__.py`.

Swift: add to `FreakError`:

```swift
case collectionNotFound(id: String)                              // Library subtree (.group == .library)
case applyFailed(underlying: FreakError, completed: [WriteReport]) // §6 stop-on-first-failure
```

`applyFailed` mirrors `restoreFailed` exactly (the Python `.completed`
attachment); `collectionNotFound` joins the `.library` group.

---

## 5. Entry points: snapshot-from-device and import-.mfprojz

Both build a `PresetCollection`, storing every referenced blob into the shared
`blobs/` dir (content-addressed, deduped — 269 Inits cost one file). Both are
pure of device I/O beyond consuming an already-read snapshot / already-parsed
bank, so both cores implement identical, fixture-coverable behavior.

An internal `Library._ensure_blob(blob) -> sha` (write iff absent; the blob
half of `add`) is factored out and reused by both builders and by `add`.

### 5.1 Snapshot-from-device → Collection

Takes a snapshot the caller already read (`snapshot(read_blobs=True,
keep_blobs=True)` — blobs and hashes required). Every slot whose name read
succeeded (`meta is not None`) becomes a ref; the arrangement is captured
including Init slots (a device arrangement is all 512 slots). Slots whose name
read failed are skipped (no meta to round-trip faithfully) and reported.

Python (`Library`):

```python
def collection_from_snapshot(self, snapshot: DeviceSnapshot, *, name: str,
                             source: str = "") -> PresetCollection:
    """Store each recorded blob (content-addressed) and build a collection of
    PresetRefs at each slot. Requires kept blobs + hashes (else ValueError).
    Skips records whose name read failed (meta is None). Provenance kind =
    DEVICE_SNAPSHOT, source defaults to snapshot.taken_at. Saved before
    return."""
```

Swift (`Library` actor):

```swift
public func collectionFromSnapshot(_ snapshot: DeviceSnapshot, name: String,
                                   source: String = "") throws -> PresetCollection
// throws .snapshotMissingBlobs (no kept blobs) / .snapshotMissingHashes
```

Behavior pinned: `source == ""` → use `snapshot.takenAt`. Ref name uses
`record.name` (never nil here — nil-name records are skipped). `meta_hex` =
`record.meta.hex()`.

### 5.2 Import `.mfprojz` bank → Collection

The verified parser is `tools/mbp_import.py` (Python) — **use it; do not
rewrite the Boost parsing**. To keep the core stdlib-clean and free of a
`tools/` dependency, the core entry point consumes an already-parsed,
normalized item list; the caller (orchestrator/app) runs the parser and adapts
each `MbpPreset` to a `BankItem`. The interop contract is therefore: *given
identical parsed items, both cores build an identical collection JSON* —
directly fixture-coverable without a Swift Boost reader (a Swift `.mfprojz`
reader is a separate deliverable feeding the same entry point; out of scope
here).

`BankItem` (core input value type, in `collections`):

```python
@dataclass(frozen=True)
class BankItem:
    slot: Optional[int]     # 0-based MF slot from the filename, or None
    name: str
    meta: bytes             # 9 bytes, or b"" for an empty/Init-only slot
    blob: Optional[bytes]   # 4672 bytes, or None for an empty slot
```

```python
# adapter the orchestrator writes (NOT core): MbpPreset -> BankItem
#   BankItem(slot=p.slot, name=p.name, meta=p.meta, blob=p.blob)
```

Import behavior (both cores), pinned:

- Skip items with `blob is None` **or** `slot is None` (empty/Init-only slots,
  or an unplaceable filename) — they contribute no ref.
- For each remaining item: `sha = _ensure_blob(blob)`; add a `PresetRef(sha,
  name, meta_hex)` at `slot`, where `meta_hex = meta.hex()` if `len(meta) == 9`
  else the 9-byte zero meta `"000000000000000000"` (the Ambient-Peaks
  all-zero case — a valid, writable meta).
- **Also add a library entry** per imported item (so packs are browsable and
  taggable), `category = uncategorized`, `favorite = false`, assigned to its
  slot — matching the established fact that downloaded packs arrive
  Uncategorized for manual/bulk tagging. The `(sha256, name)` dedupe of
  `add`-via-import is *not* applied here (a pack may legitimately repeat a
  name); each item yields one entry.
- Provenance kind = `IMPORTED_BANK`, `source` = the bank filename.

Python (`Library`):

```python
def collection_from_bank(self, items: Iterable[BankItem], *, name: str,
                         source: str) -> Tuple[PresetCollection, List[LibraryEntry]]:
    """Store blobs, add one Uncategorized library entry per placed item, build
    and save an IMPORTED_BANK collection. Returns (collection, added_entries)."""
```

Swift (`Library` actor):

```swift
public struct BankItem: Sendable, Equatable {
    public let slot: Int?
    public let name: String
    public let meta: Data          // 9 bytes, or empty for an empty slot
    public let blob: Data?         // 4672 bytes, or nil for an empty slot
    public init(slot: Int?, name: String, meta: Data, blob: Data?)
}
public func collectionFromBank(_ items: [BankItem], name: String,
                               source: String) throws -> (PresetCollection, [LibraryEntry])
```

---

## 6. Apply / switch a Collection to the device

Two phases, mirroring the pure-diff / executed-write split the core already
uses (`sync.diff` computes; the caller writes):

1. **Plan** — pure, no device: diff the collection against a full hashed
   `DeviceSnapshot`, producing a per-slot plan (`write` / `skip-unchanged` /
   `clear`) and a pre-flight summary ("changes N of 512 slots, ~M s").
2. **Execute** — write only the changed slots through the existing verified
   `MicroFreak.write`, with a `ProgressEvent` stream and cancellation,
   stopping at the first failure (restore semantics).

### 6.1 Plan types and algorithm (`collections.py`, `Collections.swift`)

```python
class PlanAction(enum.Enum):
    WRITE = "write"            # content or name differs -> full verified write
    SKIP_UNCHANGED = "skip"    # device already matches (sha AND name equal)
    CLEAR = "clear"            # not in collection; overwrite with clear_with


@dataclass(frozen=True)
class ApplyOptions:
    unlisted: str = "leave"         # "leave" | "clear" — slots absent from the collection
    clear_with: Optional[PresetRef] = None   # REQUIRED when unlisted == "clear"
    seconds_per_write: float = 1.0  # verified-write estimate (~0.5 s write + ~0.4 s verify)


@dataclass(frozen=True)
class SlotPlan:
    slot: int
    action: PlanAction
    incoming: Optional[PresetRef]   # ref to write (WRITE/CLEAR); None for SKIP
    victim: Optional[SlotRecord]    # the device record being replaced (for UI framing)


@dataclass(frozen=True)
class ApplyPlan:
    slots: Tuple[SlotPlan, ...]     # one per device slot, ascending
    write_count: int
    clear_count: int
    skip_count: int
    total_slots: int                # == len(slots) (the device's slot count)
    estimated_seconds: float        # round((write+clear) * seconds_per_write, 1)

    def changes(self) -> Tuple[SlotPlan, ...]:
        return tuple(p for p in self.slots
                     if p.action in (PlanAction.WRITE, PlanAction.CLEAR))
```

```python
def plan_apply(collection: PresetCollection, snapshot: DeviceSnapshot, *,
               options: ApplyOptions = ApplyOptions()) -> ApplyPlan:
    """Pure. Requires a FULL hashed snapshot: every slot 0..N-1 present and
    snapshot.has_hashes, else ValueError (Swift: .snapshotMissingHashes /
    a covering check). If options.unlisted == 'clear', options.clear_with is
    required, else ValueError.

    Per device record (ascending), ref = collection.slots.get(slot):
      ref present:
        record.sha256 == ref.sha256 and record.name == ref.name -> SKIP_UNCHANGED
        else                                                      -> WRITE (incoming=ref)
      ref absent:
        unlisted == 'clear':
          record already equals clear_with (sha AND name) -> SKIP_UNCHANGED
          else                                            -> CLEAR (incoming=clear_with)
        unlisted == 'leave':                              -> SKIP_UNCHANGED
    """
```

Notes pinned:

- **A name-only difference (sha equal, name differing) is a `WRITE`**, folded
  into the full verified write for the three-action model. Name-only diffs are
  rare; fidelity beats saving ~1 s on the uncommon case in v1.
- **Full hashed snapshot required.** Switching is preceded by a device read;
  the cheap path is `snapshot(read_blobs=True)` (names+hashes, no kept blobs)
  — the same ~211 s pass that *is* a backup (`ux-spec` §4). Names-only cannot
  determine content equality, so it is rejected.
- Slots in the collection beyond the snapshot's range would make the plan
  undecidable; requiring a full snapshot removes the case. If a collection
  references a slot ≥ `snapshot` slot count, `plan_apply` raises.

Swift signatures:

```swift
public enum PlanAction: String, Sendable { case write, skip = "skip", clear }

public struct ApplyOptions: Sendable {
    public enum Unlisted: Sendable { case leave, clear }
    public var unlisted: Unlisted = .leave
    public var clearWith: PresetRef? = nil          // required when unlisted == .clear
    public var secondsPerWrite: Double = 1.0
    public init() {}
}
public struct SlotPlan: Sendable, Equatable {
    public let slot: Int
    public let action: PlanAction
    public let incoming: PresetRef?
    public let victim: SlotRecord?
}
public struct ApplyPlan: Sendable, Equatable {
    public let slots: [SlotPlan]
    public let writeCount: Int
    public let clearCount: Int
    public let skipCount: Int
    public let totalSlots: Int
    public let estimatedSeconds: Double
    public func changes() -> [SlotPlan]     // WRITE + CLEAR
}
public func planApply(collection: PresetCollection, snapshot: DeviceSnapshot,
                      options: ApplyOptions = ApplyOptions()) throws -> ApplyPlan
```

### 6.2 Execute (device layer — `device.py`, `Device.swift`)

Reuses the verified-write path and the restore control shape (progress per
changed slot, cancel between slots, stop-on-first-failure with completed
reports). The resolver decouples the device from `Library`.

Python (`MicroFreak`):

```python
def apply_collection(self, plan: ApplyPlan,
                     resolve: Callable[[PresetRef], Preset], *,
                     verify: bool = True,
                     progress: Optional[ProgressFn] = None,
                     cancel: Optional[CancelToken] = None) -> List[WriteReport]:
    """Write only plan.changes() (WRITE + CLEAR), ascending. Per changed slot:
    poll cancel -> OperationCancelledError(done, total); preset =
    resolve(p.incoming); self.write(p.slot, preset, verify=verify). Stops at
    the first raised error; attaches completed reports as .completed on any
    MicroFreakError. Progress total = len(plan.changes()); eta median-based,
    same math as restore. SKIP_UNCHANGED slots are never written."""
```

The standard resolver is `library.preset_for_ref` (§4.4). `total` counts only
changed slots so the progress bar reflects real work; the pre-flight "N of
512" comes from the `ApplyPlan` counts, not the progress total.

Swift (`FreakDeviceProtocol` + `MicroFreakDevice`):

```swift
public func applyCollection(plan: ApplyPlan,
                            resolve: @Sendable (PresetRef) throws -> Preset,
                            verify: Bool = true,
                            progress: ProgressReporter?) async throws -> [WriteReport]
// cancellation is Task.isCancelled between slots -> .operationCancelled(done:total:);
// any FreakError mid-apply is rethrown as .applyFailed(underlying:, completed:);
// progress.finish() in a defer.
```

Add the default-argument overload `applyCollection(plan:resolve:progress:)`
(verify: true) to the `FreakDeviceProtocol` extension, matching the `write` /
`restore` overload pattern. The resolver is typically
`{ try await library.presetForRef($0) }` captured by the app; because it is
`@Sendable` and may hop to the `Library` actor, the app wraps the actor call.

### 6.3 Pre-flight summary (the UI's "changes N of 512, ~M s")

The `ApplyPlan` already carries `writeCount`, `clearCount`, `skipCount`,
`totalSlots`, `estimatedSeconds`. The app renders directly from those — e.g.
`"changes \(writeCount + clearCount) of \(totalSlots) slots, ~\(Int(estimatedSeconds.rounded())) s"`
— and lists each `changes()` row with its `incoming.name` and `victim` name +
expendability (via `Analysis.findExpendable` over the same snapshot), driving
the existing `OverwritePlan`/`BulkApplyPlan` guard-rail component. No new UI
type is required in the core; a thin app-side `CollectionApplyPlan` view model
wraps `ApplyPlan` for presentation.

---

## 7. App-facing seam additions (UI stays UI-only)

Extends `swift-architecture.md` §14. The app talks to these core types only;
it never touches frames or bytes.

- **Category browse/filter with counts:** `Attributes.categoryCensus(entries)`
  → `[Category: Int]` for the chip row; filter is `entries.filter { $0.category
  == chosen }`. Chip display via `Category.displayName`; chip order is the
  UI's choice over `Category.allCases`.
- **Favorites view:** `entries.filter(\.favorite)`; toggle via
  `Library.setFavorite(id:to:)`.
- **Tag filtering:** `Attributes.allTags(entries)` for the sidebar tag list;
  filter is `entries.filter { $0.tags.contains(tag) }`; edit via
  `Library.setTags(id:to:)`.
- **Category edit:** `Library.setCategory(id:to:)`. The detail view's existing
  "Category byte" row (`ux-spec` §7.4) gains an editable `Category` picker;
  the raw device byte stays a read-only diagnostic (meta is not rewritten).
- **Collections screen:** `Library.collections()` (list),
  `collectionFromSnapshot(...)` (create-from-device, off a full hashed
  snapshot / the latest backup's snapshot), `collectionFromBank(...)`
  (import-bank), `renameCollection` / `deleteCollection`. **Apply** builds a
  plan with `planApply(collection:snapshot:options:)`, shows the §6.3
  pre-flight, then runs `device.applyCollection(plan:resolve:progress:)` on the
  app's device-operation queue with the standard `ProgressReporter` + Cancel
  pattern. `.operationCancelled` mid-apply is the expected partial path (like a
  paused backup), not an error surface; `.applyFailed`/`.verifyMismatch`
  surface per `ux-spec` §14.

All new work runs on the app's single device-operation queue (one transaction
at a time), exactly as backup/restore/sync do today.

---

## 8. Parity coverage — golden vectors (`tools/gen_vectors.py`)

Every new core behavior gets fixture coverage; the Swift port consumes the
fixtures byte-for-byte and never hand-derives expected values. Add these emit
functions to `gen_vectors.py` and register them in `main()`; each writes into
`ios/FreakCore/Tests/FreakCoreTests/Fixtures/vectors/`.

- **`category.json`** (`gen_category`): every device byte `0x00..0x10`
  (covering the 13 mapped values plus three past-the-table bytes) → expected
  `{ "byte": int, "slug": str }`, asserting `Category.from_device_byte`; plus
  slug round-trips (`from_slug(slug).slug == slug`) for all 13, and
  `from_slug("future_cat") == "uncategorized"`.

- **`library_attrs.json`** (`gen_library_attrs`): entries serialized with
  `category`/`favorite`/`tags` and read back (round-trip parity), **plus** an
  "old index" case — an `index.json` object whose entries omit `category`,
  `favorite`, and `tags` — with expected parsed defaults
  (`category = "uncategorized"`, `favorite = false`, `tags = []`), asserting
  additive back-compat load. A `category_census` case over a small entry set →
  expected per-category counts.

- **`collections.json`** (`gen_collections`): a `PresetCollection` JSON (with
  each `provenance.kind`) → its parsed form (slots keyed by int, refs decoded),
  and the reverse; plus a `plan_apply` decision table — a synthetic collection
  vs. a synthetic full hashed snapshot → per-slot `{slot, action}` with
  `write_count`/`clear_count`/`skip_count`/`estimated_seconds`, covering: WRITE
  (sha differs), WRITE (name-only differs), SKIP_UNCHANGED (sha+name equal),
  CLEAR (unlisted + `clear_with`, device non-empty), SKIP (unlisted + leave),
  SKIP (unlisted + clear but device already == clear_with); and the error case
  `plan_apply` over a hash-less / partial snapshot → `expected_error`. Snapshot
  records and refs use real sha256 hex of seeded blobs (only string equality
  matters), following the existing `sync_diff.json` convention.

Blob-bearing fixtures (if any) obey the existing `verify()` guard (4672-byte
`blob_hex`, `F0…F7` framing on `frame` fields). Regenerate with
`python3 tools/gen_vectors.py` from the repo root.

Swift test suites (extend `swift-architecture.md` §13): `LibraryTests` gains
additive-field round-trip + old-index defaults + census/tags; new
`CollectionsTests` covers collection JSON round-trip, `collectionFromSnapshot`
/ `collectionFromBank` builders (blob dedupe, entry creation, provenance,
skip rules), blob GC spanning collections, and `planApply` against
`category.json`/`collections.json`; `DeviceTests` gains `applyCollection`
(writes only changed slots against the sim — assert the sim wire log has
exactly `changeCount` write bursts — cancel-between-slots, stop-on-first-
failure with `.applyFailed.completed`).

---

## 9. Non-goals for v1 (explicit, so nothing speculative is built)

- No device write of the category byte (meta round-trips verbatim; the library
  category is a separate editable attribute).
- No network / web-fetch of Arturia categories (offline only).
- No categories beyond the documented Arturia set; the device-byte index map
  is the single documented, hardware-confirmable table.
- No collection "layers"/merge, no per-collection blob store, no smart/auto
  collections, no cross-identity apply without the existing cross-identity
  warning (`ux-spec` §11).
- No rename-only fast path in apply (name-only diffs are full writes in v1).
- No new schema version bump (all additions are additive over `schema: 1`).
