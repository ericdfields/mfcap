#!/usr/bin/env python3
"""gen_vectors.py — golden-vector generator for the FreakCore Swift port.

Emits deterministic JSON fixtures into
ios/FreakCore/Tests/FreakCoreTests/Fixtures/vectors/, generated from the
Python reference core (the local `microfreak` package). These vectors are
the Swift port's definition of correct: byte-for-byte wire parity.

Run from the repo root:

    python3 tools/gen_vectors.py

Stdlib + the local microfreak package only. Fully deterministic: no
randomness (blobs are seeded sha256 streams), no real clocks (a FakeClock
drives the Session), no MIDI, no hardware.

Every file is {"description": str, "cases": [...]}. All byte sequences are
uppercase two-digit hex, space-separated ("F0 00 20 6B ...").
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tools"))

import mbp_import                                          # noqa: E402

from microfreak import protocol as p                      # noqa: E402
from microfreak.analysis import find_expendable           # noqa: E402
from microfreak.collections import (ApplyOptions,         # noqa: E402
                                    PresetCollection, Provenance,
                                    ProvenanceKind, collection_from_json,
                                    collection_to_json, plan_apply)
from microfreak.library import (Library, LibraryEntry,    # noqa: E402
                                _entry_from_json, _entry_to_json,
                                category_census)
from microfreak.model import (Category, DeviceSnapshot,   # noqa: E402
                              Preset, PresetRef, SlotRecord, TimingReport)
from microfreak.session import Session                    # noqa: E402
from microfreak.sync import diff_baseline                 # noqa: E402
from microfreak.transports.simulated import (             # noqa: E402
    SimulatedMicroFreak, _synth_blob)

OUT_DIR = REPO_ROOT / "ios/FreakCore/Tests/FreakCoreTests/Fixtures/vectors"
# App-layer fixtures (the SwiftUI FreakLibrarian test target). The .mfprojz /
# .mbp import parser (App/Sources/Support/MFProjzImport.swift) is app-layer, so
# its golden lives with the app tests, not the FreakCore vectors.
APP_FIXTURES = REPO_ROOT / "ios/App/Tests/Fixtures"

HEX_NOTE = ("All byte sequences are uppercase two-digit hex, "
            "space-separated ('F0 00 20 6B ...').")
REGEN = "Regenerate: python3 tools/gen_vectors.py (from the repo root)."

# The ten slots every builder is exercised against: bank boundaries (127/128),
# the payload[9] reply boundary (383/384), the gate slots (509/511), and the
# hardware-fixture slots (0/8/40/200/511).
SLOTS_UT = [0, 8, 40, 127, 128, 200, 383, 384, 509, 511]

# Hardware 0x52 name-reply payloads captured 2026-09-01 (fw 5.x); verbatim
# from tests/test_sysex.py FIXTURES: (slot, 35 payload bytes, expected name).
HW_FIXTURES = [
    (0,   "00 00 00 08 00 00 00 00 00 00 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
    (8,   "00 08 00 00 00 00 00 00 08 00 02 32 4A 6A 6A 6A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Jjjj"),
    (40,  "00 28 00 00 00 00 00 00 28 00 05 33 54 72 61 70 70 65 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Trapped"),
    (200, "01 48 00 10 00 00 00 00 48 00 03 11 50 6C 61 79 20 43 68 6F 72 64 73 00 00 00 00 00 00 00 00 00 00 00 00", "Play Chords"),
    (511, "03 7F 00 18 00 00 00 00 7F 01 00 33 49 6E 69 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "Init"),
]


def hx(b) -> str:
    return " ".join(f"{x:02X}" for x in bytes(b))


class FakeClock:
    """Deterministic monotonic clock; sleep() advances it (same shape as the
    core test suite's FakeClock)."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def make_session(sim: SimulatedMicroFreak) -> Session:
    fc = FakeClock()
    return Session(sim, clock=fc, sleep=fc.sleep)


def _label(direction: str, f: p.Frame) -> str:
    if f.cmd == p.CMD_OPEN:
        return "read_name_req" if f.data[2] == 0x00 else "open_dump_req"
    if f.cmd == p.CMD_NEXT:
        return "pull_next_req" if direction == "out" else "ack"
    if f.cmd == p.CMD_NAME:
        if len(f.data) == p.NAME_PAYLOAD_LEN:
            return "name_write" if direction == "out" else "name_reply"
        return "open_write"
    if f.cmd == p.CMD_GO:
        return "go"
    if f.cmd == p.CMD_CHUNK_MORE:
        return "chunk"
    if f.cmd == p.CMD_CHUNK_LAST:
        return "last_chunk"
    return f"cmd_0x{f.cmd:02X}"


def t_entry(direction: str, raw: bytes) -> dict:
    f = p.parse(raw)
    assert f is not None, "unparseable frame in a transcript"
    e = {"dir": direction, "label": _label(direction, f), "seq": f.seq,
         "frame": hx(raw)}
    if f.cmd == p.CMD_NAME and len(f.data) == p.NAME_PAYLOAD_LEN:
        info = p.decode_name_reply(f)
        e["slot"] = info.slot
        e["name"] = info.name
    return e


def transcript(sim: SimulatedMicroFreak) -> list:
    return [t_entry(d, raw) for d, raw in sim.wire_log]


def emit(name: str, description: str, cases: list) -> int:
    path = OUT_DIR / name
    path.write_text(json.dumps({"description": description, "cases": cases},
                               indent=2) + "\n")
    return len(cases)


# --------------------------------------------------------------- frames.json

def crafted_meta(slot: int) -> bytes:
    """Reply-form META_LEN bytes for a name-write case. meta[0] carries the
    reply-only 0x10 bit exactly when slot >= 128 (as hardware replies do), so
    the builder's clearing of it is exercised; meta[5] and meta[6] hold junk
    (0x55, 0x7F) to prove the builder recomputes payload[8]=pos and forces
    payload[9]=0x06 instead of copying them."""
    m0 = 0x08 | (p.REPLY_META_FLAG if slot >= p.SLOTS_PER_BANK else 0)
    return bytes([m0, 0x01, 0x02, 0x03, 0x04, 0x55, 0x7F, 0x05, 0x32])


def gen_frames() -> int:
    cases = []
    for slot in SLOTS_UT:
        bank, pos = p.addr(slot)
        seq = (slot % 126) + 1
        cases.append({"kind": "read_name_req", "slot": slot, "bank": bank,
                      "pos": pos, "seq": seq,
                      "frame": hx(p.read_name_req(seq, slot))})
    for slot in SLOTS_UT:
        bank, pos = p.addr(slot)
        seq = ((slot * 7) % 126) + 1
        cases.append({"kind": "open_dump_req", "slot": slot, "bank": bank,
                      "pos": pos, "seq": seq,
                      "frame": hx(p.open_dump_req(seq, slot)),
                      "note": "len byte 0x01 is the phase-0/core convention; "
                              "MCC sends 0x03 and hardware accepts both "
                              "(docs/write-protocol.md)"})
    for seq in (1, 64, 127):
        cases.append({"kind": "pull_next_req", "seq": seq,
                      "frame": hx(p.pull_next_req(seq)),
                      "note": "host pull-next: len 0x01, payload [0x00] — "
                              "distinct from the device's empty-payload ack"})
    cases.append({"kind": "go_frame", "seq": 0, "frame": hx(p.go_frame()),
                  "note": "seq 0, len 0, empty payload — always"})
    for slot in SLOTS_UT:
        bank, pos = p.addr(slot)
        seq = ((slot * 5) % 126) + 1
        cases.append({"kind": "open_write_frame", "slot": slot, "bank": bank,
                      "pos": pos, "seq": seq,
                      "frame": hx(p.open_write_frame(seq, slot))})

    def name_write_case(slot: int, seq: int, name: str, note: str = "",
                        meta: bytes | None = None) -> dict:
        bank, pos = p.addr(slot)
        meta = crafted_meta(slot) if meta is None else meta
        raw = p.name_write_frame(seq, slot, name, meta)
        f = p.parse(raw)
        # generator-side invariants, straight from docs/write-protocol.md
        assert f.data[3] == meta[0] & ~p.REPLY_META_FLAG
        assert f.data[8] == pos and f.data[9] == p.WRITE_PAYLOAD9
        case = {"kind": "name_write_frame", "slot": slot, "bank": bank,
                "pos": pos, "seq": seq, "name": name, "meta": hx(meta),
                "expected_payload": {"p3": f.data[3], "p8": f.data[8],
                                     "p9": f.data[9]},
                "frame": hx(raw)}
        if note:
            case["note"] = note
        return case

    for slot in SLOTS_UT:
        cases.append(name_write_case(slot, ((slot * 3) % 126) + 1,
                                     f"Vec {slot:03d}"))
    cases.append(name_write_case(
        0, 100, "", note="empty name is valid; 23 NUL bytes on the wire"))
    cases.append(name_write_case(
        511, 101, "ABCDEFGHIJKLMNOPQRSTUVW",
        note="maximum-length 23-char name; zero padding bytes"))
    cases.append(name_write_case(
        384, 102, "A", note="1-char name at the payload[9] reply boundary; "
                            "22 NUL padding bytes"))
    # explicit meta variants beyond crafted_meta's per-slot pattern
    cases.append(name_write_case(
        200, 103, "Play Chords",
        meta=bytes([0x10, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x03, 0x11]),
        note="the slot-200 hardware reply's meta round-tripped verbatim: "
             "payload[3] = 0x10 & ~0x10 = 0x00, payload[8] recomputed to "
             "0x48, payload[9] forced 0x06 over the reply's 0x00"))
    cases.append(name_write_case(
        0, 104, "Low Flag",
        meta=bytes([0x18, 0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x01, 0x0B, 0x33]),
        note="0x10 bit set in meta[0] for a LOW slot: clearing is "
             "unconditional, never slot-gated; opaque bytes at the 7-bit "
             "maximum round-trip verbatim"))
    cases.append(name_write_case(
        511, 105, "Max Meta",
        meta=bytes([0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F]),
        note="all-0x7F meta: payload[3] = 0x7F & ~0x10 = 0x6F, "
             "payload[8]/payload[9] recomputed over the 0x7F junk"))

    # full chunk_frames stream for one deterministic seeded blob
    blob = _synth_blob(2026, "chunk-frames")
    assert len(blob) == p.BLOB_SIZE and all(b <= 0x7F for b in blob)
    chunk_raws = p.chunk_frames(blob)
    assert len(chunk_raws) == p.CHUNK_COUNT
    for i, raw in enumerate(chunk_raws):
        f = p.parse(raw)
        assert f.seq == (i + 1) % 128
        assert f.cmd == (p.CMD_CHUNK_LAST if i == p.CHUNK_COUNT - 1
                         else p.CMD_CHUNK_MORE)
        assert len(f.data) == p.CHUNK_SIZE
    assert bytes(p.assemble_blob([p.parse(r) for r in chunk_raws])) == blob
    cases.append({
        "kind": "chunk_frames",
        "blob_seed": 2026,
        "blob_label": "chunk-frames",
        "blob_hex": hx(blob),
        "blob_sha256": p.digest(blob),
        "chunk_count": p.CHUNK_COUNT,
        "chunk_seqs": [(i + 1) % 128 for i in range(p.CHUNK_COUNT)],
        "frames": [hx(r) for r in chunk_raws],
        "note": "blob = _synth_blob(2026, 'chunk-frames'): concatenated "
                "sha256('2026:chunk-frames:<counter>') digests, each byte "
                "& 0x7F, truncated to 4672. 145 x 0x16 + 1 x 0x17, len "
                "byte 0x20, 32 payload bytes each; seqs (i+1) % 128 "
                "continue from the go frame's 0 and wrap THROUGH 0 at "
                "chunk index 126. Chunks carry no address and no checksum.",
    })
    return emit(
        "frames.json",
        "Every request/frame builder in microfreak.protocol, for slots "
        f"{SLOTS_UT}. Inputs (slot, seq, name, meta) are recorded per case; "
        "'frame' is the exact wire bytes the builder must emit. "
        "name_write_frame cases feed reply-form meta (0x10 bit set for "
        "slots >= 128, junk in meta[5]/meta[6]) to pin the direction-"
        "dependent recompute: payload[3] = meta[0] & ~0x10, payload[8] = "
        "pos, payload[9] = 0x06 — plus explicit meta variants (a hardware "
        "reply's meta verbatim, the 0x10 bit on a low slot, all-0x7F). The "
        "one chunk_frames case pins the complete 146-frame chunk stream "
        "for a seeded blob, listed under 'frames'. " + HEX_NOTE + " " + REGEN,
        cases)


# --------------------------------------------------------- name_replies.json

SYNTH_REPLY_SLOTS = [0, 127, 128, 383, 384, 511]     # bank + payload[9] edges


def gen_name_replies() -> int:
    cases = []
    for slot, payload_hex, expected_name in HW_FIXTURES:
        data = bytes(int(t, 16) for t in payload_hex.split())
        assert len(data) == p.NAME_PAYLOAD_LEN
        raw = p.frame(0, 0x23, p.CMD_NAME, data)
        info = p.decode_name_reply(p.parse(raw))
        assert info.name == expected_name, (slot, info.name, expected_name)
        assert info.slot == slot
        cases.append({"slot": slot, "source": "hardware-2026-09-01",
                      "payload": hx(data), "frame": hx(raw),
                      "expected": {"slot": info.slot, "name": info.name,
                                   "meta": hx(info.meta)}})
    # synthetic boundary-slot replies rendered by the reference sim
    for slot in SYNTH_REPLY_SLOTS:
        sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
        sim.send(p.read_name_req(1, slot))
        reply = sim.receive(0.0)
        assert reply is not None and sim.faults == []
        data = p.parse(reply).data
        assert len(data) == p.NAME_PAYLOAD_LEN
        raw = p.frame(0, 0x23, p.CMD_NAME, data)   # normalized seq, as above
        info = p.decode_name_reply(p.parse(raw))
        assert info.slot == slot
        expected_name = f"Patch {slot:03d}" if slot < 512 - 269 else "Init"
        assert info.name == expected_name, (slot, info.name)
        # positional-meta invariants the sim must honor (write-protocol.md)
        assert bool(info.meta[0] & p.REPLY_META_FLAG) == (slot >= p.SLOTS_PER_BANK)
        assert info.meta[5] == slot % p.SLOTS_PER_BANK
        assert info.meta[6] == (0 if slot < p.HIGH_BANK_BOUNDARY else 1)
        cases.append({"slot": slot,
                      "source": "synthetic-factory_fresh(seed=0)",
                      "payload": hx(data), "frame": hx(raw),
                      "expected": {"slot": info.slot, "name": info.name,
                                   "meta": hx(info.meta)}})
    return emit(
        "name_replies.json",
        "0x52 name-reply payloads with their expected decode. The five "
        "'hardware-2026-09-01' cases are captured payloads (fw 5.x), "
        "verbatim from tests/test_sysex.py; the six "
        "'synthetic-factory_fresh(seed=0)' cases are rendered by the "
        "reference SimulatedMicroFreak for the boundary slots "
        f"{SYNTH_REPLY_SLOTS} (bank edges 127/128 flip the reply-only 0x10 "
        "flag in meta[0]; 383/384 flip the payload[9] high-bank flag in "
        "meta[6]). All are wrapped in the frame envelope with seq 0x00 and "
        "the realistic len byte 0x23 (the parser does not validate the len "
        "byte). 'expected' is decode_name_reply's output: embedded slot, "
        "decoded name (printable-filtered, split at first NUL, stripped), "
        "and the 9 meta bytes payload[3..11] verbatim (note hardware slot "
        "200 carries category 0x03/attribute 0x11). "
        + HEX_NOTE + " " + REGEN,
        cases)


# ---------------------------------------------------------- write_burst.json

def burst_case(slot: int) -> dict:
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    sess = make_session(sim)
    blob = _synth_blob(2026, f"golden-{slot}")
    assert len(blob) == p.BLOB_SIZE and all(b <= 0x7F for b in blob)
    meta_in = sim.peek(slot).meta          # reply-form, as a real read yields
    name = f"Golden {slot:03d}"
    info = sess.write_preset(slot, Preset(name=name, blob=blob, meta=meta_in))
    assert sim.faults == [], sim.faults
    assert sim.peek(slot).blob == blob
    assert info.slot == slot and info.name == name
    acks = sum(1 for d, raw in sim.wire_log
               if d == "in" and p.parse(raw).cmd == p.CMD_NEXT)
    assert acks == 149, acks               # 3 control frames + 146 chunks
    return {
        "slot": slot,
        "name": name,
        "meta": hx(meta_in),
        "blob_hex": hx(blob),
        "blob_sha256": p.digest(blob),
        "chunk_count": p.CHUNK_COUNT,
        "control_seqs": {"read_1": 1, "name_write": 2, "open_write": 3,
                         "go": 0, "read_back": 4},
        "chunk_seqs": [(i + 1) % 128 for i in range(p.CHUNK_COUNT)],
        "expected_ack_count": acks,
        "readback": {"slot": info.slot, "name": info.name,
                     "meta": hx(info.meta)},
        "transcript": transcript(sim),
    }


def gen_write_burst() -> int:
    cases = [burst_case(3), burst_case(509)]
    return emit(
        "write_burst.json",
        "Complete gate-shape write bursts (Session.write_preset against "
        "SimulatedMicroFreak.factory_fresh(reply_lag=False)) for a "
        "deterministic seeded 4672-byte blob (_synth_blob(2026, "
        "'golden-<slot>')). 'transcript' is every wire frame in order, "
        "host->device ('out') and device->host ('in'): read-name + reply, "
        "long 0x52 name/meta write + ack, short 0x52 open + ack, go (seq 0) "
        "+ ack, 145 x 0x16 + 1 x 0x17 chunks each acked with an "
        "empty-payload seq-echoing 0x18 (control-frame acks included: 149 "
        "acks total), then the read-back + reply. Chunk seqs continue from "
        "the go frame's 0: (i+1) % 128, wrapping THROUGH 0. The input meta "
        "is reply-form (slot 509's carries the 0x10 flag and the high-bank "
        "1), so the outbound long 0x52 must clear 0x10, set payload[8]=pos "
        "and payload[9]=0x06. No checksum exists anywhere. "
        + HEX_NOTE + " " + REGEN,
        cases)


# --------------------------------------------------- write_conversation.json

def gen_write_conversation() -> int:
    from microfreak.device import MicroFreak
    slot = 300
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=False)
    fc = FakeClock()
    mf = MicroFreak(sim, clock=fc, sleep=fc.sleep)
    blob = _synth_blob(7, "write-conversation")
    assert len(blob) == p.BLOB_SIZE and all(b <= 0x7F for b in blob)
    meta_in = sim.peek(slot).meta            # reply-form, as a real read yields
    name = "Conversation 300"
    report = mf.write(slot, Preset(name=name, blob=blob, meta=meta_in))
    assert report.verified is True and report.slot == slot
    assert report.sha256 == p.digest(blob) and report.name == name
    assert sim.faults == [], sim.faults
    after = sim.peek(slot)
    assert after.blob == blob and after.name == name
    outs = sum(1 for d, _ in sim.wire_log if d == "out")
    ins = sum(1 for d, _ in sim.wire_log if d == "in")
    # write burst: 151 out / 151 in; verify dump: open + 146 pulls / 146 chunks
    assert (outs, ins) == (298, 297), (outs, ins)
    acks = sum(1 for d, raw in sim.wire_log
               if d == "in" and p.parse(raw).cmd == p.CMD_NEXT)
    assert acks == 149, acks
    case = {
        "slot": slot,
        "name": name,
        "meta": hx(meta_in),
        "blob_seed": 7,
        "blob_label": "write-conversation",
        "blob_hex": hx(blob),
        "blob_sha256": p.digest(blob),
        "report": {"slot": report.slot, "sha256": report.sha256,
                   "name": report.name, "verified": True},
        "counts": {"out_frames": outs, "in_frames": ins,
                   "write_acks": acks, "verify_chunks": p.CHUNK_COUNT},
        "transcript": transcript(sim),
    }
    return emit(
        "write_conversation.json",
        "One complete VERIFIED write conversation: MicroFreak.write(300, "
        "preset, verify=True) against factory_fresh(reply_lag=False), "
        "blob = _synth_blob(7, 'write-conversation'). The transcript is "
        "every wire frame both directions in order: the 7-frame gate "
        "sequence (read-name + reply, long 0x52 + ack, short 0x52 open + "
        "ack, go seq 0 + ack, 145 x 0x16 + 1 x 0x17 each acked, read-back "
        "+ reply), THEN the verify read-back dump (open, unanswered, plus "
        "146 pull/chunk lockstep pairs) whose reassembled blob must "
        "sha256-match what was sent. Slot 300: bank 2/pos 0x2C, meta[0] "
        "carries the reply-only 0x10 flag (>= 128, cleared outbound), "
        "payload[9] high-bank flag 0 (< 384). Session seqs: 1 (read), 2 "
        "(name write), 3 (open), 4 (read-back), 5 (dump open), pulls "
        "6..127 then 1..24 (the addressed counter skips 0); the go/chunk "
        "stream is 0 then (i+1) % 128, wrapping through 0. 'report' is "
        "the WriteReport (duration omitted — fake-clock timing is not "
        "part of the contract). " + HEX_NOTE + " " + REGEN,
        [case])


