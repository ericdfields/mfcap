"""mfcap.writer offline: template_target reads the write-open address,
address_rewrites derives the retarget map from the burst's own frames (and
never touches chunks), and synth_rows swaps blob content and patches the
name while preserving every captured header byte (raw[:9]) verbatim."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mfcap.writer import address_rewrites, synth_rows, template_target
from microfreak import protocol as p

SLOT = 509                       # bank 3, pos 125 — the gate's scratch region
META = bytes([0x18, 0x00, 0x00, 0x00, 0x00, 0x7D, 0x01, 0x00, 0x33])


def row(raw: bytes, direction="out"):
    f = p.parse(raw)
    return {"t": 0.0, "dir": direction, "hex": " ".join("%02X" % b for b in raw),
            "len": len(raw), "seq": f.seq, "lenbyte": f.length, "cmd": f.cmd,
            "cmd_name": "?"}


def make_template(blob: bytes):
    """A miniature captured write burst: the 7-frame shape with a 2-chunk
    blob (the writer is size-agnostic; it reads capacity off the template)."""
    assert len(blob) == 64
    rows = [
        row(p.read_name_req(21, SLOT)),
        row(p.frame(21, 0x23, p.CMD_NAME, [3, 125, 0] + [0] * 9 + [0x49] + [0] * 22),
            direction="in"),                              # the device's reply
        row(p.name_write_frame(22, SLOT, "Akiko San", META)),
        row(p.open_write_frame(23, SLOT)),
        row(p.go_frame()),
        row(p.frame(1, 0x20, p.CMD_CHUNK_MORE, blob[:32])),
        row(p.frame(2, 0x20, p.CMD_CHUNK_LAST, blob[32:])),
        row(p.read_name_req(24, SLOT)),
    ]
    return rows


def payload(r):
    return bytes(int(x, 16) for x in r["hex"].split())[9:-1]


def main() -> None:
    blob_a = bytes((i * 5 + 1) % 128 for i in range(64))
    template = make_template(blob_a)

    # --- template_target reads the slot off the write-open frame -----------
    assert template_target(template) == SLOT
    assert template_target([r for r in template
                            if len(payload(r)) != 3 or r["cmd"] != 0x52]) is None
    print("PASS  template_target finds slot %d from the short 0x52 open" % SLOT)

    # --- address_rewrites: every 0x19/0x52 frame, never a chunk ------------
    rewrites = address_rewrites(template)
    # out-frames 0 (0x19), 2 (long 0x52), 3 (open 0x52), 6 (0x19 read-back)
    # -> 2 rewrites (bank byte + position byte) each; chunk frames untouched
    # (out-frame indices count only rows with dir=out)
    by_frame = {}
    for rw in rewrites:
        by_frame.setdefault(rw.frame_index, []).append((rw.offset, rw.kind))
    assert set(by_frame) == {0, 1, 2, 6}, by_frame     # out-row indices
    for offs in by_frame.values():
        assert sorted(offs) == [(0, "bank"), (1, "position")]
    print("PASS  address_rewrites maps bank/pos in all four addressed frames,")
    print("PASS     and never inside a chunk")

    # --- synth_rows: new blob in, headers verbatim, name patched -----------
    blob_b = bytes((i * 11 + 7) % 128 for i in range(64))
    out = synth_rows(template, blob_b, name="Init")
    assert len(out) == len(template)
    pos = 0
    for old, new in zip(template, out):
        old_raw = bytes(int(x, 16) for x in old["hex"].split())
        new_raw = bytes(int(x, 16) for x in new["hex"].split())
        if old.get("dir") == "out" and old.get("cmd") in (0x16, 0x17):
            n = len(old_raw) - 10
            assert new_raw[:9] == old_raw[:9], "chunk header must be verbatim"
            assert new_raw[9:-1] == blob_b[pos:pos + n], "content must be swapped"
            assert new_raw[-1:] == b"\xF7"
            pos += n
        elif old.get("dir") == "out" and old.get("cmd") == 0x52 \
                and len(old_raw) > 30:
            start = 9 + p.NAME_OFFSET
            field = new_raw[start:start + p.NAME_LEN]
            assert field == b"Init" + b"\x00" * (p.NAME_LEN - 4)
            assert new_raw[:start] == old_raw[:start], \
                "long-0x52 header bytes before the name must be verbatim"
        else:
            assert new_raw == old_raw, "untouched frames must be byte-identical"
    assert pos == 64
    print("PASS  synth_rows swaps chunk content, patches only the name field,")
    print("PASS     and keeps every captured header byte verbatim")

    # --- capacity mismatch is refused --------------------------------------
    try:
        synth_rows(template, blob_b[:-1])
        raise AssertionError("a 63-byte blob must be refused by a 64-byte template")
    except ValueError:
        pass
    print("PASS  blob/template capacity mismatch raises ValueError")

    # --- name=None leaves the captured name untouched -----------------------
    out = synth_rows(template, blob_b, name=None)
    for old, new in zip(template, out):
        if old.get("cmd") == 0x52 and len(old["hex"].split()) > 30:
            assert new["hex"] == old["hex"]
    print("PASS  name=None keeps the template's captured name frame verbatim")


if __name__ == "__main__":
    main()
