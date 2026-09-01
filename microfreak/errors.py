"""Complete exception hierarchy for the microfreak core.

Nothing else escapes the public API: adapter code catches every backend
exception and re-raises TransportError (chained); the session and device
layers raise only the types below.
"""
from __future__ import annotations

from typing import List, Optional


class MicroFreakError(Exception):
    """Base for everything this package raises."""


# ---------------------------------------------------------------- protocol

class ProtocolError(MicroFreakError):
    """Malformed or unexpected frame."""


class SlotOutOfRangeError(ProtocolError):
    def __init__(self, slot: int):
        super().__init__(f"slot {slot} out of range")
        self.slot = slot


class BlobSizeError(ProtocolError):
    def __init__(self, expected: int, actual: int):
        super().__init__(f"blob is {actual} bytes, expected {expected}")
        self.expected = expected
        self.actual = actual


class InvalidNameError(ProtocolError):
    """Name is not printable ASCII or exceeds 23 characters."""


# --------------------------------------------------------------- transport

class TransportError(MicroFreakError):
    """Backend failure, wrapped (chained) by the adapter."""


class TransportUnavailableError(TransportError):
    """python-rtmidi is not installed."""


class DeviceNotFoundError(TransportError):
    def __init__(self, inputs: List[str], outputs: List[str]):
        super().__init__(
            "No MicroFreak MIDI port found.\n"
            f"  inputs seen:  {inputs}\n"
            f"  outputs seen: {outputs}")
        self.inputs = inputs
        self.outputs = outputs


# ------------------------------------------------------------- transaction

class DeviceTimeoutError(MicroFreakError):
    def __init__(self, stage: str, slot: Optional[int] = None):
        super().__init__(f"device timeout during {stage}"
                         + (f" (slot {slot})" if slot is not None else ""))
        self.stage = stage
        self.slot = slot


class ReplyMismatchError(MicroFreakError):
    """Reply-lag never resolved: every reply named a different slot."""

    def __init__(self, requested_slot: int, replied_slot: Optional[int],
                 attempts: int):
        super().__init__(
            f"asked for slot {requested_slot}, device kept answering for "
            f"slot {replied_slot} after {attempts} attempts")
        self.requested_slot = requested_slot
        self.replied_slot = replied_slot
        self.attempts = attempts


# ------------------------------------------------------------------ writes

class WriteError(MicroFreakError):
    """Base for write-path failures."""


class ChunkNotAckedError(WriteError):
    def __init__(self, slot: int, chunk_index: int):
        super().__init__(
            f"no 0x18 ack for chunk {chunk_index} writing slot {slot}")
        self.slot = slot
        self.chunk_index = chunk_index


class WriteAbortedError(WriteError):
    def __init__(self, stage: str, slot: int, chunks_sent: int):
        super().__init__(
            f"write to slot {slot} aborted at stage {stage!r} "
            f"({chunks_sent} chunks sent)")
        self.stage = stage            # "name_write"|"open"|"go"|"chunk"|"final_read"
        self.slot = slot
        self.chunks_sent = chunks_sent


class VerifyMismatchError(WriteError):
    def __init__(self, slot: int, expected_sha256: str,
                 actual_sha256: Optional[str],
                 expected_name: str, actual_name: Optional[str],
                 first_difference: Optional[int],
                 expected_len: int, actual_len: int):
        detail = []
        if actual_name is not None and actual_name != expected_name:
            detail.append(f"name {actual_name!r} != {expected_name!r}")
        if actual_sha256 is not None and actual_sha256 != expected_sha256:
            detail.append(f"sha {actual_sha256[:12]} != {expected_sha256[:12]}")
        super().__init__(
            f"verify failed for slot {slot}: " + ("; ".join(detail) or "mismatch"))
        self.slot = slot
        self.expected_sha256 = expected_sha256
        self.actual_sha256 = actual_sha256
        self.expected_name = expected_name
        self.actual_name = actual_name
        self.first_difference = first_difference
        self.expected_len = expected_len
        self.actual_len = actual_len


# ------------------------------------------------------------ cancellation

class OperationCancelledError(MicroFreakError):
    def __init__(self, done: int, total: int):
        super().__init__(f"operation cancelled after {done}/{total}")
        self.done = done
        self.total = total


# ---------------------------------------------------------- stored data

class IntegrityError(MicroFreakError):
    """Stored data fails its own hash (backup or library)."""

    def __init__(self, path: str, detail: str):
        super().__init__(f"{path}: {detail}")
        self.path = path
        self.detail = detail


class LibraryError(MicroFreakError):
    """Base for library failures."""


class EntryNotFoundError(LibraryError):
    def __init__(self, entry_id: str):
        super().__init__(f"no library entry {entry_id}")
        self.entry_id = entry_id


class LibraryCorruptError(LibraryError):
    def __init__(self, path: str, detail: str):
        super().__init__(f"{path}: {detail}")
        self.path = path
        self.detail = detail
