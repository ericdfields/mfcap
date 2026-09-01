"""CoreMIDI plumbing for the capture harness: Device, Reader, port discovery.

Since phase 1 the librarian's device I/O lives in the `microfreak` core
package (Session over an injected Transport; `mfcap backup` goes through
microfreak.MicroFreak.backup). What stays here is the capture/gate machinery
that predates it and still proves the protocol:

- `Device`: an rtmidi connection with a SysEx mailbox and the send/drain/
  quiet_for/ask surface that verify.replay() paces raw captured bursts over
  (tests drive the same surface with simulated devices).
- `Reader`: the documented read path over that surface, used by the gate to
  read scratch slots back. It intentionally tolerates non-4672-byte blobs
  from simulated devices, which the core's Session refuses.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from microfreak.transports.rtmidi import DEVICE_HINTS, find_port as _core_find_port

from . import sysex as sx

try:
    import rtmidi
except ImportError:  # surfaced properly by `mfcap doctor`
    rtmidi = None


class MidiUnavailable(RuntimeError):
    pass


def _require_rtmidi():
    if rtmidi is None:
        raise MidiUnavailable(
            "python-rtmidi is not installed. Run: pip3 install --user python-rtmidi")


def list_ports() -> dict:
    _require_rtmidi()
    mi, mo = rtmidi.MidiIn(), rtmidi.MidiOut()
    try:
        return {"inputs": mi.get_ports(), "outputs": mo.get_ports()}
    finally:
        del mi, mo


def find_port(names: List[str], hints=DEVICE_HINTS, exclude: str = "") -> Optional[int]:
    """Hint/exclude port matching. One implementation for the whole repo:
    delegates to the core adapter's matcher instead of duplicating it."""
    return _core_find_port(names, hints, exclude)


@dataclass
class Device:
    """An open connection to the MicroFreak, with a SysEx mailbox."""
    in_index: int
    out_index: int
    in_name: str = ""
    out_name: str = ""
    _in: object = None
    _out: object = None
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _inbox: List[sx.Frame] = field(default_factory=list)
    _event: threading.Event = field(default_factory=threading.Event)
    last_rx: float = 0.0
    t0: float = field(default_factory=time.time)
    tap: Optional[Callable[[sx.Frame], None]] = None

    @classmethod
    def open(cls, exclude_virtual: str = "mfcap") -> "Device":
        _require_rtmidi()
        mi, mo = rtmidi.MidiIn(), rtmidi.MidiOut()
        ins, outs = mi.get_ports(), mo.get_ports()
        i = find_port(ins, exclude=exclude_virtual)
        o = find_port(outs, exclude=exclude_virtual)
        if i is None or o is None:
            raise MidiUnavailable(
                "No MicroFreak MIDI port found.\n"
                f"  inputs seen:  {ins}\n"
                f"  outputs seen: {outs}")
        dev = cls(in_index=i, out_index=o, in_name=ins[i], out_name=outs[o],
                  _in=mi, _out=mo)
        mi.open_port(i)
        mi.ignore_types(sysex=False, timing=True, active_sense=True)
        mi.set_callback(dev._on_message)
        mo.open_port(o)
        return dev

    def close(self) -> None:
        for p in (self._in, self._out):
            try:
                p.close_port()
            except Exception:
                pass

    # ---------- receive ----------

    def _on_message(self, event, _data=None):
        message, _delta = event
        t = time.time() - self.t0
        self.last_rx = time.time()
        f = sx.parse(message, direction="in", t=t)
        if f is None:
            return
        with self._lock:
            self._inbox.append(f)
        if self.tap:
            self.tap(f)
        self._event.set()

    def quiet_for(self) -> float:
        return time.time() - self.last_rx if self.last_rx else 1e9

    def drain(self) -> List[sx.Frame]:
        with self._lock:
            got, self._inbox = self._inbox, []
        self._event.clear()
        return got

    # ---------- request/response ----------

    def send(self, msg: List[int]) -> None:
        self._out.send_message(msg)

    def ask(self, msg: List[int], want: Optional[set] = None,
            timeout: float = 1.5) -> List[sx.Frame]:
        """Send one frame, collect replies until the wire goes quiet."""
        self.drain()
        self.send(msg)
        deadline = time.time() + timeout
        got: List[sx.Frame] = []
        while time.time() < deadline:
            if self._event.wait(0.05):
                got.extend(self.drain())
                if want and got and got[-1].cmd in want:
                    break
                deadline = min(deadline, time.time() + 0.25)
        return got


class Reader:
    """Pulls names and preset blobs using the documented read protocol."""

    def __init__(self, dev: Device, max_chunks: int = 512):
        self.dev = dev
        self.seq = 0
        self.max_chunks = max_chunks

    def _next_seq(self) -> int:
        # 1..127 without repeats, same as microfreak.Session._next_seq.
        # (The old "(seq + 1) % 0x80 or 1" emitted seq 1 twice at the wrap
        # because the substituted 1 was never stored back.)
        self.seq = self.seq % 127 + 1
        return self.seq

    def name(self, slot: int, timeout: float = 1.0) -> Optional[str]:
        # The 0x52 reply carries the slot it describes in its first two bytes.
        # Under rapid back-to-back reads the device's replies can lag one
        # request behind, so accepting any 0x52 frame mis-labels every slot
        # from then on. Only accept a reply that names the slot we asked for.
        bank, pos = sx.addr(slot)
        for _ in range(3):
            replies = self.dev.ask(sx.read_name(self._next_seq(), slot),
                                   want={sx.CMD_NAME}, timeout=timeout)
            for f in replies:
                if (f.cmd == sx.CMD_NAME and len(f.data) >= 2
                        and f.data[0] == bank and f.data[1] == pos):
                    return sx.decode_name(f)
        return None

    def preset(self, slot: int, timeout: float = 1.5) -> Optional[bytes]:
        """Open a dump, then pull chunks until the device says 'last'."""
        chunks: List[sx.Frame] = []
        opened = self.dev.ask(sx.open_dump(self._next_seq(), slot),
                              want={sx.CMD_CHUNK_MORE, sx.CMD_CHUNK_LAST},
                              timeout=timeout)
        chunks.extend(f for f in opened if f.cmd in (sx.CMD_CHUNK_MORE, sx.CMD_CHUNK_LAST))
        if chunks and chunks[-1].cmd == sx.CMD_CHUNK_LAST:
            return sx.assemble(chunks)

        for _ in range(self.max_chunks):
            got = self.dev.ask(sx.next_chunk(self._next_seq()),
                               want={sx.CMD_CHUNK_MORE, sx.CMD_CHUNK_LAST},
                               timeout=timeout)
            useful = [f for f in got if f.cmd in (sx.CMD_CHUNK_MORE, sx.CMD_CHUNK_LAST)]
            if not useful:
                return None  # device stopped answering; caller decides
            chunks.extend(useful)
            if useful[-1].cmd == sx.CMD_CHUNK_LAST:
                return sx.assemble(chunks)
        return None
