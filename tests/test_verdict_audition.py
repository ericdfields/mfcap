"""Verdict attribute (round-trip, back-compat, dedupe merge) and the audition
session against SimulatedMicroFreak: borrowed slot, verified write + Program
Change selection per preset, verdicts filed, original restored on stop."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.audition import AuditionSession
from microfreak.device import MicroFreak
from microfreak.library import Library
from microfreak.model import Preset, Verdict
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def blob7(seed: int) -> bytes:
    out = bytearray()
    x = (seed % 126) + 1
    while len(out) < p.BLOB_SIZE:
        x = (x * 75 + 74) % 127
        out.append(x)
    return bytes(out[:p.BLOB_SIZE])


META = bytes(9)


def run(work: Path) -> None:
    # --- verdict: slug round-trip + back-compat + setter ----------------------
    assert Verdict.from_slug("keep") is Verdict.KEEP
    assert Verdict.from_slug("bogus") is Verdict.UNRATED
    lib = Library.create(work / "lib")
    e = lib.add(Preset(name="A", blob=blob7(1), meta=META))
    assert e.verdict is Verdict.UNRATED
    e = lib.set_verdict(e.id, Verdict.TRY_LATER)
    assert Library.open(work / "lib").entry(e.id).verdict is Verdict.TRY_LATER
    # an index written before verdict existed loads as UNRATED
    idx = work / "lib" / "index.json"
    data = json.loads(idx.read_text())
    for d in data["entries"]:
        d.pop("verdict", None)
    idx.write_text(json.dumps(data))
    assert Library.open(work / "lib").entry(e.id).verdict is Verdict.UNRATED
    print("PASS  verdict slug round-trip, setter, back-compat load")

    # dedupe keeps a set verdict over UNRATED
    lib2 = Library.create(work / "lib2")
    a = lib2.add(Preset(name="X", blob=blob7(2), meta=META))
    lib2.set_verdict(a.id, Verdict.KEEP)
    lib2.add(Preset(name="X", blob=blob7(2), meta=META))          # exact dup
    lib2.dedupe()
    assert lib2.entries()[0].verdict is Verdict.KEEP
    print("PASS  dedupe merge prefers the filed verdict")

    # --- select: Bank Select + Program Change reaches the simulated panel ----
    sim = SimulatedMicroFreak()
    fc = FakeClock()
    dev = MicroFreak(sim, clock=fc, sleep=fc.sleep)
    dev.select(300)                       # bank 2, program 44
    assert sim.selected_slot == 300, sim.selected_slot
    msgs = p.select_preset_messages(300)
    assert msgs[-1] == bytes([0xC0, 44]) and msgs[0] == bytes([0xB0, 0, 2])
    assert not sim.faults, sim.faults
    print("PASS  select(): bank 2 / program 44 -> panel shows slot 300")

    # --- audition session ------------------------------------------------------
    lib3 = Library.create(work / "lib3")
    entries = [lib3.add(Preset(name=f"P{i}", blob=blob7(10 + i), meta=META))
               for i in range(3)]
    slot = 509
    before = sim.peek(slot)
    s = AuditionSession(dev, lib3, AuditionSession.unrated(lib3.entries()), slot)
    s.start()
    assert s.original == before and s.remaining == 3
    first = s.next()
    assert first is entries[0]
    assert sim.peek(slot).blob == lib3.get(first.id).blob   # verified-written
    assert sim.selected_slot == slot                        # and selected
    s.verdict(Verdict.KEEP)
    second = s.next()
    s.verdict(Verdict.NEVER, second)
    third = s.next()
    assert third is entries[2] and s.remaining == 0
    assert s.next() is None                                 # exhausted
    s.stop()
    assert sim.peek(slot) == before, "original must be restored"
    s.stop()                                                # idempotent
    assert lib3.entry(entries[0].id).verdict is Verdict.KEEP
    assert lib3.entry(entries[1].id).verdict is Verdict.NEVER
    assert lib3.entry(entries[2].id).verdict is Verdict.UNRATED
    assert [v for _, v in s.history] == [Verdict.KEEP, Verdict.NEVER]
    assert not sim.faults, sim.faults
    print("PASS  audition: borrow slot, write+select each, file verdicts, restore")


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-audition-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