# ------------------------------------------------------- device_state.json

def gen_device_state() -> int:
    seed, init_copies, slots = 0, 269, p.SLOTS
    named = slots - init_copies
    sim = SimulatedMicroFreak.factory_fresh(init_copies=init_copies, seed=seed)
    state = {}
    records = []
    shas = set()
    for slot in range(slots):
        pr = sim.peek(slot)
        sha = p.digest(pr.blob)
        state[f"{slot:03d}"] = {"name": pr.name, "sha256": sha,
                                "meta": hx(pr.meta)}
        records.append(SlotRecord(slot=slot, name=pr.name, sha256=sha,
                                  meta=pr.meta, blob=None))
        shas.add(sha)
        # positional-meta invariants, every slot
        assert bool(pr.meta[0] & p.REPLY_META_FLAG) == (slot >= p.SLOTS_PER_BANK)
        assert pr.meta[5] == slot % p.SLOTS_PER_BANK
        assert pr.meta[6] == (0 if slot < p.HIGH_BANK_BOUNDARY else 1)
    init_sha = p.digest(_synth_blob(seed, "init"))
    assert state["000"]["name"] == "Patch 000"
    assert state[f"{named - 1:03d}"]["name"] == f"Patch {named - 1:03d}"
    assert all(state[f"{s:03d}"]["name"] == "Init"
               and state[f"{s:03d}"]["sha256"] == init_sha
               for s in range(named, slots))
    assert len(shas) == named + 1, len(shas)          # 243 distinct + 1 Init
    expendable = find_expendable(records)
    assert expendable == set(range(named, slots)), "expendable != init zone"
    case = {
        "seed": seed,
        "init_copies": init_copies,
        "slots": slots,
        "named_slots": named,
        "init_blob_sha256": init_sha,
        "distinct_sha_count": len(shas),
        "expected_expendable": {"first_slot": named, "count": init_copies},
        "state": state,
    }
    return emit(
        "device_state.json",
        "The deterministic factory state of SimulatedMicroFreak."
        "factory_fresh(seed=0, init_copies=269): all 512 slots as "
        "zero-padded slot -> {name, sha256 of the 4672-byte blob, meta "
        "(reply-form, 9 bytes)}. Slots 0..242 are distinct named presets "
        "'Patch NNN' with per-slot _synth_blob(0, 'slot<NNN>') blobs; "
        "slots 243..511 are 269 byte-identical factory 'Init' duplicates "
        "of _synth_blob(0, 'init') — so find_expendable (threshold 3) "
        "returns exactly the init zone, and meta is positionally correct "
        "(0x10 flag in meta[0] for slots >= 128, meta[5]=pos, meta[6] "
        "flips 0->1 at slot 384). A Swift factoryFresh with the same seed "
        "must reproduce every name, sha and meta byte for snapshot/sync/"
        "expendability parity. " + HEX_NOTE + " " + REGEN,
        [case])


