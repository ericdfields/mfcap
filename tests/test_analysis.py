"""analysis: threshold-3 expendability, blank names, sha-None never
expendable, and pick_scratch_slot parity with the proven
mfcap.verify.pick_scratch_slot."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.analysis import find_expendable, pick_scratch_slot, sha_census
from microfreak.model import SlotRecord
from mfcap.verify import pick_scratch_slot as phase0_pick


def rec(slot, name, sha):
    return SlotRecord(slot=slot, name=name, sha256=sha, meta=None, blob=None)


def phase0_index(records):
    """The same population expressed as a phase-0 backup index."""
    return {"presets": {str(r.slot): {"slot": r.slot, "name": r.name,
                                      "sha256": r.sha256}
                        for r in records}}


def parity(records, tmp, prefer_from=500, exclude=()):
    """Both implementations must pick the same slot from the same data."""
    path = tmp / "index.json"
    path.write_text(json.dumps(phase0_index(records)))
    old = phase0_pick(path, prefer_from=prefer_from, exclude=tuple(exclude))
    new = pick_scratch_slot(records, prefer_from=prefer_from, exclude=exclude)
    assert old == new, "parity broken: phase0=%r core=%r" % (old, new)
    return new


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-analysis-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    # census
    records = [rec(0, "A", "s1"), rec(1, "B", "s1"), rec(2, "C", "s2"),
               rec(3, "D", None)]
    assert sha_census(records) == {"s1": 2, "s2": 1}
    print("PASS  sha_census counts hashes and skips records without one")

    # threshold semantics: 2 copies safe, 3 copies expendable
    two = [rec(0, "Mine", "dup"), rec(1, "Mine copy", "dup"),
           rec(2, "Other", "u1")]
    assert find_expendable(two) == set()
    three = two + [rec(3, "Mine copy 2", "dup")]
    assert find_expendable(three) == {0, 1, 3}
    assert find_expendable(three, threshold=4) == set()
    print("PASS  threshold-3: a single user duplicate is never expendable")

    # blank names qualify; the string "Init" alone never does
    named_init = [rec(0, "Init", "unique-a"), rec(1, "Keep", "unique-b"),
                  rec(2, "", "unique-c"), rec(3, "   ", "unique-d")]
    assert find_expendable(named_init) == {2, 3}, \
        "emptiness is a content judgement, not a name=='Init' match"
    print("PASS  blank names expendable; a unique blob named 'Init' is NOT")

    # sha None is never expendable — unknown != empty
    unknown = [rec(0, "", None), rec(1, None, None), rec(2, "X", "u")]
    assert find_expendable(unknown) == set()
    print("PASS  records without a hash are never expendable")

    # pick_scratch_slot parity with the proven phase-0 implementation
    device = ([rec(s, "Patch %d" % s, "sha%d" % s) for s in range(0, 8)]
              + [rec(s, "Init", "init-sha") for s in (100, 200, 505, 510)])

    got = parity(device, work)
    assert got == 510                       # highest expendable >= 500
    got = parity(device, work, exclude=(510,))
    assert got == 505
    got = parity(device, work, exclude=(505, 510))
    assert got == 200                       # falls back below prefer_from
    print("PASS  parity: prefers >=500, honors exclude, falls back to highest")

    full = [rec(s, "Patch %d" % s, "sha%d" % s) for s in range(12)]
    got = parity(full, work)
    assert got is None                      # nothing qualifies: ask the human
    print("PASS  parity: a genuinely full device yields None for both")

    blanks = ([rec(s, "Patch %d" % s, "sha%d" % s) for s in range(6)]
              + [rec(50, "", "blank-sha")])
    got = parity(blanks, work)
    assert got == 50
    print("PASS  parity: blank-named slot picked identically by both")


if __name__ == "__main__":
    main()
