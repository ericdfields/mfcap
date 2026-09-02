"""Wire constants and the pure, stateless codec. No I/O anywhere in here.

Ground truth: docs/write-protocol.md (decoded and gate-verified 2026-09-01
against firmware 5.x hardware). Frame envelope:

    F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7

The <len> bytes: name read 0x03, pull-next 0x01 with payload [0x00], chunks
0x20, long 0x52 0x23, short 0x52 0x03, go 0x00 — all gate-verified literals.
The dump-open 0x01 is the phase-0 value (archived francoisgeorgy notes,
proven on hardware by full 512-slot backups); MCC's own captured dump open
carries len 0x03 (= payload length) and the device accepts both.

Address invariant, structural: no function in this module accepts or returns
a slot for a chunk frame; chunk builders and parsers have no address
parameters. A chunk payload may coincidentally begin `03 7F` — pattern
matching an address inside a chunk is not expressible against this API.

No checksum exists anywhere in the protocol; nothing here computes one.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Tuple

from .errors import (BlobSizeError, InvalidNameError, ProtocolError,
                     SlotOutOfRangeError)

ARTURIA = (0x00, 0x20, 0x6B)
MICROFREAK = 0x07
PREFIX = bytes([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01])   # F0 + Arturia + device id + 0x01

CMD_OPEN = 0x19        # name read (trailer 0x00) / dump open (trailer 0x01)
CMD_NEXT = 0x18        # pull next chunk (reads); device's per-chunk ack (writes)
CMD_CHUNK_MORE = 0x16
CMD_CHUNK_LAST = 0x17
CMD_GO = 0x15          # write "go": seq 0, len 0, empty payload
CMD_NAME = 0x52        # long form: name+meta (35B); short form [bank,pos,0x01]: open write

SLOTS = 512
SLOTS_PER_BANK = 128
HIGH_BANK_BOUNDARY = 384       # REPLY payload[9]: 0 below, 1 at/above (writes: 0x06)
WRITE_PAYLOAD9 = 0x06          # payload[9] in every captured outbound long 0x52
REPLY_META_FLAG = 0x10         # payload[3] bit set by the device in replies for
                               # slots >= 128; clear in every captured outbound write
BLOB_SIZE = 4672               # 146 x 32; the blob you write is the blob you read
CHUNK_SIZE = 32
CHUNK_COUNT = 146
NAME_PAYLOAD_LEN = 35          # long 0x52: 12-byte header + 23-byte name
NAME_OFFSET = 12
NAME_LEN = 23
META_LEN = 9                   # long-0x52 payload[3..11]
DUPLICATE_THRESHOLD = 3        # content-based expendability (3, not 2)
NO_CHECKSUM = True             # documented fact; nothing to compute, ever


@dataclass(frozen=True)
class Frame:
    raw: bytes
    seq: int
    length: int
    cmd: int
    data: bytes


@dataclass(frozen=True)
class NameInfo:
    """Decoded long-0x52 payload."""
    slot: int          # from payload[0:2] — the reply-lag matching key
    name: str
    meta: bytes        # META_LEN bytes = payload[3..11], verbatim


# ------------------------------------------------------------- addressing

def addr(slot: int) -> Tuple[int, int]:
    """Slot number (0-based) -> (bank, position)."""
    if not isinstance(slot, int) or not 0 <= slot < SLOTS:
        raise SlotOutOfRangeError(slot)
    return slot // SLOTS_PER_BANK, slot % SLOTS_PER_BANK


def slot_of(bank: int, pos: int) -> int:
    """(bank, position) -> slot number. Inverse of addr()."""
    if not 0 <= pos < SLOTS_PER_BANK or bank < 0:
        raise SlotOutOfRangeError(bank * SLOTS_PER_BANK + pos)
    slot = bank * SLOTS_PER_BANK + pos
    if slot >= SLOTS:
        raise SlotOutOfRangeError(slot)
    return slot


# ----------------------------------------------------------------- frames

def frame(seq: int, length: int, cmd: int, data: Iterable[int] = ()) -> bytes:
    """One complete SysEx message F0..F7. All payload bytes masked to 7 bits."""
    body = bytes([seq & 0x7F, length & 0x7F, cmd & 0x7F])
    body += bytes(b & 0x7F for b in data)
    return PREFIX + body + b"\xF7"


# ------------------------------------------------------- request builders
# seq is always explicit; this module counts nothing.

def read_name_req(seq: int, slot: int) -> bytes:
    bank, pos = addr(slot)
    return frame(seq, 0x03, CMD_OPEN, [bank, pos, 0x00])


def open_dump_req(seq: int, slot: int) -> bytes:
    bank, pos = addr(slot)
    return frame(seq, 0x01, CMD_OPEN, [bank, pos, 0x01])


def pull_next_req(seq: int) -> bytes:
    return frame(seq, 0x01, CMD_NEXT, [0x00])


def name_write_frame(seq: int, slot: int, name: str, meta: bytes) -> bytes:
    """THE single composer of address-derived header bytes.

    The long-0x52 payload is direction-dependent (every captured MCC write in
    c2/c3/c4 vs. every captured reply). Outbound payload:

        [0]=bank [1]=pos [2]=0x00
        [3]     = meta[0] & ~0x10         (REPLY_META_FLAG cleared: the device
                                           sets 0x10 here in replies for slots
                                           >= 128; no captured outbound write
                                           ever carries it)
        [4..7]  = meta[1..4]              (opaque, round-tripped verbatim)
        [8]     = pos                     (RECOMPUTED for the target slot; meta[5] ignored)
        [9]     = 0x06                    (WRITE_PAYLOAD9, constant in all captured
                                           writes; meta[6] — the reply-side 0/1
                                           slot-384 flag — ignored)
        [10]    = meta[7]  [11] = meta[8] (category / attribute, verbatim)
        [12..34]= name, ASCII, NUL-padded to 23
    """
    bank, pos = addr(slot)
    validate_name(name)
    if not isinstance(meta, (bytes, bytearray)) or len(meta) != META_LEN:
        raise ProtocolError(
            f"meta must be {META_LEN} bytes, got "
            f"{len(meta) if isinstance(meta, (bytes, bytearray)) else type(meta).__name__}")
    if any(b > 0x7F for b in meta):
        raise ProtocolError("meta contains non-7-bit bytes")
    field = name.encode("ascii")
    field += b"\x00" * (NAME_LEN - len(field))
    payload = (bytes([bank, pos, 0x00, meta[0] & ~REPLY_META_FLAG])
               + bytes(meta[1:5])
               + bytes([pos, WRITE_PAYLOAD9, meta[7], meta[8]])
               + field)
    assert len(payload) == NAME_PAYLOAD_LEN
    return frame(seq, 0x23, CMD_NAME, payload)


def open_write_frame(seq: int, slot: int) -> bytes:
    """Short 0x52 [bank, pos, 0x01]: open blob write to (bank, pos)."""
    bank, pos = addr(slot)
    return frame(seq, 0x03, CMD_NAME, [bank, pos, 0x01])


def go_frame() -> bytes:
    """Write 'go': seq 0, len 0, empty payload."""
    return frame(0, 0x00, CMD_GO)


def chunk_frames(blob: bytes) -> List[bytes]:
    """145 x 0x16 + 1 x 0x17, each carrying exactly 32 content bytes.

    Chunk seq bytes reproduce every captured write burst: the go frame
    carries seq 0 and the chunks continue from it — 1, 2, .., 127, 0, 1, ..
    (mod 128, wrapping THROUGH 0). Chunk i therefore carries (i + 1) % 128.
    This stream is separate from the session's addressed-request counter
    (which walks 1..127 and never emits 0).

    Chunks carry no address, by design — see the module docstring.
    """
    if len(blob) != BLOB_SIZE:
        raise BlobSizeError(BLOB_SIZE, len(blob))
    bad = next((i for i, b in enumerate(blob) if b > 0x7F), None)
    if bad is not None:
        # frame() masks to 7 bits, so letting this through would silently
        # alter the content on the wire; reject the input instead
        raise ProtocolError(
            f"blob byte {bad} is 0x{blob[bad]:02X}: SysEx content must be "
            "7-bit clean")
    out: List[bytes] = []
    for i in range(CHUNK_COUNT):
        piece = blob[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]
        cmd = CMD_CHUNK_LAST if i == CHUNK_COUNT - 1 else CMD_CHUNK_MORE
        out.append(frame((i + 1) % 128, 0x20, cmd, piece))
    return out


# ---------------------------------------------------------------- parsers

def parse(raw: bytes) -> Optional[Frame]:
    """Parse one SysEx message; None for non-MicroFreak traffic."""
    b = bytes(raw)
    if len(b) < 10 or b[0] != 0xF0 or b[-1] != 0xF7:
        return None
    if b[:6] != PREFIX:      # full 6-byte prefix, incl. the trailing 0x01 —
        return None          # matches phase-0 Frame.is_microfreak exactly
    return Frame(raw=b, seq=b[6], length=b[7], cmd=b[8], data=b[9:-1])


def decode_name_reply(f: Frame) -> NameInfo:
    """Decode the long-0x52 payload (a reply or an outbound name write)."""
    if f.cmd != CMD_NAME or len(f.data) != NAME_PAYLOAD_LEN:
        raise ProtocolError(
            f"not a long 0x52 name frame: cmd=0x{f.cmd:02X} len={len(f.data)}")
    slot = slot_of(f.data[0], f.data[1])
    return NameInfo(slot=slot, name=_decode_name(f.data),
                    meta=bytes(f.data[3:NAME_OFFSET]))


def _decode_name(data: bytes) -> str:
    """Name out of a 35-byte long-0x52 payload. Printable ASCII, trimmed.

    Matches mfcap.sysex.decode_name exactly (verified against hardware
    fixtures): data[12:] split at the first NUL, printable-filtered, stripped.
    """
    body = data[NAME_OFFSET:].split(b"\x00")[0]
    chars = [chr(c) for c in body if 0x20 <= c < 0x7F]
    return "".join(chars).strip()


def is_chunk(f: Frame) -> bool:
    return f.cmd in (CMD_CHUNK_MORE, CMD_CHUNK_LAST)


def is_last_chunk(f: Frame) -> bool:
    return f.cmd == CMD_CHUNK_LAST


def is_ack(f: Frame) -> bool:
    return f.cmd == CMD_NEXT


def assemble_blob(chunks: Sequence[Frame]) -> bytes:
    """Concatenate chunk payloads into the preset blob; must total 4672."""
    out = bytearray()
    for c in chunks:
        out.extend(c.data)
    if len(out) != BLOB_SIZE:
        raise BlobSizeError(BLOB_SIZE, len(out))
    return bytes(out)


# ------------------------------------------------ channel messages (non-SysEx)
# The MicroFreak switches presets on MIDI Program Change ("Program Change
# Receive", user manual §MicroFreak Configuration — it can be turned off there).
# 512 presets = 4 banks x 128: Bank Select then Program Change. The manual does
# not state whether the device reads the MSB (CC0) or LSB (CC32) bank byte, so
# both carry the bank index (0..3); with only four banks no device combines
# them. HARDWARE-CONFIRMABLE in one try; see docs/arturia-taxonomy.md.

CC_BANK_MSB = 0x00
CC_BANK_LSB = 0x20


def control_change(channel: int, controller: int, value: int) -> bytes:
    return bytes([0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F])


def program_change(channel: int, program: int) -> bytes:
    return bytes([0xC0 | (channel & 0x0F), program & 0x7F])


def select_preset_messages(slot: int, channel: int = 0) -> List[bytes]:
    """The short MIDI messages that make the device load `slot` (0-based)."""
    bank, pos = addr(slot)
    return [control_change(channel, CC_BANK_MSB, bank),
            control_change(channel, CC_BANK_LSB, bank),
            program_change(channel, pos)]


def digest(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def validate_name(name: str) -> str:
    """<= 23 printable-ASCII characters, no leading/trailing whitespace;
    returns the name unchanged.

    Leading/trailing spaces are rejected because name replies are decoded
    stripped (_decode_name), so such a name can never round-trip — a
    verified write of 'Foo ' would always fail its read-back comparison
    even though the device write succeeded."""
    if not isinstance(name, str):
        raise InvalidNameError(f"name must be str, got {type(name).__name__}")
    if len(name) > NAME_LEN:
        raise InvalidNameError(f"name is {len(name)} chars, max {NAME_LEN}")
    if name != name.strip():
        raise InvalidNameError(
            f"name {name!r} has leading/trailing whitespace, which cannot "
            "round-trip through the device (replies decode stripped)")
    for ch in name:
        if not 0x20 <= ord(ch) < 0x7F:
            raise InvalidNameError(f"non-printable/non-ASCII character {ch!r} in name")
    return name