# ------------------------------------------------------------ read_dump.json

def dump_case(slot: int, *, with_name_read: bool, reply_lag: bool) -> dict:
    sim = SimulatedMicroFreak.factory_fresh(reply_lag=reply_lag)
    sess = make_session(sim)
    case = {"slot": slot, "reply_lag": reply_lag}
    if with_name_read:
        info = sess.read_name(slot)
        assert info.slot == slot
        case["name_info"] = {"slot": info.slot, "name": info.name,
                             "meta": hx(info.meta)}
    blob = sess.read_blob(slot)
    assert sim.faults == [], sim.faults
    assert blob == sim.peek(slot).blob and len(blob) == p.BLOB_SIZE
    pull_seqs = [p.parse(raw).seq for d, raw in sim.wire_log
                 if d == "out" and p.parse(raw).cmd == p.CMD_NEXT]
    assert len(pull_seqs) == p.CHUNK_COUNT
    case.update({
        "pull_seqs": pull_seqs,
        "chunk_count": p.CHUNK_COUNT,
        "blob_hex": hx(blob),
        "blob_sha256": p.digest(blob),
        "transcript": transcript(sim),
    })
    return case


def gen_read_dump() -> int:
    cases = [dump_case(200, with_name_read=True, reply_lag=False),
             dump_case(511, with_name_read=False, reply_lag=True)]
    return emit(
        "read_dump.json",
        "Complete read/dump conversations against factory_fresh "
        "SimulatedMicroFreak. Case 1 (slot 200, reply_lag off): name read + "
        "reply, then the dump. Case 2 (slot 511, reply_lag ON — dumps are "
        "unaffected by name-reply lag): dump only. A dump is: open "
        "[bank,pos,0x01] (unanswered), then strict lockstep — 146 pull-next "
        "0x18 requests (len 0x01, payload [0x00]), each answered by one "
        "chunk (145 x 0x16 + 1 x 0x17, 32 bytes each) echoing its pull's "
        "seq. Session seqs walk 1..127 and wrap SKIPPING 0 (the addressed-"
        "request counter never emits 0). Reassembled blob must be exactly "
        "4672 bytes. " + HEX_NOTE + " " + REGEN,
        cases)


