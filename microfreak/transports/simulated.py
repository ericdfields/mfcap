"""SimulatedMicroFreak: an in-memory device faithful to
docs/write-protocol.md. Stdlib only.

Implements Transport synchronously: send() runs the device state machine
inline and appends replies to an internal outbox; receive(timeout) pops the
outbox FIFO, returning None immediately when empty (no real sleeping —
offline tests are instant).

Fidelity (asserted by tests/test_simulated_fidelity.py):

1. Name reads reply with the full 35-byte long-0x52 payload: bank, pos,
   0x00, 5 opaque bytes, pos-again, the 0/1 slot-384 flag, category,
   attribute (printable values like 0x32/0x33 included, so header-leak
   regressions are caught), then the NUL-padded 23-byte name. The reply
   echoes its request's seq, as every captured reply does.
2. reply_lag=True (the default, so every offline test exercises the
   defense): the reply to name-read N is held and emitted only when
   name-read N+1 arrives; the first name read yields nothing. The held
   reply's content is rendered from device state at emission time — the
   behavior of a device that is slow to answer, not one that answers wrong.
   NOTE: this is deliberately HARSHER than hardware. On the real device a
   lone name read is answered; replies lag only under rapid back-to-back
   reads (write-protocol.md). Holding unconditionally guarantees the
   Session's retry defense engages in every offline run, at the cost of one
   name_timeout on a first read — do not tune real-time lag behavior
   against this model.
3. Dump reads: open [bank,pos,0x01], then 145 x 0x16 + 1 x 0x17 (32 bytes
   each), pull-paced by 0x18; each emitted chunk echoes its pull's seq, as
   captured.
4. Writes: the long 0x52 alone updates name+meta with no blob change (a
   rename is only this frame, per MCC); the short 0x52 [bank,pos,0x01]
   opens; 0x15 arms; 0x17 commits. Matching the captures, the device acks
   the long 0x52, the short 0x52 open, the 0x15 go AND every chunk, each
   with a 0x18 whose len byte is 0x00, payload empty, seq echoing the acked
   frame's seq. Inbound long-0x52 writes are validated against the captured
   outbound convention (payload[8]=pos, payload[9]=0x06, payload[3] without
   the reply-only 0x10 bit); deviations append to `faults`. A committed
   total != 4672 bytes, or chunks without an open, leaves the slot
   untouched and appends to `faults` — so a broken writer fails
   verification instead of passing. No checksum anywhere.
5. fail_chunk_at=N: the write chunk with 0-based cumulative index N (counted
   across the sim's lifetime) and every later one receive no 0x18 ack —
   drives ChunkNotAckedError and torn-write tests.

wire_log direction convention is the host's (mfcap house style): ("out",
raw) = host -> device, ("in", raw) = device -> host.
"""
from __future__ import annotations

import hashlib
from typing import Dict, List, Optional, Tuple

from .. import protocol
from ..model import Preset
from ..protocol import (BLOB_SIZE, CHUNK_COUNT, CHUNK_SIZE,
                        HIGH_BANK_BOUNDARY, META_LEN, NAME_LEN,
                        NAME_PAYLOAD_LEN, SLOTS, SLOTS_PER_BANK, frame)


def _synth_blob(seed: int, label: str) -> bytes:
    """Deterministic synthetic 4672-byte, 7-bit-clean content. No real
    Arturia blob is bundled."""
    out = bytearray()
    counter = 0
    while len(out) < BLOB_SIZE:
        h = hashlib.sha256(f"{seed}:{label}:{counter}".encode()).digest()
        out.extend(b & 0x7F for b in h)
        counter += 1
    return bytes(out[:BLOB_SIZE])


class _Slot:
    __slots__ = ("name", "meta", "blob")

    def __init__(self, name: str, meta: bytes, blob: bytes):
        self.name = name
        self.meta = meta      # META_LEN bytes = long-0x52 payload[3..11]
        self.blob = blob


