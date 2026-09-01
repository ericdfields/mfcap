"""microfreak.protocol: frame bytes checked literally against
docs/write-protocol.md, and name decode against the hardware 0x52 fixtures
(fw 5.x, 2026-09-01) from tests/test_sysex.py."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.errors import (BlobSizeError, InvalidNameError, ProtocolError,
                               SlotOutOfRangeError)


def hx(s: str) -> bytes:
    return bytes(int(b, 16) for b in s.split())


# (slot, raw data bytes of the 0x52 reply, expected name) — hardware captures,
# verbatim from tests/test_sysex.py.
FIXTURES = [
    (0,   "00 00 00 08 00 00 00 00 00 00 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
    (8,   "00 08 00 00 00 00 00 00 08 00 02 32 4A 6A 6A 6A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Jjjj"),
    (40,  "00 28 00 00 00 00 00 00 28 00 05 33 54 72 61 70 70 65 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Trapped"),
    (200, "01 48 00 10 00 00 00 00 48 00 03 11 50 6C 61 79 20 43 68 6F 72 64 73 00 00 00 00 00 00 00 00 00 00 00 00", "Play Chords"),
    (511, "03 7F 00 18 00 00 00 00 7F 01 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
]


def main() -> None:
    # --- request frames, byte-for-byte per docs/write-protocol.md ---------
    # envelope: F0 00 20 6B 07 01 <seq> <len> <cmd> [payload] F7
    assert p.read_name_req(5, 511) == hx("F0 00 20 6B 07 01 05 03 19 03 7F 00 F7")
    assert p.read_name_req(1, 0) == hx("F0 00 20 6B 07 01 01 03 19 00 00 00 F7")
    print("PASS  name read is 0x19 len 0x03 [bank, pos, 0x00]")

    assert p.open_dump_req(2, 200) == hx("F0 00 20 6B 07 01 02 01 19 01 48 01 F7")
    print("PASS  dump open is 0x19 len 0x01 [bank, pos, 0x01]")

    assert p.pull_next_req(3) == hx("F0 00 20 6B 07 01 03 01 18 00 F7")
    print("PASS  pull-next is 0x18 len 0x01 [0x00]")

    assert p.open_write_frame(9, 509) == hx("F0 00 20 6B 07 01 09 03 52 03 7D 01 F7")
    print("PASS  open-write is the short 0x52 len 0x03 [bank, pos, 0x01]")

    assert p.go_frame() == hx("F0 00 20 6B 07 01 00 00 15 F7")
    print("PASS  go is 0x15 with seq 0, len 0, empty payload")

    # --- chunking: 145 x 0x16 + 1 x 0x17, 32 bytes each, no addresses -----
    blob = bytes((i * 7 + 13) % 128 for i in range(p.BLOB_SIZE))
    frames = p.chunk_frames(blob)
    assert len(frames) == p.CHUNK_COUNT == 146
    # chunk seqs continue from the go frame's 0: 1..127, wrap through 0, ..18
    assert frames[0] == p.PREFIX + bytes([0x01, 0x20, 0x16]) + blob[:32] + b"\xF7"
    assert frames[-1] == p.PREFIX + bytes([146 % 128, 0x20, 0x17]) + blob[-32:] + b"\xF7"
    assert [p.parse(f).seq for f in frames] == [(i + 1) % 128 for i in range(146)]
    for f in frames[:-1]:
        assert f[8] == p.CMD_CHUNK_MORE and f[7] == 0x20 and len(f) == 42
    assert frames[-1][8] == p.CMD_CHUNK_LAST
    reassembled = p.assemble_blob([p.parse(f) for f in frames])
    assert reassembled == blob
    print("PASS  chunk frames: 145 x 0x16 + 1 x 0x17, 32 bytes each, len 0x20")
    print("PASS  146 x 32 = 4672 bytes reassemble to the original blob")

    try:
        p.chunk_frames(blob[:-1])
        raise AssertionError("short blob must be rejected")
    except BlobSizeError as e:
        assert e.expected == 4672 and e.actual == 4671
    try:
        p.assemble_blob([p.parse(f) for f in frames[:-1]])
        raise AssertionError("incomplete chunk set must be rejected")
    except BlobSizeError:
        pass
    print("PASS  blob size is enforced both chunking and assembling")

    # --- hardware fixtures through decode_name_reply ----------------------
    for slot, hexstr, expected in FIXTURES:
        data = hx(hexstr)
        raw = p.PREFIX + bytes([0x00, 0x23, p.CMD_NAME]) + data + b"\xF7"
        f = p.parse(raw)
        assert f is not None and f.cmd == p.CMD_NAME and len(f.data) == 35
        info = p.decode_name_reply(f)
        assert info.slot == slot, (info.slot, slot)
        assert info.name == expected, (info.name, expected)
        assert info.meta == data[3:12] and len(info.meta) == p.META_LEN
        print(f"PASS  slot {slot:3d} hardware 0x52 decodes to "
              f"{expected!r} + slot + 9 meta bytes")

    # --- encode over the same hardware bytes: the direction transform ------
    # The fixtures are REPLIES. Re-encoding their decoded fields as a write
    # must apply the captured reply->write transform (c2's read/write pairs):
    # payload[3] drops the reply-only 0x10 bit, payload[8] is the pos,
    # payload[9] becomes the constant 0x06, everything else verbatim.
    for slot, hexstr, expected in FIXTURES:
        data = hx(hexstr)
        f = p.parse(p.PREFIX + bytes([0x00, 0x23, p.CMD_NAME]) + data + b"\xF7")
        info = p.decode_name_reply(f)
        rb = p.parse(p.name_write_frame(0, slot, info.name, info.meta)).data
        assert rb[0:3] == data[0:3]
        assert rb[3] == data[3] & ~0x10, f"slot {slot}: reply bit not cleared"
        assert rb[4:8] == data[4:8]
        assert rb[8] == slot % 128
        assert rb[9] == 0x06, f"slot {slot}: write payload[9] must be 0x06"
        assert rb[10:] == data[10:]
    print("PASS  decode -> name_write_frame applies the captured reply->write")
    print("PASS     transform (payload[3] & ~0x10, payload[9]=0x06) on all 5 fixtures")

    # retarget: slot-200 meta written to slot 511 must recompute the
    # positional byte and carry the rest verbatim (modulo the direction bits)
    meta200 = hx(FIXTURES[3][1])[3:12]
    raw = p.name_write_frame(7, 511, "Play Chords", meta200)
    f = p.parse(raw)
    assert f.data[0] == 3 and f.data[1] == 0x7F        # new address
    assert f.data[8] == 0x7F, "payload[8] must be recomputed to the new pos"
    assert f.data[9] == 0x06, "outbound payload[9] is 0x06 for every slot"
    assert f.data[3] == meta200[0] & ~0x10             # reply bit cleared
    assert f.data[4:8] == meta200[1:5]                 # opaque bytes verbatim
    assert f.data[10] == meta200[7] and f.data[11] == meta200[8]
    assert p.decode_name_reply(f).slot == 511
    print("PASS  retargeting recomputes payload[8], keeps opaque meta verbatim")

    # --- parser rejects non-MicroFreak traffic ----------------------------
    assert p.parse(b"") is None
    assert p.parse(b"\xF0\x7E\x00\x06\x01\xF7") is None            # other vendor
    assert p.parse(hx("F0 00 20 6B 06 01 00 03 19 00 00 00 F7")) is None  # wrong device id
    assert p.parse(hx("F0 00 20 6B 07 01 00 03 19 00 00 00")) is None     # no F7
    print("PASS  parse() returns None for foreign or truncated traffic")

    # --- addressing and validation ----------------------------------------
    assert p.addr(0) == (0, 0) and p.addr(511) == (3, 127)
    assert p.addr(200) == (1, 72) and p.slot_of(1, 72) == 200
    for s in range(0, 512, 7):
        assert p.slot_of(*p.addr(s)) == s
    for bad in (-1, 512, 4672):
        try:
            p.addr(bad)
            raise AssertionError(f"slot {bad} must be out of range")
        except SlotOutOfRangeError:
            pass
    print("PASS  addr()/slot_of() are inverses; out-of-range slots rejected")

    try:
        p.validate_name("x" * 24)
        raise AssertionError("24-char name must be rejected")
    except InvalidNameError:
        pass
    try:
        p.validate_name("café")
        raise AssertionError("non-ASCII name must be rejected")
    except InvalidNameError:
        pass
    assert p.validate_name("Akiko San") == "Akiko San"
    try:
        p.name_write_frame(1, 0, "Init", b"\x00" * 8)
        raise AssertionError("8-byte meta must be rejected")
    except ProtocolError:
        pass
    print("PASS  name and meta validation reject bad inputs")

    assert p.NO_CHECKSUM is True
    print("PASS  NO_CHECKSUM stands: the protocol has none to compute")


if __name__ == "__main__":
    main()