# ------------------------------------------------------------ reply_lag.json

def lag_wire_case() -> dict:
    sim = SimulatedMicroFreak.factory_fresh()
    assert sim.reply_lag is True
    reads = [(1, 5), (2, 9), (3, 12)]
    releases = []
    for seq, slot in reads:
        sim.send(p.read_name_req(seq, slot))
        raw = sim.receive(0.0)
        if raw is None:
            releases.append(None)
        else:
            info = p.decode_name_reply(p.parse(raw))
            releases.append({"reply_slot": info.slot, "name": info.name,
                             "reply_seq": p.parse(raw).seq})
    assert releases[0] is None                       # first reply is held
    assert releases[1]["reply_slot"] == 5 and releases[1]["reply_seq"] == 1
    assert releases[2]["reply_slot"] == 9 and releases[2]["reply_seq"] == 2
    return {
        "kind": "raw_wire_lag",
        "requests": [{"seq": s, "slot": sl} for s, sl in reads],
        "reply_after_each_request": releases,
        "transcript": transcript(sim),
        "note": "reply N is held until request N+1 arrives; the released "
                "reply echoes ITS OWN request's seq and embedded address — "
                "a naive first-reply-for-latest-request pairing mislabels "
                "slot 9 with slot 5's data",
    }


def lag_session_case() -> dict:
    sim = SimulatedMicroFreak.factory_fresh()
    sess = make_session(sim)
    order = [0, 511, 7, 384, 7, 200, 383, 1, 400, 12, 0, 269, 500, 268, 3]
    results = []
    for slot in order:
        info = sess.read_name(slot)
        expected = sim.peek(slot)
        assert info.slot == slot and info.name == expected.name
        assert info.meta == expected.meta
        results.append({"requested_slot": slot, "name": info.name,
                        "meta": hx(info.meta)})
    assert sim.faults == [], sim.faults
    requests_sent = sum(
        1 for d, raw in sim.wire_log
        if d == "out"
        for f in [p.parse(raw)]
        if f.cmd == p.CMD_OPEN and f.data[2] == 0x00)
    assert requests_sent > len(order)                # the defense engaged
    return {
        "kind": "session_scrambled_order",
        "read_order": order,
        "results": results,
        "reads": len(order),
        "name_requests_sent": requests_sent,
        "transcript": transcript(sim),
        "note": "scrambled slots with revisits over a lag-ON sim; the "
                "Session matches each reply's embedded bank/pos to the "
                "request, discarding stale replies and resending — so "
                "name_requests_sent > reads, and every result is labeled "
                "correctly. The first read costs one full name_timeout "
                "(the sim holds every first reply, harsher than hardware).",
    }


def gen_reply_lag() -> int:
    cases = [lag_wire_case(), lag_session_case()]
    return emit(
        "reply_lag.json",
        "Reply-lag scenarios from SimulatedMicroFreak with reply_lag=True "
        "(the default): the reply to name-read N is held and emitted only "
        "when name-read N+1 arrives, rendered from device state at emission "
        "time. Case 1 shows the raw hazard on the wire; case 2 is a full "
        "Session transcript over a scrambled slot order (revisits included) "
        "proving embedded-address matching never mislabels. Session driven "
        "by a deterministic FakeClock (sleep advances time by max(dt, "
        "1e-4)); name_timeout 1.0, poll sleep 0.002. " + HEX_NOTE + " " + REGEN,
        cases)


