"""Write-verify cycle against SimulatedMicroFreak: the 7-frame sequence in
docs/write-protocol.md order, hash-verified read-back, a corrupted write that
MUST fail verification, unacked chunks, and rename-without-blob-traffic."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.device import MicroFreak
from microfreak.errors import ChunkNotAckedError, VerifyMismatchError
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


def make_device(transport, **kw):
    fc = FakeClock()
    return MicroFreak(transport, clock=fc, sleep=fc.sleep, **kw)


def blob7(seed: int) -> bytes:
    out = bytearray()
    x = (seed % 126) + 1
    while len(out) < p.BLOB_SIZE:
        x = (x * 75 + 74) % 127
        out.append(x)
    return bytes(out[:p.BLOB_SIZE])


META = bytes([0x18, 0x00, 0x00, 0x00, 0x00, 0x7F, 0x01, 0x00, 0x33])


class ChunkCorruptingTransport:
    """Passes everything through, but flips one bit of one write chunk in
    transit — a wire that lies."""

    def __init__(self, inner, chunk_index: int, byte_offset: int):
        self.inner = inner
        self.chunk_index = chunk_index
        self.byte_offset = byte_offset
        self.seen = 0

    def send(self, message):
        raw = bytes(message)
        f = p.parse(raw)
        if f is not None and f.cmd in (p.CMD_CHUNK_MORE, p.CMD_CHUNK_LAST):
            if self.seen == self.chunk_index:
                body = bytearray(raw)
                body[9 + self.byte_offset] ^= 0x01   # stays 7-bit clean
                raw = bytes(body)
            self.seen += 1
        self.inner.send(raw)

    def receive(self, timeout):
        return self.inner.receive(timeout)

    def close(self):
        self.inner.close()


def main() -> None:
    preset = Preset(name="Akiko San", blob=blob7(7), meta=META)

    # ---- happy path: write + verify under reply lag (the default) ---------
    sim = SimulatedMicroFreak.factory_fresh()
    dev = make_device(sim)
    before = sim.peek(509)
    assert before.blob != preset.blob
    report = dev.write(509, preset)                 # verify=True is the default
    assert report.verified is True
    assert report.slot == 509 and report.name == "Akiko San"
    assert report.sha256 == preset.sha256
    after = sim.peek(509)
    assert after.blob == preset.blob and after.name == "Akiko San"
    assert after.sha256 == preset.sha256
    assert sim.faults == [], sim.faults             # payload[8]/[9] recomputed right
    print("PASS  verified write: blob lands byte-identical, read-back sha matches")

    # ---- the exact 7-frame sequence, in order (lag off for determinism) ---
    sim = SimulatedMicroFreak(reply_lag=False)
    fc = FakeClock()
    sess = Session(sim, clock=fc, sleep=fc.sleep)
    info = sess.write_preset(509, preset)
    assert info.slot == 509 and info.name == "Akiko San"
    out = [p.parse(raw) for d, raw in sim.wire_log if d == "out"]
    kinds = [(f.cmd, len(f.data)) for f in out]
    expected = ([(0x19, 3)]                          # 1: name read
                + [(0x52, 35)]                       # 2: name + meta
                + [(0x52, 3)]                        # 3: open blob write
                + [(0x15, 0)]                        # 4: go
                + [(0x16, 32)] * 145                 # 5: chunks, acked 0x18 each
                + [(0x17, 32)]                       # 6: last chunk
                + [(0x19, 3)])                       # 7: name read back
    assert kinds == expected, "write is not the verbatim 7-frame sequence"
    assert out[0].data == bytes([3, 125, 0])         # addresses only in 0x19/0x52
    assert out[2].data == bytes([3, 125, 1])
    assert out[3].data == b"" and out[3].seq == 0    # go: seq 0, len 0
    sent_blob = b"".join(f.data for f in out if f.cmd in (0x16, 0x17))
    assert sent_blob == preset.blob                  # chunks carry content only
    acks = sum(1 for d, raw in sim.wire_log if d == "in"
               for f in [p.parse(raw)] if f.cmd == p.CMD_NEXT)
    assert acks == 149, \
        "captured ack traffic: name 0x52 + open 0x52 + go + 146 chunks = 149"
    assert sim.peek(509).blob == preset.blob
    assert sim.faults == [], sim.faults
    print("PASS  wire shows write-protocol.md frames 1-7 verbatim; 149 x 0x18 acks")

    # ---- corrupted write MUST fail verification ---------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    wire = ChunkCorruptingTransport(sim, chunk_index=10, byte_offset=5)
    dev = make_device(wire)
    try:
        dev.write(509, preset)
        raise AssertionError("a corrupted write must fail verification")
    except VerifyMismatchError as e:
        assert e.slot == 509
        assert e.expected_sha256 == preset.sha256
        assert e.actual_sha256 is not None and e.actual_sha256 != preset.sha256
        assert e.first_difference == 10 * 32 + 5, e.first_difference
        assert e.expected_len == e.actual_len == p.BLOB_SIZE
    # the device really holds the corrupted byte — verification caught a
    # write that the ack stream alone would have called successful
    stored = sim.peek(509).blob
    assert stored[325] == preset.blob[325] ^ 0x01
    assert stored[:325] == preset.blob[:325] and stored[326:] == preset.blob[326:]
    print("PASS  one flipped bit in transit -> VerifyMismatchError, first_difference=325")

    # ---- verify=False is the explicit opt-out -----------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    wire = ChunkCorruptingTransport(sim, chunk_index=0, byte_offset=0)
    dev = make_device(wire)
    report = dev.write(509, preset, verify=False)
    assert report.verified is None                  # not True: nothing was checked
    assert sim.peek(509).blob != preset.blob        # the lie went undetected
    print("PASS  verify=False skips the read-back (verified=None) — opt-out is real")

    # ---- unacked chunk -> ChunkNotAckedError ------------------------------
    sim = SimulatedMicroFreak(reply_lag=False, fail_chunk_at=3)
    dev = make_device(sim)
    before = sim.peek(5).blob
    try:
        dev.write(5, preset)
        raise AssertionError("an unacked chunk must abort the write")
    except ChunkNotAckedError as e:
        assert e.slot == 5 and e.chunk_index == 3
    assert sim.peek(5).blob == before               # no commit, slot untouched
    print("PASS  missing 0x18 ack raises ChunkNotAckedError(slot, chunk 3)")

    # ---- rename: long 0x52 only, zero blob traffic ------------------------
    sim = SimulatedMicroFreak.factory_fresh()
    dev = make_device(sim)
    blob_before = sim.peek(42).blob
    mark = len(sim.wire_log)
    report = dev.rename(42, "New Name")
    assert report.verified is True and report.name == "New Name"
    assert report.sha256 == ""                      # no blob was sent
    assert sim.peek(42).name == "New Name"
    assert sim.peek(42).blob == blob_before
    sent = [p.parse(raw) for d, raw in sim.wire_log[mark:] if d == "out"]
    assert all(f.cmd not in (0x15, 0x16, 0x17) for f in sent), \
        "rename must never send go/chunk frames"
    assert sum(1 for f in sent if f.cmd == 0x52 and len(f.data) == 35) == 1
    assert sim.faults == [], sim.faults
    print("PASS  rename sends one long 0x52 + refresh reads; blob untouched")


if __name__ == "__main__":
    main()
