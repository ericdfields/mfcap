"""MicroFreak SysEx frames.

Frame layout (francoisgeorgy/microfreak-reverse):

    F0 00 20 6B 07 01 <seq> <len> <cmd> [data...] F7
       |________| |
       Arturia    MicroFreak device id = 0x07

Known commands
    0x19  open: preset name read (trailer 0x00) / preset dump (trailer 0x01)
    0x18  pull next dump chunk
    0x16  reply: chunk, more to come
    0x17  reply: chunk, last one
    0x52  reply: preset name

The <len> byte does not obviously equal the payload length in the published
notes (name reads use 0x03, dump opens use 0x01). We reproduce the documented
byte sequences literally and treat <len> as opaque until a capture proves what
it means. LEN_IS_UNVERIFIED marks every place that assumption lives.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Iterable, List, Optional

ARTURIA = [0x00, 0x20, 0x6B]
MICROFREAK = 0x07
PREFIX = [0xF0] + ARTURIA + [MICROFREAK, 0x01]

CMD_OPEN = 0x19
CMD_NEXT = 0x18
CMD_CHUNK_MORE = 0x16
CMD_CHUNK_LAST = 0x17
CMD_NAME = 0x52

CMD_NAMES = {
    0x19: "open",
    0x18: "next",
    0x16: "chunk+",
    0x17: "chunk.",
    0x52: "name",
}

LEN_IS_UNVERIFIED = True
SLOTS_PER_BANK = 128


def addr(slot: int) -> tuple[int, int]:
    """Slot number (0-based) -> (bank, position)."""
    return slot // SLOTS_PER_BANK, slot % SLOTS_PER_BANK


def frame(seq: int, length: int, cmd: int, data: Iterable[int] = ()) -> List[int]:
    return PREFIX + [seq & 0x7F, length & 0x7F, cmd & 0x7F] + [b & 0x7F for b in data] + [0xF7]


def read_name(seq: int, slot: int) -> List[int]:
    bank, pos = addr(slot)
    return frame(seq, 0x03, CMD_OPEN, [bank, pos, 0x00])


def open_dump(seq: int, slot: int) -> List[int]:
    bank, pos = addr(slot)
    return frame(seq, 0x01, CMD_OPEN, [bank, pos, 0x01])


def next_chunk(seq: int) -> List[int]:
    return frame(seq, 0x01, CMD_NEXT, [0x00])


@dataclass
class Frame:
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


def parse(raw: bytes | List[int], direction: str = "?", t: float = 0.0) -> Optional[Frame]:
    b = bytes(raw)
    if len(b) < 9 or b[0] != 0xF0 or b[-1] != 0xF7:
        return None
    if list(b[1:5]) != ARTURIA + [MICROFREAK]:
        return None
    return Frame(raw=b, seq=b[6], length=b[7], cmd=b[8], data=b[9:-1],
                 direction=direction, t=t)


def decode_name(f: Frame) -> str:
    """Preset name out of a 0x52 reply. Printable ASCII, trimmed."""
    chars = [chr(c) for c in f.data if 0x20 <= c < 0x7F]
    return "".join(chars).strip()


def decode_param(msb: int, mid: int, lsb: int, negative: bool = False) -> float:
    """15-bit value -> the 0-100 the MicroFreak screen shows.

    The published notes carry the sign outside these three bytes, so the caller
    passes it in. Do not infer sign from bit 14 until a capture confirms it.
    """
    raw = (msb << 8) + (mid << 7) + lsb
    if negative:
        raw = (((~raw) & 0x7FFF) + 1)
        raw = -raw
    return round(raw * 1000 / 32768) / 10


def assemble(chunks: Iterable[Frame]) -> bytes:
    """Concatenate dump chunk payloads into the preset blob."""
    out = bytearray()
    for c in chunks:
        out.extend(c.data)
    return bytes(out)


def digest(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()
