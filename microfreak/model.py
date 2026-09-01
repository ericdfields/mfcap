"""Value types. All frozen dataclasses with primitive fields, so a Swift
port is a transliteration.

Long operations poll a CancelToken between slots and between write chunks
and raise OperationCancelledError(done, total). Worst-case cancel latency is
one dump/ack timeout.
"""
from __future__ import annotations

import dataclasses
import threading
from dataclasses import dataclass
from typing import Callable, Optional, Tuple

from .errors import BlobSizeError, ProtocolError
from .protocol import BLOB_SIZE, META_LEN, digest, validate_name


@dataclass(frozen=True)
class Preset:
    """One preset: name + 4672-byte blob + the 9 opaque meta bytes.

    meta has no default — every Preset traces to a real read (device, backup,
    or library). It is round-tripped verbatim except the direction-dependent
    header bytes name_write_frame recomputes (payload[3] reply flag cleared,
    payload[8]=pos, payload[9]=0x06 on writes).

    Blob and meta must be 7-bit clean: SysEx payload bytes have bit 7 clear,
    and the wire encoder masks with & 0x7F — so a byte > 0x7F would be
    silently rewritten in transit. Rejecting it here keeps a foreign or
    corrupted .bin from producing a "successful" unverified write of
    different content.
    """
    name: str
    blob: bytes
    meta: bytes

    def __post_init__(self):
        validate_name(self.name)
        if not isinstance(self.blob, (bytes, bytearray)) or len(self.blob) != BLOB_SIZE:
            raise BlobSizeError(BLOB_SIZE, len(self.blob)
                                if isinstance(self.blob, (bytes, bytearray)) else -1)
        if not isinstance(self.meta, (bytes, bytearray)) or len(self.meta) != META_LEN:
            raise ProtocolError(
                f"meta must be {META_LEN} bytes, got "
                f"{len(self.meta) if isinstance(self.meta, (bytes, bytearray)) else type(self.meta).__name__}")
        bad = next((i for i, b in enumerate(self.blob) if b > 0x7F), None)
        if bad is not None:
            raise ProtocolError(
                f"blob byte {bad} is 0x{self.blob[bad]:02X}: SysEx content "
                "must be 7-bit clean (it would be masked in transit)")
        if any(b > 0x7F for b in self.meta):
            raise ProtocolError("meta contains non-7-bit bytes")

    @property
    def sha256(self) -> str:
        return digest(bytes(self.blob))

    def renamed(self, name: str) -> "Preset":
        return dataclasses.replace(self, name=name)


@dataclass(frozen=True)
class SlotRecord:
    slot: int
    name: Optional[str]        # None = name read failed
    sha256: Optional[str]      # None = blob not read (names-only snapshot)
    meta: Optional[bytes]      # None only when the name read failed
    blob: Optional[bytes]      # None when the snapshot did not keep blobs


@dataclass(frozen=True)
class TimingReport:
    total_seconds: float
    per_slot_seconds: float
    name_ms_median: Optional[float]
    dump_ms_median: Optional[float]


@dataclass(frozen=True)
class DeviceSnapshot:
    taken_at: str                        # ISO 8601
    records: Tuple[SlotRecord, ...]      # ascending slot order; only requested slots
    timing: TimingReport

    def record(self, slot: int) -> Optional[SlotRecord]:
        for r in self.records:
            if r.slot == slot:
                return r
        return None

    @property
    def has_hashes(self) -> bool:
        return all(r.sha256 is not None for r in self.records)


@dataclass(frozen=True)
class WriteReport:
    slot: int
    sha256: str                # of the blob sent ("" for a rename: no blob traffic)
    name: str
    verified: Optional[bool]   # True (read back, matched) / None (verify skipped);
                               # False never occurs — a mismatch raises instead
    duration_seconds: float


@dataclass(frozen=True)
class ProgressEvent:
    done: int
    total: int
    slot: int
    name: str
    elapsed_seconds: float
    eta_seconds: Optional[float]   # median-based, same math as mfcap midi.backup timing


ProgressFn = Callable[[ProgressEvent], None]


class CancelToken:
    """Cooperative cancellation. One threading.Event — the only threading
    primitive in this module."""

    def __init__(self):
        self._event = threading.Event()

    def cancel(self) -> None:
        self._event.set()

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()