# ------------------------------------------------------------ sync_diff.json

def _snapshot(records) -> DeviceSnapshot:
    return DeviceSnapshot(taken_at="2026-09-01T00:00:00",
                          records=tuple(records),
                          timing=TimingReport(0.0, 0.0, None, None))


def _rec(slot, name, sha) -> SlotRecord:
    return SlotRecord(slot=slot, name=name, sha256=sha, meta=None, blob=None)


def _rec_json(r: SlotRecord) -> dict:
    return {"slot": r.slot, "name": r.name, "sha256": r.sha256}


def _bref(name: str, sha: str) -> PresetRef:
    return PresetRef(sha256=sha, name=name, meta_hex="080000000000000033")


def gen_sync_diff() -> int:
    u = {i: p.digest(_synth_blob(11, f"user{i}")) for i in range(4)}
    init_sha = p.digest(_synth_blob(11, "init"))
    newer_sha = p.digest(_synth_blob(11, "newer"))
    missing_sha = p.digest(_synth_blob(11, "missing"))
    records = ([_rec(i, f"User {i}", u[i]) for i in range(4)]
               + [_rec(s, "Init", init_sha) for s in (500, 501, 502, 503)])
    baseline = {0: _bref("User 0", u[0]),
                1: _bref("Newer Take", newer_sha),
                500: _bref("Went Missing", missing_sha),
                501: _bref("Kept Init", init_sha)}
    snap = _snapshot(records)

    def diff_case(name, threshold, note, *, recs=None, base=None):
        recs = records if recs is None else recs
        base = baseline if base is None else base
        kwargs = {} if threshold is None else {"threshold": threshold}
        d = diff_baseline(_snapshot(recs), base, **kwargs)
        return {
            "name": name,
            "threshold": threshold,
            "records": [_rec_json(r) for r in recs],
            "baseline": [{"slot": s, "sha256": base[s].sha256,
                          "name": base[s].name, "meta_hex": base[s].meta_hex}
                         for s in sorted(base)],
            "expected": [{"slot": row.slot, "status": row.status.value,
                          "status_name": row.status.name,
                          "name_differs": row.name_differs}
                         for row in d.slots],
            "unread_baseline_slots": list(d.unread_baseline_slots),
            "note": note,
        }

    sparse = {0: _bref("User 0", u[0])}
    exact = {r.slot: _bref(r.name, r.sha256) for r in records}
    renamed = dict(exact)
    renamed[2] = _bref("Renamed Only", u[2])

    cases = [
        diff_case("five_statuses", None,
                  "default threshold 3: 0 IN_SYNC, 1 DIFFERS, 2/3 UNLISTED "
                  "(the baseline says nothing about those slots — NOT "
                  "missing), 500 BASELINE_ONLY (the collection places a "
                  "preset over an expendable slot), 501 IN_SYNC (sha equality "
                  "wins before expendability), 502/503 EMPTY"),
        diff_case("threshold_5", 5,
                  "at threshold 5 the four Inits stop being expendable: "
                  "500 becomes DIFFERS, 502/503 become UNLISTED; sha "
                  "equality (0, 501) is unaffected"),
        diff_case("sparse_baseline", None,
                  "the regression that names the bug: a baseline mentioning "
                  "only slot 0 against 8 device slots reports 0 IN_SYNC and "
                  "NOTHING else actionable — zero `missing`, zero `changed`. "
                  "Slots a collection is silent about are UNLISTED/EMPTY.",
                  base=sparse),
        diff_case("exact_match", None,
                  "baseline == every device record: all IN_SYNC, every other "
                  "bucket empty — a device holding its collection reads as in "
                  "sync, expendable Init slots included",
                  base=exact),
        diff_case("name_only_differs", None,
                  "slot 2's baseline ref has the same sha under a different "
                  "name: status stays IN_SYNC (the diff is content-based) but "
                  "name_differs is true, which is what drives plan_apply to "
                  "WRITE",
                  base=renamed),
        diff_case("unread_baseline_slots", None,
                  "the snapshot covers slots 0..3 only; the baseline's 500 "
                  "and 501 come back in unread_baseline_slots — unknown, "
                  "never reported as missing",
                  recs=records[:4]),
    ]
    # sanity-pin the headline cases against the reference expectations
    st = {c["slot"]: c["status_name"] for c in cases[0]["expected"]}
    assert st == {0: "IN_SYNC", 1: "DIFFERS", 2: "UNLISTED",
                  3: "UNLISTED", 500: "BASELINE_ONLY", 501: "IN_SYNC",
                  502: "EMPTY", 503: "EMPTY"}, st
    st5 = {c["slot"]: c["status_name"] for c in cases[1]["expected"]}
    assert st5[500] == "DIFFERS" and st5[502] == "UNLISTED"
    sparse_st = {c["slot"]: c["status_name"] for c in cases[2]["expected"]}
    assert sparse_st[0] == "IN_SYNC"
    assert "BASELINE_ONLY" not in sparse_st.values(), sparse_st
    assert "DIFFERS" not in sparse_st.values(), sparse_st
    assert {c["status_name"] for c in cases[3]["expected"]} == {"IN_SYNC"}
    nd = {c["slot"]: (c["status_name"], c["name_differs"])
          for c in cases[4]["expected"]}
    assert nd[2] == ("IN_SYNC", True) and nd[0] == ("IN_SYNC", False), nd
    assert cases[5]["unread_baseline_slots"] == [500, 501]

    bad_records = [_rec(0, "User 0", u[0]), _rec(1, "Unread", None)]
    try:
        diff_baseline(_snapshot(bad_records), baseline)
        raise AssertionError("diff without hashes must refuse")
    except ValueError:
        pass
    cases.append({
        "name": "refuses_missing_hashes",
        "threshold": None,
        "records": [_rec_json(r) for r in bad_records],
        "baseline": [],
        "expect_error": "ValueError",
        "note": "diff requires every record to carry sha256 — refusing "
                "beats guessing",
    })
    return emit(
        "sync_diff.json",
        "Pure sync.diff_baseline decision-table vectors: synthetic device "
        "snapshot records (slot, name, sha256 — shas are real sha256 hex of "
        "seeded blobs, but only string equality matters) against a BASELINE "
        "arrangement ({slot: PresetRef}, normally a PresetCollection's "
        "slots). The library is never a baseline: it is a flat catalog and "
        "carries no slot opinion. Status enum: IN_SYNC='in_sync', "
        "UNLISTED='unlisted' (baseline silent, device slot real), "
        "BASELINE_ONLY='missing' (baseline places a preset, device slot "
        "expendable), DIFFERS='changed', EMPTY='empty'. `name_differs` is "
        "true when the shas match but the names do not — never a status "
        "change, but it is what makes plan_apply WRITE. "
        "`unread_baseline_slots` lists baseline slots the snapshot never "
        "covered. Rows come back one per record, ascending slot. threshold "
        "null means the default DUPLICATE_THRESHOLD=3. " + REGEN,
        cases)


# ----------------------------------------------------------- expendable.json

