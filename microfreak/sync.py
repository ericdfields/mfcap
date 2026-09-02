"""Pure two-way diff between a DeviceSnapshot and a BASELINE arrangement.

A baseline is a `{slot: PresetRef}` map — normally a `PresetCollection`'s
`slots`. It answers exactly one question: *how does the device differ from
this named arrangement?*

The library is deliberately NOT a baseline. It is a flat catalog of unique
patches and carries no slot opinion of its own (a `LibraryEntry.slot` is a
deliberate user pin, not an arrangement), so diffing a device against the
whole library merges every imported bank into one incoherent mash. Compare
against a collection the user chose instead.

Deterministic, no baseline state, computes and never writes. Executing a
diff is the caller composing MicroFreak.write / Library.add calls per row;
the core never auto-writes from a diff.

This module is the SINGLE definition of device-vs-collection difference:
`collections.plan_apply` is this same decision table plus the unlisted
policy and write bookkeeping, so the Sync screen and Apply can never
disagree.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import TYPE_CHECKING, List, Mapping, Optional, Tuple

from .analysis import find_expendable
from .model import DeviceSnapshot, PresetRef, SlotRecord
from .protocol import DUPLICATE_THRESHOLD

if TYPE_CHECKING:                       # no runtime import: collections imports us
    from .collections import PresetCollection


class SlotStatus(Enum):
    IN_SYNC = "in_sync"        # baseline ref's sha == device sha
    UNLISTED = "unlisted"      # non-expendable on device, baseline silent here
    BASELINE_ONLY = "missing"  # baseline places a preset, device slot expendable
    DIFFERS = "changed"        # baseline places a preset, device real, shas differ
    EMPTY = "empty"            # device slot expendable, baseline silent here


@dataclass(frozen=True)
class SlotDiff:
    slot: int
    status: SlotStatus
    device: Optional[SlotRecord]
    baseline: Optional[PresetRef]
    name_differs: bool = False     # shas equal, names differ (never a status change)


@dataclass(frozen=True)
class SyncDiff:
    slots: Tuple[SlotDiff, ...]                  # one per snapshot record, ascending
    unread_baseline_slots: Tuple[int, ...] = ()  # baseline slots the snapshot missed

    def by_status(self, status: SlotStatus) -> List[SlotDiff]:
        return [d for d in self.slots if d.status == status]


def diff_baseline(snapshot: DeviceSnapshot, baseline: Mapping[int, PresetRef],
                  *, threshold: int = DUPLICATE_THRESHOLD) -> SyncDiff:
    """Per snapshot record: ex = expendable on device, b = baseline.get(slot).
    Then: no b and ex -> EMPTY; no b, not ex -> UNLISTED; b and shas equal ->
    IN_SYNC; b and ex -> BASELINE_ONLY; else DIFFERS. Requires every
    considered record to carry sha256 — refusing beats guessing.

    A slot the baseline says nothing about can only land in UNLISTED or
    EMPTY: both mean "this collection has no opinion here", neither is
    actionable, and neither is `missing`."""
    records = sorted(snapshot.records, key=lambda r: r.slot)
    if any(r.sha256 is None for r in records):
        raise ValueError("diff requires a snapshot with blob hashes")
    expendable = find_expendable(records, threshold=threshold)
    out: List[SlotDiff] = []
    for r in records:
        b = baseline.get(r.slot)
        ex = r.slot in expendable
        if b is None:
            status = SlotStatus.EMPTY if ex else SlotStatus.UNLISTED
        elif b.sha256 == r.sha256:
            status = SlotStatus.IN_SYNC
        elif ex:
            status = SlotStatus.BASELINE_ONLY
        else:
            status = SlotStatus.DIFFERS
        out.append(SlotDiff(slot=r.slot, status=status, device=r, baseline=b,
                            name_differs=b is not None and r.name != b.name))
    read = {r.slot for r in records}
    unread = tuple(sorted(s for s in baseline if s not in read))
    return SyncDiff(slots=tuple(out), unread_baseline_slots=unread)


def diff(snapshot: DeviceSnapshot, collection: "PresetCollection", *,
         threshold: int = DUPLICATE_THRESHOLD) -> SyncDiff:
    """Convenience: diff_baseline(snapshot, collection.slots, threshold=...)."""
    return diff_baseline(snapshot, collection.slots, threshold=threshold)
