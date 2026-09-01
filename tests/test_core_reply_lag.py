"""Reply-lag rejection: the simulated device answers one request late; a
naive first-reply reader mislabels slots, the Session's embedded-address
matching never does."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.device import MicroFreak
from microfreak.session import Session
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_session(sim):
    fc = FakeClock()
    return Session(sim, clock=fc, sleep=fc.sleep)


def main() -> None:
    # ---- the hazard is real: raw wire, no defense -------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    assert sim.reply_lag is True, "reply lag must be the sim default"
    sim.send(p.read_name_req(1, 5))                 # request A
    assert sim.receive(0.0) is None, "reply to A is held — the lag"
    sim.send(p.read_name_req(2, 9))                 # request B
    late = sim.receive(0.0)
    assert late is not None, "B's arrival releases A's held reply"
    info = p.decode_name_reply(p.parse(late))
    assert info.slot == 5, "first reply after B is A's — one request late"
    # a naive reader pairing first-reply-with-latest-request would now
    # label slot 9 with slot 5's data; the embedded address is the tell
    assert info.name == sim.peek(5).name
    print("PASS  lag demonstrated on the wire: reply to request N arrives after N+1")

    # ---- Session never mislabels under lag --------------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    sess = make_session(sim)
    # scrambled order, revisits included — worst case for a lagged pipeline
    order = [0, 511, 7, 384, 7, 200, 383, 1, 400, 12, 0, 269, 500, 268, 3]
    for slot in order:
        info = sess.read_name(slot)
        expected = sim.peek(slot)
        assert info.slot == slot, (info.slot, slot)
        assert info.name == expected.name, (slot, info.name, expected.name)
        assert info.meta == expected.meta
    assert sim.faults == [], sim.faults
    print("PASS  %d scrambled reads under lag: every reply matched to its slot"
          % len(order))

    # the defense engaged: stale replies were discarded and requests resent
    reads_sent = sum(1 for d, raw in sim.wire_log
                     if d == "out"
                     for f in [p.parse(raw)]
                     if f and f.cmd == p.CMD_OPEN and f.data[2] == 0x00)
    assert reads_sent > len(order), "no retries means the lag never engaged"
    print("PASS  defense engaged: %d requests for %d reads (stale replies discarded)"
          % (reads_sent, len(order)))

    # ---- names-only snapshot over a lagged device -------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    fc = FakeClock()
    dev = MicroFreak(sim, clock=fc, sleep=fc.sleep)
    slots = [0, 1, 2, 240, 241, 242, 243, 244, 509, 510, 511]
    snap = dev.snapshot(read_blobs=False, slots=slots)
    assert [r.slot for r in snap.records] == slots
    for r in snap.records:
        assert r.name == sim.peek(r.slot).name, (r.slot, r.name)
        assert r.meta == sim.peek(r.slot).meta
    assert sim.faults == [], sim.faults
    print("PASS  names-only snapshot under lag labels all %d slots correctly"
          % len(slots))

    # ---- lag survives interleaved blob reads ------------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    sess = make_session(sim)
    for slot in (2, 250, 480):
        info = sess.read_name(slot)
        blob = sess.read_blob(slot)
        assert info.slot == slot and info.name == sim.peek(slot).name
        assert blob == sim.peek(slot).blob and len(blob) == p.BLOB_SIZE
    assert sim.faults == [], sim.faults
    print("PASS  name reads stay correctly labeled with dumps interleaved")

    # ---- lag OFF still works (no spurious retries needed) -----------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sess = make_session(sim)
    for slot in (0, 9, 200, 511):
        info = sess.read_name(slot)
        assert info.slot == slot and info.name == sim.peek(slot).name
    reads = [p.parse(raw) for d, raw in sim.wire_log if d == "out"]
    assert len([f for f in reads if f.cmd == p.CMD_OPEN]) == 4, \
        "an unlagged device must need exactly one request per read"
    print("PASS  unlagged sim: one request per read, same correct labels")


if __name__ == "__main__":
    main()
