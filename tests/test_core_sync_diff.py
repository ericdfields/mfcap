"""Sync diff: a synthetic library against a simulated device, exercising all
five slot statuses of the decision table, and the refusal to diff without
blob hashes."""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.device import MicroFreak
from microfreak.library import Library
from microfreak.model import Preset
from microfreak.sync import SlotStatus, diff
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_device(sim):
    fc = FakeClock()
    return MicroFreak(sim, clock=fc, sleep=fc.sleep)


def blob7(seed: int) -> bytes:
    out = bytearray()
    x = (seed % 126) + 1
    while len(out) < p.BLOB_SIZE:
        x = (x * 75 + 74) % 127
        out.append(x)
    return bytes(out[:p.BLOB_SIZE])


META = bytes([0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x33])

# device: slots 0-3 are unique named patches; 500-503 are four identical
# factory Inits (>= DUPLICATE_THRESHOLD copies within the diffed set)
NAMED = [0, 1, 2, 3]
INITS = [500, 501, 502, 503]
SLOTS = NAMED + INITS


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-core-sync-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    sim = SimulatedMicroFreak.factory_fresh()       # 243 named + 269 Inits
    dev = make_device(sim)
    for s in INITS:
        assert sim.peek(s).name == "Init"
    init_blob = sim.peek(500).blob
    assert all(sim.peek(s).blob == init_blob for s in INITS)

    lib = Library.create(work / "library")
    # slot 0: entry with the device's exact bytes            -> IN_SYNC
    lib.add(sim.peek(0), slot=0)
    # slot 1: entry with different bytes, device non-empty   -> DIFFERS
    lib.add(Preset(name="Newer Take", blob=blob7(50), meta=META), slot=1)
    # slots 2, 3: no entry, device non-expendable            -> DEVICE_ONLY
    # slot 500: entry assigned, device slot is expendable    -> LIBRARY_ONLY
    lib.add(Preset(name="Went Missing", blob=blob7(51), meta=META), slot=500)
    # slot 501: entry whose bytes ARE the Init blob          -> IN_SYNC
    #           (sha equality wins before expendability)
    lib.add(Preset(name="Kept Init", blob=init_blob, meta=META), slot=501)
    # slots 502, 503: no entry, expendable                   -> EMPTY

    snap = dev.snapshot(slots=SLOTS)                # blobs hashed, lag on
    assert snap.has_hashes
    d = diff(snap, lib)

    expected = {
        0: SlotStatus.IN_SYNC,
        1: SlotStatus.DIFFERS,
        2: SlotStatus.DEVICE_ONLY,
        3: SlotStatus.DEVICE_ONLY,
        500: SlotStatus.LIBRARY_ONLY,
        501: SlotStatus.IN_SYNC,
        502: SlotStatus.EMPTY,
        503: SlotStatus.EMPTY,
    }
    assert [row.slot for row in d.slots] == SLOTS
    for row in d.slots:
        assert row.status == expected[row.slot], \
            "slot %d: %s != %s" % (row.slot, row.status, expected[row.slot])
    print("PASS  all five statuses land on the decision table exactly")

    # rows carry both sides for the caller to act on
    for row in d.slots:
        assert row.device is not None and row.device.slot == row.slot
        if row.status in (SlotStatus.IN_SYNC, SlotStatus.DIFFERS,
                          SlotStatus.LIBRARY_ONLY):
            assert row.library is not None and row.library.slot == row.slot
        else:
            assert row.library is None
    print("PASS  each row carries its SlotRecord and LibraryEntry sides")

    # by_status buckets and the added/changed/missing vocabulary
    assert [r.slot for r in d.by_status(SlotStatus.DEVICE_ONLY)] == [2, 3]
    assert [r.slot for r in d.by_status(SlotStatus.DIFFERS)] == [1]
    assert [r.slot for r in d.by_status(SlotStatus.LIBRARY_ONLY)] == [500]
    assert [r.slot for r in d.by_status(SlotStatus.IN_SYNC)] == [0, 501]
    assert [r.slot for r in d.by_status(SlotStatus.EMPTY)] == [502, 503]
    assert SlotStatus.DEVICE_ONLY.value == "added"
    assert SlotStatus.DIFFERS.value == "changed"
    assert SlotStatus.LIBRARY_ONLY.value == "missing"
    print("PASS  by_status buckets; added/changed/missing per slot")

    # ---- the diff is read-only --------------------------------------------
    assert sim.peek(1).blob != blob7(50)            # device untouched
    assert lib.slot_map()[1].name == "Newer Take"   # library untouched
    print("PASS  diff computed without writing to device or library")

    # ---- names-only snapshots are refused ---------------------------------
    names_only = dev.snapshot(read_blobs=False, slots=SLOTS)
    try:
        diff(names_only, lib)
        raise AssertionError("diff without hashes must refuse")
    except ValueError:
        pass
    print("PASS  diff refuses a snapshot without blob hashes")

    # ---- threshold is honored: at 5, four Inits stop being expendable -----
    d5 = diff(snap, lib, threshold=5)
    st5 = {row.slot: row.status for row in d5.slots}
    assert st5[502] == SlotStatus.DEVICE_ONLY       # no longer "empty"
    assert st5[500] == SlotStatus.DIFFERS           # no longer "missing"
    assert st5[0] == SlotStatus.IN_SYNC             # sha equality unaffected
    print("PASS  duplicate threshold flows through the diff")

    # ---- executing the diff converges it: write the DIFFERS entry ---------
    row1 = next(r for r in d.slots if r.slot == 1)
    dev.write(1, lib.get(row1.library.id))
    snap2 = dev.snapshot(slots=SLOTS)
    d2 = diff(snap2, lib)
    st2 = {row.slot: row.status for row in d2.slots}
    assert st2[1] == SlotStatus.IN_SYNC
    assert not d2.by_status(SlotStatus.DIFFERS)
    print("PASS  after writing the changed preset, the diff converges to IN_SYNC")


if __name__ == "__main__":
    main()
