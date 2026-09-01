"""sync.diff: all five statuses from a factory-fresh sim plus a library;
ValueError on a names-only snapshot."""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.device import MicroFreak
from microfreak.library import Library
from microfreak.sync import SlotStatus, diff
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-sync-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    # slots 0..10 named+unique, slots 11..15 identical Inits (expendable:
    # 5 copies >= threshold 3)
    sim = SimulatedMicroFreak.factory_fresh(slots=16, init_copies=5)
    fc = FakeClock()
    dev = MicroFreak(sim, slots=16, clock=fc, sleep=fc.sleep)

    lib = Library.create(work / "lib")
    lib.add(sim.peek(0), slot=0)                     # same sha    -> IN_SYNC
    lib.add(sim.peek(2), slot=1)                     # wrong sha   -> DIFFERS
    lib.add(sim.peek(4), slot=12)                    # device Init -> LIBRARY_ONLY
    # slot 3: named on device, no entry              ->              DEVICE_ONLY
    # slot 13: Init on device, no entry              ->              EMPTY

    snap = dev.snapshot(read_blobs=True)
    d = diff(snap, lib)

    assert len(d.slots) == 16
    assert [x.slot for x in d.slots] == list(range(16))
    by = {x.slot: x.status for x in d.slots}

    assert by[0] == SlotStatus.IN_SYNC
    assert by[1] == SlotStatus.DIFFERS
    assert by[12] == SlotStatus.LIBRARY_ONLY
    assert by[3] == SlotStatus.DEVICE_ONLY
    assert by[13] == SlotStatus.EMPTY
    print("PASS  all five statuses: IN_SYNC, DIFFERS, LIBRARY_ONLY, DEVICE_ONLY, EMPTY")

    # the full deterministic picture
    assert [s for s in range(16) if by[s] == SlotStatus.DEVICE_ONLY] == \
        [2, 3, 4, 5, 6, 7, 8, 9, 10]
    assert [s for s in range(16) if by[s] == SlotStatus.EMPTY] == [11, 13, 14, 15]
    print("PASS  every remaining slot classified deterministically")

    # rows carry both sides
    row = d.by_status(SlotStatus.DIFFERS)[0]
    assert row.slot == 1
    assert row.device is not None and row.device.sha256 == sim.peek(1).sha256
    assert row.library is not None and row.library.sha256 == sim.peek(2).sha256
    empty_row = d.by_status(SlotStatus.EMPTY)[0]
    assert empty_row.library is None and empty_row.device is not None
    print("PASS  SlotDiff rows carry the device record and the library entry")

    # by_status filters
    assert len(d.by_status(SlotStatus.IN_SYNC)) == 1
    assert len(d.by_status(SlotStatus.LIBRARY_ONLY)) == 1
    print("PASS  by_status filters rows")

    # names-only snapshot refused — refusing beats guessing
    names_only = dev.snapshot(read_blobs=False)
    try:
        diff(names_only, lib)
        raise AssertionError("diff must refuse a snapshot without hashes")
    except ValueError as e:
        assert "blob hashes" in str(e)
    print("PASS  diff refuses a names-only snapshot (ValueError)")

    assert sim.faults == [], sim.faults
    print("PASS  no protocol faults recorded by the simulated device")


if __name__ == "__main__":
    main()
