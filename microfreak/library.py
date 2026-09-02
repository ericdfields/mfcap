"""Library: a local folder of content-addressed preset blobs + index.json.

    <root>/
      index.json                 {"schema": 1, "entries": [entry...]}
      blobs/<sha256>.bin         content-addressed 4672-byte blobs
                                 (269 Inits cost one file)
      collections/<id>.json      named device arrangements
      notes/<entry id>.json      per-entry voice/typed notes (docs/voice-notes.md)

Index writes are atomic (temp file + os.replace). Single-writer assumption;
no cross-process locking. Every get() re-hashes the blob file against its
filename (IntegrityError on rot).

`_entry_to_json` below builds a FIXED dict and _save() rewrites EVERY entry
through it — which is exactly why notes live in their own sidecar files and not
in the index (docs/voice-notes.md §0).
"""
from __future__ import annotations

import dataclasses
import json
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import (Dict, Iterable, List, Optional, Sequence, Set, Tuple,
                    Union)

from .analysis import find_expendable
from .backup import atomic_write_text
from .collections import (BankItem, PresetCollection, Provenance,
                          ProvenanceKind, collection_from_json,
                          collection_to_json)
from .errors import (CollectionNotFoundError, EntryNotFoundError,
                     IntegrityError, LibraryCorruptError, SlotOutOfRangeError)
from .model import Category, DeviceSnapshot, Preset, PresetRef, Verdict
from .notes import (NOTE_SCHEMA, NoteDocument, PresetNote, canonical_order,
                    note_document_from_json, note_document_to_json)
from .protocol import DUPLICATE_THRESHOLD, SLOTS, digest

_SCHEMA = 1


@dataclass(frozen=True)
class LibraryEntry:
    id: str                    # uuid4 hex, minted at add(); survives rename
    name: str
    sha256: str
    meta_hex: str              # 18 hex chars, round-trips Preset.meta
    slot: Optional[int]        # a DELIBERATE user pin: "when I send this
                               # patch, it belongs in this slot". Set only by
                               # assign_slot (and device-capture adds that
                               # record where the bytes came from) — NEVER by
                               # importing a bank or merging a bundle, whose
                               # arrangement lives in a PresetCollection.
                               # At most one entry per slot.
    added_at: str              # ISO 8601
    tags: Tuple[str, ...]
    category: Category = Category.UNCATEGORIZED   # editable; auto-filled from meta[7] on device import
    favorite: bool = False
    verdict: Verdict = Verdict.UNRATED             # audition verdict (additive, back-compat)


def _entry_to_json(e: LibraryEntry) -> dict:
    return {"id": e.id, "name": e.name, "sha256": e.sha256,
            "meta_hex": e.meta_hex, "slot": e.slot, "added_at": e.added_at,
            "tags": list(e.tags),
            "category": e.category.slug, "favorite": bool(e.favorite),
            "verdict": e.verdict.slug}


def _entry_from_json(d: dict) -> LibraryEntry:
    return LibraryEntry(id=d["id"], name=d["name"], sha256=d["sha256"],
                        meta_hex=d["meta_hex"], slot=d.get("slot"),
                        added_at=d.get("added_at", ""),
                        tags=tuple(d.get("tags") or ()),
                        category=Category.from_slug(d.get("category", "uncategorized")),
                        favorite=bool(d.get("favorite", False)),
                        verdict=Verdict.from_slug(d.get("verdict", "unrated")))


# --------------------------------------------------------- read helpers (pure)

def category_census(entries: Iterable[LibraryEntry]) -> Dict[Category, int]:
    """Count entries per Category. Every Category key present (0 when none),
    so the UI renders a stable chip row."""
    counts: Dict[Category, int] = {c: 0 for c in Category}
    for e in entries:
        counts[e.category] = counts.get(e.category, 0) + 1
    return counts


def all_tags(entries: Iterable[LibraryEntry]) -> List[str]:
    """Sorted unique tag set across entries."""
    seen: Set[str] = set()
    for e in entries:
        seen.update(e.tags)
    return sorted(seen)