def gen_expendable() -> int:
    def case(name, records, expected, *, threshold=None, note=""):
        kwargs = {} if threshold is None else {"threshold": threshold}
        got = find_expendable(records, **kwargs)
        assert got == set(expected), (name, got, expected)
        c = {"name": name, "threshold": threshold,
             "records": [_rec_json(r) for r in records],
             "expected_expendable": sorted(got)}
        if note:
            c["note"] = note
        return c

    r = _rec
    cases = [
        case("two_copies_kept",
             [r(0, "Dup", "d"), r(1, "Dup", "d"), r(2, "Solo", "s")], [],
             note="threshold boundary: 2 identical blobs stay below the "
                  "default DUPLICATE_THRESHOLD of 3 — a user's own single "
                  "duplicate is never expendable"),
        case("three_copies_expendable",
             [r(0, "Dup", "d"), r(1, "Dup", "d"), r(2, "Solo", "s"),
              r(3, "Dup", "d")], [0, 1, 3],
             note="threshold boundary: at exactly 3 copies all three are "
                  "expendable; the solo is kept"),
        case("threshold_override_2",
             [r(0, "Dup", "d"), r(1, "Dup", "d"), r(2, "Solo", "s")], [0, 1],
             threshold=2),
        case("threshold_override_4",
             [r(0, "Dup", "d"), r(1, "Dup", "d"), r(2, "Solo", "s"),
              r(3, "Dup", "d")], [], threshold=4),
        case("blank_names_and_unknowns",
             [r(0, "", "u1"), r(1, "   ", "u2"), r(2, None, "u3"),
              r(3, "", None), r(4, "Keeper", "u4"), r(5, None, None)],
             [0, 1],
             note="blank/whitespace READ names are expendable; name=None "
                  "(read FAILED) with unique content is NOT; sha256=None is "
                  "never expendable — unknown is not empty"),
        case("init_name_never_matched",
             [r(0, "Init", "unique-a"), r(1, "Init", "unique-b"),
              r(2, "My Patch", "unique-c")], [],
             note="emptiness is a content judgement: the string 'Init' is "
                  "never matched by name"),
        case("three_inits_by_content",
             [r(0, "Init", "i"), r(1, "Init", "i"), r(2, "Init", "i")],
             [0, 1, 2]),
        case("name_none_unique_sha",
             [r(0, None, "u"), r(1, "Keeper", "k")], [],
             note="an unreadable name with unique content is never "
                  "expendable — a transient name-read failure cannot make "
                  "a unique preset overwritable"),
        case("name_none_in_duplicate_group",
             [r(0, None, "d"), r(1, "Init", "d"), r(2, "Init", "d")],
             [0, 1, 2],
             note="name=None disqualifies only the blank-name rule; the "
                  "sha-duplicate rule still applies, so a name-read-failed "
                  "slot whose CONTENT is mass-duplicated is expendable "
                  "(find_expendable's elif chain)"),
        case("sha_none_never_expendable",
             [r(0, "", None), r(1, None, None), r(2, "Init", None)], [],
             note="content unread: no rule can fire"),
    ]
    return emit(
        "expendable.json",
        "analysis.find_expendable vectors. A slot is expendable when its "
        "successfully-read name is blank/whitespace-only, OR its sha256 "
        "occurs >= threshold times (default DUPLICATE_THRESHOLD=3). sha256 "
        "values here are symbolic tokens — only string equality matters. "
        "null name means the name read FAILED; null sha256 means content "
        "unread; neither ever satisfies its respective rule. threshold "
        "null means the default 3. " + REGEN,
        cases)


# ------------------------------------------------------------ category.json

def gen_category() -> int:
    decode = []
    for byte in range(0x00, 0x11):        # 13 mapped + three past-the-table bytes
        cat = Category.from_device_byte(byte)
        decode.append({"byte": byte, "slug": cat.slug})
    # pin the two invariants: byte->slug table and the clamp
    assert decode[0x03]["slug"] == "keys"          # slot-200 ground-truth byte
    assert all(d["slug"] == "uncategorized" for d in decode[0x0D:])
    slug_roundtrip = []
    for cat in Category:
        assert Category.from_slug(cat.slug) is cat
        slug_roundtrip.append(cat.slug)
    assert Category.from_slug("future_cat") is Category.UNCATEGORIZED
    cases = [{
        "name": "device_byte_decode",
        "decode": decode,
        "note": "index == the device category byte (meta[7] == long-0x52 "
                "payload[10]); bytes 0x0D and up clamp to uncategorized",
    }, {
        "name": "slug_roundtrip",
        "slugs": slug_roundtrip,
        "unknown_slug": "future_cat",
        "unknown_expected": "uncategorized",
        "note": "from_slug(slug).slug == slug for all 13; an unknown slug "
                "loads as uncategorized (forward compat), never a crash",
    }]
    return emit(
        "category.json",
        "Category device-byte decode table and slug round-trip. "
        "from_device_byte(byte) maps 0x00..0x0C to the 13 Arturia slugs and "
        "clamps every other byte to 'uncategorized'. Slugs are the stable "
        "wire form used in the library index and collection files by both "
        "cores. " + REGEN,
        cases)


# -------------------------------------------------------- library_attrs.json

def _attr_entry(i: int, name: str, cat: Category, favorite: bool, tags) -> LibraryEntry:
    return LibraryEntry(id=f"lib{i:02d}", name=name,
                        sha256=p.digest(_synth_blob(7, f"attr{i}")),
                        meta_hex="080000000000000033", slot=i,
                        added_at="2026-09-01T00:00:00", tags=tuple(tags),
                        category=cat, favorite=favorite)


def gen_library_attrs() -> int:
    cases = []

    # round-trip: entry -> index JSON -> entry, category/favorite/tags carried
    rt = [
        _attr_entry(0, "Pad One", Category.PAD, True, ("ambient", "pad")),
        _attr_entry(1, "Deep Bass", Category.BASS, False, ("sub",)),
        _attr_entry(2, "Plain", Category.UNCATEGORIZED, False, ()),
    ]
    for e in rt:
        d = _entry_to_json(e)
        assert _entry_from_json(d) == e
        cases.append({
            "name": f"roundtrip_{e.id}",
            "entry_json": d,
            "expected": {"category": e.category.slug, "favorite": e.favorite,
                         "tags": list(e.tags)},
        })

    # additive back-compat: an OLD index entry lacking category/favorite/tags
    old_json = {"id": "old0", "name": "Legacy", "sha256": rt[0].sha256,
                "meta_hex": "080000000000000033", "slot": 5,
                "added_at": "2026-01-01T00:00:00"}     # NO tags/category/favorite
    parsed = _entry_from_json(old_json)
    assert parsed.category is Category.UNCATEGORIZED
    assert parsed.favorite is False and parsed.tags == ()
    cases.append({
        "name": "old_index_defaults",
        "entry_json": old_json,
        "expected": {"category": "uncategorized", "favorite": False, "tags": []},
        "note": "an index predating these keys loads with defaults "
                "(category=uncategorized, favorite=false, tags=[])",
    })

    # category_census over a small entry set: every category key present
    census_entries = [
        _attr_entry(0, "a", Category.PAD, False, ()),
        _attr_entry(1, "b", Category.PAD, False, ()),
        _attr_entry(2, "c", Category.BASS, False, ()),
        _attr_entry(3, "d", Category.UNCATEGORIZED, False, ()),
    ]
    census = category_census(census_entries)
    census_slugs = {c.slug: n for c, n in census.items()}
    assert census_slugs["pad"] == 2 and census_slugs["bass"] == 1
    assert census_slugs["uncategorized"] == 1 and census_slugs["lead"] == 0
    assert sum(census_slugs.values()) == len(census_entries)
    cases.append({
        "name": "category_census",
        "entries": [{"category": e.category.slug} for e in census_entries],
        "expected_census": census_slugs,
        "note": "counts per category with every category key present (0 when "
                "none), so the UI chip row is stable",
    })
    return emit(
        "library_attrs.json",
        "Additive library-index preset attributes: category (Category slug), "
        "favorite (bool), tags ([str]). 'roundtrip' cases assert an entry "
        "serializes and parses back identically; 'old_index_defaults' asserts "
        "an entry dict missing the new keys parses with defaults (additive "
        "back-compat, schema stays 1); 'category_census' pins the per-category "
        "counts helper. " + REGEN,
        cases)


