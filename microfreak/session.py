"""Session: seq counter, one transaction at a time, the reply-lag chokepoint.

Semantics (docs/core-api.md is the normative statement):

- The addressed-request seq counter is owned here; it increments 1..127 and
  wraps, never emitting 0, matching mfcap.midi.Reader. The write burst has a
  separate seq stream, verbatim from the captures: go_frame() carries seq 0
  and the chunks continue from it, (i + 1) % 128 — wrapping THROUGH 0
  (chunk_frames owns that stream).
- One internal threading.Lock wraps every public method, so concurrent
  callers queue instead of interleaving chunk streams (chunks are unaddressed
  and unmatchable by design; interleaving is forbidden, and the lock makes
  accidental interleaving impossible from one Session). One Session per
  transport.
- _transact_addressed() is the ONLY function in the package that inspects a
  0x52 reply — read_name, write_name's read-back, and write_preset's frames
  1 and 7 all pass through it, so the reply-lag bug cannot be reintroduced
  without deleting this function.
"""
from __future__ import annotations

import threading
import time
from typing import Callable, List, Optional

from . import protocol
from .errors import (ChunkNotAckedError, DeviceTimeoutError,
                     OperationCancelledError, ProtocolError,
                     ReplyMismatchError, TransportError, WriteAbortedError)
from .model import CancelToken, Preset
from .protocol import (CHUNK_COUNT, NameInfo, chunk_frames, go_frame,
                       is_ack, is_chunk, is_last_chunk, name_write_frame,
                       open_dump_req, open_write_frame, parse, pull_next_req,
                       read_name_req)
from .transport import Transport

_POLL_SLEEP = 0.002


