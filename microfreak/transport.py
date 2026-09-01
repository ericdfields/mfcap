"""The injected seam: byte movement and message-boundary reassembly, nothing
more.

Poll model, deliberately: the core stays single-threaded and thread-free;
push-style backends (rtmidi callback, CoreMIDI MIDIReadProc, ALSA events)
buffer into an internal queue inside the adapter (queue.Queue in Python, a
locked array + semaphore in Swift). Discovery is a per-backend factory
concern, not part of the interface.
"""
from __future__ import annotations

from typing import Optional

try:
    from typing import Protocol, runtime_checkable
except ImportError:  # pragma: no cover - 3.9+ always has these
    Protocol = object          # type: ignore

    def runtime_checkable(cls):  # type: ignore
        return cls


@runtime_checkable
class Transport(Protocol):
    """Structural interface every backend implements.

    Contract:
    - send() transmits one complete SysEx message F0..F7, atomically.
    - receive() returns the next complete inbound SysEx message, or None on
      timeout. Arrival order is preserved; the transport buffers and never
      drops. The transport's only jobs are byte movement and message-boundary
      reassembly — no parsing, filtering, matching, retries, or threading
      above the seam.
    - close() releases the backend; further calls may raise TransportError.
    """

    def send(self, message: bytes) -> None:
        """Send one complete SysEx message F0..F7, atomically."""
        ...

    def receive(self, timeout: float) -> Optional[bytes]:
        """Next complete inbound SysEx message, or None on timeout."""
        ...

    def close(self) -> None:
        ...
