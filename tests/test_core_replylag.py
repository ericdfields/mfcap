"""Reply-lag rejection: the simulated device answers one request late, a
naive first-reply reader mislabels slots, and Session's embedded-address
matching never does."""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.session import Session
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    """Injected clock+sleep: sleeping advances virtual time, so silent
    timeout windows cost nothing real."""

    def __init__(self):
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, dt: float) -> None:
        self.now += max(dt, 1e-4)


def make_session(transport, **kw):
    fc = FakeClock()
    return Session(transport, clock=fc, sleep=fc.sleep, **kw)


def main() -> None:
    # --- the trap, demonstrated raw: replies lag one request behind -------
    sim = SimulatedMicroFreak.factory_fresh()
    assert sim.reply_lag is True, "reply-lag must be the sim default"

    sim.send(p.read_name_req(1, 10))
    assert sim.receive(0.0) is None, "first name read must yield nothing yet"
    sim.send(p.read_name_req(2, 20))
    raw = sim.receive(0.0)
    assert raw is not None, "second read must flush the held reply"
    late = p.decode_name_reply(p.parse(raw))
    assert late.slot == 10, "the flushed reply answers the PREVIOUS request"
    assert late.slot != 20
    assert late.name == sim.peek(10).name
    print("PASS  lagged sim answers request N only when N+1 arrives")
    print("PASS  a naive first-reply reader would label slot 20 with slot 10's name")

    # --- Session never mislabels: embedded bank/pos is the match key ------
    sim = SimulatedMicroFreak.factory_fresh()
    sess = make_session(sim)
    order = list(range(sim.slots))
    random.Random(2026).shuffle(order)
    for slot in order:
        info = sess.read_name(slot)
        expected = sim.peek(slot)
        assert info.slot == slot, (info.slot, slot)
        assert info.name == expected.name, (slot, info.name, expected.name)
        assert info.meta == expected.meta, slot
    assert sim.faults == [], sim.faults
    print(f"PASS  {len(order)} shuffled reads under lag: every slot labeled right")

    # the defense actually engaged: stale replies were discarded and the
    # requests resent, so the wire carries more reads than slots
    reads = [p.parse(raw) for d, raw in sim.wire_log if d == "out"]
    reads = [f for f in reads if f.cmd == p.CMD_OPEN and f.data[2] == 0x00]
    assert len(reads) > len(order), \
        "no retries seen: the lag defense never engaged"
    print(f"PASS  defense engaged: {len(reads)} requests for {len(order)} slots")

    # --- lag OFF still works (no spurious retries needed) -----------------
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
