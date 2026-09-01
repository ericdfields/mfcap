"""MicroFreak SysEx frames - mfcap's capture-oriented view.

Since phase 1 the protocol itself lives in the `microfreak` core package:
`microfreak.protocol` is the single stateless codec, and
docs/write-protocol.md remains ground truth. This module is a thin shim that
delegates every wire fact to that codec and keeps only what the capture
harness adds on top:

- the timestamped, direction-tagged `Frame` that proxy captures and JSONL
  rows are built from;
- list-of-int frame builders (what rtmidi's send_message and the recorded
  hex rows historically used);
- `assemble` without the 4672-byte check - gate/replay tooling assembles
  partial and simulated dumps, while the librarian path
  (microfreak.protocol.assemble_blob) enforces the real blob size.

Frame layout: F0 00 20 6B 07 01 <seq> <len> <cmd> [data...] F7
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List, Optional, Tuple

from microfreak import protocol as _p

ARTURIA = list(_p.ARTURIA)
MICROFREAK = _p.MICROFREAK
PREFIX = list(_p.PREFIX)

CMD_OPEN = _p.CMD_OPEN
CMD_NEXT = _p.CMD_NEXT
CMD_CHUNK_MORE = _p.CMD_CHUNK_MORE
CMD_CHUNK_LAST = _p.CMD_CHUNK_LAST
CMD_GO = _p.CMD_GO
CMD_NAME = _p.CMD_NAME

CMD_NAMES = {
    0x19: "open",
    0x18: "next",
    0x16: "chunk+",
    0x17: "chunk.",
    0x52: "name",
}

SLOTS_PER_BANK = _p.SLOTS_PER_BANK

# Name position inside the long 0x52 payload (see microfreak.protocol).
NAME_OFFSET = _p.NAME_OFFSET


def addr(slot: int) -> Tuple[int, int]:
    """Slot number (0-based) -> (bank, position)."""
    return _p.addr(slot)


def frame(seq: int, length: int, cmd: int, data: Iterable[int] = ()) -> List[int]:
    return list(_p.frame(seq, length, cmd, data))


def read_name(seq: int, slot: int) -> List[int]:
    return list(_p.read_name_req(seq, slot))


def open_dump(seq: int, slot: int) -> List[int]:
    return list(_p.open_dump_req(seq, slot))


def next_chunk(seq: int) -> List[int]:
    return list(_p.pull_next_req(seq))


@dataclass
class Frame:
    """A parsed frame plus the capture metadata the harness records."""
    raw: bytes
    seq: int
    length: int
    cmd: int
    data: bytes
    direction: str = "?"     # "out" (to device) or "in" (from device)
    t: float = 0.0

    @property
    def is_microfreak(self) -> bool:
        return list(self.raw[:6]) == PREFIX

    def label(self) -> str:
        return CMD_NAMES.get(self.cmd, f"0x{self.cmd:02X}")

    def hex(self) -> str:
        return " ".join(f"{b:02X}" for b in self.raw)

    def pretty(self) -> str:
        arrow = "->" if self.direction == "out" else "<-"
        body = " ".join(f"{b:02X}" for b in self.data)
        return (f"{self.t:9.3f} {arrow} seq={self.seq:3d} len={self.length:02X} "
                f"{self.label():7s} {body}")


def parse(raw: "bytes | List[int]", direction: str = "?", t: float = 0.0) -> Optional[Frame]:
    f = _p.parse(bytes(raw))
    if f is None:
        return None
    return Frame(raw=f.raw, seq=f.seq, length=f.length, cmd=f.cmd, data=f.data,
                 direction=direction, t=t)


def decode_name(f: Frame) -> str:
    """Preset name out of a 0x52 reply. Printable ASCII, trimmed.

    Delegates to the core codec (verified against the hardware fixtures in
    tests/test_sysex.py; the core asserts parity with those same fixtures).
    """
    return _p._decode_name(bytes(f.data))


def assemble(chunks: Iterable[Frame]) -> bytes:
    """Concatenate dump chunk payloads into a blob.

    Deliberately does NOT enforce BLOB_SIZE: the gate and replay tooling
    assemble partial bursts and simulated (short) dumps. The librarian path
    uses microfreak.protocol.assemble_blob, which does enforce 4672.
    """
    out = bytearray()
    for c in chunks:
        out.extend(c.data)
    return bytes(out)


def digest(blob: bytes) -> str:
    return _p.digest(blob)
