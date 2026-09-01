"""Pure content-analysis functions. Accept SlotRecords from snapshots,
backups, anywhere.

Emptiness is a content judgement: the MicroFreak ships every unused slot as
a factory Init preset with the name "Init", so a blank name never happens on
a stock device and the string "Init" is never matched. A slot is expendable
when its exact bytes occur at least DUPLICATE_THRESHOLD times (3, not 2, so
a user's own single duplicated preset is never chosen), or its
successfully-read name is blank/whitespace-only (the phase-0 scratch rule).
Unknown disqualifies its own rule: a record whose sha256 is None (content
unread) can never satisfy the duplicate rule, and a record whose name is
None — the name READ FAILED (a swallowed timeout in MicroFreak.snapshot),
not a blank slot — can never satisfy the blank-name rule. The rules stay
independent: a name-read-failed slot whose blob IS mass-duplicated is still
expendable, because the content judgement doesn't need the name.
"""
from __future__ import annotations

from typing import Collection, Dict, Iterable, Optional, Set

from .model import SlotRecord
from .protocol import DUPLICATE_THRESHOLD


def sha_census(records: Iterable[SlotRecord]) -> Dict[str, int]:
    """How many slots hold each blob hash. Records without a hash are
    skipped."""
    counts: Dict[str, int] = {}
    for r in records:
        if r.sha256 is not None:
            counts[r.sha256] = counts.get(r.sha256, 0) + 1
    return counts


def find_expendable(records: Iterable[SlotRecord], *,
                    threshold: int = DUPLICATE_THRESHOLD) -> Set[int]:
    """Slots whose content is expendable: a successfully-read blank name, OR
    sha256 occurring >= threshold times. Never a name == "Init" string
    match. Unknown is never expendable: sha256 None (content unread) and
    name None (name read FAILED — MicroFreak.snapshot records None after a
    swallowed timeout/mismatch) both disqualify the respective rule, so a
    unique user preset with one transient name-read failure is never
    classified overwritable."""
    records = list(records)
    counts = sha_census(records)
    out: Set[int] = set()
    for r in records:
        if r.sha256 is None:
            continue
        if r.name is not None and not r.name.strip():
            out.add(r.slot)
        elif counts[r.sha256] >= threshold:
            out.add(r.slot)
    return out


def pick_scratch_slot(records: Iterable[SlotRecord], *, prefer_from: int = 500,
                      exclude: Collection[int] = ()) -> Optional[int]:
    """The safest slot to write into: the highest-numbered expendable slot
    >= prefer_from, else the highest expendable slot overall; None if
    nothing qualifies (the caller asks the human). Preserves the proven
    mfcap.verify.pick_scratch_slot semantics exactly."""
    records = list(records)
    expendable = find_expendable(records)
    excluded = set(exclude)
    for floor in (prefer_from, 0):
        picks = [r.slot for r in records
                 if r.slot >= floor and r.slot not in excluded
                 and r.slot in expendable]
        if picks:
            return max(picks)
    return None