# --------------------------------------------------------- collections.json

def _cref(seed: str, name: str) -> PresetRef:
    return PresetRef(sha256=p.digest(_synth_blob(9, seed)), name=name,
                     meta_hex="080000000000000033")


def gen_collections() -> int:
    cases = []

    # collection JSON round-trip, one per provenance kind
    refs = {0: _cref("c0", "Voltage Forms"),
            128: _cref("c1", "Tokyo88 V3"),
            384: _cref("c2", "High Bank")}
    for kind in ProvenanceKind:
        coll = PresetCollection(id=p.digest(kind.value.encode())[:32],
                                name=f"Set {kind.value}",
                                created_at="2026-09-01T14:32:00",
                                provenance=Provenance(kind=kind,
                                                      source="Ambient Peaks.mfprojz"),
                                slots=dict(refs))
        d = collection_to_json(coll)
        assert collection_from_json(d) == coll
        cases.append({
            "name": f"roundtrip_{kind.value}",
            "collection": d,
            "expected_slots": [{"slot": s, "sha256": refs[s].sha256,
                                "name": refs[s].name,
                                "meta_hex": refs[s].meta_hex}
                               for s in sorted(refs)],
            "expected_provenance": {"kind": kind.value,
                                    "source": "Ambient Peaks.mfprojz"},
        })

    # plan_apply decision table over a synthetic full hashed snapshot (6 slots)
    sha = {k: p.digest(_synth_blob(9, k)) for k in
           ("keep", "old", "new", "alpha", "gone", "init", "untouched")}

    def rec(slot, name, key):
        return SlotRecord(slot=slot, name=name, sha256=sha[key],
                          meta=None, blob=None)

    records = [rec(0, "Keep", "keep"), rec(1, "Old", "old"),
               rec(2, "Alpha", "alpha"), rec(3, "Gone", "gone"),
               rec(4, "Init", "init"), rec(5, "Untouched", "untouched")]
    snap = DeviceSnapshot(taken_at="2026-09-01T00:00:00",
                          records=tuple(records),
                          timing=TimingReport(0.0, 0.0, None, None))
    # collection covers 0 (unchanged), 1 (sha differs), 2 (name-only differs)
    coll = PresetCollection.new(
        "Plan", Provenance(ProvenanceKind.MANUAL),
        {0: PresetRef(sha["keep"], "Keep", "080000000000000033"),
         1: PresetRef(sha["new"], "New", "080000000000000033"),
         2: PresetRef(sha["alpha"], "Beta", "080000000000000033")})
    clear_with = PresetRef(sha["init"], "Init", "080000000000000033")

    def snap_json():
        return [{"slot": r.slot, "name": r.name, "sha256": r.sha256}
                for r in records]

    def coll_slots_json(c):
        return {str(s): {"sha256": c.slots[s].sha256, "name": c.slots[s].name,
                         "meta_hex": c.slots[s].meta_hex}
                for s in sorted(c.slots)}

    def plan_case(name, options, expected):
        plan = plan_apply(coll, snap, options=options)
        got = {sp.slot: sp.action.value for sp in plan.slots}
        assert got == expected, (name, got, expected)
        c = {"name": name,
             "snapshot": snap_json(),
             "collection_slots": coll_slots_json(coll),
             "options": {"unlisted": options.unlisted,
                         "clear_with": (None if options.clear_with is None else
                                        {"sha256": options.clear_with.sha256,
                                         "name": options.clear_with.name,
                                         "meta_hex": options.clear_with.meta_hex}),
                         "seconds_per_write": options.seconds_per_write},
             "expected": [{"slot": sp.slot, "action": sp.action.value}
                          for sp in plan.slots],
             "write_count": plan.write_count,
             "clear_count": plan.clear_count,
             "skip_count": plan.skip_count,
             "total_slots": plan.total_slots,
             "estimated_seconds": plan.estimated_seconds}
        return c

    cases.append(plan_case(
        "clear_policy",
        ApplyOptions(unlisted="clear", clear_with=clear_with),
        {0: "skip", 1: "write", 2: "write", 3: "clear", 4: "skip", 5: "clear"}))
    cases.append(plan_case(
        "leave_policy",
        ApplyOptions(unlisted="leave"),
        {0: "skip", 1: "write", 2: "write", 3: "skip", 4: "skip", 5: "skip"}))
    # pin the headline counts
    assert cases[-2]["write_count"] == 2 and cases[-2]["clear_count"] == 2
    assert cases[-2]["estimated_seconds"] == 4.0
    assert cases[-1]["write_count"] == 2 and cases[-1]["skip_count"] == 4
    assert cases[-1]["estimated_seconds"] == 2.0

    # error: a hash-less / partial snapshot is undecidable
    partial = DeviceSnapshot(
        taken_at="2026-09-01T00:00:00",
        records=(SlotRecord(0, "Keep", sha["keep"], None, None),
                 SlotRecord(1, "Old", None, None, None)),
        timing=TimingReport(0.0, 0.0, None, None))
    try:
        plan_apply(coll, partial)
        raise AssertionError("hash-less/partial snapshot must be refused")
    except ValueError:
        pass
    cases.append({
        "name": "refuses_partial_snapshot",
        "snapshot": [{"slot": 0, "name": "Keep", "sha256": sha["keep"]},
                     {"slot": 1, "name": "Old", "sha256": None}],
        "collection_slots": coll_slots_json(coll),
        "expect_error": "ValueError",
        "note": "plan_apply requires a FULL hashed snapshot (every slot "
                "0..N-1 present, has_hashes) — refusing beats guessing",
    })
    return emit(
        "collections.json",
        "PresetCollection JSON round-trip (one case per provenance.kind; "
        "slots keyed by decimal-string slot, refs are {sha256,name,meta_hex}) "
        "and the pure plan_apply decision table. Actions: WRITE='write' "
        "(content OR name differs), SKIP_UNCHANGED='skip' (sha AND name "
        "equal), CLEAR='clear' (unlisted slot overwritten with clear_with). "
        "estimated_seconds == round((write+clear) * seconds_per_write, 1). "
        "shas are real sha256 hex of seeded blobs but only string equality "
        "matters, following the sync_diff convention. " + REGEN,
        cases)


# ---------------------------------------------------------- bank_import.json
#
# Golden fixture for the SWIFT .mfprojz/.mbp reader (MFProjzImport.swift), a
# port of the VERIFIED tools/mbp_import.py. The expected values here are
# produced BY that verified parser, so the Swift port is checked against the
# reference — the Boost text tokenizer, latin-1 decode, hex-meta decode, the
# sub-bank slot map, AND the hand-rolled Zip/DEFLATE reader (a real DEFLATE
# member and a STORED member). Emitted to the app test target, not OUT_DIR.

