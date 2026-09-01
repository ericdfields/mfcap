"""Expendable-slot detection: the duplicate threshold (3, not 2), blank-name
and unknown-content rules, never a name match on "Init", and scratch-slot
selection semantics."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.analysis import find_expendable, pick_scratch_slot, sha_census
from microfreak.device import MicroFreak
from microfreak.model import SlotRecord
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def rec(slot, name, sha):
    return SlotRecord(slot=slot, name=name, sha256=sha, meta=None, blob=None)


def main() -> None:
    assert p.DUPLICATE_THRESHOLD == 3
    print("PASS  DUPLICATE_THRESHOLD is 3 (a user's own single duplicate is safe)")

    # ---- census -----------------------------------------------------------
    records = [rec(0, "A", "x"), rec(1, "B", "y"), rec(2, "C", "y"),
               rec(3, "D", None)]
    assert sha_census(records) == {"x": 1, "y": 2}   # None sha skipped
    print("PASS  sha_census counts hashes and skips unhashed records")

    # ---- the threshold boundary: 2 copies keep, 3 copies expend -----------
    two = [rec(0, "Dup", "d"), rec(1, "Dup", "d"), rec(2, "Solo", "s")]
    assert find_expendable(two) == set()
    three = two + [rec(3, "Dup", "d")]
    assert find_expendable(three) == {0, 1, 3}       # all three copies, not the solo
    print("PASS  2 identical blobs are kept; 3 identical blobs are expendable")

    # threshold is a parameter: at 2 the pair becomes expendable, at 4 the
    # triple stops being expendable
    assert find_expendable(two, threshold=2) == {0, 1}
    assert find_expendable(three, threshold=4) == set()
    print("PASS  threshold override honored at >= threshold occurrences")

    # ---- blank READ names are expendable; anything unknown never is -------
    records = [
        rec(0, "", "u1"),          # blank name, unique content -> expendable
        rec(1, "   ", "u2"),       # whitespace-only name       -> expendable
        rec(2, None, "u3"),        # name read FAILED           -> NOT (unknown != empty)
        rec(3, "", None),          # blank name but sha None    -> NOT (unknown != empty)
        rec(4, "Keeper", "u4"),    # named, unique              -> NOT
        rec(5, None, None),        # nothing known              -> NOT
    ]
    assert find_expendable(records) == {0, 1}
    print("PASS  blank read names expendable; a failed name read (None) and")
    print("PASS     sha256=None are never expendable — unknown is not empty")

    # ---- emptiness is a content judgement, never the string "Init" --------
    records = [rec(0, "Init", "unique-a"), rec(1, "Init", "unique-b"),
               rec(2, "My Patch", "unique-c")]
    assert find_expendable(records) == set(), \
        "a uniquely-edited preset someone left named 'Init' must be kept"
    # but three Inits sharing bytes fall to the duplicate rule, name aside
    records = [rec(0, "Init", "i"), rec(1, "Init", "i"), rec(2, "Init", "i")]
    assert find_expendable(records) == {0, 1, 2}
    print("PASS  'Init' is never matched by name; identical content is what counts")

    # ---- pick_scratch_slot ------------------------------------------------
    records = ([rec(s, "Patch %d" % s, "u%d" % s) for s in range(0, 6)]
               + [rec(s, "Init", "init-blob") for s in (100, 300, 501, 502, 505)])
    assert pick_scratch_slot(records) == 505              # highest >= 500
    assert pick_scratch_slot(records, exclude=[505]) == 502
    assert pick_scratch_slot(records, exclude=[505, 502, 501]) == 300
    assert pick_scratch_slot(records, prefer_from=506) == 505   # falls back below
    only_low = ([rec(s, "Patch %d" % s, "u%d" % s) for s in range(0, 6)]
                + [rec(s, "Init", "init-blob") for s in (100, 200, 300)])
    assert pick_scratch_slot(only_low) == 300             # nothing >= 500 exists
    assert pick_scratch_slot([rec(0, "A", "x"), rec(1, "B", "y")]) is None
    print("PASS  pick_scratch_slot: highest expendable >= 500, exclusions, None")

    # ---- against the simulated reference device ---------------------------
    sim = SimulatedMicroFreak.factory_fresh()             # 243 named + 269 Inits
    fc = FakeClock()
    dev = MicroFreak(sim, clock=fc, sleep=fc.sleep)
    slots = [0, 1, 2, 240, 241, 242, 243, 244, 300, 510, 511]
    snap = dev.snapshot(slots=slots)
    ex = find_expendable(snap.records)
    assert ex == {243, 244, 300, 510, 511}, ex            # exactly the Init copies
    assert pick_scratch_slot(snap.records) == 511
    assert pick_scratch_slot(snap.records, exclude=[511]) == 510
    assert sim.faults == [], sim.faults
    print("PASS  factory-shaped sim: expendable = the Init copies, scratch = 511")


if __name__ == "__main__":
    main()
