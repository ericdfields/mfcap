"""decode_name against real 0x52 payloads captured from hardware (fw 5.x, 2026-09-01)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mfcap import sysex as sx

# (slot, raw data bytes of the 0x52 reply, expected name)
FIXTURES = [
    (0,   "00 00 00 08 00 00 00 00 00 00 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
    (8,   "00 08 00 00 00 00 00 00 08 00 02 32 4A 6A 6A 6A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Jjjj"),
    (40,  "00 28 00 00 00 00 00 00 28 00 05 33 54 72 61 70 70 65 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Trapped"),
    (200, "01 48 00 10 00 00 00 00 48 00 03 11 50 6C 61 79 20 43 68 6F 72 64 73 00 00 00 00 00 00 00 00 00 00 00 00", "Play Chords"),
    (511, "03 7F 00 18 00 00 00 00 7F 01 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
]


def frame_from_data(data: bytes) -> sx.Frame:
    raw = bytes(sx.PREFIX) + bytes([0x00, 0x00, sx.CMD_NAME]) + data + bytes([0xF7])
    f = sx.parse(raw)
    assert f is not None, "fixture frame failed to parse"
    return f


def main() -> None:
    for slot, hexstr, expected in FIXTURES:
        data = bytes(int(b, 16) for b in hexstr.split())
        got = sx.decode_name(frame_from_data(data))
        assert got == expected, f"slot {slot}: {got!r} != {expected!r}"
        print(f"PASS  slot {slot:3d} name decodes to {expected!r}")


if __name__ == "__main__":
    main()
