"""End-to-end test of replay + gate against a simulated MicroFreak.

The simulator speaks the documented READ protocol and a plausible invented
WRITE protocol (open / chunk / commit with a sum checksum). The point is not to
guess Arturia's real write frames - it is to prove that once a capture exists,
`replay()` retargets it correctly and `run_gate()` reaches a correct verdict.
"""
import hashlib
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mfcap import sysex as sx, verify as vf


class FakeFreak:
    """512 slots, documented reads, invented writes."""

    def __init__(self, chunk=32, blob_len=160):
        self.slots = {}
        self.chunk = chunk
        self.blob_len = blob_len
        self._dump = None
        self._write = None
        self.last_rx = 1.0

    def load(self, slot, blob):
        self.slots[slot] = bytes(blob)

    # --- interface used by Reader / replay ---
    def drain(self):
        return []

    def quiet_for(self):
        return 0.0

    def send(self, msg):
        self._handle(bytes(msg))

    def ask(self, msg, want=None, timeout=1.5):
        return self._handle(bytes(msg))

    def _reply(self, cmd, data, seq=1):
        return sx.parse(sx.frame(seq, len(data), cmd, data), direction="in")

    def _handle(self, b):
        f = sx.parse(b, direction="out")
        if f is None:
            return []
        d = list(f.data)

        if f.cmd == sx.CMD_OPEN and len(d) >= 3:
            slot = d[0] * 128 + d[1]
            if d[2] == 0x00:                       # name read
                name = f"SLOT{slot:03d}"
                return [self._reply(sx.CMD_NAME, [ord(c) for c in name])]
            blob = self.slots.get(slot)
            if blob is None:
                return []
            self._dump = (list(blob), 0)
            return self._chunk()

        if f.cmd == sx.CMD_NEXT:
            return self._chunk()

        # invented write protocol
        if f.cmd == 0x1A and len(d) >= 3:
            self._write = (d[0] * 128 + d[1], bytearray())
            return []
        if f.cmd == 0x1B and self._write is not None:
            body = d[:-1]
            if (sum(body) & 0x7F) != d[-1]:
                self._write = None                 # bad checksum, refuse
                return []
            self._write[1].extend(body)
            return []
        if f.cmd == 0x1C and self._write is not None:
            slot = d[0] * 128 + d[1]
            self.slots[slot] = bytes(self._write[1][:self.blob_len])
            self._write = None
            return []
        return []

    def _chunk(self):
        if self._dump is None:
            return []
        blob, i = self._dump
        part = blob[i:i + self.chunk]
        i += self.chunk
        last = i >= len(blob)
        self._dump = None if last else (blob, i)
        return [self._reply(sx.CMD_CHUNK_LAST if last else sx.CMD_CHUNK_MORE, part)]


def make_capture(slot, blob, chunk=32):
    """What a capture of MCC writing `blob` to `slot` would look like."""
    import json
    bank, pos = sx.addr(slot)
    rows, t = [], 0.0

    def emit(cmd, data, seq):
        nonlocal t
        body = list(data) + [sum(data) & 0x7F]
        msg = sx.frame(seq, len(body), cmd, body)
        rows.append({"t": round(t, 4), "dir": "out",
                     "hex": " ".join(f"{b:02X}" for b in msg),
                     "len": len(msg), "seq": seq, "lenbyte": len(body),
                     "cmd": cmd, "cmd_name": "?"})
        t += 0.01

    emit(0x1A, [bank, pos, 0x01], 1)
    for i in range(0, len(blob), chunk):
        emit(0x1B, list(blob[i:i + chunk]), 2 + i // chunk)
    emit(0x1C, [bank, pos, 0x00], 99)
    return rows


def test_gate_passes():
    random.seed(11)
    blob = bytes(random.randint(0, 127) for _ in range(160))
    dev = FakeFreak()
    dev.load(509, blob)                      # what MCC wrote
    rows = make_capture(509, blob)           # what we captured it doing
    rewrites = [vf.Rewrite(0, 1, "position"), vf.Rewrite(len(rows) - 1, 1, "position")]

    out = Path("/tmp/mfgate")
    logs = []
    result = vf.run_gate(dev, rows, source_slot=509, scratch_slot=511,
                         rewrites=rewrites, out_dir=out, log=logs.append)
    assert result["passed"], result
    assert dev.slots[511] == blob, "replay did not land in the retargeted slot"
    assert result["expected_sha256"] == hashlib.sha256(blob).hexdigest()
    return result


def test_gate_catches_a_wrong_rewrite():
    """A bad rewrite map must FAIL the gate, not quietly pass it."""
    random.seed(12)
    blob = bytes(random.randint(0, 127) for _ in range(160))
    dev = FakeFreak()
    dev.load(509, blob)
    rows = make_capture(509, blob)
    bad = [vf.Rewrite(0, 1, "position")]     # commit frame left pointing at 509
    result = vf.run_gate(dev, rows, 509, 511, bad, Path("/tmp/mfgate2"), lambda s: None)
    assert not result["passed"], "gate passed with a broken rewrite map"
    return result


if __name__ == "__main__":
    r1 = test_gate_passes()
    print("PASS  gate reaches a correct verdict:", r1["readback_sha256"][:16], "...")
    r2 = test_gate_catches_a_wrong_rewrite()
    print("PASS  gate rejects a bad rewrite map:", r2["stage"])
