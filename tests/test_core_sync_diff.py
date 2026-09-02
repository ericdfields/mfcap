"""Sync diff: a synthetic BASELINE COLLECTION against a simulated device,
exercising all five slot statuses of the decision table, the sparse-baseline
regression, and the refusal to diff without blob hashes.

The library is deliberately NOT a baseline any more: it is a flat catalog of
unique patches and carries no slot opinion, so diffing against it merged every
imported bank into one incoherent mash. Sync compares the device to ONE
collection the user chose."""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.collections import (PresetCollection, Provenance,
                                    ProvenanceKind, plan_apply, PlanAction)
from microfreak.device import MicroFreak
from microfreak.library import Library
from microfreak.model import Preset, PresetRef
from microfreak.sync import SlotStatus, diff, diff_baseline
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


def _ref(preset) -> PresetRef:
    return PresetRef(sha256=preset.sha256, name=preset.name,
                     meta_hex=bytes(preset.meta).hex())


def _collection(name, slots) -> PresetCollection:
    return PresetCollection.new(
        name=name, provenance=Provenance(kind=ProvenanceKind.MANUAL),
        slots=slots)


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
    # slot 0:   collection places the device's exact bytes    -> IN_SYNC
    # slot 1:   collection places different bytes             -> DIFFERS
    # slots 2,3: collection silent, device non-expendable     -> UNLISTED
    # slot 500: collection places a preset, device expendable -> BASELINE_ONLY
    # slot 501: collection places the Init bytes themselves   -> IN_SYNC
    #           (sha equality wins before expendability)
    # slots 502, 503: collection silent, expendable           -> EMPTY
    baseline = _collection("Chosen", {
        0: _ref(sim.peek(0)),
        1: _ref(Preset(name="Newer Take", blob=blob7(50), meta=META)),
        500: _ref(Preset(name="Went Missing", blob=blob7(51), meta=META)),
        501: _ref(Preset(name="Kept Init", blob=init_blob, meta=META)),
    })
    lib.save_collection(baseline)

    snap = dev.snapshot(slots=SLOTS)                # blobs hashed, lag on
    assert snap.has_hashes
    d = diff(snap, baseline)

    expected = {
        0: SlotStatus.IN_SYNC,
        1: SlotStatus.DIFFERS,
        2: SlotStatus.UNLISTED,
        3: SlotStatus.UNLISTED,
        500: SlotStatus.BASELINE_ONLY,
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
                          SlotStatus.BASELINE_ONLY):
            assert row.baseline is not None
        else:
            assert row.baseline is None
    print("PASS  each row carries its SlotRecord and baseline PresetRef sides")

    # by_status buckets and the unlisted/changed/missing vocabulary
    assert [r.slot for r in d.by_status(SlotStatus.UNLISTED)] == [2, 3]
    assert [r.slot for r in d.by_status(SlotStatus.DIFFERS)] == [1]
    assert [r.slot for r in d.by_status(SlotStatus.BASELINE_ONLY)] == [500]
    assert [r.slot for r in d.by_status(SlotStatus.IN_SYNC)] == [0, 501]
    assert [r.slot for r in d.by_status(SlotStatus.EMPTY)] == [502, 503]
    assert SlotStatus.UNLISTED.value == "unlisted"
    assert SlotStatus.DIFFERS.value == "changed"
    assert SlotStatus.BASELINE_ONLY.value == "missing"
    print("PASS  by_status buckets; unlisted/changed/missing per slot")

    # ---- the reported bug: a sparse baseline reports nothing missing -------
    sparse = _collection("Just Slot 0", {0: _ref(sim.peek(0))})
    ds = diff(snap, sparse)
    assert [r.slot for r in ds.by_status(SlotStatus.IN_SYNC)] == [0]
    assert ds.by_status(SlotStatus.BASELINE_ONLY) == []
    assert ds.by_status(SlotStatus.DIFFERS) == []
    assert {r.status for r in ds.slots} == {SlotStatus.IN_SYNC,
                                            SlotStatus.UNLISTED,
                                            SlotStatus.EMPTY}
    print("PASS  slots a collection is silent about are never 'missing'")

    # ---- the diff is read-only --------------------------------------------
    assert sim.peek(1).blob != blob7(50)            # device untouched
    assert lib.collection(baseline.id).slots[1].name == "Newer Take"
    print("PASS  diff computed without writing to device or library")

    # ---- names-only snapshots are refused ---------------------------------
    names_only = dev.snapshot(read_blobs=False, slots=SLOTS)
    try:
        diff(names_only, baseline)
        raise AssertionError("diff without hashes must refuse")
    except ValueError:
        pass
    print("PASS  diff refuses a snapshot without blob hashes")

    # ---- threshold is honored: at 5, four Inits stop being expendable -----
    d5 = diff(snap, baseline, threshold=5)
    st5 = {row.slot: row.status for row in d5.slots}
    assert st5[502] == SlotStatus.UNLISTED          # no longer "empty"
    assert st5[500] == SlotStatus.DIFFERS           # no longer "missing"
    assert st5[0] == SlotStatus.IN_SYNC             # sha equality unaffected
    print("PASS  duplicate threshold flows through the diff")

    # ---- executing the diff converges it: write the DIFFERS row -----------
    row1 = next(r for r in d.slots if r.slot == 1)
    dev.write(1, row1.baseline.to_preset(blob7(50)))
    snap2 = dev.snapshot(slots=SLOTS)
    d2 = diff(snap2, baseline)
    st2 = {row.slot: row.status for row in d2.slots}
    assert st2[1] == SlotStatus.IN_SYNC
    assert not d2.by_status(SlotStatus.DIFFERS)
    print("PASS  after writing the changed preset, the diff converges to IN_SYNC")

    # ---- ONE table: plan_apply's actions ARE the diff's statuses ----------
    full = dev.snapshot(slots=list(range(p.SLOTS)))
    coll = _collection("Mixed", {
        0: _ref(sim.peek(0)),                                    # IN_SYNC
        1: _ref(Preset(name="Other", blob=blob7(60), meta=META)),  # DIFFERS
        2: PresetRef(sha256=sim.peek(2).sha256, name="Renamed",
                     meta_hex=bytes(sim.peek(2).meta).hex()),    # IN_SYNC + name
        500: _ref(Preset(name="Fat Bass", blob=blob7(61), meta=META)),  # BASELINE_ONLY
    })
    dfull = diff(full, coll)
    for policy in ("leave", "clear"):
        from microfreak.collections import ApplyOptions
        options = ApplyOptions(unlisted=policy,
                               clear_with=_ref(sim.peek(500)))
        plan = plan_apply(coll, full, options=options)
        assert len(plan.slots) == len(dfull.slots)
        for sp, row in zip(plan.slots, dfull.slots):
            assert sp.slot == row.slot
            if row.baseline is not None:
                want = (PlanAction.SKIP_UNCHANGED
                        if row.status is SlotStatus.IN_SYNC and not row.name_differs
                        else PlanAction.WRITE)
            elif policy == "leave":
                want = PlanAction.SKIP_UNCHANGED
            elif (row.device.sha256 == options.clear_with.sha256
                  and row.device.name == options.clear_with.name):
                want = PlanAction.SKIP_UNCHANGED
            else:
                want = PlanAction.CLEAR
            assert sp.action is want, (row.slot, row.status, sp.action, want)
    print("PASS  plan_apply is the same decision table as the diff (one definition)")


if __name__ == "__main__":
    main()
