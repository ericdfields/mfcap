"""protocol.py: builders and parsers round-trip, hardware fixtures decode,
name_write_frame recompute rules including the slot-384 boundary."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.errors import (BlobSizeError, InvalidNameError, ProtocolError,
                               SlotOutOfRangeError)

# Real 0x52 payloads captured from hardware (fw 5.x, 2026-09-01) — same
# fixtures as tests/test_sysex.py, re-asserted through decode_name_reply.
FIXTURES = [
    (0,   "00 00 00 08 00 00 00 00 00 00 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
    (8,   "00 08 00 00 00 00 00 00 08 00 02 32 4A 6A 6A 6A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Jjjj"),
    (40,  "00 28 00 00 00 00 00 00 28 00 05 33 54 72 61 70 70 65 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Trapped"),
    (200, "01 48 00 10 00 00 00 00 48 00 03 11 50 6C 61 79 20 43 68 6F 72 64 73 00 00 00 00 00 00 00 00 00 00 00 00", "Play Chords"),
    (511, "03 7F 00 18 00 00 00 00 7F 01 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
]


def hx(s):
    return bytes(int(b, 16) for b in s.split())


def main() -> None:
    # addressing
    assert p.addr(0) == (0, 0) and p.addr(511) == (3, 127) and p.addr(200) == (1, 72)
    assert p.slot_of(3, 127) == 511 and p.slot_of(1, 72) == 200
    for bad in (-1, 512, 10_000):
        try:
            p.addr(bad)
            raise AssertionError("addr(%r) should raise" % bad)
        except SlotOutOfRangeError as e:
            assert e.slot == bad
    try:
        p.slot_of(4, 0)
        raise AssertionError("slot_of(4,0) should raise")
    except SlotOutOfRangeError:
        pass
    print("PASS  addr/slot_of round-trip and range-check")

    # request builders — gate-verified literal byte sequences
    assert p.read_name_req(0x2A, 200) == hx("F0 00 20 6B 07 01 2A 03 19 01 48 00 F7")
    assert p.open_dump_req(0x2B, 200) == hx("F0 00 20 6B 07 01 2B 01 19 01 48 01 F7")
    assert p.pull_next_req(0x05) == hx("F0 00 20 6B 07 01 05 01 18 00 F7")
    assert p.open_write_frame(0x11, 511) == hx("F0 00 20 6B 07 01 11 03 52 03 7F 01 F7")
    assert p.go_frame() == hx("F0 00 20 6B 07 01 00 00 15 F7")
    print("PASS  request builders emit the gate-verified byte sequences")

    # hardware fixtures through parse + decode_name_reply
    for slot, hexstr, expected in FIXTURES:
        data = hx(hexstr)
        raw = p.PREFIX + bytes([0x00, 0x23, p.CMD_NAME]) + data + b"\xF7"
        f = p.parse(raw)
        assert f is not None and f.cmd == p.CMD_NAME
        info = p.decode_name_reply(f)
        assert info.slot == slot, (info.slot, slot)
        assert info.name == expected, (info.name, expected)
        assert info.meta == data[3:12] and len(info.meta) == p.META_LEN
        print("PASS  fixture slot %3d decodes name=%r meta=%s"
              % (slot, expected, info.meta.hex()))

    # name_write_frame recompute rules (payload[3] reply bit cleared,
    # payload[8]=pos, payload[9]=the constant 0x06 of every captured write)
    meta_200 = hx(FIXTURES[3][1])[3:12]      # meta captured at slot 200 (reply form)
    raw = p.name_write_frame(7, 511, "Akiko San", meta_200)
    f = p.parse(raw)
    assert f.length == 0x23 and len(f.data) == 35
    assert f.data[0] == 3 and f.data[1] == 0x7F and f.data[2] == 0x00
    assert f.data[3] == meta_200[0] & ~0x10      # reply-only 0x10 bit cleared
    assert f.data[4:8] == meta_200[1:5]          # opaque bytes verbatim
    assert f.data[8] == 0x7F                     # pos RECOMPUTED (meta[5] was 0x48)
    assert f.data[9] == 0x06                     # write constant (meta[6] ignored)
    assert f.data[10] == meta_200[7] and f.data[11] == meta_200[8]
    assert f.data[12:].split(b"\x00")[0] == b"Akiko San"
    info = p.decode_name_reply(f)                # the frame still decodes
    assert info.slot == 511 and info.name == "Akiko San"
    # payload[9] does NOT follow the reply-side 384 flag on writes
    assert p.parse(p.name_write_frame(1, 383, "X", meta_200)).data[9] == 0x06
    assert p.parse(p.name_write_frame(1, 384, "X", meta_200)).data[9] == 0x06
    assert p.parse(p.name_write_frame(1, 384, "X", meta_200)).data[8] == 384 % 128
    print("PASS  name_write_frame clears reply bit, recomputes payload[8], sends 0x06")

    try:
        p.name_write_frame(1, 0, "X", b"\x00" * 8)
        raise AssertionError("8-byte meta should raise")
    except ProtocolError:
        pass
    print("PASS  name_write_frame rejects bad meta length")

    # chunk frames
    blob = bytes(range(64)) * 73                 # 4672 bytes
    assert len(blob) == p.BLOB_SIZE
    frames = p.chunk_frames(blob)
    assert len(frames) == p.CHUNK_COUNT
    parsed = [p.parse(r) for r in frames]
    assert all(x.length == 0x20 and len(x.data) == 32 for x in parsed)
    assert all(x.cmd == p.CMD_CHUNK_MORE for x in parsed[:-1])
    assert parsed[-1].cmd == p.CMD_CHUNK_LAST
    assert p.assemble_blob(parsed) == blob
    try:
        p.chunk_frames(blob[:-1])
        raise AssertionError("short blob should raise")
    except BlobSizeError as e:
        assert e.expected == 4672 and e.actual == 4671
    try:
        p.assemble_blob(parsed[:-1])
        raise AssertionError("short assembly should raise")
    except BlobSizeError:
        pass
    print("PASS  chunk_frames: 145x0x16 + 1x0x17, 32 bytes each, reassembles")

    # parse rejects non-MicroFreak traffic
    assert p.parse(b"\xF0\x7E\x00\x06\x01\xF7") is None          # generic SysEx
    assert p.parse(b"\x90\x40\x40") is None                      # note on
    assert p.parse(b"") is None
    assert p.parse(p.PREFIX + b"\x01\x00\x15") is None           # no F7
    print("PASS  parse returns None for non-MicroFreak traffic")

    # decode_name_reply strictness
    short = p.parse(p.open_write_frame(1, 5))
    try:
        p.decode_name_reply(short)
        raise AssertionError("short 0x52 must not decode as a name reply")
    except ProtocolError:
        pass
    print("PASS  decode_name_reply rejects the short 0x52 form")

    # names
    assert p.validate_name("") == ""
    assert p.validate_name("A" * 23) == "A" * 23
    for bad in ("A" * 24, "umläut", "tab\tchar"):
        try:
            p.validate_name(bad)
            raise AssertionError("validate_name(%r) should raise" % bad)
        except InvalidNameError:
            pass
    print("PASS  validate_name enforces <=23 printable ASCII")

    assert p.NO_CHECKSUM is True
    print("PASS  no checksum exists, and the codec knows it")


if __name__ == "__main__":
    main()
