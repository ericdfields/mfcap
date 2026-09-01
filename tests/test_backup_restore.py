"""Backup to the phase-0 on-disk format, resume, BackupSet.load integrity
re-hash, restore round-trip, and stop-on-first-failure with .completed."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.backup import BackupSet
from microfreak.device import MicroFreak
from microfreak.errors import IntegrityError, SlotOutOfRangeError, VerifyMismatchError
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_device(sim, **kw):
    fc = FakeClock()
    return MicroFreak(sim, clock=fc, sleep=fc.sleep, **kw)


class CorruptingSim(SimulatedMicroFreak):
    def __init__(self, bad_slots, **kw):
        super().__init__(**kw)
        self._bad = set(bad_slots)
        self._writing = None

    def _on_name(self, f):
        if len(f.data) == 3 and f.data[2] == 0x01:
            self._writing = f.data[0] * p.SLOTS_PER_BANK + f.data[1]
        super()._on_name(f)

    def _on_chunk(self, f):
        super()._on_chunk(f)
        if f.cmd == p.CMD_CHUNK_LAST and self._writing in self._bad:
            st = self._state[self._writing]
            mangled = bytearray(st.blob)
            mangled[0] ^= 0x01
            st.blob = bytes(mangled)


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-backup-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    slots = list(range(6))
    sim = SimulatedMicroFreak.factory_fresh()          # lag ON, the default
    dev = make_device(sim)
    dest = work / "backup"

    events = []
    bs = dev.backup(dest, slots=slots, progress=events.append)
    assert bs.covered_slots() == slots
    index = json.loads((dest / "index.json").read_text())
    assert set(index) == {"created", "slots", "presets", "timing"}
    assert index["slots"] == 512
    for slot in slots:
        entry = index["presets"][str(slot)]
        expected = sim.peek(slot)
        assert entry["name"] == expected.name
        assert entry["bytes"] == p.BLOB_SIZE
        assert entry["sha256"] == expected.sha256
        assert entry["meta_hex"] == expected.meta.hex()
        assert len(entry["meta_hex"]) == 18
        blob = (dest / "presets" / ("%03d.bin" % slot)).read_bytes()
        assert blob == expected.blob
    assert index["timing"]["name_ms_median"] is not None
    assert index["timing"]["dump_ms_median"] is not None
    assert [e.done for e in events] == [1, 2, 3, 4, 5, 6]
    assert events[-1].eta_seconds == 0
    print("PASS  backup writes the phase-0 format: index + NNN.bin + meta_hex")

    # BackupSet API
    assert bs.covers(3) and not bs.covers(100)
    pr = bs.preset(3)
    assert pr.name == sim.peek(3).name and pr.blob == sim.peek(3).blob
    assert pr.meta == sim.peek(3).meta
    recs = bs.records()
    assert [r.slot for r in recs] == slots
    assert all(r.blob is None and r.sha256 and r.meta for r in recs)
    try:
        bs.preset(100)
        raise AssertionError("uncovered slot must raise")
    except SlotOutOfRangeError:
        pass
    print("PASS  BackupSet: covers/preset/records; uncovered slot refused")

    # resume: delete one blob file; only that slot is re-read
    (dest / "presets" / "003.bin").unlink()
    reads_before = len(sim.wire_log)
    dev.backup(dest, slots=slots, resume=True)
    dump_opens = [1 for d, raw in sim.wire_log[reads_before:] if d == "out"
                  for f in [p.parse(raw)]
                  if f.cmd == p.CMD_OPEN and f.data[2] == 0x01]
    assert len(dump_opens) == 1, dump_opens
    assert (dest / "presets" / "003.bin").read_bytes() == sim.peek(3).blob
    print("PASS  resume re-reads only the missing slot")

    # integrity: tamper one blob file -> load names the bad slot
    good = (dest / "presets" / "002.bin").read_bytes()
    (dest / "presets" / "002.bin").write_bytes(good[:-1] + bytes([good[-1] ^ 1]))
    try:
        BackupSet.load(dest)
        raise AssertionError("tampered blob must fail the load re-hash")
    except IntegrityError as e:
        assert "002" in str(e.path) or "slot 2" in e.detail
    (dest / "presets" / "002.bin").write_bytes(good)
    BackupSet.load(dest)                    # healthy again
    print("PASS  BackupSet.load re-hashes and IntegrityError names the bad slot")

    # old (phase-0) index without meta_hex: readable, not restorable
    old = json.loads((dest / "index.json").read_text())
    del old["presets"]["4"]["meta_hex"]
    (dest / "index.json").write_text(json.dumps(old))
    bs2 = BackupSet.load(dest)
    assert bs2.records()[4].meta is None
    try:
        bs2.preset(4)
        raise AssertionError("meta-less slot must refuse to restore")
    except IntegrityError as e:
        assert "re-backup" in e.detail
    assert bs2.preset(3) is not None        # other slots unaffected
    print("PASS  old index without meta_hex: readable for analysis, restore refused")

    # restore round-trip onto a blank device (slot 4 lost its meta above, so
    # restore the still-covered-with-meta slots)
    bs = BackupSet.load(dest)
    target = SimulatedMicroFreak()          # blank: all "Init", zero blobs
    dev2 = make_device(target)
    reports = dev2.restore(bs, slots=[0, 1, 2, 3, 5])
    assert len(reports) == 5
    assert all(r.verified is True for r in reports)
    for slot in (0, 1, 2, 3, 5):
        assert target.peek(slot).blob == sim.peek(slot).blob
        assert target.peek(slot).name == sim.peek(slot).name
    assert target.faults == [], target.faults
    print("PASS  restore round-trip: blobs and names land byte-identical, verified")

    # stop-on-first-failure with .completed
    bad = CorruptingSim([2], reply_lag=False)
    dev3 = make_device(bad)
    try:
        dev3.restore(bs, slots=[0, 1, 2, 3])
        raise AssertionError("failing write must stop the restore")
    except VerifyMismatchError as e:
        assert e.slot == 2
        completed = e.completed
        assert [r.slot for r in completed] == [0, 1]
        assert all(r.verified for r in completed)
    print("PASS  restore stops at the first failure; .completed lists slots 0,1")


if __name__ == "__main__":
    main()