class Library:
    def __init__(self, root: Path, entries: List[LibraryEntry]):
        self.root = Path(root)
        self._entries = entries

    # ------------------------------------------------------------ open/create

    @classmethod
    def create(cls, root: Union[str, Path]) -> "Library":
        """Create a NEW library. Refuses (FileExistsError) if root already
        holds an index.json — creating over an existing library would wipe
        its entry list and orphan its blobs. Open-or-create idiom:

            try:
                lib = Library.open(root)
            except FileNotFoundError:
                lib = Library.create(root)
        """
        root = Path(root)
        index_path = root / "index.json"
        if index_path.exists():
            raise FileExistsError(
                f"{index_path}: a library already exists here — use "
                "Library.open(); create() will not overwrite an index")
        (root / "blobs").mkdir(parents=True, exist_ok=True)
        lib = cls(root, [])
        lib._save()
        return lib

    @classmethod
    def open(cls, root: Union[str, Path]) -> "Library":
        """Open an existing library. A missing index.json raises
        FileNotFoundError (there is no library here — create one); an
        unreadable or malformed one raises LibraryCorruptError."""
        root = Path(root)
        index_path = root / "index.json"
        try:
            data = json.loads(index_path.read_text())
        except FileNotFoundError:
            raise
        except (OSError, ValueError) as e:
            raise LibraryCorruptError(str(index_path), str(e)) from e
        if data.get("schema") != _SCHEMA or not isinstance(data.get("entries"), list):
            raise LibraryCorruptError(str(index_path),
                                      f"unsupported schema: {data.get('schema')!r}")
        try:
            entries = [_entry_from_json(d) for d in data["entries"]]
        except (KeyError, TypeError) as e:
            raise LibraryCorruptError(str(index_path),
                                      f"bad entry: {e}") from e
        return cls(root, entries)

    def _save(self) -> None:
        payload = {"schema": _SCHEMA,
                   "entries": [_entry_to_json(e) for e in self._entries]}
        atomic_write_text(self.root / "index.json",
                          json.dumps(payload, indent=2))

    def _blob_path(self, sha256: str) -> Path:
        return self.root / "blobs" / f"{sha256}.bin"

    def _ensure_blob(self, blob: bytes) -> str:
        """Write the blob content-addressed iff absent; return its sha256.
        The blob half of add(), reused by the collection builders."""
        sha = digest(bytes(blob))
        path = self._blob_path(sha)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes(blob))
        return sha

    def _collections_dir(self) -> Path:
        return self.root / "collections"

    def _collection_path(self, coll_id: str) -> Path:
        return self._collections_dir() / f"{coll_id}.json"

    def _notes_dir(self) -> Path:
        """<root>/notes — created lazily on first write (§1.1)."""
        return self.root / "notes"

    def _note_path(self, entry_id: str) -> Path:
        return self._notes_dir() / f"{entry_id}.json"

    # ---------------------------------------------------------------- reads

    def entries(self) -> List[LibraryEntry]:
        return list(self._entries)

    def entry(self, entry_id: str) -> LibraryEntry:
        for e in self._entries:
            if e.id == entry_id:
                return e
        raise EntryNotFoundError(entry_id)

    def get(self, entry_id: str) -> Preset:
        e = self.entry(entry_id)
        path = self._blob_path(e.sha256)
        try:
            blob = path.read_bytes()
        except OSError as exc:
            raise IntegrityError(str(path), "blob file missing") from exc
        if digest(blob) != e.sha256:
            raise IntegrityError(str(path), "sha256 mismatch (bit rot?)")
        return Preset(name=e.name, blob=blob, meta=bytes.fromhex(e.meta_hex))

    def find_by_sha(self, sha256: str) -> List[LibraryEntry]:
        return [e for e in self._entries if e.sha256 == sha256]

    def has_blob(self, sha256: str) -> bool:
        return self._blob_path(sha256).exists()

    def slot_map(self) -> Dict[int, LibraryEntry]:
        return {e.slot: e for e in self._entries if e.slot is not None}

    # --------------------------------------------------------------- writes

    def add(self, preset: Preset, *, slot: Optional[int] = None,
            tags: Sequence[str] = (),
            category: Category = Category.UNCATEGORIZED,
            favorite: bool = False, dedupe: bool = False) -> LibraryEntry:
        """Blob written iff absent; a new entry unless `dedupe` and an entry
        with the same (sha256, name) already exists, in which case that entry
        is reused (attributes merged) so the library stays a catalog of unique
        patches. Two entries may still share one blob under different names."""
        if slot is not None and not 0 <= slot < SLOTS:
            raise SlotOutOfRangeError(slot)
        sha = self._ensure_blob(preset.blob)
        if dedupe:
            for i, e in enumerate(self._entries):
                if e.sha256 == sha and e.name == preset.name:
                    new_slot = e.slot if e.slot is not None else slot
                    # The new-entry path below clears competing claims; the
                    # dedupe path must too, or two entries can claim one slot
                    # and slot_map() would silently drop one.
                    if e.slot is None and new_slot is not None:
                        self._clear_slot_claims(new_slot)
                        e = self._entries[i]     # list may have been rewritten
                    merged = dataclasses.replace(
                        e,
                        slot=new_slot,
                        tags=tuple(dict.fromkeys((*e.tags, *tags))),
                        favorite=e.favorite or bool(favorite),
                        category=(category if e.category == Category.UNCATEGORIZED
                                  else e.category))   # verdict: keep e's
                    self._entries[i] = merged
                    self._save()
                    return merged
        entry = LibraryEntry(id=uuid.uuid4().hex, name=preset.name,
                             sha256=sha, meta_hex=bytes(preset.meta).hex(),
                             slot=slot,
                             added_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
                             tags=tuple(tags), category=category,
                             favorite=bool(favorite))
        if slot is not None:
            self._clear_slot_claims(slot)
        self._entries.append(entry)
        self._save()
        return entry

    def dedupe(self) -> int:
        """Collapse entries with identical (sha256, name) into one, merging
        attributes (union tags, OR favorite, prefer a set category, keep the
        first slot) AND merging notes sidecars (the losers' notes are folded
        into the survivor's file, concatenated and re-sorted into the
        docs/voice-notes.md §1.3 canonical order, and the losers' files are
        deleted). Safe for collections, which reference presets by sha, not by
        entry id. Returns the number of entries removed.

        Notes merge like tags, not like slots: an entry's notes are provenance
        for the bytes, and two catalog rows for the same (sha256, name) were
        always the same preset, so dropping the loser's notes would lose the
        only record of what the user said about it. The one refusal is the §1.2
        schema gate: if ANY sidecar in a group was written by a newer core this
        one cannot read losslessly, the whole group's files are left untouched —
        an unreachable-but-intact sidecar beats a rewritten one."""
        keep: Dict[tuple, LibraryEntry] = {}
        order: List[tuple] = []
        groups: Dict[tuple, List[str]] = {}
        for e in self._entries:
            key = (e.sha256, e.name)
            groups.setdefault(key, []).append(e.id)
            if key not in keep:
                keep[key] = e
                order.append(key)
            else:
                p = keep[key]
                keep[key] = dataclasses.replace(
                    p,
                    slot=p.slot if p.slot is not None else e.slot,
                    tags=tuple(dict.fromkeys((*p.tags, *e.tags))),
                    favorite=p.favorite or e.favorite,
                    category=(e.category if p.category == Category.UNCATEGORIZED
                              else p.category),
                    verdict=(e.verdict if p.verdict == Verdict.UNRATED
                             else p.verdict))
        removed = len(self._entries) - len(order)
        if removed:
            for key in order:
                if len(groups[key]) > 1:
                    self._merge_notes(keep[key].id, groups[key])
            self._entries = [keep[k] for k in order]
            self._save()
        return removed

    def _merge_notes(self, survivor: str, ids: Sequence[str]) -> None:
        """Fold every collapsed entry's notes into the survivor's sidecar and
        drop the losers' files. `ids` is the whole group in list order;
        `survivor` is the first of them, and the only one that still exists
        afterwards."""
        docs = []
        for entry_id in ids:
            doc = self._load_note_document(entry_id)
            if doc is not None:
                docs.append((entry_id, doc))
        if not docs:
            return
        # §1.2: never rewrite a file a newer schema wrote, and never destroy one
        # either — leave the whole group alone and take the orphan.
        if any(doc.is_read_only for _, doc in docs):
            return
        merged: List[PresetNote] = [n for _, doc in docs for n in doc.notes]
        for entry_id, _ in docs:
            if entry_id != survivor:
                self.delete_notes(entry_id)
        self._write_notes(survivor, merged)     # canonical order applied here

    def clear_collection_slot_claims(self) -> int:
        """One-time repair for libraries built before bank import stopped
        stamping entry slots (every pack numbered from slot 1, so all of them
        claimed 0..31 and each import silently stole those slots from the
        last). Clears a claim ONLY when an IMPORTED_BANK collection already
        records the same (sha256, name) at that same slot — i.e. only when the
        arrangement being removed from the flat catalog is stored, intact, in
        the imported bank that put it there. Loss-free by construction.
        Idempotent. Returns the number of claims cleared.

        The imported-bank restriction is what makes the promise below true.
        Only `collection_from_bank` ever stamped a slot it did not own, so
        only an IMPORTED_BANK collection can explain a claim that should not
        exist. A DEVICE_SNAPSHOT collection records the very same (sha256,
        name, slot) triples as the `import_snapshot` pins taken in the same
        capture, so keying on every collection erased the ordinary
        "Import Device… then Snapshot This Device as a Collection" flow's pins
        wholesale; keying on imported banks alone leaves a device capture
        alone, as documented.

        Residual, unavoidable case: a deliberate `assign_slot` survives unless
        an imported bank happens to place those exact (sha256, name) bytes at
        that exact slot — the one state a legacy stamped claim is genuinely
        indistinguishable from, because the legacy import created it."""
        placed: Dict[int, Set[Tuple[str, str]]] = {}
        for coll in self.collections():
            if coll.provenance.kind is not ProvenanceKind.IMPORTED_BANK:
                continue     # only a bank import ever stamped a slot it did
                             # not own; a device capture is left alone
            for slot, ref in coll.slots.items():
                placed.setdefault(slot, set()).add((ref.sha256, ref.name))
        cleared = 0
        for i, e in enumerate(self._entries):
            if e.slot is None:
                continue
            if (e.sha256, e.name) in placed.get(e.slot, ()):
                self._entries[i] = dataclasses.replace(e, slot=None)
                cleared += 1
        if cleared:
            self._save()
        return cleared

    def set_category(self, entry_id: str, category: Category) -> LibraryEntry:
        return self._replace_entry(entry_id, category=category)

    def set_favorite(self, entry_id: str, favorite: bool) -> LibraryEntry:
        return self._replace_entry(entry_id, favorite=bool(favorite))

    def set_verdict(self, entry_id: str, verdict: Verdict) -> LibraryEntry:
        return self._replace_entry(entry_id, verdict=verdict)

    def set_tags(self, entry_id: str, tags: Sequence[str]) -> LibraryEntry:
        return self._replace_entry(entry_id, tags=tuple(tags))

    def _replace_entry(self, entry_id: str, **changes) -> LibraryEntry:
        e = self.entry(entry_id)
        new = dataclasses.replace(e, **changes)
        self._entries[self._entries.index(e)] = new
        self._save()
        return new

    def rename_entry(self, entry_id: str, name: str) -> LibraryEntry:
        from .protocol import validate_name
        validate_name(name)
        e = self.entry(entry_id)
        new = dataclasses.replace(e, name=name)
        self._entries[self._entries.index(e)] = new
        self._save()
        return new

    def remove(self, entry_id: str) -> None:
        """Delete the entry; the blob file is deleted only when no remaining
        entry AND no remaining collection references it, and the entry's notes
        sidecar goes with it."""
        e = self.entry(entry_id)
        self._entries.remove(e)
        if not self._blob_referenced(e.sha256):
            try:
                self._blob_path(e.sha256).unlink()
            except OSError:
                pass
        # Notes GC is unconditional and needs no reference check: a sidecar is
        # keyed on THIS entry's id, so nothing else can be pointing at it
        # (docs/voice-notes.md §1.1 — deleting an entry deletes its sidecar).
        self.delete_notes(entry_id)
        self._save()

    def _blob_referenced(self, sha256: str) -> bool:
        """True when any entry OR any collection references this sha256. Blob
        GC now spans collections, so deleting the last entry that shares a blob
        cannot orphan a collection's occupant."""
        if any(e.sha256 == sha256 for e in self._entries):
            return True
        for coll in self.collections():
            if any(ref.sha256 == sha256 for ref in coll.slots.values()):
                return True
        return False

    def assign_slot(self, entry_id: str, slot: Optional[int]) -> None:
        """Assigning a slot clears any other entry's claim to that slot."""
        e = self.entry(entry_id)
        if slot is not None:
            if not 0 <= slot < SLOTS:
                raise SlotOutOfRangeError(slot)
            self._clear_slot_claims(slot)
            e = self.entry(entry_id)     # list may have been rewritten
        new = dataclasses.replace(e, slot=slot)
        self._entries[self._entries.index(e)] = new
        self._save()

    def _clear_slot_claims(self, slot: int) -> None:
        for i, other in enumerate(self._entries):
            if other.slot == slot:
                self._entries[i] = dataclasses.replace(other, slot=None)

    # --------------------------------------------------------------- import

    def import_snapshot(self, snapshot: DeviceSnapshot, *,
                        skip_expendable: bool = True,
                        threshold: int = DUPLICATE_THRESHOLD) -> List[LibraryEntry]:
        """Import a snapshot's presets. Requires records with blobs
        (snapshot(read_blobs=True, keep_blobs=True)). Each imported entry is
        assigned the slot it came from. Skips expendable slots when asked;
        skips records for which an entry with identical (sha256, name)
        already exists; returns the entries actually added."""
        records = snapshot.records
        if any(r.blob is None for r in records):
            raise ValueError(
                "import_snapshot requires a snapshot with blobs "
                "(snapshot(read_blobs=True, keep_blobs=True))")
        expendable: Set[int] = (find_expendable(records, threshold=threshold)
                                if skip_expendable else set())
        existing = {(e.sha256, e.name) for e in self._entries}
        added: List[LibraryEntry] = []
        for r in records:
            if r.slot in expendable:
                continue
            if r.meta is None:
                continue     # name read failed: cannot round-trip meta
            name = r.name or ""
            if (r.sha256, name) in existing:
                continue
            entry = self.add(Preset(name=name, blob=r.blob, meta=r.meta),
                             slot=r.slot,
                             category=Category.from_device_byte(r.meta[7]))
            existing.add((r.sha256, name))
            added.append(entry)
        return added

    # ---------------------------------------------------------- collections

    def collections(self) -> List[PresetCollection]:
        """Every <root>/collections/*.json, parsed; ascending by created_at
        then id. Missing dir -> []."""
        cdir = self._collections_dir()
        if not cdir.is_dir():
            return []
        out: List[PresetCollection] = []
        for path in sorted(cdir.glob("*.json")):
            try:
                data = json.loads(path.read_text())
            except (OSError, ValueError) as e:
                raise LibraryCorruptError(str(path), str(e)) from e
            out.append(collection_from_json(data, path=str(path)))
        out.sort(key=lambda c: (c.created_at, c.id))
        return out

    def collection(self, coll_id: str) -> PresetCollection:
        path = self._collection_path(coll_id)
        if not path.exists():
            raise CollectionNotFoundError(coll_id)
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError) as e:
            raise LibraryCorruptError(str(path), str(e)) from e
        return collection_from_json(data, path=str(path))

    def store_preset(self, preset: Preset) -> PresetRef:
        """Store a preset's blob content-addressed and return the PresetRef
        that names it — WITHOUT creating a catalog entry.

        The blob half of `add()`, exposed for callers that edit a collection
        directly (adopting a device slot into an arrangement, say). Building
        a `PresetRef` from bytes the store never received produces a ref that
        `preset_for_ref` cannot resolve, which `plan_apply` then folds to SKIP
        forever — a silent, permanent hole in the arrangement. Going through
        here makes that impossible. Idempotent; safe to call for bytes already
        held."""
        sha = self._ensure_blob(preset.blob)
        ref = PresetRef.of(preset)
        assert ref.sha256 == sha
        return ref

    def save_collection(self, coll: PresetCollection) -> None:
        cdir = self._collections_dir()
        cdir.mkdir(parents=True, exist_ok=True)
        atomic_write_text(self._collection_path(coll.id),
                          json.dumps(collection_to_json(coll), indent=2))

    def rename_collection(self, coll_id: str, name: str) -> PresetCollection:
        coll = self.collection(coll_id)
        renamed = dataclasses.replace(coll, name=name)
        self.save_collection(renamed)
        return renamed

    def delete_collection(self, coll_id: str) -> None:
        coll = self.collection(coll_id)                 # CollectionNotFoundError
        shas = {ref.sha256 for ref in coll.slots.values()}
        try:
            self._collection_path(coll_id).unlink()
        except OSError:
            pass
        for sha in shas:                                # GC now that the file is gone
            if not self._blob_referenced(sha):
                try:
                    self._blob_path(sha).unlink()
                except OSError:
                    pass

    def merge_bundle(self, other: "Library") -> int:
        """Merge another library's collections (and their presets) into this
        one. Collection-granular and idempotent: a collection whose id already
        exists here is skipped, so re-running merges nothing new. Blobs are
        content-addressed, so shared presets are stored once. Returns the
        number of collections newly merged.

        Used to fold the bundled seed into an existing user library without
        disturbing entries the user already has.

        Notes need NOTHING here, deliberately. A bundled seed is built by the
        tooling and ships with collections/ and blobs/ only — it has no notes/
        directory, because a note is a recording of something a user said in an
        audition session and a seed has never been auditioned. And the merge is
        collection-granular: it copies arrangements and blobs and mints its own
        catalog entries with their own fresh ids, so there is no id under which
        a foreign sidecar could even be addressed. If a future bundle ever did
        carry notes, this method would have to grow an explicit entry-id
        remapping; silently importing them is not a thing that can happen by
        accident."""
        have = {c.id for c in self.collections()}
        merged = 0
        for coll in other.collections():
            if coll.id in have:
                continue
            slots: Dict[int, PresetRef] = {}
            for slot, ref in coll.slots.items():
                preset = other.preset_for_ref(ref)
                # The merged collection below carries the arrangement; the
                # catalog entry stays slot-less.
                entry = self.add(preset, dedupe=True)
                slots[slot] = PresetRef(sha256=entry.sha256, name=preset.name,
                                        meta_hex=ref.meta_hex)
            self.save_collection(dataclasses.replace(coll, slots=slots))
            merged += 1
        return merged

    def preset_for_ref(self, ref: PresetRef) -> Preset:
        """Read blobs/<ref.sha256>.bin, re-hash (IntegrityError on rot/missing),
        build ref.to_preset(blob). The standard resolver for apply."""
        path = self._blob_path(ref.sha256)
        try:
            blob = path.read_bytes()
        except OSError as exc:
            raise IntegrityError(str(path), "blob file missing") from exc
        if digest(blob) != ref.sha256:
            raise IntegrityError(str(path), "sha256 mismatch (bit rot?)")
        return ref.to_preset(blob)

    # ---------------------------------------------- collection builders

    def collection_from_snapshot(self, snapshot: DeviceSnapshot, *, name: str,
                                 source: str = "") -> PresetCollection:
        """Store each recorded blob (content-addressed) and build a collection
        of PresetRefs at each slot. Requires kept blobs + hashes (else
        ValueError). Skips records whose name read failed (meta is None).
        Provenance kind = DEVICE_SNAPSHOT, source defaults to
        snapshot.taken_at. Saved before return."""
        records = snapshot.records
        if any(r.blob is None for r in records):
            raise ValueError(
                "collection_from_snapshot requires a snapshot with kept blobs "
                "(snapshot(read_blobs=True, keep_blobs=True))")
        if not snapshot.has_hashes:
            raise ValueError(
                "collection_from_snapshot requires a snapshot with blob hashes")
        slots: Dict[int, PresetRef] = {}
        for r in records:
            if r.meta is None:
                continue     # name read failed: cannot round-trip meta
            sha = self._ensure_blob(r.blob)
            slots[r.slot] = PresetRef(sha256=sha, name=r.name or "",
                                      meta_hex=bytes(r.meta).hex())
        prov = Provenance(kind=ProvenanceKind.DEVICE_SNAPSHOT,
                          source=source or snapshot.taken_at)
        coll = PresetCollection.new(name=name, provenance=prov, slots=slots)
        self.save_collection(coll)
        return coll

    def collection_from_bank(self, items: Iterable[BankItem], *, name: str,
                             source: str) -> Tuple[PresetCollection, List[LibraryEntry]]:
        """Store blobs, add one SLOT-LESS Uncategorized library entry per
        placed item, build and save an IMPORTED_BANK collection. The
        arrangement lives in the collection's `slots`; the flat catalog entry
        claims nothing (UX spec §26.3). Skips items with no blob or no slot.
        Returns (collection, added_entries)."""
        slots: Dict[int, PresetRef] = {}
        added: List[LibraryEntry] = []
        for item in items:
            if item.blob is None or item.slot is None:
                continue     # empty/Init-only slot, or unplaceable filename
            meta = bytes(item.meta) if len(item.meta) == 9 else b"\x00" * 9
            preset = Preset(name=item.name, blob=item.blob, meta=meta)
            # The COLLECTION owns the arrangement (`slots` below); the library
            # entry is a catalog record and carries no slot opinion.
            # UX spec §26.3: "no slot claim".
            entry = self.add(preset, dedupe=True)                   # unique catalog
            slots[item.slot] = PresetRef(sha256=entry.sha256, name=preset.name,
                                         meta_hex=meta.hex())
            added.append(entry)
        prov = Provenance(kind=ProvenanceKind.IMPORTED_BANK, source=source)
        coll = PresetCollection.new(name=name, provenance=prov, slots=slots)
        self.save_collection(coll)
        return coll, added

    # ---------------------------------------------------------------- notes

    # The per-entry sidecar store, docs/voice-notes.md §1. PROVENANCE ONLY: no
    # reader anywhere may consult notes/ to determine an entry's verdict,
    # category or tags — an accepted proposal goes to its canonical home through
    # set_verdict / set_category / set_tags. Delete notes/ and the library is
    # exactly as correct as before; only the provenance is gone.

    def notes(self, entry_id: str) -> List[PresetNote]:
        """The notes attached to one entry, in the §1.3 canonical order they
        were written in. A MISSING FILE MEANS ZERO NOTES and is never an error;
        an unparseable one raises LibraryCorruptError. A sidecar whose entry no
        longer exists is IGNORED (it is never resurrected), so this returns []
        for an unknown id rather than raising."""
        doc = self.note_document(entry_id)
        return list(doc.notes) if doc is not None else []

    def note_document(self, entry_id: str) -> Optional[NoteDocument]:
        """The whole sidecar document, or None when there is no file. Callers
        that care about the §1.2 schema gate — "can I still write to this?" —
        read `is_read_only` here."""
        try:
            self.entry(entry_id)
        except EntryNotFoundError:
            return None
        return self._load_note_document(entry_id)

    def append_note(self, entry_id: str, note: PresetNote) -> List[PresetNote]:
        """Append one note. The file is rewritten atomically in canonical order.
        Raises EntryNotFoundError for an unknown entry (a sidecar with no entry
        is garbage by construction) and IntegrityError when the existing file
        carries a NEWER schema than this core understands (§1.2)."""
        existing = self._notes_for_writing(entry_id)
        return self._write_notes(entry_id, existing + [note])

    def replace_notes(self, entry_id: str,
                      notes: Sequence[PresetNote]) -> List[PresetNote]:
        """Replace the whole note list for an entry (the "move to previous
        preset" half of §4, and correction/acceptance edits). An empty list
        DELETES the sidecar rather than leaving an empty document behind."""
        self._notes_for_writing(entry_id)
        return self._write_notes(entry_id, list(notes))

    # ------------------------------------------- atomic read-modify-write
    #
    # The Swift core's mirror of these (FreakCore/Notes.swift) is what makes
    # a read-modify-write of a sidecar indivisible there: `notes()` followed
    # by `replace_notes()` is two awaits on an actor with a suspension in
    # between, and a note appended in the gap is silently overwritten by the
    # stale list the caller still holds. Because §1.5 keeps no audio, that
    # verbatim transcript was the only copy that ever existed. Kept here in
    # parity so both cores offer — and both cores' callers use — the same
    # indivisible operations.

    def mutate_notes(self, entry_id: str, transform) -> List[PresetNote]:
        """Read, transform and rewrite an entry's notes as one step."""
        existing = self._notes_for_writing(entry_id)
        return self._write_notes(entry_id, list(transform(existing)))

    def remove_note(self, entry_id: str, note_id: str) -> List[PresetNote]:
        """Drop one note by id. A note that was never there is not an error."""
        return self.mutate_notes(entry_id,
                                 lambda ns: [n for n in ns if n.id != note_id])

    def move_note(self, note_id: str, from_entry: str,
                  to_entry: str) -> Optional[PresetNote]:
        """Move one note between two sidecars (the §4 "that was about the
        previous preset" repair).

        THE APPEND LANDS FIRST, deliberately. append_note can raise for reasons
        that belong entirely to the destination (EntryNotFoundError, the §1.2
        IntegrityError, any write error); removing first meant such a failure
        destroyed the note instead of moving it. This order can at worst leave
        the note in BOTH files, which a user can see and fix.
        """
        source = self._notes_for_writing(from_entry)
        note = next((n for n in source if n.id == note_id), None)
        if note is None:
            return None
        if to_entry == from_entry:
            return note
        self.append_note(to_entry, note)
        self._write_notes(from_entry, [n for n in source if n.id != note_id])
        return note

    def delete_notes(self, entry_id: str) -> None:
        """Delete an entry's sidecar. Idempotent, and never an error when there
        is no file. Deliberately does NOT require the entry to exist: this is
        also how an orphaned sidecar is garbage-collected. No schema gate — §1.2
        forbids REWRITING a newer file, and §1.1 says flatly that deleting an
        entry deletes its sidecar."""
        try:
            self._note_path(entry_id).unlink()
        except OSError:
            pass

    def _load_note_document(self, entry_id: str) -> Optional[NoteDocument]:
        """Read + parse, or None when the file is absent. Shared by the public
        readers, remove()'s GC and dedupe()'s merge."""
        path = self._note_path(entry_id)
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError) as e:
            raise LibraryCorruptError(str(path), str(e)) from e
        if not isinstance(data, dict):
            raise LibraryCorruptError(str(path), "not a JSON object")
        return note_document_from_json(data, path=str(path))

    def _notes_for_writing(self, entry_id: str) -> List[PresetNote]:
        """The write preflight: the entry must exist, and the file on disk must
        not be a newer schema."""
        self.entry(entry_id)                     # EntryNotFoundError
        doc = self._load_note_document(entry_id)
        if doc is None:
            return []
        if doc.is_read_only:
            raise IntegrityError(
                str(self._note_path(entry_id)),
                f"notes sidecar schema {doc.schema} is newer than this core's "
                f"{NOTE_SCHEMA} — refusing to rewrite it")
        return list(doc.notes)

    def _write_notes(self, entry_id: str,
                     notes: Sequence[PresetNote]) -> List[PresetNote]:
        """Atomic write in canonical order; an empty list removes the file."""
        ordered = canonical_order(notes)
        if not ordered:
            self.delete_notes(entry_id)
            return []
        self._notes_dir().mkdir(parents=True, exist_ok=True)
        doc = NoteDocument(schema=NOTE_SCHEMA, entry_id=entry_id,
                           notes=tuple(ordered))
        atomic_write_text(self._note_path(entry_id),
                          json.dumps(note_document_to_json(doc), indent=2))
        return ordered
