"""The ONLY module in the package that touches python-rtmidi — and it does
so lazily, inside functions, so `import microfreak` (and even importing this
module) succeeds with no rtmidi installed.

Push-to-poll adaptation: rtmidi's callback feeds an internal queue.Queue;
receive() pops it. The adapter also reassembles SysEx message boundaries in
case the backend delivers a message split across callbacks.
"""
from __future__ import annotations

import queue
from typing import Dict, List, Optional, Sequence, Tuple

from ..errors import (DeviceNotFoundError, TransportError,
                      TransportUnavailableError)

DEVICE_HINTS = ("microfreak", "micro freak", "arturia microfreak")


def _import_rtmidi():
    try:
        import rtmidi                     # the lazy touchpoint
        return rtmidi
    except ImportError as e:
        raise TransportUnavailableError(
            "python-rtmidi is not installed. "
            "Install with: pip install 'microfreak[rtmidi]'") from e


def available() -> bool:
    """True when python-rtmidi can be imported. Never raises."""
    try:
        _import_rtmidi()
        return True
    except TransportUnavailableError:
        return False


def list_ports() -> Dict[str, List[str]]:
    rtmidi = _import_rtmidi()
    try:
        mi, mo = rtmidi.MidiIn(), rtmidi.MidiOut()
        try:
            return {"inputs": mi.get_ports(), "outputs": mo.get_ports()}
        finally:
            del mi, mo
    except TransportError:
        raise
    except Exception as e:
        raise TransportError(f"port enumeration failed: {e}") from e


def find_port(names: Sequence[str], hints: Sequence[str],
          exclude: str) -> Optional[int]:
    for i, name in enumerate(names):
        low = name.lower()
        if exclude and exclude.lower() in low:
            continue
        if any(h in low for h in hints):
            return i
    return None


def find_microfreak(hints: Sequence[str] = DEVICE_HINTS,
                    exclude: str = "mfcap") -> Optional[Tuple[str, str]]:
    """(input name, output name) of the first matching device, or None."""
    ports = list_ports()
    i = find_port(ports["inputs"], hints, exclude)
    o = find_port(ports["outputs"], hints, exclude)
    if i is None or o is None:
        return None
    return ports["inputs"][i], ports["outputs"][o]


class RtMidiTransport:
    """Implements the Transport protocol over python-rtmidi."""

    def __init__(self, midi_in, midi_out, in_name: str, out_name: str):
        self.in_name = in_name
        self.out_name = out_name
        self._in = midi_in
        self._out = midi_out
        self._queue: "queue.Queue[bytes]" = queue.Queue()
        self._partial = bytearray()
        midi_in.ignore_types(sysex=False, timing=True, active_sense=True)
        midi_in.set_callback(self._on_message)

    # ------------------------------------------------------------ factories

    @classmethod
    def open(cls, hints: Sequence[str] = DEVICE_HINTS,
             exclude: str = "mfcap") -> "RtMidiTransport":
        rtmidi = _import_rtmidi()
        try:
            mi, mo = rtmidi.MidiIn(), rtmidi.MidiOut()
            ins, outs = mi.get_ports(), mo.get_ports()
        except Exception as e:
            raise TransportError(f"port enumeration failed: {e}") from e
        i = find_port(ins, hints, exclude)
        o = find_port(outs, hints, exclude)
        if i is None or o is None:
            raise DeviceNotFoundError(ins, outs)
        return cls._open_indices(mi, mo, i, o, ins[i], outs[o])

    @classmethod
    def open_ports(cls, in_name: str, out_name: str) -> "RtMidiTransport":
        """Explicit picker: open ports by their exact names."""
        rtmidi = _import_rtmidi()
        try:
            mi, mo = rtmidi.MidiIn(), rtmidi.MidiOut()
            ins, outs = mi.get_ports(), mo.get_ports()
        except Exception as e:
            raise TransportError(f"port enumeration failed: {e}") from e
        if in_name not in ins or out_name not in outs:
            raise DeviceNotFoundError(ins, outs)
        return cls._open_indices(mi, mo, ins.index(in_name),
                                 outs.index(out_name), in_name, out_name)

    @classmethod
    def _open_indices(cls, mi, mo, i: int, o: int,
                      in_name: str, out_name: str) -> "RtMidiTransport":
        try:
            mi.open_port(i)
        except Exception as e:
            raise TransportError(f"opening MIDI input failed: {e}") from e
        try:
            mo.open_port(o)
        except Exception as e:
            try:                            # don't leak the opened input
                mi.close_port()
            except Exception:
                pass
            raise TransportError(f"opening MIDI output failed: {e}") from e
        return cls(mi, mo, in_name, out_name)

    # ------------------------------------------------------------ Transport

    def send(self, message: bytes) -> None:
        try:
            self._out.send_message(list(message))
        except Exception as e:
            raise TransportError(f"send failed: {e}") from e

    def send_short(self, message: bytes) -> None:
        """One channel message (Program Change / Control Change), 2-3 bytes."""
        self.send(message)

    def receive(self, timeout: float) -> Optional[bytes]:
        try:
            if timeout <= 0:
                return self._queue.get_nowait()
            return self._queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        try:                                     # stop callbacks firing
            self._in.cancel_callback()           # during/after close
        except Exception:
            pass
        for port in (self._in, self._out):
            try:
                port.close_port()
            except Exception:
                pass

    # ------------------------------------------------------------- callback

    def _on_message(self, event, _data=None) -> None:
        """Reassemble SysEx boundaries; do not let interleaved traffic
        corrupt a buffered partial.

        - A message starting 0xF0 begins a new SysEx: any pending partial
          was torn (its terminator never arrived) and is dropped.
        - While a partial is pending, only continuation data (first byte
          < 0x80, or a lone 0xF7 terminator) extends it — an interleaved
          realtime byte or complete channel message passes through on its
          own instead of being spliced into the frame.
        """
        message, _delta = event
        b = bytes(message)
        if not b:
            return
        if b[0] == 0xF0:                          # new SysEx begins
            self._partial = bytearray()           # a pending partial was torn
            if b.endswith(b"\xF7"):
                self._queue.put(b)
            else:
                self._partial = bytearray(b)      # split SysEx: buffer it
        elif self._partial and (b[0] < 0x80 or b[0] == 0xF7):
            self._partial.extend(b)               # SysEx continuation
            if b.endswith(b"\xF7"):
                self._queue.put(bytes(self._partial))
                self._partial = bytearray()
        elif b[0] >= 0xF8:
            pass                                  # realtime; never SysEx data
        else:
            self._queue.put(b)                    # unrelated complete message
