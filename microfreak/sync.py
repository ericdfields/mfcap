"""Pure two-way diff between a DeviceSnapshot and a Library.

Deterministic, no baseline state, computes and never writes. Executing a
diff is the caller composing MicroFreak.write / Library.add calls per row;
the core never auto-writes from a diff.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import List, Optional, Tuple

from .analysis import find_expendable
from .library import Library, LibraryEntry
from .model import DeviceSnapshot, SlotRecord
from .protocol import DUPLICATE_THRESHOLD


class SlotStatus(Enum):
    IN_SYNC = "in_sync"        # assigned entry's sha == device sha
    DEVICE_ONLY = "added"      # non-expendable on device, no assigned entry
    LIBRARY_ONLY = "missing"   # entry assigned, device slot expendable
    DIFFERS = "changed"        # entry assigned, device non-expendable, shas differ
    EMPTY = "empty"            # device slot expendable, no assigned entry


@dataclass(frozen=True)
class SlotDiff:
    slot: int
    status: SlotStatus
    device: Optional[SlotRecord]
    library: Optional[LibraryEntry]


@dataclass(frozen=True)
class SyncDiff:
    slots: Tuple[SlotDiff, ...]          # one per snapshot record, ascending

    def by_status(self, status: SlotStatus) -> List[SlotDiff]:
        return [d for d in self.slots if d.status == status]


def diff(snapshot: DeviceSnapshot, library: Library, *,
         threshold: int = DUPLICATE_THRESHOLD) -> SyncDiff:
    """Per snapshot record: ex = expendable on device, lib = entry assigned
    to that slot. Then: no lib and ex -> EMPTY; no lib, not ex ->
    DEVICE_ONLY; lib and shas equal -> IN_SYNC; lib and ex -> LIBRARY_ONLY;
    else DIFFERS. Requires every considered record to carry sha256 —
    refusing beats guessing."""
    records = sorted(snapshot.records, key=lambda r: r.slot)
    if any(r.sha256 is None for r in records):
        raise ValueError("diff requires a snapshot with blob hashes")
    expendable = find_expendable(records, threshold=threshold)
    slot_map = library.slot_map()
    out: List[SlotDiff] = []
    for r in records:
        lib = slot_map.get(r.slot)
        ex = r.slot in expendable
        if lib is None:
            status = SlotStatus.EMPTY if ex else SlotStatus.DEVICE_ONLY
        elif lib.sha256 == r.sha256:
            status = SlotStatus.IN_SYNC
        elif ex:
            status = SlotStatus.LIBRARY_ONLY
        else:
            status = SlotStatus.DIFFERS
        out.append(SlotDiff(slot=r.slot, status=status, device=r, library=lib))
    return SyncDiff(slots=tuple(out))
