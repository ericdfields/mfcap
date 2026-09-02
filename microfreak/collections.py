"""PresetCollection: a named device arrangement — an ordered slot->PresetRef
map over the library's content-addressed blobs, plus identity and provenance.

This module is pure of device I/O: it defines the collection value types, their
JSON codec, and the pure apply/switch PLAN (plan_apply). It imports model and
errors ONLY (never device or library), so planning is importable everywhere and
stays free of any wire/byte dependency. Executing a plan is
MicroFreak.apply_collection (device.py); building/storing collections is the
Library (library.py).

On-disk format — one file per collection under the library:

    <root>/collections/<id>.json
      {"schema": 1, "id": str, "name": str, "created_at": ISO8601,
       "provenance": {"kind": str, "source": str},
       "slots": {"<slot>": {"sha256": str, "name": str, "meta_hex": str}}}

`slots` is keyed by the DECIMAL slot number as a string (mirrors the backup
`presets` map). Canonical iteration is ascending by int(key); JSON key order is
irrelevant. Referenced blobs live in the SHARED blobs/ dir; a collection stores
no blob bytes of its own.
"""
from __future__ import annotations

import enum
import time
import uuid
from dataclasses import dataclass
from typing import Dict, Optional, Tuple

from .errors import LibraryCorruptError
from .model import DeviceSnapshot, PresetRef, SlotRecord

_COLLECTION_SCHEMA = 1
_ZERO_META_HEX = "00" * 9        # a valid, writable all-zero meta (Ambient Peaks)


# --------------------------------------------------------------- provenance

class ProvenanceKind(enum.Enum):
    DEVICE_SNAPSHOT = "device_snapshot"
    IMPORTED_BANK = "imported_bank"
    MANUAL = "manual"

    @classmethod
    def from_str(cls, s: str) -> "ProvenanceKind":
        try:
            return cls(s)
        except ValueError:
            return cls.MANUAL


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


# ---------------------------------------------------------------- bank input

@dataclass(frozen=True)
class BankItem:
    """Core input value type for import-.mfprojz-as-Collection. The caller
    (orchestrator/app) runs the verified tools/mbp_import.py parser and adapts
    each MbpPreset to a BankItem:
        BankItem(slot=p.slot, name=p.name, meta=p.meta, blob=p.blob)
    keeping the core stdlib-clean and free of a tools/ dependency."""
    slot: Optional[int]     # 0-based MF slot from the filename, or None
    name: str
    meta: bytes             # 9 bytes, or b"" for an empty/Init-only slot
    blob: Optional[bytes]   # 4672 bytes, or None for an empty slot


# ------------------------------------------------------------------- codec

def _ref_to_json(ref: PresetRef) -> dict:
    return {"sha256": ref.sha256, "name": ref.name, "meta_hex": ref.meta_hex}


def _ref_from_json(d: dict) -> PresetRef:
    return PresetRef(sha256=d["sha256"], name=d["name"], meta_hex=d["meta_hex"])


def collection_to_json(coll: PresetCollection) -> dict:
    return {
        "schema": _COLLECTION_SCHEMA,
        "id": coll.id,
        "name": coll.name,
        "created_at": coll.created_at,
        "provenance": {"kind": coll.provenance.kind.value,
                       "source": coll.provenance.source},
        "slots": {str(slot): _ref_to_json(coll.slots[slot])
                  for slot in sorted(coll.slots)},
    }


def collection_from_json(d: dict, *, path: str = "<collection>") -> PresetCollection:
    if d.get("schema") != _COLLECTION_SCHEMA:
        raise LibraryCorruptError(path, f"unsupported schema: {d.get('schema')!r}")
    try:
        prov_d = d.get("provenance") or {}
        provenance = Provenance(
            kind=ProvenanceKind.from_str(prov_d.get("kind", "manual")),
            source=prov_d.get("source", ""))
        slots: Dict[int, PresetRef] = {
            int(k): _ref_from_json(v) for k, v in (d.get("slots") or {}).items()}
        return PresetCollection(id=d["id"], name=d["name"],
                                created_at=d.get("created_at", ""),
                                provenance=provenance, slots=slots)
    except (KeyError, TypeError, ValueError) as e:
        raise LibraryCorruptError(path, f"bad collection: {e}") from e


# ---------------------------------------------------------- apply / switch plan

