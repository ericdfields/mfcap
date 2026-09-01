"""Core codec: every frame builder emits the exact byte sequences documented
in docs/write-protocol.md, parses back to itself, and the chunk stream
reassembles byte-identically. No checksum anywhere, no address in chunks."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.errors import BlobSizeError, SlotOutOfRangeError


def hx(s):
    return bytes(int(b, 16) for b in s.split())


# meta captured from hardware at slot 511 (fixture data[3:12] in test_sysex.py)
META_511 = hx("18 00 00 00 00 7F 01 00 33")


def blob7(seed: int) -> bytes:
    """Deterministic 4672-byte, 7-bit-clean synthetic blob."""
    out = bytearray()
    x = seed & 0x7F
    while len(out) < p.BLOB_SIZE:
        x = (x * 75 + 74) % 127
        out.append(x)
    return bytes(out[:p.BLOB_SIZE])


def main() -> None:
    # ---- envelope: F0 00 20 6B 07 01 <seq> <len> <cmd> [payload] F7 -------
    assert p.PREFIX == hx("F0 00 20 6B 07 01")
    raw = p.frame(0x2A, 0x03, 0x19, [0x03, 0x7D, 0x00])
    assert raw[0] == 0xF0 and raw[-1] == 0xF7
    assert raw[6] == 0x2A and raw[7] == 0x03 and raw[8] == 0x19
    print("PASS  envelope is F0 00 20 6B 07 01 <seq> <len> <cmd> ... F7")

    # ---- addressing: bank = slot // 128, pos = slot % 128 -----------------
    assert p.addr(0) == (0, 0)
    assert p.addr(383) == (2, 127)
    assert p.addr(384) == (3, 0)
    assert p.addr(509) == (3, 125)
    assert p.addr(511) == (3, 127)
    assert p.slot_of(3, 125) == 509
    for slot in (0, 127, 128, 383, 384, 511):
        assert p.slot_of(*p.addr(slot)) == slot
    for bad in (-1, 512):
        try:
            p.addr(bad)
            raise AssertionError("addr(%d) must raise" % bad)
        except SlotOutOfRangeError:
            pass
    print("PASS  addr/slot_of: bank=slot//128, pos=slot%128, round-trips")

    # ---- write-protocol.md frame 1/7: name read ---------------------------
    assert p.read_name_req(0x2A, 509) == hx("F0 00 20 6B 07 01 2A 03 19 03 7D 00 F7")
    # ---- dump open + pull (the read protocol the writes mirror) -----------
    assert p.open_dump_req(0x2B, 509) == hx("F0 00 20 6B 07 01 2B 01 19 03 7D 01 F7")
    assert p.pull_next_req(0x05) == hx("F0 00 20 6B 07 01 05 01 18 00 F7")
    # ---- frame 3: open blob write (short 0x52) ----------------------------
    assert p.open_write_frame(0x11, 509) == hx("F0 00 20 6B 07 01 11 03 52 03 7D 01 F7")
    # ---- frame 4: go — seq 0, len 0, empty payload ------------------------
    assert p.go_frame() == hx("F0 00 20 6B 07 01 00 00 15 F7")
    print("PASS  0x19/0x18/short-0x52/0x15 builders match write-protocol.md verbatim")

    # ---- frame 2: the long 0x52 name+meta frame, byte for byte ------------
    # Writing "Akiko San" (the gate's preset) to slot 509 with meta captured
    # at slot 511 (reply form: payload[3]=0x18, payload[9]=1). The outbound
    # frame is direction-transformed per the c2/c3/c4 captures: payload[3]
    # drops the reply-only 0x10 bit (0x18 -> 0x08), payload[8] is recomputed
    # to pos 0x7D, payload[9] is the constant 0x06 every captured MCC write
    # carries; remaining opaque and attribute bytes verbatim.
    expected = hx("F0 00 20 6B 07 01 0C 23 52"
                  " 03 7D 00"                       # bank, pos, 0x00
                  " 08 00 00 00 00"                 # meta[0]&~0x10, meta[1..4]
                  " 7D 06"                          # pos again, write 0x06
                  " 00 33"                          # category, attribute
                  " 41 6B 69 6B 6F 20 53 61 6E"    # "Akiko San"
                  " 00 00 00 00 00 00 00 00 00 00 00 00 00 00"   # NUL pad to 23
                  " F7")
    raw = p.name_write_frame(0x0C, 509, "Akiko San", META_511)
    assert raw == expected, ("name_write_frame mismatch:\n got %s\nwant %s"
                             % (raw.hex(" "), expected.hex(" ")))
    # payload[9] is 0x06 on writes for EVERY slot — the 0/1 flag is reply-only
    assert p.parse(p.name_write_frame(1, 383, "X", META_511)).data[9] == 0x06
    assert p.parse(p.name_write_frame(1, 384, "X", META_511)).data[9] == 0x06
    print("PASS  long 0x52 name frame is byte-exact; payload[3]/[8]/[9] per capture")

    # ---- frames 5-6: 146 x 32-byte chunks, 145 x 0x16 + 1 x 0x17 ----------
    # Blob deliberately starts 03 7F — the bytes of address (3, 127) — to
    # prove chunks are content-only and nothing rewrites lookalike addresses.
    blob = bytes([0x03, 0x7F]) + blob7(1)[2:]
    assert len(blob) == p.BLOB_SIZE == 4672 == 146 * 32
    frames = p.chunk_frames(blob)
    assert len(frames) == p.CHUNK_COUNT == 146
    for i, raw in enumerate(frames):
        assert len(raw) == 42                      # 6 prefix + seq,len,cmd + 32 + F7
        f = p.parse(raw)
        assert f.length == 0x20 and len(f.data) == 32
        assert f.seq == (i + 1) % 128, (i, f.seq)  # captured: 1..127, 0, 1..18
        want_cmd = p.CMD_CHUNK_LAST if i == 145 else p.CMD_CHUNK_MORE
        assert f.cmd == want_cmd, (i, f.cmd)
        assert f.data == blob[i * 32:(i + 1) * 32]  # content verbatim, no address
    assert frames[0][9:11] == bytes([0x03, 0x7F])   # the lookalike survived
    print("PASS  146 chunks x 32 bytes: 145 x 0x16 + 0x17, address-free, verbatim")
    print("PASS  chunk seqs increment (i+1) %% 128, wrapping through 0 as captured")

    # ---- no checksum: chunk bytes are prefix+seq+len+cmd+content+F7 only --
    total_wire = sum(len(r) for r in frames)
    assert total_wire == 146 * 42                   # not one integrity byte anywhere
    assert p.NO_CHECKSUM is True
    print("PASS  no checksum: 146 frames carry exactly 4672 content bytes + framing")

    # ---- reassembly round-trips ------------------------------------------
    parsed = [p.parse(r) for r in frames]
    assert p.assemble_blob(parsed) == blob
    try:
        p.chunk_frames(blob[:-1])
        raise AssertionError("4671-byte blob must be refused")
    except BlobSizeError as e:
        assert e.expected == 4672 and e.actual == 4671
    try:
        p.assemble_blob(parsed[:-1])
        raise AssertionError("145-chunk assembly must be refused")
    except BlobSizeError:
        pass
    print("PASS  chunk stream reassembles byte-identically; short blobs refused")

    # ---- every builder parses back to its own fields ----------------------
    cases = [
        (p.read_name_req(9, 200), 9, 0x03, p.CMD_OPEN, bytes([1, 72, 0])),
        (p.open_dump_req(10, 200), 10, 0x01, p.CMD_OPEN, bytes([1, 72, 1])),
        (p.pull_next_req(11), 11, 0x01, p.CMD_NEXT, bytes([0])),
        (p.open_write_frame(12, 200), 12, 0x03, p.CMD_NAME, bytes([1, 72, 1])),
        (p.go_frame(), 0, 0x00, p.CMD_GO, b""),
    ]
    for raw, seq, length, cmd, data in cases:
        f = p.parse(raw)
        assert (f.seq, f.length, f.cmd, f.data) == (seq, length, cmd, data), raw.hex()
        assert f.raw == raw
    print("PASS  builder -> parse round-trip preserves seq/len/cmd/payload")

    # ---- parse rejects foreign traffic ------------------------------------
    assert p.parse(b"") is None
    assert p.parse(b"\x90\x40\x40") is None                       # note-on
    assert p.parse(b"\xF0\x7E\x00\x06\x01\xF7") is None           # generic SysEx
    assert p.parse(hx("F0 00 20 6B 06 01 00 00 15 F7")) is None   # wrong device id
    # wrong prefix byte 5 (another Arturia sub-protocol under device id 0x07)
    # — phase-0 Frame.is_microfreak matched all 6 prefix bytes; so must parse
    assert p.parse(hx("F0 00 20 6B 07 02 00 00 15 F7")) is None
    assert p.parse(p.go_frame()[:-1]) is None                     # missing F7
    print("PASS  parse returns None for non-MicroFreak traffic")


if __name__ == "__main__":
    main()
