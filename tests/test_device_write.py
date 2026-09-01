"""MicroFreak.write: the 7-frame gate-verified sequence on the wire,
verification on/off, VerifyMismatchError, ChunkNotAckedError, rename
preserving meta+blob, and cancellation."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.device import MicroFreak
from microfreak.errors import (ChunkNotAckedError, OperationCancelledError,
                               VerifyMismatchError)
from microfreak.model import CancelToken, Preset
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
    """A device that flips one bit of anything committed to bad_slots —
    exactly what verification exists to catch."""

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


def source_preset(sim, slot):
    return sim.peek(slot)


def main() -> None:
    donor = SimulatedMicroFreak.factory_fresh()
    preset = source_preset(donor, 5).renamed("Akiko San")

    # --- the 7-frame sequence, byte-order asserted on the wire ------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    dev = make_device(sim)
    report = dev.write(200, preset, verify=False)      # end log at frame 7
    host = [p.parse(raw) for d, raw in sim.wire_log if d == "out"]
    cmds = [f.cmd for f in host]
    assert cmds[0] == p.CMD_OPEN and host[0].data[2] == 0x00      # 1 name read
    assert cmds[1] == p.CMD_NAME and len(host[1].data) == 35      # 2 long 0x52
    assert cmds[2] == p.CMD_NAME and host[2].data[2] == 0x01      # 3 open write
    assert cmds[3] == p.CMD_GO and host[3].seq == 0               # 4 go
    assert cmds[4:149] == [p.CMD_CHUNK_MORE] * 145                # 5 chunks
    assert cmds[149] == p.CMD_CHUNK_LAST                          # 6 last chunk
    assert cmds[150] == p.CMD_OPEN and host[150].data[2] == 0x00  # 7 read back
    assert len(host) == 151
    addressed = [f for f in host if f.cmd in (p.CMD_OPEN, p.CMD_NAME)]
    assert all(f.data[0] == 1 and f.data[1] == 72 for f in addressed)
    acks = [f for d, raw in sim.wire_log if d == "in"
            for f in [p.parse(raw)] if f.cmd == p.CMD_NEXT]
    assert len(acks) == 149          # name 0x52 + open 0x52 + go + 146 chunks
    assert sim.faults == [], sim.faults
    assert report.verified is None and report.sha256 == preset.sha256
    assert sim.peek(200).blob == preset.blob
    assert sim.peek(200).name == "Akiko San"
    print("PASS  write emits exactly the 7-frame gate-verified sequence")
    print("PASS  149 acks as captured (3 control + 146 chunks); verified=None on opt-out")

    # --- verified write under reply-lag (the default) ---------------------
    sim = SimulatedMicroFreak.factory_fresh()          # lag ON
    dev = make_device(sim)
    report = dev.write(509, preset, verify=True)
    assert report.verified is True and report.slot == 509
    assert sim.peek(509).blob == preset.blob
    assert sim.faults == [], sim.faults
    print("PASS  verified write succeeds under reply-lag")

    # --- a corrupting device fails verification, loudly -------------------
    sim = CorruptingSim([300], reply_lag=False)
    dev = make_device(sim)
    try:
        dev.write(300, preset)
        raise AssertionError("corrupted write must fail verification")
    except VerifyMismatchError as e:
        assert e.slot == 300
        assert e.expected_sha256 == preset.sha256
        assert e.actual_sha256 not in (None, preset.sha256)
        assert e.first_difference == 0
        assert e.expected_len == p.BLOB_SIZE and e.actual_len == p.BLOB_SIZE
    print("PASS  corrupted read-back raises VerifyMismatchError (first_difference=0)")

    # --- missing ack -> ChunkNotAckedError, slot not committed ------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False, fail_chunk_at=10)
    dev = make_device(sim)
    before = sim.peek(400).blob
    try:
        dev.write(400, preset)
        raise AssertionError("missing ack must raise")
    except ChunkNotAckedError as e:
        assert e.slot == 400 and e.chunk_index == 10
    assert sim.peek(400).blob == before, "torn write must not commit"
    print("PASS  no 0x18 ack raises ChunkNotAckedError(slot, chunk_index=10)")

    # --- rename preserves meta and blob ------------------------------------
    sim = SimulatedMicroFreak.factory_fresh()          # lag ON
    dev = make_device(sim)
    before = sim.peek(40)
    report = dev.rename(40, "Trapped II")
    after = sim.peek(40)
    assert report.verified is True and report.sha256 == ""
    assert after.name == "Trapped II"
    assert after.blob == before.blob, "rename must not touch the blob"
    assert after.meta == before.meta, "rename must round-trip meta verbatim"
    chunk_frames = [1 for d, raw in sim.wire_log if d == "out"
                    and p.parse(raw).cmd in (p.CMD_CHUNK_MORE, p.CMD_CHUNK_LAST)]
    assert not chunk_frames, "rename must produce no blob traffic"
    assert sim.faults == [], sim.faults
    print("PASS  rename changes only the name: meta and blob untouched, no chunks")

    # --- cancellation ------------------------------------------------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    dev = make_device(sim)
    token = CancelToken()
    token.cancel()
    before = sim.peek(100).blob
    try:
        dev.write(100, preset, cancel=token)
        raise AssertionError("pre-cancelled write must raise")
    except OperationCancelledError as e:
        assert e.done == 0 and e.total == p.CHUNK_COUNT
    assert sim.peek(100).blob == before
    print("PASS  cancelled write raises OperationCancelledError before chunk 0")

    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    dev = make_device(sim)
    token = CancelToken()
    seen = []

    def cancel_after_three(ev):
        seen.append(ev.slot)
        if ev.done == 3:
            token.cancel()

    try:
        dev.snapshot(read_blobs=False, slots=range(10),
                     progress=cancel_after_three, cancel=token)
        raise AssertionError("cancelled snapshot must raise")
    except OperationCancelledError as e:
        assert e.done == 3 and e.total == 10
    assert seen == [0, 1, 2]
    print("PASS  cancelled snapshot raises OperationCancelledError(done=3, total=10)")


if __name__ == "__main__":
    main()
