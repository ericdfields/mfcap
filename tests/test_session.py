"""Session: the reply-lag defense proven over 512 rapid reads, timeout ->
DeviceTimeoutError, persistent mismatch -> ReplyMismatchError."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.errors import DeviceTimeoutError, ReplyMismatchError
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
    return Session(transport, clock=fc, sleep=fc.sleep, **kw), fc


class DeadTransport:
    """Never answers anything."""

    def send(self, message):
        pass

    def receive(self, timeout):
        return None

    def close(self):
        pass


class WrongSlotTransport:
    """Always replies to a name read with a reply for one fixed other slot —
    a lag that never resolves."""

    def __init__(self, wrong_slot):
        self.wrong = wrong_slot
        self.outbox = []
        self.sends = 0

    def send(self, message):
        f = p.parse(bytes(message))
        if f and f.cmd == p.CMD_OPEN and len(f.data) == 3 and f.data[2] == 0:
            self.sends += 1
            bank, pos = p.addr(self.wrong)
            meta = bytes([0, 0, 0, 0, 0, pos, 0 if self.wrong < 384 else 1,
                          0, 0x33])
            payload = bytes([bank, pos, 0]) + meta + b"Wrong" + b"\x00" * 18
            self.outbox.append(p.frame(0, 0x23, p.CMD_NAME, payload))

    def receive(self, timeout):
        return self.outbox.pop(0) if self.outbox else None

    def close(self):
        pass


def main() -> None:
    # --- the reply-lag defense, proven across every slot ------------------
    sim = SimulatedMicroFreak.factory_fresh()          # 512 slots, lag ON
    assert sim.reply_lag is True, "lag must be the default"
    sess, _ = make_session(sim)
    for slot in range(512):
        info = sess.read_name(slot)
        expected = sim.peek(slot)
        assert info.slot == slot, (info.slot, slot)
        assert info.name == expected.name, (slot, info.name, expected.name)
        assert info.meta == expected.meta
    assert sim.faults == [], sim.faults
    print("PASS  512 rapid name reads under reply-lag: every slot labeled right")

    # the lag was real: the sim held replies (first read answered nothing)
    outbound_reads = sum(1 for d, raw in sim.wire_log
                         if d == "out" and p.parse(raw)
                         and p.parse(raw).cmd == p.CMD_OPEN)
    assert outbound_reads > 512, "retries prove the defense actually engaged"
    print("PASS  defense engaged: %d requests for 512 slots (retries happened)"
          % outbound_reads)

    # --- blob read over the same lagged sim -------------------------------
    blob = sess.read_blob(3)
    assert blob == sim.peek(3).blob and len(blob) == p.BLOB_SIZE
    assert sim.faults == []
    print("PASS  read_blob assembles the 146-chunk dump byte-identically")

    # --- total silence -> DeviceTimeoutError ------------------------------
    sess2, _ = make_session(DeadTransport())
    try:
        sess2.read_name(7)
        raise AssertionError("silence should time out")
    except DeviceTimeoutError as e:
        assert e.stage == "name_read" and e.slot == 7
    print("PASS  silence raises DeviceTimeoutError(stage='name_read', slot)")

    try:
        sess2.read_blob(7)
        raise AssertionError("silent dump should time out")
    except DeviceTimeoutError as e:
        assert e.stage == "dump" and e.slot == 7
    print("PASS  silent dump raises DeviceTimeoutError(stage='dump', slot)")

    # --- unresolvable mismatch -> ReplyMismatchError after retries --------
    wrong = WrongSlotTransport(wrong_slot=500)
    sess3, _ = make_session(wrong)
    try:
        sess3.read_name(5)
        raise AssertionError("permanent mismatch should raise")
    except ReplyMismatchError as e:
        assert e.requested_slot == 5
        assert e.replied_slot == 500
        assert e.attempts == 3
    assert wrong.sends == 3, wrong.sends
    print("PASS  persistent wrong-slot replies raise ReplyMismatchError after 3 attempts")

    # --- seq discipline: 1..127, never 0 ----------------------------------
    sim2 = SimulatedMicroFreak(reply_lag=False)
    sess4, _ = make_session(sim2)
    for slot in range(300):
        sess4.read_name(slot % sim2.slots)
    seqs = [p.parse(raw).seq for d, raw in sim2.wire_log if d == "out"]
    assert 0 not in seqs, "seq 0 must appear only in the go frame"
    assert max(seqs) == 127 and min(seqs) == 1
    print("PASS  seq counter walks 1..127 and wraps without emitting 0")


if __name__ == "__main__":
    main()
