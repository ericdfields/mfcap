"""sync.diff against a CHOSEN BASELINE COLLECTION: all five statuses from a
factory-fresh sim, the sparse-baseline regression (silence is not "missing"),
and ValueError on a names-only snapshot."""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.collections import (PresetCollection, Provenance,
                                    ProvenanceKind)
from microfreak.device import MicroFreak
from microfreak.library import Library
from microfreak.model import PresetRef
from microfreak.sync import SlotStatus, diff, diff_baseline
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def _ref(preset) -> PresetRef:
    return PresetRef(sha256=preset.sha256, name=preset.name,
                     meta_hex=bytes(preset.meta).hex())


def _collection(name, slots) -> PresetCollection:
    return PresetCollection.new(
        name=name, provenance=Provenance(kind=ProvenanceKind.MANUAL),
        slots=slots)


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
    # The BASELINE is a collection — a named arrangement the user picked.
    baseline = _collection("Baseline", {
        0: _ref(sim.peek(0)),      # same sha             -> IN_SYNC
        1: _ref(sim.peek(2)),      # wrong sha            -> DIFFERS
        12: _ref(sim.peek(4)),     # device slot is Init  -> BASELINE_ONLY
    })
    # slot 3: named on device, baseline silent           ->  UNLISTED
    # slot 13: Init on device, baseline silent           ->  EMPTY
    lib.save_collection(baseline)

    snap = dev.snapshot(read_blobs=True)
    d = diff(snap, baseline)

    assert len(d.slots) == 16
    assert [x.slot for x in d.slots] == list(range(16))
    by = {x.slot: x.status for x in d.slots}

    assert by[0] == SlotStatus.IN_SYNC
    assert by[1] == SlotStatus.DIFFERS
    assert by[12] == SlotStatus.BASELINE_ONLY
    assert by[3] == SlotStatus.UNLISTED
    assert by[13] == SlotStatus.EMPTY
    print("PASS  all five statuses: IN_SYNC, DIFFERS, BASELINE_ONLY, UNLISTED, EMPTY")

    # the full deterministic picture
    assert [s for s in range(16) if by[s] == SlotStatus.UNLISTED] == \
        [2, 3, 4, 5, 6, 7, 8, 9, 10]
    assert [s for s in range(16) if by[s] == SlotStatus.EMPTY] == [11, 13, 14, 15]
    print("PASS  every remaining slot classified deterministically")

    # rows carry both sides
    row = d.by_status(SlotStatus.DIFFERS)[0]
    assert row.slot == 1
    assert row.device is not None and row.device.sha256 == sim.peek(1).sha256
    assert row.baseline is not None and row.baseline.sha256 == sim.peek(2).sha256
    empty_row = d.by_status(SlotStatus.EMPTY)[0]
    assert empty_row.baseline is None and empty_row.device is not None
    print("PASS  SlotDiff rows carry the device record and the baseline ref")

    # by_status filters
    assert len(d.by_status(SlotStatus.IN_SYNC)) == 1
    assert len(d.by_status(SlotStatus.BASELINE_ONLY)) == 1
    print("PASS  by_status filters rows")

    # ---- the reported bug: silence is NOT "missing" -----------------------
    sparse = _collection("Just One", {0: _ref(sim.peek(0))})
    ds = diff(snap, sparse)
    assert [r.slot for r in ds.by_status(SlotStatus.IN_SYNC)] == [0]
    assert ds.by_status(SlotStatus.BASELINE_ONLY) == []
    assert ds.by_status(SlotStatus.DIFFERS) == []
    print("PASS  a 1-slot baseline over 16 device slots reports 0 missing, 0 changed")

    # ---- a device holding its collection reads as in sync ------------------
    exact = _collection("As Read", {r.slot: PresetRef(
        sha256=r.sha256, name=r.name, meta_hex=bytes(r.meta).hex())
        for r in snap.records})
    de = diff(snap, exact)
    assert all(r.status == SlotStatus.IN_SYNC for r in de.slots)
    assert not any(r.name_differs for r in de.slots)
    print("PASS  device matching its own collection is entirely IN_SYNC")

    # ---- a rename never changes the status, but is flagged -----------------
    renamed = dict(exact.slots)
    renamed[0] = PresetRef(sha256=exact.slots[0].sha256, name="Renamed Only",
                           meta_hex=exact.slots[0].meta_hex)
    dr = diff_baseline(snap, renamed)
    row0 = next(r for r in dr.slots if r.slot == 0)
    assert row0.status == SlotStatus.IN_SYNC and row0.name_differs
    print("PASS  name-only difference stays IN_SYNC and sets name_differs")

    # ---- baseline slots the snapshot never covered are `unknown` -----------
    partial = dev.snapshot(read_blobs=True, slots=[0, 1])
    dp = diff(partial, baseline)
    assert dp.unread_baseline_slots == (12,)
    assert dp.by_status(SlotStatus.BASELINE_ONLY) == []
    print("PASS  unread baseline slots are reported separately, never as missing")

    # names-only snapshot refused — refusing beats guessing
    names_only = dev.snapshot(read_blobs=False)
    try:
        diff(names_only, baseline)
        raise AssertionError("diff must refuse a snapshot without hashes")
    except ValueError as e:
        assert "blob hashes" in str(e)
    print("PASS  diff refuses a names-only snapshot (ValueError)")

    assert sim.faults == [], sim.faults
    print("PASS  no protocol faults recorded by the simulated device")


if __name__ == "__main__":
    main()