class Session:
    """One serialized request/reply conversation with the device."""

    def __init__(self, transport: Transport, *,
                 name_timeout: float = 1.0, dump_timeout: float = 1.5,
                 ack_timeout: float = 1.0, name_retries: int = 3,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep):
        self.transport = transport
        self.name_timeout = name_timeout
        self.dump_timeout = dump_timeout
        self.ack_timeout = ack_timeout
        self.name_retries = name_retries
        self.clock = clock
        self.sleep = sleep
        self._lock = threading.Lock()
        self._seq = 0

    # ------------------------------------------------------------- public

    def read_name(self, slot: int) -> NameInfo:
        with self._lock:
            return self._transact_addressed(
                read_name_req(self._next_seq(), slot), slot)

    def read_blob(self, slot: int) -> bytes:
        with self._lock:
            return self._read_blob_locked(slot)

    def write_preset(self, slot: int, preset: Preset,
                     cancel: Optional[CancelToken] = None) -> NameInfo:
        """The gate-verified 7-frame write sequence, verbatim from
        docs/write-protocol.md. No checksum is computed at any point; none
        exists. The returned NameInfo is frame 7's read-back — comparison is
        the caller's job (the frame itself is protocol fidelity and always
        sent)."""
        frames = chunk_frames(preset.blob)   # validates blob size up front
        with self._lock:
            # 1. name read (fidelity to MCC; result discarded)
            self._transact_addressed(read_name_req(self._next_seq(), slot), slot)
            chunks_sent = 0
            stage = "name_write"
            try:
                # 2. name + meta — the device acks it with 0x18 (captured:
                #    every outbound 0x52 and 0x15 is acked, not just chunks)
                self._send(name_write_frame(self._next_seq(), slot,
                                            preset.name, preset.meta),
                           "name_write", slot, chunks_sent)
                self._require_ack("name_write", slot, chunks_sent)
                # 3. open blob write — acked with 0x18
                stage = "open"
                self._send(open_write_frame(self._next_seq(), slot),
                           "open", slot, chunks_sent)
                self._require_ack("open", slot, chunks_sent)
                # 4. go — acked with 0x18
                stage = "go"
                self._send(go_frame(), "go", slot, chunks_sent)
                self._require_ack("go", slot, chunks_sent)
                # 5-6. 146 chunks, each acked by the device with 0x18.
                # The three control-frame acks above are consumed before the
                # chunk loop, so ack N here really is the ack for chunk N —
                # flow control stays in lockstep with the device.
                stage = "chunk"
                for i, ch in enumerate(frames):
                    if cancel is not None and cancel.cancelled:
                        # Cancelling mid-write tears the slot; the fields say
                        # how far it got — recovery is "write again".
                        raise OperationCancelledError(i, len(frames))
                    self._send(ch, "chunk", slot, chunks_sent)
                    chunks_sent += 1
                    if not self._await_ack():
                        raise ChunkNotAckedError(slot, i)
            except (ChunkNotAckedError, OperationCancelledError,
                    WriteAbortedError):
                raise
            except (TransportError, ProtocolError) as e:
                raise WriteAbortedError(stage, slot, chunks_sent) from e
            # 7. name read back
            try:
                return self._transact_addressed(
                    read_name_req(self._next_seq(), slot), slot)
            except (DeviceTimeoutError, ReplyMismatchError, TransportError) as e:
                raise WriteAbortedError("final_read", slot, chunks_sent) from e

    def write_name(self, slot: int, name: str, meta: bytes) -> NameInfo:
        """Rename-in-place, exactly what MCC sends: the long 0x52 frame
        (acked by the device with 0x18, per the c4 capture) plus a refresh
        read. No blob traffic."""
        with self._lock:
            self.transport.send(name_write_frame(self._next_seq(), slot,
                                                 name, meta))
            if not self._await_ack():
                raise DeviceTimeoutError("name_write_ack", slot)
            return self._transact_addressed(
                read_name_req(self._next_seq(), slot), slot)

    def close(self) -> None:
        self.transport.close()

    # ------------------------------------------------------------ private

    def _next_seq(self) -> int:
        self._seq = self._seq % 127 + 1     # 1..127, never 0
        return self._seq

    def _send(self, message: bytes, stage: str, slot: int,
              chunks_sent: int) -> None:
        try:
            self.transport.send(message)
        except TransportError as e:
            raise WriteAbortedError(stage, slot, chunks_sent) from e

    def _require_ack(self, stage: str, slot: int, chunks_sent: int) -> None:
        """Await the device's 0x18 ack for a write control frame (long 0x52,
        short 0x52 open, go); absence aborts the write at that stage."""
        if not self._await_ack():
            raise WriteAbortedError(stage, slot, chunks_sent)

    def _drain(self) -> None:
        while self.transport.receive(0.0) is not None:
            pass

    def _next_frame(self, timeout: float) -> Optional[protocol.Frame]:
        """Next parseable MicroFreak frame within timeout, else None."""
        deadline = self.clock() + timeout
        while True:
            remaining = deadline - self.clock()
            if remaining <= 0:
                return None
            raw = self.transport.receive(remaining)
            if raw is None:
                self.sleep(_POLL_SLEEP)
                continue
            f = parse(raw)
            if f is not None:
                return f

    def _transact_addressed(self, request: bytes, slot: int) -> NameInfo:
        """Send an addressed request; accept only a long-0x52 reply whose
        embedded bank/pos names the requested slot — the reply-lag defense.

        A mismatched reply is discarded as stale and the request retried,
        name_retries times total; then ReplyMismatchError. Total silence
        raises DeviceTimeoutError(stage="name_read", slot=slot).

        Known limitation: when two consecutive reads target the SAME slot
        (write_preset frames 1 and 7; a rename's read-back), a lagged reply
        to the first is indistinguishable from the answer to the second —
        the embedded address matches either way. Blob-hash verification
        covers write(); for a rename this could in principle compare against
        a stale pre-rename name (whether a lagged hardware reply carries
        request-time or emission-time content is unobserved). No
        protocol-level fix exists: replies carry no request id.
        """
        self._drain()
        saw_reply = False
        replied_slot: Optional[int] = None
        for _attempt in range(self.name_retries):
            self.transport.send(request)
            deadline = self.clock() + self.name_timeout
            while True:
                remaining = deadline - self.clock()
                if remaining <= 0:
                    break                       # silent attempt; resend
                f = self._next_frame(remaining)
                if f is None:
                    break                       # silent attempt; resend
                if f.cmd != protocol.CMD_NAME or \
                        len(f.data) != protocol.NAME_PAYLOAD_LEN:
                    continue                    # unrelated traffic; ignore
                try:
                    info = protocol.decode_name_reply(f)
                except ProtocolError:
                    continue                    # malformed (e.g. out-of-range
                                                # embedded address); ignore
                saw_reply = True
                if info.slot == slot:
                    return info
                replied_slot = info.slot        # stale (lagged) reply
                break                           # discard and resend at once
        if saw_reply:
            raise ReplyMismatchError(slot, replied_slot, self.name_retries)
        raise DeviceTimeoutError("name_read", slot)

    def _read_blob_locked(self, slot: int) -> bytes:
        """Open a dump, then pull chunks in strict lockstep — one outstanding
        request — until the device says 'last'."""
        self._drain()
        self.transport.send(open_dump_req(self._next_seq(), slot))
        chunks: List[protocol.Frame] = []
        while True:
            # collect anything already delivered before pulling again; the
            # len bound keeps a runaway device (streaming 0x16 forever with
            # no terminator) from spinning this loop unboundedly
            got_last = False
            while len(chunks) < CHUNK_COUNT:
                raw = self.transport.receive(0.0)
                if raw is None:
                    break
                f = parse(raw)
                if f is None or not is_chunk(f):
                    continue
                chunks.append(f)
                if is_last_chunk(f):
                    got_last = True
                    break
            if got_last:
                return protocol.assemble_blob(chunks)
            if len(chunks) >= CHUNK_COUNT:
                raise ProtocolError(
                    f"slot {slot}: {len(chunks)} chunks without a 0x17 terminator")
            self.transport.send(pull_next_req(self._next_seq()))
            f = self._await_chunk(slot)
            chunks.append(f)
            if is_last_chunk(f):
                return protocol.assemble_blob(chunks)

    def _await_chunk(self, slot: int) -> protocol.Frame:
        deadline = self.clock() + self.dump_timeout
        while True:
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise DeviceTimeoutError("dump", slot)
            f = self._next_frame(remaining)
            if f is None:
                raise DeviceTimeoutError("dump", slot)
            if is_chunk(f):
                return f
            # anything else during a dump is stale; discard

    def _await_ack(self) -> bool:
        deadline = self.clock() + self.ack_timeout
        while True:
            remaining = deadline - self.clock()
            if remaining <= 0:
                return False
            f = self._next_frame(remaining)
            if f is None:
                return False
            if is_ack(f):
                return True
            # anything else during a write is stale; discard
