"""Name decode against the hardware-captured 0x52 payloads (12-byte header +
23-byte name), byte-parity with mfcap.sysex.decode_name, and the header-leak
regression (printable attribute bytes must never reach the name)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mfcap import sysex as sx
from microfreak import protocol as p

# Real 0x52 reply payloads captured from hardware (fw 5.x, 2026-09-01) —
# identical to the fixtures in tests/test_sysex.py.
FIXTURES = [
    (0,   "00 00 00 08 00 00 00 00 00 00 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
    (8,   "00 08 00 00 00 00 00 00 08 00 02 32 4A 6A 6A 6A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Jjjj"),
    (40,  "00 28 00 00 00 00 00 00 28 00 05 33 54 72 61 70 70 65 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Trapped"),
    (200, "01 48 00 10 00 00 00 00 48 00 03 11 50 6C 61 79 20 43 68 6F 72 64 73 00 00 00 00 00 00 00 00 00 00 00 00", "Play Chords"),
    (511, "03 7F 00 18 00 00 00 00 7F 01 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
]


def hx(s):
    return bytes(int(b, 16) for b in s.split())


def core_frame(data: bytes) -> p.Frame:
    f = p.parse(p.PREFIX + bytes([0x00, 0x23, p.CMD_NAME]) + data + b"\xF7")
    assert f is not None, "fixture frame failed to parse"
    return f


def phase0_frame(data: bytes) -> sx.Frame:
    raw = bytes(sx.PREFIX) + bytes([0x00, 0x23, sx.CMD_NAME]) + data + bytes([0xF7])
    f = sx.parse(raw)
    assert f is not None
    return f


def main() -> None:
    # ---- the hardware fixtures decode through the core --------------------
    for slot, hexstr, expected in FIXTURES:
        data = hx(hexstr)
        info = p.decode_name_reply(core_frame(data))
        assert info.name == expected, (slot, info.name, expected)
        assert info.slot == slot, (info.slot, slot)
        assert info.meta == data[3:12] and len(info.meta) == p.META_LEN
        print("PASS  slot %3d decodes name=%r slot-embedded meta=%s"
              % (slot, expected, info.meta.hex()))

    # ---- byte parity with the proven phase-0 decoder ----------------------
    for slot, hexstr, expected in FIXTURES:
        data = hx(hexstr)
        assert p.decode_name_reply(core_frame(data)).name == \
            sx.decode_name(phase0_frame(data)), slot
    print("PASS  core decode is byte-parity with mfcap.sysex.decode_name")

    # ---- 12-byte header structure of every fixture ------------------------
    for slot, hexstr, _ in FIXTURES:
        data = hx(hexstr)
        bank, pos = p.addr(slot)
        assert data[0] == bank and data[1] == pos and data[2] == 0x00
        assert data[8] == pos, "payload[8] is pos again"
        assert data[9] == (0 if slot < 384 else 1), "payload[9] flips at 384"
    assert hx(FIXTURES[4][1])[9] == 1               # slot 511, above the boundary
    print("PASS  fixtures confirm header: [0]=bank [1]=pos [8]=pos [9]=384-flag")

    # ---- header-leak regression -------------------------------------------
    # Slot 8's header carries printable bytes: pos 0x08 twice and attribute
    # 0x32 ('2'). A decoder that starts before offset 12 leaks them; the name
    # must be exactly "Jjjj".
    data = hx(FIXTURES[1][1])
    assert chr(data[11]) == "2"                     # the byte that used to leak
    assert p.decode_name_reply(core_frame(data)).name == "Jjjj"
    # Slot 200: attribute 0x11 is non-printable and pos 0x48 is 'H'; neither
    # may appear in "Play Chords".
    data = hx(FIXTURES[3][1])
    assert p.decode_name_reply(core_frame(data)).name == "Play Chords"
    print("PASS  printable header bytes (pos, 0x32 attribute) never leak into names")

    # ---- decode(name_write_frame(...)): same layout, write-direction bytes -
    meta = hx(FIXTURES[3][1])[3:12]                 # meta captured at slot 200
    for slot, name in [(0, "Init"), (200, "Play Chords"), (511, "Akiko San")]:
        f = p.parse(p.name_write_frame(1, slot, name, meta))
        info = p.decode_name_reply(f)
        assert info.slot == slot and info.name == name
        assert info.meta[0] == meta[0] & ~0x10      # reply-only bit cleared on writes
        assert info.meta[1:5] == meta[1:5]          # opaque bytes verbatim
        assert info.meta[6] == 0x06                 # write payload[9], per captures
        assert info.meta[7:9] == meta[7:9]          # category/attribute verbatim
    print("PASS  name_write_frame -> decode_name_reply: layout shared, direction")
    print("PASS     bytes transformed (payload[3] & ~0x10, payload[9]=0x06)")

    # ---- NUL handling: name stops at the first NUL ------------------------
    data = bytearray(hx(FIXTURES[0][1]))
    data[15] = 0x00                                 # truncate "Init" -> "Ini"
    data[16] = 0x58                                 # printable garbage after NUL
    assert p.decode_name_reply(core_frame(bytes(data))).name == "Ini"
    print("PASS  decode stops at the first NUL; trailing bytes ignored")


if __name__ == "__main__":
    main()