def _bank_blob(seed: int) -> bytes:
    """A deterministic 4672-byte MCC byte array (full 0..255 range — the .mbp
    blob is not 7-bit limited, unlike a wire payload)."""
    out = bytearray(p.BLOB_SIZE)
    x = (seed * 2654435761 + 1) & 0xFFFFFFFF
    for i in range(p.BLOB_SIZE):
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF
        out[i] = (x >> 16) & 0xFF
    return bytes(out)


def _mbp_text(name: str, blob, meta_hex: str) -> str:
    """A MicroFreak Boost archive parseable by tools/mbp_import (same shape as
    tests/test_core_collections.py's helper). blob=None -> a short archive
    (name only), which the parser reports as an empty slot."""
    head = f"serialization::archive 17 0 0 0 0 {len(name)} {name}"
    if blob is None:
        return head + " 0 0 0"
    return (head + f" 0 0 0 {len(meta_hex)} {meta_hex} 0 0 1 {p.BLOB_SIZE} "
            + " ".join(str(b) for b in blob))


def _expected(pr: "mbp_import.MbpPreset") -> dict:
    return {
        "slot": pr.slot,
        "name": pr.name,
        "meta_hex": pr.meta.hex(),
        "blob_sha256": (None if pr.blob is None
                        else hashlib.sha256(pr.blob).hexdigest()),
        "is_empty": pr.is_empty,
    }


def gen_bank_import() -> int:
    APP_FIXTURES.mkdir(parents=True, exist_ok=True)
    b0, b1, b2 = _bank_blob(1), _bank_blob(2), _bank_blob(3)
    meta0 = "080000000005000311"          # 9 bytes, non-zero (exercises decode)
    meta1 = "00" * 9                       # all-zero (a realistic pack export)

    # --- standalone .mbp: "07-Voltage Forms-A7.mbp" -> slot 6 ---------------
    mbp_name = "07-Voltage Forms-A7.mbp"
    mbp_bytes = _mbp_text("Voltage Forms", b0, meta0).encode("latin-1")
    # Parse through the verified parser with the real source filename (the
    # slot derives from it); read_mbp would use the temp file's random name.
    mbp_expected = _expected(mbp_import.parse_mbp_text(
        mbp_bytes.decode("latin-1"), order=1, source=mbp_name))
    assert mbp_expected["slot"] == 6 and mbp_expected["name"] == "Voltage Forms"
    assert mbp_expected["blob_sha256"] == hashlib.sha256(b0).hexdigest()

    # --- .mfprojz: a DEFLATE member, a STORED member, an empty slot, and a
    #     non-.mbp file (which must be ignored). Members come back sorted by
    #     name, exactly as the Swift Zip reader returns them. -----------------
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("07-Voltage Forms-A7.mbp", _mbp_text("Voltage Forms", b0, meta0))
        z.writestr("259-Tokyo88 V3-C4.mbp", _mbp_text("Tokyo88 V3", b1, meta1),
                   compress_type=zipfile.ZIP_STORED)        # STORED path
        z.writestr("04-Twin Peaks-A4.mbp", _mbp_text("Twin Peaks", b2, meta0))
        z.writestr("40-Init-B1.mbp", _mbp_text("Init", None, ""))   # empty slot
        z.writestr("manifest.txt", "not a preset; must be ignored")
    projz_bytes = buf.getvalue()
    with tempfile.NamedTemporaryFile(suffix=".mfprojz", delete=False) as f:
        f.write(projz_bytes)
        projz_path = Path(f.name)
    try:
        parsed = mbp_import.read_mfprojz(projz_path)
    finally:
        os.unlink(projz_path)
    projz_expected = [_expected(pr) for pr in parsed]
    # sorted filename order: "04-…" < "07-…" < "259-…" < "40-…"
    assert [e["name"] for e in projz_expected] == [
        "Twin Peaks", "Voltage Forms", "Tokyo88 V3", "Init"]
    # slot is the GLOBAL 1-based filename prefix minus one (see mbp_import):
    # "04-…"->3, "07-…"->6, "259-…"->258, "40-…"->39
    assert [e["slot"] for e in projz_expected] == [3, 6, 258, 39]
    assert projz_expected[-1]["is_empty"] and projz_expected[-1]["blob_sha256"] is None
    assert projz_expected[1]["meta_hex"] == meta0
    assert projz_expected[2]["meta_hex"] == meta1

    doc = {
        "description":
            "Golden fixture for the Swift .mfprojz/.mbp reader "
            "(App/Sources/Support/MFProjzImport.swift), a port of the verified "
            "tools/mbp_import.py. 'mbp' is one standalone Boost archive; "
            "'mfprojz' is a Zip of .mbp members (one DEFLATE, one STORED, one "
            "empty/short archive, plus a non-.mbp file to be ignored), members "
            "in sorted-filename order. 'bytes_b64' is the exact file bytes fed "
            "to MFProjzImport.parse; 'expected' is what the VERIFIED Python "
            "parser yields — slot (the global 1-based filename prefix minus "
            "one), name, meta_hex "
            "(lowercase), blob_sha256 (lowercase sha256 of the 4672-byte blob, "
            "null for an empty slot), is_empty. Regenerate: python3 "
            "tools/gen_vectors.py (from the repo root).",
        "mbp": {
            "filename": mbp_name,
            "bytes_b64": base64.b64encode(mbp_bytes).decode("ascii"),
            "expected": mbp_expected,
        },
        "mfprojz": {
            "filename": "Ambient Peaks.mfprojz",
            "bytes_b64": base64.b64encode(projz_bytes).decode("ascii"),
            "expected": projz_expected,
        },
    }
    path = APP_FIXTURES / "bank_import.json"
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return 1 + len(projz_expected)


# ------------------------------------------------------------- verification

def verify() -> list:
    lines = []
    for path in sorted(OUT_DIR.glob("*.json")):
        data = json.loads(path.read_text())     # must parse
        assert set(data) == {"description", "cases"}, path.name
        blob_count = 0

        def walk(node):
            nonlocal blob_count
            if isinstance(node, dict):
                for k, v in node.items():
                    if k == "blob_hex":
                        n = len(v.split())
                        assert n == p.BLOB_SIZE, (path.name, n)
                        blob_count += 1
                    elif k == "frame":
                        toks = v.split()
                        assert toks[:6] == ["F0", "00", "20", "6B", "07", "01"]
                        assert toks[-1] == "F7"
                        assert all(len(t) == 2 and t == t.upper()
                                   for t in toks)
                    else:
                        walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)

        walk(data["cases"])
        lines.append(f"{path.name}: {len(data['cases'])} cases"
                     + (f", {blob_count} x {p.BLOB_SIZE}-byte blobs"
                        if blob_count else ""))
    return lines


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    gen_frames()
    gen_name_replies()
    gen_write_burst()
    gen_write_conversation()
    gen_device_state()
    gen_read_dump()
    gen_reply_lag()
    gen_sync_diff()
    gen_expendable()
    gen_category()
    gen_library_attrs()
    gen_collections()
    bank_cases = gen_bank_import()
    for line in verify():
        print("OK  " + line)
    print(f"OK  bank_import.json: {bank_cases} parsed items "
          f"-> {APP_FIXTURES.relative_to(REPO_ROOT)}")
    print(f"vectors written to {OUT_DIR.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
