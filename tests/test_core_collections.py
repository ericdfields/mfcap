"""Collections: save/load round-trip (all provenance kinds), blob GC spanning
collections, snapshot->collection, mfprojz->collection (through the verified
tools/mbp_import.py parser), the pure plan_apply decision table, and
apply_collection writing ONLY changed slots (unchanged slots never written) with
a full switch bringing the sim to the collection state, plus cancel and
stop-on-first-failure."""
import io
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))

from microfreak import protocol as p
from microfreak.collections import (ApplyOptions, PlanAction, PresetCollection,
                                     Provenance, ProvenanceKind, plan_apply)
from microfreak.device import MicroFreak
from microfreak.errors import (CollectionNotFoundError, IntegrityError,
                               OperationCancelledError, VerifyMismatchError)
from microfreak.library import BankItem, Library
from microfreak.model import CancelToken, Preset, PresetRef
from microfreak.transports.simulated import SimulatedMicroFreak

import mbp_import


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_device(sim, slots):
    fc = FakeClock()
    return MicroFreak(sim, slots=slots, clock=fc, sleep=fc.sleep)


def _mbp_text(name: str, blob, meta_hex: str) -> str:
    """A MicroFreak Boost archive parseable by tools/mbp_import. When blob is
    None a short archive (name only, no 4672-array) is produced -> is_empty."""
    head = f"serialization::archive 17 0 0 0 0 {len(name)} {name}"
    if blob is None:
        return head + " 0 0 0"                      # too few toks: no meta, no blob
    body = f" 0 0 0 18 {meta_hex} 0 0 1 {p.BLOB_SIZE} " + " ".join(str(x) for x in blob)
    return head + body


def _write_mfprojz(path: Path, items):
    """items: list of (order, name, blob-or-None, meta_hex, bank_letter, idx)."""
    with zipfile.ZipFile(path, "w") as z:
        for order, name, blob, meta_hex, bank, idx in items:
            fname = f"{order:02d}-{name}-{bank}{idx}.mbp"
            z.writestr(fname, _mbp_text(name, blob, meta_hex))


