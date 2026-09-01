"""sync.diff on a synthetic library vs a simulated device: all five statuses
land on the right slots, and a hash-less snapshot is refused."""
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
    return MicroFreak(sim, slots=sim.slots, clock=fc, sleep=fc.sleep)


def other_preset(name: str, seed: int) -> Preset:
    blob = bytes((i * 13 + seed) % 128 for i in range(p.BLOB_SIZE))
    return Preset(name=name, blob=blob,
                  meta=bytes([0, 0, 0, 0, 0, 0, 0, 0x02, 0x32]))


def main() -> None:
    # 16-slot device: slots 0..9 named unique presets, 10..15 six identical
    # "Init" blobs (>= threshold 3, so expendable)
    sim = SimulatedMicroFreak.factory_fresh(slots=16, init_copies=6)
    dev = make_device(sim)
    snapshot = dev.snapshot(read_blobs=True, keep_blobs=True)
    assert snapshot.has_hashes and len(snapshot.records) == 16

    lib = Library.create(Path(tempfile.mkdtemp()) / "library")
    # slot 0: exactly what the device holds            -> IN_SYNC
    lib.add(sim.peek(0), slot=0)
    # slot 1: same slot, different content             -> DIFFERS ("changed")
    lib.add(other_preset("Edited Patch", 5), slot=1)
    # slot 12: assigned, but device slot is expendable -> LIBRARY_ONLY ("missing")
    lib.add(other_preset("Wants Slot 12", 9), slot=12)
    # slots 2..9: on device only, non-expendable       -> DEVICE_ONLY ("added")
    # slots 10, 11, 13..15: expendable, unclaimed      -> EMPTY

    d = diff(snapshot, lib)
    assert len(d.slots) == 16
    by_slot = {row.slot: row for row in d.slots}

    assert by_slot[0].status is SlotStatus.IN_SYNC
    assert by_slot[0].library is not None and by_slot[0].device is not None
    assert by_slot[0].library.sha256 == by_slot[0].device.sha256
    print("PASS  matching sha -> IN_SYNC")

    assert by_slot[1].status is SlotStatus.DIFFERS
    assert by_slot[1].library.sha256 != by_slot[1].device.sha256
    print("PASS  same slot, different sha -> DIFFERS ('changed')")

    assert by_slot[12].status is SlotStatus.LIBRARY_ONLY
    assert by_slot[12].library.name == "Wants Slot 12"
    print("PASS  entry over an expendable device slot -> LIBRARY_ONLY ('missing')")

    for s in range(2, 10):
        assert by_slot[s].status is SlotStatus.DEVICE_ONLY, \
            (s, by_slot[s].status)
        assert by_slot[s].library is None
        assert by_slot[s].device.name == f"Patch {s:03d}"
    print("PASS  unclaimed non-expendable slots 2..9 -> DEVICE_ONLY ('added')")

    for s in (10, 11, 13, 14, 15):
        assert by_slot[s].status is SlotStatus.EMPTY, (s, by_slot[s].status)
    print("PASS  unclaimed expendable slots -> EMPTY")

    assert len(d.by_status(SlotStatus.IN_SYNC)) == 1
    assert len(d.by_status(SlotStatus.DIFFERS)) == 1
    assert len(d.by_status(SlotStatus.LIBRARY_ONLY)) == 1
    assert len(d.by_status(SlotStatus.DEVICE_ONLY)) == 8
    assert len(d.by_status(SlotStatus.EMPTY)) == 5
    print("PASS  by_status() totals: 1/1/1/8/5 across the five statuses")

    # writing the DIFFERS entry to the device converges the diff
    dev.write(1, lib.get(by_slot[1].library.id))
    snapshot2 = dev.snapshot(read_blobs=True, keep_blobs=True)
    d2 = diff(snapshot2, lib)
    by_slot2 = {row.slot: row for row in d2.slots}
    assert by_slot2[1].status is SlotStatus.IN_SYNC
    assert not d2.by_status(SlotStatus.DIFFERS)
    print("PASS  after writing the changed preset, the diff converges to IN_SYNC")

    # a names-only snapshot is refused — refusing beats guessing
    names_only = dev.snapshot(read_blobs=False)
    try:
        diff(names_only, lib)
        raise AssertionError("diff must refuse a snapshot without hashes")
    except ValueError:
        pass
    print("PASS  diff refuses a hash-less snapshot with ValueError")


if __name__ == "__main__":
    main()