class PlanAction(enum.Enum):
    WRITE = "write"            # content or name differs -> full verified write
    SKIP_UNCHANGED = "skip"    # device already matches (sha AND name equal)
    CLEAR = "clear"            # not in collection; overwrite with clear_with


@dataclass(frozen=True)
class ApplyOptions:
    unlisted: str = "leave"          # "leave" | "clear" — slots absent from the collection
    clear_with: Optional[PresetRef] = None   # REQUIRED when unlisted == "clear"
    seconds_per_write: float = 1.0   # verified-write estimate (~0.5 s write + ~0.4 s verify)


@dataclass(frozen=True)
class SlotPlan:
    slot: int
    action: PlanAction
    incoming: Optional[PresetRef]    # ref to write (WRITE/CLEAR); None for SKIP
    victim: Optional[SlotRecord]     # the device record being replaced (for UI framing)


@dataclass(frozen=True)
class ApplyPlan:
    slots: Tuple[SlotPlan, ...]      # one per device slot, ascending
    write_count: int
    clear_count: int
    skip_count: int
    total_slots: int                 # == len(slots) (the device's slot count)
    estimated_seconds: float         # round((write+clear) * seconds_per_write, 1)

    def changes(self) -> Tuple[SlotPlan, ...]:
        return tuple(p for p in self.slots
                     if p.action in (PlanAction.WRITE, PlanAction.CLEAR))


def plan_apply(collection: PresetCollection, snapshot: DeviceSnapshot, *,
               options: ApplyOptions = ApplyOptions()) -> ApplyPlan:
    """Pure. Requires a FULL hashed snapshot: every slot 0..N-1 present and
    snapshot.has_hashes, else ValueError. If options.unlisted == 'clear',
    options.clear_with is required, else ValueError. A collection slot beyond
    the snapshot's range makes the plan undecidable -> ValueError.

    Per device record (ascending), ref = collection.slots.get(slot):
      ref present:
        record.sha256 == ref.sha256 and record.name == ref.name -> SKIP_UNCHANGED
        else                                                      -> WRITE
      ref absent:
        unlisted == 'clear':
          record already equals clear_with (sha AND name) -> SKIP_UNCHANGED
          else                                            -> CLEAR
        unlisted == 'leave':                              -> SKIP_UNCHANGED
    """
    records = sorted(snapshot.records, key=lambda r: r.slot)
    total = len(records)
    slot_set = {r.slot for r in records}
    if slot_set != set(range(total)):
        raise ValueError(
            "plan_apply requires a FULL snapshot: every slot 0..N-1 present")
    if not snapshot.has_hashes:
        raise ValueError("plan_apply requires a snapshot with blob hashes")
    if options.unlisted not in ("leave", "clear"):
        raise ValueError(f"unknown unlisted policy: {options.unlisted!r}")
    if options.unlisted == "clear" and options.clear_with is None:
        raise ValueError("unlisted == 'clear' requires options.clear_with")
    if collection.slots and max(collection.slots) >= total:
        raise ValueError(
            f"collection references slot {max(collection.slots)} beyond the "
            f"snapshot's {total} slots")

    plans = []
    write_count = clear_count = skip_count = 0
    for r in records:
        ref = collection.slots.get(r.slot)
        if ref is not None:
            if r.sha256 == ref.sha256 and r.name == ref.name:
                plans.append(SlotPlan(r.slot, PlanAction.SKIP_UNCHANGED, None, None))
                skip_count += 1
            else:
                plans.append(SlotPlan(r.slot, PlanAction.WRITE, ref, r))
                write_count += 1
        elif options.unlisted == "clear":
            cw = options.clear_with
            if r.sha256 == cw.sha256 and r.name == cw.name:
                plans.append(SlotPlan(r.slot, PlanAction.SKIP_UNCHANGED, None, None))
                skip_count += 1
            else:
                plans.append(SlotPlan(r.slot, PlanAction.CLEAR, cw, r))
                clear_count += 1
        else:   # leave
            plans.append(SlotPlan(r.slot, PlanAction.SKIP_UNCHANGED, None, None))
            skip_count += 1

    estimated = round((write_count + clear_count) * options.seconds_per_write, 1)
    return ApplyPlan(slots=tuple(plans), write_count=write_count,
                     clear_count=clear_count, skip_count=skip_count,
                     total_slots=total, estimated_seconds=estimated)
