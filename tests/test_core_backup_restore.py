"""Backup/restore round-trip: back a device up, wreck it, restore it, and
prove every slot is byte-identical again. Plus the load-time integrity
re-hash on tampered files."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.backup import BackupSet
from microfreak.device import MicroFreak
from microfreak.errors import IntegrityError
from microfreak.model import Preset
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


# straddles the 384 boundary and both ends of the device
SLOTS = [0, 1, 2, 3, 383, 384, 509, 510, 511]


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-core-br-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    sim = SimulatedMicroFreak.factory_fresh()       # lag ON, the default
    dev = make_device(sim)
    originals = {s: sim.peek(s) for s in SLOTS}

    # ---- backup to the phase-0 on-disk format -----------------------------
    dest = work / "backup"
    events = []
    bs = dev.backup(dest, slots=SLOTS, progress=events.append)
    assert bs.covered_slots() == SLOTS
    index = json.loads((dest / "index.json").read_text())
    for s in SLOTS:
        entry = index["presets"][str(s)]
        want = originals[s]
        assert entry["name"] == want.name
        assert entry["sha256"] == want.sha256
        assert entry["bytes"] == p.BLOB_SIZE
        assert bytes.fromhex(entry["meta_hex"]) == want.meta
        assert (dest / "presets" / ("%03d.bin" % s)).read_bytes() == want.blob
    assert [e.done for e in events] == list(range(1, len(SLOTS) + 1))
    assert sim.faults == [], sim.faults
    print("PASS  backup: %d slots to index.json + NNN.bin, names/shas/meta correct"
          % len(SLOTS))

    # ---- wreck the device -------------------------------------------------
    for i, s in enumerate(SLOTS):
        sim.load(s, Preset(name="Wrecked %d" % i, blob=blob7(100 + i),
                           meta=b"\x00" * p.META_LEN))
    assert all(sim.peek(s).blob != originals[s].blob for s in SLOTS)
    assert all(sim.peek(s).name != originals[s].name for s in SLOTS)
    print("PASS  device wrecked: all %d slots now differ from the backup"
          % len(SLOTS))

    # ---- restore: every slot returns byte-identical, hash-verified --------
    bs = BackupSet.load(dest)
    reports = dev.restore(bs)                       # covered slots, verify=True
    assert [r.slot for r in reports] == SLOTS
    assert all(r.verified is True for r in reports)
    for s in SLOTS:
        got = sim.peek(s)
        want = originals[s]
        assert got.blob == want.blob, "slot %d blob differs after restore" % s
        assert got.name == want.name, (s, got.name, want.name)
        assert got.meta == want.meta, "slot %d meta not round-tripped" % s
        assert got.sha256 == want.sha256
    assert sim.faults == [], sim.faults             # incl. payload[8]/[9] at 384+
    print("PASS  restore round-trip: blob, name and meta byte-identical, verified")

    # restore is write traffic: chunks + go frames went out for every slot
    gos = sum(1 for d, raw in sim.wire_log if d == "out"
              for f in [p.parse(raw)] if f and f.cmd == 0x15)
    assert gos == len(SLOTS)
    print("PASS  restore used the real write path (one 0x15 go per slot)")

    # ---- tampered blob file: load re-hash names the bad slot --------------
    victim = dest / "presets" / "384.bin"
    good = victim.read_bytes()
    victim.write_bytes(good[:100] + bytes([good[100] ^ 0x01]) + good[101:])
    try:
        BackupSet.load(dest)
        raise AssertionError("tampered blob must fail the load re-hash")
    except IntegrityError as e:
        assert "384" in e.path or "384" in e.detail
    victim.write_bytes(good)
    BackupSet.load(dest)                            # healthy again
    print("PASS  tampering with one .bin fails BackupSet.load with the slot named")

    # ---- a second backup of the restored device matches the first ---------
    dest2 = work / "backup2"
    bs2 = make_device(sim).backup(dest2, slots=SLOTS)
    for s in SLOTS:
        assert bs2.preset(s).blob == bs.preset(s).blob
        assert bs2.preset(s).name == bs.preset(s).name
        assert bs2.preset(s).meta == bs.preset(s).meta
    print("PASS  backup -> restore -> backup is a fixed point")


if __name__ == "__main__":
    main()
