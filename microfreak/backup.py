"""BackupSet: the phase-0 on-disk backup format, unchanged.

    <dest>/
      index.json        {"created": ISO8601, "slots": N,
                         "presets": {"<slot>": {"slot", "name", "bytes",
                                                "sha256", "meta_hex"}},
                         "timing": {total_seconds, per_slot_seconds,
                                    name_ms_median, dump_ms_median}}
      presets/NNN.bin   the 4672-byte blob, zero-padded 3-digit slot number

Byte-compatible with what `mfcap backup` writes today, so existing backups
open unchanged. `meta_hex` (18 hex chars) is a new, additive field; loading
an old index without it yields records whose meta is None, and preset() on
such a slot raises IntegrityError — old backups remain readable for
diff/analysis; they only lack write-back capability.

Creation goes through MicroFreak.backup only (there is no BackupSet.create
taking a device — one mutation/IO path).
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Union

from .errors import IntegrityError, LibraryCorruptError, SlotOutOfRangeError
from .model import Preset, SlotRecord, TimingReport
from .protocol import digest


def atomic_write_text(path: Path, text: str) -> None:
    """Write text via a temp file + os.replace so readers never see a torn
    file."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent),
                               prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class BackupSet:
    """A loaded, hash-verified phase-0 backup directory."""

    def __init__(self, path: Path, created_at: str, timing: TimingReport,
                 entries: Dict[int, dict]):
        self.path = path
        self.created_at = created_at
        self.timing = timing
        self._entries = entries

    @classmethod
    def load(cls, path: Union[str, Path]) -> "BackupSet":
        """Load and verify: re-hashes every blob file against the index
        sha256; IntegrityError names the first bad slot. LibraryCorruptError
        on an unparseable index."""
        path = Path(path)
        index_path = path / "index.json"
        try:
            data = json.loads(index_path.read_text())
        except (OSError, ValueError) as e:
            raise LibraryCorruptError(str(index_path), str(e)) from e
        presets = data.get("presets")
        if not isinstance(presets, dict):
            raise LibraryCorruptError(str(index_path), "no 'presets' table")
        entries: Dict[int, dict] = {}
        for key in sorted(presets, key=lambda k: int(k)):
            v = presets[key]
            slot = int(key)
            sha = v.get("sha256")
            if sha:
                bin_path = path / "presets" / f"{slot:03d}.bin"
                if not bin_path.exists():
                    raise IntegrityError(str(bin_path),
                                         f"slot {slot}: blob file missing")
                if digest(bin_path.read_bytes()) != sha:
                    raise IntegrityError(str(bin_path),
                                         f"slot {slot}: sha256 mismatch")
            entries[slot] = v
        t = data.get("timing") or {}
        timing = TimingReport(
            total_seconds=float(t.get("total_seconds") or 0.0),
            per_slot_seconds=float(t.get("per_slot_seconds") or 0.0),
            name_ms_median=t.get("name_ms_median"),
            dump_ms_median=t.get("dump_ms_median"))
        return cls(path=path, created_at=data.get("created", ""),
                   timing=timing, entries=entries)

    def covers(self, slot: int) -> bool:
        v = self._entries.get(slot)
        return bool(v and v.get("sha256"))

    def covered_slots(self) -> List[int]:
        return sorted(s for s in self._entries if self.covers(s))

    def preset(self, slot: int) -> Preset:
        if not self.covers(slot):
            raise SlotOutOfRangeError(slot)
        v = self._entries[slot]
        meta_hex = v.get("meta_hex")
        bin_path = self.path / "presets" / f"{slot:03d}.bin"
        if not meta_hex:
            raise IntegrityError(
                str(bin_path),
                "no meta recorded; re-backup to restore this slot")
        blob = bin_path.read_bytes()
        return Preset(name=v.get("name") or "", blob=blob,
                      meta=bytes.fromhex(meta_hex))

    def records(self) -> List[SlotRecord]:
        """name + sha + meta per covered slot; blob=None (lazy)."""
        out: List[SlotRecord] = []
        for slot in sorted(self._entries):
            v = self._entries[slot]
            meta_hex = v.get("meta_hex")
            out.append(SlotRecord(
                slot=slot, name=v.get("name"), sha256=v.get("sha256"),
                meta=bytes.fromhex(meta_hex) if meta_hex else None,
                blob=None))
        return out
