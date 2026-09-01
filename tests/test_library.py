"""Library: create/open/add/get/remove/assign_slot, dedup by sha, atomic
index, IntegrityError on tampered blobs, import_snapshot skip rules."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.device import MicroFreak
from microfreak.errors import (EntryNotFoundError, IntegrityError,
                               LibraryCorruptError, SlotOutOfRangeError)
from microfreak.library import Library
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-library-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    donor = SimulatedMicroFreak.factory_fresh()
    a, b, c = donor.peek(0), donor.peek(1), donor.peek(2)

    root = work / "lib"
    lib = Library.create(root)
    assert (root / "index.json").exists() and (root / "blobs").is_dir()
    assert Library.open(root).entries() == []
    print("PASS  create/open an empty library")

    # add / get round-trip
    ea = lib.add(a, slot=0, tags=("bass",))
    got = lib.get(ea.id)
    assert got.name == a.name and got.blob == a.blob and got.meta == a.meta
    assert ea.slot == 0 and ea.tags == ("bass",)
    assert len(ea.meta_hex) == 18
    print("PASS  add/get round-trips name, blob, and meta")

    # dedup by sha: same blob under two names = two entries, one file
    e1 = lib.add(b)
    e2 = lib.add(b.renamed("Same Bytes New Name"))
    assert e1.id != e2.id and e1.sha256 == e2.sha256
    blob_files = list((root / "blobs").glob("*.bin"))
    assert len(blob_files) == 2                     # a's blob + b's blob
    assert lib.find_by_sha(b.sha256) == [e1, e2]
    assert lib.has_blob(b.sha256)
    print("PASS  content-addressing: one blob file serves two entries")

    # remove: blob survives while referenced, dies with its last entry
    lib.remove(e1.id)
    assert lib.has_blob(b.sha256), "still referenced by e2"
    lib.remove(e2.id)
    assert not lib.has_blob(b.sha256), "last reference gone"
    try:
        lib.entry(e1.id)
        raise AssertionError("removed entry must be gone")
    except EntryNotFoundError:
        pass
    print("PASS  remove deletes the blob only with its last referencing entry")

    # rename_entry keeps id and sha
    ea2 = lib.rename_entry(ea.id, "Renamed")
    assert ea2.id == ea.id and ea2.sha256 == ea.sha256 and ea2.name == "Renamed"
    print("PASS  rename_entry keeps id and sha")

    # assign_slot: at most one entry per slot
    ec = lib.add(c)
    lib.assign_slot(ec.id, 0)                       # steals slot 0 from ea
    assert lib.entry(ec.id).slot == 0
    assert lib.entry(ea.id).slot is None
    assert lib.slot_map() == {0: lib.entry(ec.id)}
    try:
        lib.assign_slot(ec.id, 512)
        raise AssertionError("bad slot must raise")
    except SlotOutOfRangeError:
        pass
    lib.assign_slot(ec.id, None)
    assert lib.slot_map() == {}
    print("PASS  assign_slot enforces one entry per slot and validates range")

    # persistence + atomicity: reopen sees the same state; no temp litter
    lib2 = Library.open(root)
    assert {e.id for e in lib2.entries()} == {ea.id, ec.id}
    assert not list(root.glob("index.json.*")), "no temp files left behind"
    print("PASS  index persists atomically; reopen sees identical state")

    # corrupt index refused
    badroot = work / "badlib"
    badroot.mkdir()
    (badroot / "index.json").write_text("{not json")
    try:
        Library.open(badroot)
        raise AssertionError("corrupt index must raise")
    except LibraryCorruptError:
        pass
    print("PASS  unparseable index raises LibraryCorruptError")

    # bit rot: tampered blob file fails get()
    blob_path = root / "blobs" / (ea2.sha256 + ".bin")
    original = blob_path.read_bytes()
    blob_path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    try:
        lib.get(ea.id)
        raise AssertionError("tampered blob must fail its hash")
    except IntegrityError:
        pass
    blob_path.write_bytes(original)
    print("PASS  get() re-hashes the blob file: IntegrityError on rot")

    # import_snapshot: skip rules
    sim = SimulatedMicroFreak.factory_fresh(slots=16, init_copies=5)
    fc = FakeClock()
    dev = MicroFreak(sim, slots=16, clock=fc, sleep=fc.sleep)
    snap = dev.snapshot(read_blobs=True, keep_blobs=True)

    root2 = work / "lib2"
    lib3 = Library.create(root2)
    added = lib3.import_snapshot(snap)
    assert len(added) == 11, len(added)             # 11 named, 5 Inits skipped
    assert {e.name for e in added} == {"Patch %03d" % i for i in range(11)}
    assert sorted(e.slot for e in added) == list(range(11))
    print("PASS  import_snapshot skips the %d expendable Init slots" % 5)

    again = lib3.import_snapshot(snap)
    assert again == [], "identical (sha, name) pairs must be skipped"
    print("PASS  re-import adds nothing (identical sha+name skipped)")

    lib4 = Library.create(work / "lib3")
    all_in = lib4.import_snapshot(snap, skip_expendable=False)
    assert len(all_in) == 12, len(all_in)           # 11 named + 1 Init (dups collapse)
    print("PASS  skip_expendable=False imports one Init (duplicates collapse)")

    names_only = dev.snapshot(read_blobs=False)
    try:
        lib4.import_snapshot(names_only)
        raise AssertionError("names-only snapshot must be refused")
    except ValueError:
        pass
    print("PASS  import_snapshot refuses a snapshot without blobs")


if __name__ == "__main__":
    main()
