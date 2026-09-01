"""Library: a local folder of content-addressed preset blobs + index.json.

    <root>/
      index.json                 {"schema": 1, "entries": [entry...]}
      blobs/<sha256>.bin         content-addressed 4672-byte blobs
                                 (269 Inits cost one file)

Index writes are atomic (temp file + os.replace). Single-writer assumption;
no cross-process locking. Every get() re-hashes the blob file against its
filename (IntegrityError on rot).
"""
from __future__ import annotations

import dataclasses
import json
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple, Union

from .analysis import find_expendable
from .backup import atomic_write_text
from .errors import (EntryNotFoundError, IntegrityError, LibraryCorruptError,
                     SlotOutOfRangeError)
from .model import DeviceSnapshot, Preset
from .protocol import DUPLICATE_THRESHOLD, SLOTS, digest

_SCHEMA = 1


@dataclass(frozen=True)
class LibraryEntry:
    id: str                    # uuid4 hex, minted at add(); survives rename
    name: str
    sha256: str
    meta_hex: str              # 18 hex chars, round-trips Preset.meta
    slot: Optional[int]        # this library's desired device slot;
                               # at most one entry per slot
    added_at: str              # ISO 8601
    tags: Tuple[str, ...]


def _entry_to_json(e: LibraryEntry) -> dict:
    return {"id": e.id, "name": e.name, "sha256": e.sha256,
            "meta_hex": e.meta_hex, "slot": e.slot, "added_at": e.added_at,
            "tags": list(e.tags)}


def _entry_from_json(d: dict) -> LibraryEntry:
    return LibraryEntry(id=d["id"], name=d["name"], sha256=d["sha256"],
                        meta_hex=d["meta_hex"], slot=d.get("slot"),
                        added_at=d.get("added_at", ""),
                        tags=tuple(d.get("tags") or ()))


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
            tags: Sequence[str] = ()) -> LibraryEntry:
        """Blob written iff absent; always a new entry (two entries may share
        one blob sha under different names)."""
        if slot is not None and not 0 <= slot < SLOTS:
            raise SlotOutOfRangeError(slot)
        sha = preset.sha256
        path = self._blob_path(sha)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes(preset.blob))
        entry = LibraryEntry(id=uuid.uuid4().hex, name=preset.name,
                             sha256=sha, meta_hex=bytes(preset.meta).hex(),
                             slot=slot,
                             added_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
                             tags=tuple(tags))
        if slot is not None:
            self._clear_slot_claims(slot)
        self._entries.append(entry)
        self._save()
        return entry

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
        entry references it."""
        e = self.entry(entry_id)
        self._entries.remove(e)
        if not self.find_by_sha(e.sha256):
            try:
                self._blob_path(e.sha256).unlink()
            except OSError:
                pass
        self._save()

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
                             slot=r.slot)
            existing.add((r.sha256, name))
            added.append(entry)
        return added
