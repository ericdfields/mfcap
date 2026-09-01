"""The five fidelity requirements of the SimulatedMicroFreak (spec §10):
full 35-byte name replies, reply-lag, pull-paced dumps, write semantics
(rename-only frame, torn commits, no checksum), and fail_chunk_at."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak import protocol as p
from microfreak.model import Preset
from microfreak.session import Session
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def recv_all(sim):
    out = []
    while True:
        raw = sim.receive(0.0)
        if raw is None:
            return out
        out.append(raw)


def main() -> None:
    # ---- 1. full 35-byte long-0x52 name reply payload --------------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sim.send(p.read_name_req(1, 200))
    replies = recv_all(sim)
    assert len(replies) == 1
    f = p.parse(replies[0])
    assert f.cmd == p.CMD_NAME and f.length == 0x23
    assert len(f.data) == p.NAME_PAYLOAD_LEN == 35
    assert f.data[0] == 1 and f.data[1] == 72 and f.data[2] == 0x00  # bank,pos,0
    assert f.data[8] == 72                       # pos again
    assert f.data[9] == 0                        # slot < 384
    sim.send(p.read_name_req(2, 400))
    f400 = p.parse(recv_all(sim)[0])
    assert f400.data[9] == 1                     # slot >= 384: the flag flips
    assert f400.data[8] == 400 % 128
    # attribute byte is printable (0x32/0x33) — the header-leak trap is armed
    assert f.data[11] in (0x32, 0x33)
    name_field = f.data[12:]
    assert len(name_field) == 23
    assert name_field.split(b"\x00")[0] == sim.peek(200).name.encode()
    print("PASS  1. name reply: full 35-byte payload, pos-again, 384 flag,")
    print("PASS     printable attribute byte present (header-leak trap armed)")

    # ---- 2. reply-lag: held one behind, resolved by the Session ----------
    sim = SimulatedMicroFreak.factory_fresh()            # lag ON (default)
    sim.send(p.read_name_req(1, 5))
    assert recv_all(sim) == [], "first name read must yield nothing"
    sim.send(p.read_name_req(2, 6))
    lagged = recv_all(sim)
    assert len(lagged) == 1
    lf = p.parse(lagged[0])
    assert p.decode_name_reply(lf).slot == 5, "reply is for the PREVIOUS request"
    print("PASS  2. lag: first read silent; reply N arrives with request N+1")

    # ...and the Session's drain-retry-match loop defeats it for every slot
    sim = SimulatedMicroFreak.factory_fresh()
    fc = FakeClock()
    sess = Session(sim, clock=fc, sleep=fc.sleep)
    for slot in (0, 1, 127, 128, 383, 384, 511):
        info = sess.read_name(slot)
        assert info.slot == slot and info.name == sim.peek(slot).name
    print("PASS  2. Session resolves every slot correctly under lag (the defense)")

    # ---- 3. dump: 145 x 0x16 + 1 x 0x17, 32 bytes each, pull-paced -------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sim.send(p.open_dump_req(1, 40))
    assert recv_all(sim) == [], "chunks are pull-paced by 0x18"
    chunks = []
    for i in range(p.CHUNK_COUNT):
        sim.send(p.pull_next_req(i + 1))
        got = recv_all(sim)
        assert len(got) == 1, "one chunk per pull (lockstep)"
        chunks.append(p.parse(got[0]))
        assert chunks[-1].seq == (i + 1) % 128, "chunk echoes its pull's seq"
    assert all(len(c.data) == 32 and c.length == 0x20 for c in chunks)
    assert [c.cmd for c in chunks[:-1]] == [p.CMD_CHUNK_MORE] * 145
    assert chunks[-1].cmd == p.CMD_CHUNK_LAST
    assert p.assemble_blob(chunks) == sim.peek(40).blob
    assert sim.faults == [], sim.faults
    print("PASS  3. dump: open, then 145x0x16 + 1x0x17 of 32 bytes, one per pull")

    # ---- 4. write semantics ----------------------------------------------
    # 4a. the long 0x52 alone is a rename: name+meta change, blob does not,
    #     and the device acks it with a device-shape 0x18 (c4 capture:
    #     out 52 -> in 18, len 0x00, empty payload, seq echoed)
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    before = sim.peek(8)
    sim.send(p.name_write_frame(5, 8, "Renamed", before.meta))
    got = recv_all(sim)
    assert len(got) == 1, "the long 0x52 is acked with exactly one 0x18"
    ack = p.parse(got[0])
    assert ack.cmd == p.CMD_NEXT and ack.length == 0x00 and ack.data == b""
    assert ack.seq == 5, "device acks echo the acked frame's seq"
    after = sim.peek(8)
    assert after.name == "Renamed" and after.blob == before.blob
    assert after.meta == before.meta
    assert sim.faults == [], sim.faults
    print("PASS  4. long 0x52 alone renames: no blob change, acked 0x18, no fault")

    # 4b. chunks without an open+armed write: fault, slot untouched, no ack
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    before = sim.peek(0).blob
    donor = sim.peek(3)
    sim.send(p.chunk_frames(donor.blob)[0])
    assert recv_all(sim) == [], "no ack for an orphan chunk"
    assert sim.peek(0).blob == before and sim.peek(3).blob == donor.blob
    assert any("without an open" in fault for fault in sim.faults), sim.faults
    print("PASS  4. orphan chunks: fault recorded, nothing written, no ack")

    # 4c. committed total != 4672: fault, slot untouched
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    target_before = sim.peek(9).blob
    sim.send(p.open_write_frame(1, 9))
    sim.send(p.go_frame())
    frames = p.chunk_frames(donor.blob)
    for fr in frames[:10]:
        sim.send(fr)
    # forge an early "last" chunk: total 11 x 32 = 352 bytes, not 4672
    sim.send(p.frame(0, 0x20, p.CMD_CHUNK_LAST, frames[10][9:-1]))
    assert sim.peek(9).blob == target_before, "short commit must not land"
    assert any("untouched" in fault for fault in sim.faults), sim.faults
    print("PASS  4. short commit rejected: slot untouched, fault recorded")

    # 4d. a full, correct burst carries no checksum and still commits;
    #     matching the captures, the name frame, the open and the go are
    #     each acked too (c3: 149 inbound 0x18s for 146 chunks)
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sim.send(p.name_write_frame(1, 9, donor.name, donor.meta))
    sim.send(p.open_write_frame(2, 9))
    sim.send(p.go_frame())
    control_acks = [p.parse(r) for r in recv_all(sim)]
    assert [a.cmd for a in control_acks] == [p.CMD_NEXT] * 3, \
        "long 0x52, open and go are each acked with 0x18"
    assert all(a.length == 0x00 and a.data == b"" for a in control_acks)
    acked = 0
    for fr in p.chunk_frames(donor.blob):
        sim.send(fr)
        got = recv_all(sim)
        acked += sum(1 for r in got if p.parse(r).cmd == p.CMD_NEXT)
    assert acked == 146, "every chunk acked with 0x18"
    assert sim.peek(9).blob == donor.blob
    assert sim.faults == [], sim.faults
    print("PASS  4. raw burst: 3 control acks + 146 chunk acks (149, as captured)")

    # ---- 5. fail_chunk_at ------------------------------------------------
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False, fail_chunk_at=3)
    before = sim.peek(9).blob
    sim.send(p.open_write_frame(1, 9))
    sim.send(p.go_frame())
    assert len(recv_all(sim)) == 2                  # open + go acks
    ack_pattern = []
    for fr in p.chunk_frames(donor.blob)[:6]:
        sim.send(fr)
        ack_pattern.append(len(recv_all(sim)))
    assert ack_pattern == [1, 1, 1, 0, 0, 0], ack_pattern
    assert sim.peek(9).blob == before
    print("PASS  5. fail_chunk_at=3: chunks 0-2 acked, 3+ silent (torn write)")


if __name__ == "__main__":
    main()