class SimulatedMicroFreak:
    """Implements the Transport protocol; also the test back doors."""

    def __init__(self, *, slots: int = SLOTS, reply_lag: bool = True,
                 fail_chunk_at: Optional[int] = None):
        self.slots = slots
        self.reply_lag = reply_lag
        self.fail_chunk_at = fail_chunk_at
        self.faults: List[str] = []
        self.wire_log: List[Tuple[str, bytes]] = []
        self._state: Dict[int, _Slot] = {
            s: _Slot("Init", self._positional_meta(s, b"\x00" * 5, 0x00, 0x33),
                     b"\x00" * BLOB_SIZE)
            for s in range(slots)}
        self._outbox: List[bytes] = []
        # reply-lag holding cell: (slot, request seq) of the unanswered read
        self._held: Optional[Tuple[int, int]] = None
        self._dump: Optional[List[int]] = None     # [slot, next_chunk_index]
        self._write: Optional[dict] = None         # {"slot","armed","buf"}
        self._chunk_counter = 0                    # cumulative, for fail_chunk_at

    @classmethod
    def factory_fresh(cls, *, init_copies: int = 269, seed: int = 0,
                      **kw) -> "SimulatedMicroFreak":
        """The reference device's shape: named pseudo-presets in the low
        slots plus init_copies identical "Init" blobs, correct meta including
        the payload[9] flip at 384 — so expendability tests are real."""
        sim = cls(**kw)
        if not 0 <= init_copies <= sim.slots:
            raise ValueError(f"init_copies {init_copies} > slots {sim.slots}")
        named = sim.slots - init_copies
        init_blob = _synth_blob(seed, "init")
        for slot in range(sim.slots):
            if slot < named:
                name = f"Patch {slot:03d}"
                blob = _synth_blob(seed, f"slot{slot}")
                opaque = bytes([(slot * 3) % 0x20, 0x00, 0x00, 0x00, 0x00])
                category = slot % 0x0C
                attribute = 0x32 if slot % 2 == 0 else 0x33
            else:
                name = "Init"
                blob = init_blob
                opaque = b"\x08\x00\x00\x00\x00"
                category = 0x00
                attribute = 0x33
            sim._state[slot] = _Slot(
                name, sim._positional_meta(slot, opaque, category, attribute),
                blob)
        return sim

    # ------------------------------------------------------ test back doors

    def load(self, slot: int, preset: Preset) -> None:
        self._check_slot(slot)
        m = bytes(preset.meta)
        self._state[slot] = _Slot(
            preset.name,
            self._positional_meta(slot, m[0:5], m[7], m[8]),
            bytes(preset.blob))

    def peek(self, slot: int) -> Preset:
        self._check_slot(slot)
        st = self._state[slot]
        return Preset(name=st.name, blob=st.blob, meta=st.meta)

    # ------------------------------------------------------------ Transport

    def send(self, message: bytes) -> None:
        raw = bytes(message)
        self.wire_log.append(("out", raw))
        f = protocol.parse(raw)
        if f is None:
            self.faults.append(f"unparseable frame: {raw[:12].hex()}...")
            return
        if f.cmd == protocol.CMD_OPEN:
            self._on_open(f)
        elif f.cmd == protocol.CMD_NEXT:
            self._on_pull(f)
        elif f.cmd == protocol.CMD_NAME:
            self._on_name(f)
        elif f.cmd == protocol.CMD_GO:
            self._on_go(f)
        elif f.cmd in (protocol.CMD_CHUNK_MORE, protocol.CMD_CHUNK_LAST):
            self._on_chunk(f)
        else:
            self.faults.append(f"unknown command 0x{f.cmd:02X}")

    def receive(self, timeout: float) -> Optional[bytes]:
        if self._outbox:
            return self._outbox.pop(0)
        return None

    def close(self) -> None:
        pass

    # -------------------------------------------------------- state machine

    def _on_open(self, f: protocol.Frame) -> None:
        if len(f.data) != 3:
            self.faults.append(f"0x19 with {len(f.data)}-byte payload")
            return
        slot = self._slot_from(f.data[0], f.data[1])
        if slot is None:
            return
        trailer = f.data[2]
        if trailer == 0x00:                       # name read
            if self.reply_lag:
                pending, self._held = self._held, (slot, f.seq)
                if pending is not None:
                    self._emit_name_reply(*pending)
            else:
                self._emit_name_reply(slot, f.seq)
        elif trailer == 0x01:                     # dump open
            self._dump = [slot, 0]
        else:
            self.faults.append(f"0x19 with trailer 0x{trailer:02X}")

    def _on_pull(self, f: protocol.Frame) -> None:
        if self._dump is None:
            self.faults.append("0x18 pull without a dump open")
            return
        slot, i = self._dump
        blob = self._state[slot].blob
        piece = blob[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]
        cmd = (protocol.CMD_CHUNK_LAST if i == CHUNK_COUNT - 1
               else protocol.CMD_CHUNK_MORE)
        self._emit(frame(f.seq, 0x20, cmd, piece))   # chunk echoes the pull's seq
        if i == CHUNK_COUNT - 1:
            self._dump = None
        else:
            self._dump[1] = i + 1

    def _on_name(self, f: protocol.Frame) -> None:
        if len(f.data) == NAME_PAYLOAD_LEN:       # long form: name + meta
            slot = self._slot_from(f.data[0], f.data[1])
            if slot is None:
                return
            if f.data[2] != 0x00:
                self.faults.append(f"long 0x52 payload[2]=0x{f.data[2]:02X}")
            pos = slot % SLOTS_PER_BANK
            if f.data[8] != pos:
                self.faults.append(
                    f"long 0x52 payload[8]=0x{f.data[8]:02X}, expected pos "
                    f"0x{pos:02X} (slot {slot})")
            if f.data[9] != protocol.WRITE_PAYLOAD9:
                # every captured outbound write carries 0x06 here; the 0/1
                # slot-384 flag belongs to REPLIES only
                self.faults.append(
                    f"long 0x52 payload[9]={f.data[9]}, expected "
                    f"0x{protocol.WRITE_PAYLOAD9:02X} on a write (slot {slot})")
            if f.data[3] & protocol.REPLY_META_FLAG:
                self.faults.append(
                    f"long 0x52 payload[3]=0x{f.data[3]:02X} carries the "
                    f"reply-only 0x10 bit (slot {slot})")
            st = self._state[slot]
            st.name = protocol._decode_name(f.data)
            # store reply-form meta so subsequent name reads mirror hardware
            st.meta = self._positional_meta(slot, bytes(f.data[3:8]),
                                            f.data[10], f.data[11])
            self._ack(f)          # captured: the long 0x52 is acked with 0x18
        elif len(f.data) == 3 and f.data[2] == 0x01:   # short form: open write
            slot = self._slot_from(f.data[0], f.data[1])
            if slot is None:
                return
            if self._write is not None:
                self.faults.append("write opened while a write was pending")
            self._write = {"slot": slot, "armed": False, "buf": bytearray()}
            self._ack(f)          # captured: the open is acked with 0x18
        else:
            self.faults.append(
                f"0x52 with {len(f.data)}-byte payload: {f.data.hex()}")

    def _on_go(self, f: protocol.Frame) -> None:
        if self._write is None or self._write["armed"]:
            self.faults.append("0x15 go without a fresh write open")
            return
        self._write["armed"] = True
        self._ack(f)              # captured: go is acked with 0x18

    def _on_chunk(self, f: protocol.Frame) -> None:
        idx = self._chunk_counter
        self._chunk_counter += 1
        if self._write is None or not self._write["armed"]:
            self.faults.append("chunk without an open+armed write")
            return                                # slot untouched, no ack
        if len(f.data) != CHUNK_SIZE:
            self.faults.append(f"chunk with {len(f.data)} bytes")
        self._write["buf"].extend(f.data)
        acked = not (self.fail_chunk_at is not None
                     and idx >= self.fail_chunk_at)
        if acked:
            self._ack(f)
        if f.cmd == protocol.CMD_CHUNK_LAST:      # commit
            w, self._write = self._write, None
            total = len(w["buf"])
            if total == BLOB_SIZE:
                self._state[w["slot"]].blob = bytes(w["buf"])
            else:
                self.faults.append(
                    f"write to slot {w['slot']} committed {total} bytes, "
                    f"expected {BLOB_SIZE}; slot untouched")

    # -------------------------------------------------------------- helpers

    def _slot_from(self, bank: int, pos: int) -> Optional[int]:
        slot = bank * SLOTS_PER_BANK + pos
        if not 0 <= slot < self.slots or pos >= SLOTS_PER_BANK:
            self.faults.append(f"address (bank {bank}, pos {pos}) out of range")
            return None
        return slot

    def _check_slot(self, slot: int) -> None:
        if not 0 <= slot < self.slots:
            raise IndexError(f"slot {slot} out of range for {self.slots}-slot sim")

    def _ack(self, f: protocol.Frame) -> None:
        """Device-shape 0x18 ack: len byte 0x00, empty payload, seq echoing
        the acked frame's seq — the shape of every captured inbound ack."""
        self._emit(frame(f.seq, 0x00, protocol.CMD_NEXT))

    def _positional_meta(self, slot: int, opaque5: bytes, category: int,
                         attribute: int) -> bytes:
        """META_LEN bytes in REPLY form, positionally correct for slot:
        meta[5]=pos, meta[6]=the 0/1 slot-384 flag, and meta[0] carries the
        reply-only 0x10 bit exactly when slot >= 128 (all hardware reply
        fixtures: slots 0/8/40 clear, 200/511 set)."""
        pos = slot % SLOTS_PER_BANK
        high = 0 if slot < HIGH_BANK_BOUNDARY else 1
        m = bytearray(bytes(opaque5[:5]) + bytes(5 - len(opaque5[:5])))
        m[0] &= ~protocol.REPLY_META_FLAG
        if slot >= SLOTS_PER_BANK:
            m[0] |= protocol.REPLY_META_FLAG
        return bytes(m) + bytes([pos, high, category & 0x7F, attribute & 0x7F])

    def _emit_name_reply(self, slot: int, seq: int) -> None:
        """Render the long-0x52 reply from CURRENT device state (a lagged
        device is slow, not wrong) and append it to the outbox. The reply
        echoes its own request's seq, as every captured reply does — under
        lag that is the seq of the read it answers, not of the read that
        released it."""
        st = self._state[slot]
        bank, pos = slot // SLOTS_PER_BANK, slot % SLOTS_PER_BANK
        field = st.name.encode("ascii", "replace")[:NAME_LEN]
        field += b"\x00" * (NAME_LEN - len(field))
        payload = bytes([bank, pos, 0x00]) + st.meta + field
        assert len(payload) == NAME_PAYLOAD_LEN
        self._emit(frame(seq, 0x23, protocol.CMD_NAME, payload))

    def _emit(self, raw: bytes) -> None:
        self.wire_log.append(("in", raw))
        self._outbox.append(raw)
