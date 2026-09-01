"""WriteAbortedError paths: transport failure at each write stage, a missing
control-frame ack, and a failing final read-back — the stage and chunks_sent
bookkeeping in Session.write_preset, exercised offline."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.errors import (DeviceTimeoutError, TransportError,
                               WriteAbortedError)
from microfreak.model import Preset
from microfreak.session import Session
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_session(transport):
    fc = FakeClock()
    return Session(transport, clock=fc, sleep=fc.sleep)


def blob7(seed: int) -> bytes:
    out = bytearray()
    x = (seed % 126) + 1
    while len(out) < p.BLOB_SIZE:
        x = (x * 75 + 74) % 127
        out.append(x)
    return bytes(out[:p.BLOB_SIZE])


META = bytes([0x18, 0x00, 0x00, 0x00, 0x00, 0x7F, 0x01, 0x00, 0x33])
PRESET = Preset(name="Akiko San", blob=blob7(3), meta=META)


class FailingSendTransport:
    """Passes through to the sim until `judge(frame)` says fail, then raises
    TransportError from send()."""

    def __init__(self, inner, judge):
        self.inner = inner
        self.judge = judge

    def send(self, message):
        f = p.parse(bytes(message))
        if f is not None and self.judge(f):
            raise TransportError("wire pulled")
        self.inner.send(message)

    def receive(self, timeout):
        return self.inner.receive(timeout)

    def close(self):
        self.inner.close()


class AckDroppingTransport:
    """Delivers everything except device 0x18 acks once armed."""

    def __init__(self, inner):
        self.inner = inner
        self.drop_acks = False

    def send(self, message):
        self.inner.send(message)

    def receive(self, timeout):
        while True:
            raw = self.inner.receive(timeout)
            if raw is None:
                return None
            f = p.parse(raw)
            if self.drop_acks and f is not None and f.cmd == p.CMD_NEXT:
                continue
            return raw

    def close(self):
        self.inner.close()


class ReplyDroppingTransport:
    """After the last chunk goes out, suppress long-0x52 name replies so the
    final read-back times out."""

    def __init__(self, inner):
        self.inner = inner
        self.after_last_chunk = False

    def send(self, message):
        f = p.parse(bytes(message))
        self.inner.send(message)
        if f is not None and f.cmd == p.CMD_CHUNK_LAST:
            self.after_last_chunk = True

    def receive(self, timeout):
        while True:
            raw = self.inner.receive(timeout)
            if raw is None:
                return None
            f = p.parse(raw)
            if (self.after_last_chunk and f is not None
                    and f.cmd == p.CMD_NAME):
                continue
            return raw

    def close(self):
        self.inner.close()


def expect_abort(sess, slot, stage, chunks_sent, cause=None):
    try:
        sess.write_preset(slot, PRESET)
        raise AssertionError("write must abort at stage %r" % stage)
    except WriteAbortedError as e:
        assert e.stage == stage, (e.stage, stage)
        assert e.slot == slot
        assert e.chunks_sent == chunks_sent, (e.chunks_sent, chunks_sent)
        if cause is not None:
            assert isinstance(e.__cause__, cause), e.__cause__
        return e


def main() -> None:
    # --- send failure at each control stage --------------------------------
    for stage, judge in [
        ("name_write", lambda f: f.cmd == p.CMD_NAME and len(f.data) == 35),
        ("open", lambda f: f.cmd == p.CMD_NAME and len(f.data) == 3),
        ("go", lambda f: f.cmd == p.CMD_GO),
    ]:
        sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
        sess = make_session(FailingSendTransport(sim, judge))
        e = expect_abort(sess, 509, stage, 0, cause=TransportError)
        assert "0 chunks sent" in str(e)
    print("PASS  send failure at name_write/open/go -> WriteAbortedError(stage, 0)")

    # --- send failure mid-chunk stream -------------------------------------
    counter = {"chunks": 0}

    def fail_fifth_chunk(f):
        if f.cmd in (p.CMD_CHUNK_MORE, p.CMD_CHUNK_LAST):
            counter["chunks"] += 1
            return counter["chunks"] == 6          # fail sending chunk index 5
        return False

    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sess = make_session(FailingSendTransport(sim, fail_fifth_chunk))
    before = sim.peek(509).blob
    expect_abort(sess, 509, "chunk", 5, cause=TransportError)
    assert sim.peek(509).blob == before, "torn write must not commit"
    print("PASS  send failure at chunk 5 -> WriteAbortedError('chunk', chunks_sent=5)")

    # --- missing control-frame ack -----------------------------------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    wire = AckDroppingTransport(sim)
    sess = make_session(wire)
    wire.drop_acks = True
    expect_abort(sess, 509, "name_write", 0)
    print("PASS  missing 0x18 for the long 0x52 -> WriteAbortedError('name_write')")

    # --- failing final read-back -------------------------------------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sess = make_session(ReplyDroppingTransport(sim))
    e = expect_abort(sess, 509, "final_read", p.CHUNK_COUNT,
                     cause=DeviceTimeoutError)
    # the write itself completed: the blob is committed on the device
    assert sim.peek(509).blob == PRESET.blob
    assert "146 chunks sent" in str(e)
    print("PASS  silent read-back -> WriteAbortedError('final_read', 146),")
    print("PASS     chained from DeviceTimeoutError, with the blob committed")


if __name__ == "__main__":
    main()