def last_chunk_count(sim, since: int) -> int:
    """Number of blob-write commits (CMD_CHUNK_LAST) on the wire since index."""
    return sum(1 for d, raw in sim.wire_log[since:]
               if d == "out" and p.parse(raw).cmd == p.CMD_CHUNK_LAST)


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-collections-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    # ---- collection JSON round-trip, all three provenance kinds -------------
    root = work / "lib"
    lib = Library.create(root)
    donor = SimulatedMicroFreak.factory_fresh(slots=8, init_copies=0)
    refs = {}
    for s in range(3):
        pr = donor.peek(s)
        sha = lib._ensure_blob(pr.blob)
        refs[s] = PresetRef(sha256=sha, name=pr.name, meta_hex=bytes(pr.meta).hex())

    for kind in ProvenanceKind:
        coll = PresetCollection.new(
            name=f"C {kind.value}",
            provenance=Provenance(kind=kind, source="src.mfprojz"),
            slots=dict(refs))
        lib.save_collection(coll)
        back = lib.collection(coll.id)
        assert back == coll, (kind, back, coll)
        assert back.covered_slots() == (0, 1, 2)
        assert back.provenance.kind is kind
    assert len(lib.collections()) == 3
    print("PASS  collection save/load round-trips for every provenance kind")

    # collections() ordering + not-found
    ids_by_time = [c.id for c in lib.collections()]
    assert ids_by_time == sorted(ids_by_time, key=lambda i:
                                 (lib.collection(i).created_at, i))
    try:
        lib.collection("deadbeef")
        raise AssertionError("missing collection must raise")
    except CollectionNotFoundError as e:
        assert e.collection_id == "deadbeef"
    print("PASS  collection() raises CollectionNotFoundError; collections() ordered")

    # ---- rename / delete + blob GC spanning collections ---------------------
    keep = lib.collections()[0]
    renamed = lib.rename_collection(keep.id, "Renamed Set")
    assert renamed.name == "Renamed Set" and renamed.id == keep.id
    assert lib.collection(keep.id).name == "Renamed Set"
    print("PASS  rename_collection persists the new name, keeps id")

    # a blob referenced ONLY by collections survives entry-less; dies with the
    # last collection referencing it
    gc_root = work / "gclib"
    gclib = Library.create(gc_root)
    pr = donor.peek(4)
    sha = gclib._ensure_blob(pr.blob)
    ref = PresetRef(sha256=sha, name=pr.name, meta_hex=bytes(pr.meta).hex())
    c1 = PresetCollection.new("one", Provenance(ProvenanceKind.MANUAL), {0: ref})
    c2 = PresetCollection.new("two", Provenance(ProvenanceKind.MANUAL), {5: ref})
    gclib.save_collection(c1)
    gclib.save_collection(c2)
    assert gclib.has_blob(sha)
    gclib.delete_collection(c1.id)
    assert gclib.has_blob(sha), "still referenced by c2"
    try:
        gclib.collection(c1.id)
        raise AssertionError("deleted collection must be gone")
    except CollectionNotFoundError:
        pass
    gclib.delete_collection(c2.id)
    assert not gclib.has_blob(sha), "last collection reference gone -> blob GC'd"
    print("PASS  blob GC spans collections: freed only with the last reference")

    # a blob shared by an entry AND a collection is NOT GC'd by removing entry
    e = gclib.add(donor.peek(4))                  # same content as ref above
    sha4 = e.sha256
    c3 = PresetCollection.new("three", Provenance(ProvenanceKind.MANUAL),
                              {2: PresetRef(sha4, "Patch 004",
                                            bytes(donor.peek(4).meta).hex())})
    gclib.save_collection(c3)
    gclib.remove(e.id)
    assert gclib.has_blob(sha4), "collection still references it"
    gclib.delete_collection(c3.id)
    assert not gclib.has_blob(sha4)
    print("PASS  remove() consults collections before deleting a shared blob")

    # ---- snapshot -> collection --------------------------------------------
    sim = SimulatedMicroFreak.factory_fresh(slots=8, init_copies=0)
    dev = make_device(sim, 8)
    snap = dev.snapshot(read_blobs=True, keep_blobs=True)
    slib = Library.create(work / "snaplib")
    scoll = slib.collection_from_snapshot(snap, name="Live Set")
    assert scoll.provenance.kind is ProvenanceKind.DEVICE_SNAPSHOT
    assert scoll.provenance.source == snap.taken_at
    assert scoll.covered_slots() == tuple(range(8))
    # every ref resolves and matches the device
    for s in range(8):
        preset = slib.preset_for_ref(scoll.slots[s])
        assert preset.sha256 == sim.peek(s).sha256
        assert preset.name == sim.peek(s).name
    # a names-only snapshot is refused
    names_only = dev.snapshot(read_blobs=False)
    try:
        slib.collection_from_snapshot(names_only, name="x")
        raise AssertionError("names-only snapshot must be refused")
    except ValueError:
        pass
    print("PASS  collection_from_snapshot captures all 8 slots; refs resolve")

    # ---- mfprojz -> collection (through the verified mbp_import parser) ------
    zpath = work / "Ambient Peaks.mfprojz"
    zbank = [
        (1, "Voltage Forms", donor.peek(0).blob, "00" * 9, "A", 1),   # slot 0
        (2, "Tokyo88 V3",    donor.peek(1).blob, "00" * 9, "A", 2),   # slot 1
        (3, "Deep Pad",      donor.peek(2).blob, "00" * 9, "A", 3),   # slot 2
        (4, "Init",          None,               "",       "A", 4),   # empty -> skipped
    ]
    _write_mfprojz(zpath, zbank)
    parsed = mbp_import.read_mfprojz(zpath)
    assert len(parsed) == 4 and sum(1 for pr in parsed if pr.is_empty) == 1
    items = [BankItem(slot=pr.slot, name=pr.name, meta=pr.meta, blob=pr.blob)
             for pr in parsed]
    blib = Library.create(work / "banklib")
    bcoll, added = blib.collection_from_bank(items, name="Ambient Peaks",
                                             source=zpath.name)
    assert bcoll.provenance.kind is ProvenanceKind.IMPORTED_BANK
    assert bcoll.provenance.source == "Ambient Peaks.mfprojz"
    assert bcoll.covered_slots() == (0, 1, 2)          # empty slot contributed no ref
    assert len(added) == 3
    # packs arrive Uncategorized for manual tagging; all-zero meta is preserved
    from microfreak.model import Category
    assert all(en.category is Category.UNCATEGORIZED for en in added)
    assert bcoll.slots[0].meta_hex == "00" * 9
    assert blib.preset_for_ref(bcoll.slots[1]).name == "Tokyo88 V3"
    # one library entry per placed item — SLOT-LESS. The COLLECTION owns the
    # arrangement (asserted above as covered_slots() == (0, 1, 2)); the flat
    # catalog carries no slot opinion, so the next pack cannot steal 0..2.
    assert all(en.slot is None for en in added), [en.slot for en in added]
    assert blib.slot_map() == {}
    print("PASS  collection_from_bank: 3 placed, empty skipped, slot-less entries")

    # a second pack covering the same slots leaves both arrangements intact
    zbank2 = [(1, "Bass One", donor.peek(3).blob, "00" * 9, "A", 1),
              (2, "Bass Two", donor.peek(4).blob, "00" * 9, "A", 2)]
    zpath2 = work / "Naughty Bass.mfprojz"
    _write_mfprojz(zpath2, zbank2)
    items2 = [BankItem(slot=pr.slot, name=pr.name, meta=pr.meta, blob=pr.blob)
              for pr in mbp_import.read_mfprojz(zpath2)]
    bcoll2, added2 = blib.collection_from_bank(items2, name="Naughty Bass",
                                               source=zpath2.name)
    assert blib.slot_map() == {}, "no pack steals slots from the last"
    assert bcoll.covered_slots() == (0, 1, 2)
    assert bcoll2.covered_slots() == (0, 1)
    assert blib.collection(bcoll.id).slots[0].name == "Voltage Forms"
    print("PASS  two packs claiming slots 0..1 keep separate, intact arrangements")

    # ---- the one-time repair, on a library built before the fix ------------
    pinned = added[0]
    blib.assign_slot(pinned.id, 0)         # explained by "Ambient Peaks"
    blib.assign_slot(added2[1].id, 400)    # no collection places slot 400
    assert len(blib.slot_map()) == 2
    cleared = blib.clear_collection_slot_claims()
    assert cleared == 1, cleared
    assert list(blib.slot_map()) == [400], blib.slot_map()
    assert blib.clear_collection_slot_claims() == 0, "idempotent"
    # loss-free: the cleared arrangement is still in the collection that owns it
    assert blib.collection(bcoll.id).slots[0].sha256 == pinned.sha256
    assert blib.collection(bcoll.id).slots[0].name == pinned.name
    print("PASS  clear_collection_slot_claims: loss-free, keeps a real pin, idempotent")

    # ---- the repair leaves a DEVICE CAPTURE alone --------------------------
    # The ordinary two-step flow ("Import Device..." then "Snapshot This Device
    # as a Collection") records the same (sha256, name) at the same slot in a
    # DEVICE_SNAPSHOT collection as import_snapshot pinned on the entries. A
    # repair keyed on every collection wiped every one of those pins; only a
    # bank import ever stamped a slot it did not own, so only an IMPORTED_BANK
    # collection may explain a claim.
    caplib = Library.create(work / "capturelib")
    caplib.import_snapshot(snap)
    cap_pins = sorted(e.slot for e in caplib.entries() if e.slot is not None)
    assert cap_pins == list(range(8)), cap_pins
    cap_coll = caplib.collection_from_snapshot(snap, name="Oct dump")
    assert cap_coll.provenance.kind is ProvenanceKind.DEVICE_SNAPSHOT
    assert cap_coll.covered_slots() == tuple(range(8))
    assert caplib.clear_collection_slot_claims() == 0, \
        "a device capture's pins are left alone"
    assert sorted(e.slot for e in caplib.entries()
                  if e.slot is not None) == list(range(8))
    print("PASS  repair leaves device-capture pins alone (only banks explain)")

    # ---- store_preset: adopting device bytes into a collection -------------
    # "Update the collection from the device" edits a collection's slots map
    # with bytes read off the synth. A PresetRef built straight from those
    # bytes names a blob the store never received: preset_for_ref then raises,
    # and plan_apply folds the slot to SKIP -- a silent, permanent hole in the
    # arrangement. store_preset is the only correct way to mint that ref.
    adoptlib = Library.create(work / "adoptlib")
    adopted = Preset(name=snap.records[2].name, blob=snap.records[2].blob,
                     meta=snap.records[2].meta)
    dangling = PresetRef.of(adopted)                    # the WRONG way
    assert not adoptlib.has_blob(dangling.sha256)
    try:
        adoptlib.preset_for_ref(dangling)
        raise AssertionError("a ref to bytes never stored must not resolve")
    except IntegrityError:
        pass
    stored = adoptlib.store_preset(adopted)             # the right way
    assert stored == dangling, "same ref, blob now present"
    assert adoptlib.has_blob(stored.sha256)
    assert adoptlib.preset_for_ref(stored) == adopted
    assert adoptlib.store_preset(adopted) == stored, "idempotent"
    # store_preset does NOT catalogue: the arrangement is the collection's job
    assert adoptlib.entries() == []
    # and the adopted slot is now writable rather than silently skipped
    adopt_coll = PresetCollection.new("Adopted",
                                      Provenance(ProvenanceKind.MANUAL),
                                      {2: stored})
    adoptlib.save_collection(adopt_coll)
    aplan = plan_apply(adopt_coll, snap)
    assert aplan.write_count == 0 and aplan.skip_count == 8   # device already matches
    assert adoptlib.preset_for_ref(adoptlib.collection(adopt_coll.id).slots[2])
    print("PASS  store_preset: blob stored, ref resolvable, no catalog entry")

    # ---- plan_apply: the WRITE / SKIP / CLEAR decision table ----------------
    # collection identical to the device -> all SKIP, zero writes
    plan = plan_apply(scoll, snap)
    assert plan.write_count == 0 and plan.clear_count == 0 and plan.skip_count == 8
    assert plan.total_slots == 8 and plan.estimated_seconds == 0.0
    assert all(sp.action is PlanAction.SKIP_UNCHANGED for sp in plan.slots)
    assert plan.changes() == ()
    print("PASS  plan_apply: collection == device -> 8 SKIP, 0 writes")

    # a WRITE (sha differs), a WRITE (name-only differs), SKIP (equal)
    mixed_slots = dict(scoll.slots)
    mixed_slots[3] = scoll.slots[5]                     # slot 3 gets slot-5 content: sha differs
    r4 = scoll.slots[4]
    mixed_slots[4] = PresetRef(r4.sha256, "Renamed Same Bytes", r4.meta_hex)  # name-only
    mixed = PresetCollection.new("Mixed", Provenance(ProvenanceKind.MANUAL),
                                 mixed_slots)
    mplan = plan_apply(mixed, snap, options=ApplyOptions(seconds_per_write=1.0))
    acts = {sp.slot: sp.action for sp in mplan.slots}
    assert acts[3] is PlanAction.WRITE and acts[4] is PlanAction.WRITE
    assert acts[0] is PlanAction.SKIP_UNCHANGED
    assert mplan.write_count == 2 and mplan.skip_count == 6
    assert mplan.estimated_seconds == 2.0
    assert mplan.slots[3].victim is not None and mplan.slots[3].victim.slot == 3
    print("PASS  plan_apply: sha-diff WRITE + name-only WRITE + SKIP, eta counts writes")

    # CLEAR on unlisted, and SKIP when an unlisted device slot already == clear_with.
    # clear_with is slot 7's real snapshot content, so device slot 7 already matches.
    clear_with = scoll.slots[7]
    partial = PresetCollection.new("Partial", Provenance(ProvenanceKind.MANUAL),
                                   {0: scoll.slots[0]})
    cplan = plan_apply(partial, snap,
                       options=ApplyOptions(unlisted="clear", clear_with=clear_with))
    cacts = {sp.slot: sp.action for sp in cplan.slots}
    assert cacts[0] is PlanAction.SKIP_UNCHANGED         # in collection, unchanged
    assert cacts[7] is PlanAction.SKIP_UNCHANGED         # unlisted BUT device == clear_with
    assert cacts[1] is PlanAction.CLEAR                  # unlisted, device != clear_with
    assert cplan.clear_count == 6                        # slots 1..6 cleared
    # unlisted == leave leaves them alone
    lplan = plan_apply(partial, snap, options=ApplyOptions(unlisted="leave"))
    assert lplan.clear_count == 0 and lplan.write_count == 0
    assert lplan.skip_count == 8
    print("PASS  plan_apply: unlisted clear vs leave; already-cleared slot is SKIP")

    # error cases: hash-less / partial snapshot, clear without clear_with
    try:
        plan_apply(scoll, names_only)
        raise AssertionError("hash-less snapshot must be refused")
    except ValueError:
        pass
    partial_snap = dev.snapshot(read_blobs=True, keep_blobs=True, slots=range(4))
    try:
        plan_apply(scoll, partial_snap)
        raise AssertionError("partial snapshot must be refused")
    except ValueError:
        pass
    try:
        plan_apply(partial, snap, options=ApplyOptions(unlisted="clear"))
        raise AssertionError("clear policy needs clear_with")
    except ValueError:
        pass
    print("PASS  plan_apply refuses hash-less/partial snapshots and clear w/o clear_with")

    # ---- apply_collection writes ONLY changed slots -------------------------
    before = {s: sim.peek(s).sha256 for s in range(8)}
    mark = len(sim.wire_log)
    reports = dev.apply_collection(mplan, slib.preset_for_ref)
    assert len(reports) == 2, reports              # exactly the 2 WRITE slots
    assert last_chunk_count(sim, mark) == 2, "only 2 blob writes on the wire"
    assert {r.slot for r in reports} == {3, 4}
    assert sim.peek(3).sha256 == before[5]         # slot 3 now holds slot-5 content
    assert sim.peek(4).name == "Renamed Same Bytes"
    for s in (0, 1, 2, 5, 6, 7):
        assert sim.peek(s).sha256 == before[s], f"slot {s} must be untouched"
    assert sim.faults == [], sim.faults
    print("PASS  apply_collection writes ONLY the 2 changed slots; rest untouched")

    # ---- a full switch brings a scrambled device to the collection state ----
    sim2 = SimulatedMicroFreak.factory_fresh(slots=8, init_copies=0)
    dev2 = make_device(sim2, 8)
    target = slib.collection_from_snapshot(
        dev2.snapshot(read_blobs=True, keep_blobs=True), name="Target")
    # scramble: overwrite 3 slots with foreign content
    foreign = donor.peek(6).renamed("Foreign One")
    for s in (1, 4, 6):
        sim2.load(s, foreign)
    snap2 = dev2.snapshot(read_blobs=True, keep_blobs=True)
    switch = plan_apply(target, snap2)
    assert switch.write_count == 3 and switch.skip_count == 5
    mark2 = len(sim2.wire_log)
    seen = []
    dev2.apply_collection(switch, slib.preset_for_ref,
                          progress=lambda ev: seen.append((ev.done, ev.total, ev.slot)))
    assert last_chunk_count(sim2, mark2) == 3
    assert [d for d, _t, _s in seen] == [1, 2, 3] and seen[-1][1] == 3
    for s in range(8):
        assert sim2.peek(s).sha256 == slib.preset_for_ref(target.slots[s]).sha256
        assert sim2.peek(s).name == target.slots[s].name
    assert sim2.faults == [], sim2.faults
    print("PASS  full switch: 3 changed slots written, device now matches collection")

    # ---- cancellation between slots ----------------------------------------
    for s in (1, 4, 6):
        sim2.load(s, foreign)
    snap3 = dev2.snapshot(read_blobs=True, keep_blobs=True)
    plan3 = plan_apply(target, snap3)
    assert plan3.write_count == 3
    token = CancelToken()

    def cancel_after_one(ev):
        if ev.done == 1:
            token.cancel()

    try:
        dev2.apply_collection(plan3, slib.preset_for_ref,
                              progress=cancel_after_one, cancel=token)
        raise AssertionError("cancelled apply must raise")
    except OperationCancelledError as ex:
        assert ex.done == 1 and ex.total == 3
        assert len(ex.completed) == 1               # one slot written before cancel
    print("PASS  apply_collection cancels between slots (done=1, total=3, 1 completed)")

    # ---- stop on first failure, completed reports attached ------------------
    class CorruptingSim(SimulatedMicroFreak):
        def __init__(self, *, bad=(), **kw):
            super().__init__(**kw)
            self._bad = set(bad)
            self._writing = None

        def _on_name(self, f):
            if len(f.data) == 3 and f.data[2] == 0x01:
                self._writing = f.data[0] * p.SLOTS_PER_BANK + f.data[1]
            super()._on_name(f)

        def _on_chunk(self, f):
            super()._on_chunk(f)
            if f.cmd == p.CMD_CHUNK_LAST and self._writing in self._bad:
                st = self._state[self._writing]
                m = bytearray(st.blob)
                m[0] ^= 0x01
                st.blob = bytes(m)

    # same factory content as `target` was snapped from, so only 1/4/6 differ
    csim = CorruptingSim.factory_fresh(slots=8, init_copies=0,
                                       reply_lag=False, bad=[4])
    for s in (1, 4, 6):
        csim.load(s, foreign)
    cdev = make_device(csim, 8)
    csnap = cdev.snapshot(read_blobs=True, keep_blobs=True)
    cplan2 = plan_apply(target, csnap)
    assert cplan2.write_count == 3           # slots 1, 4, 6 (ascending)
    try:
        cdev.apply_collection(cplan2, slib.preset_for_ref)
        raise AssertionError("corrupting device must fail verification")
    except VerifyMismatchError as ex:
        assert ex.slot == 4
        assert len(ex.completed) == 1        # slot 1 completed before slot 4 failed
        assert ex.completed[0].slot == 1
    print("PASS  apply_collection stops at first failure; .completed holds prior writes")


if __name__ == "__main__":
    main()
