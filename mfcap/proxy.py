"""Man-in-the-middle between MIDI Control Center and the MicroFreak.

Primary capture route, and the one that needs no admin password, no kernel
driver and no GUI scripting:

    MCC  ->  [virtual destination]  ->  mfcap  ->  real MicroFreak
    MCC  <-  [virtual source]       <-  mfcap  <-  real MicroFreak

We publish a CoreMIDI virtual endpoint pair named to look like the hardware.
If MCC picks it, every byte it writes is ours, in order, with timestamps, and
the device's answers come back through the same log.

If MCC refuses to talk to a virtual port (some hosts filter on USB transport),
`probe()` finds that out in 30 seconds and the runner falls back to the
MIDI Monitor spy route in mmlog.py. That decision is made by the script, not
by the person standing there.
"""
from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from . import sysex as sx
from .midi import MidiUnavailable, find_port

try:
    import rtmidi
except ImportError:
    rtmidi = None

VIRTUAL_NAME = "MicroFreak"


@dataclass
class Proxy:
    capture_path: Path
    port_name: str = VIRTUAL_NAME
    frames: List[sx.Frame] = field(default_factory=list)
    raw_events: List[dict] = field(default_factory=list)
    t0: float = field(default_factory=time.time)
    last_event: float = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _fh: object = None

    # endpoints
    _host_in: object = None      # what MCC writes to (our virtual destination)
    _host_out: object = None     # what MCC reads from (our virtual source)
    _dev_in: object = None       # real device -> us
    _dev_out: object = None      # us -> real device

    def start(self) -> None:
        if rtmidi is None:
            raise MidiUnavailable("python-rtmidi is not installed")
        Path(self.capture_path).parent.mkdir(parents=True, exist_ok=True)
        self._fh = open(self.capture_path, "a")

        # real hardware, excluding anything we ourselves published
        self._dev_in = rtmidi.MidiIn(name="mfcap")
        self._dev_out = rtmidi.MidiOut(name="mfcap")
        ins, outs = self._dev_in.get_ports(), self._dev_out.get_ports()
        i = find_port(ins, exclude=self.port_name if self._already_published(ins) else "")
        o = find_port(outs, exclude=self.port_name if self._already_published(outs) else "")
        if i is None or o is None:
            raise MidiUnavailable(
                f"MicroFreak hardware port not found.\n  in: {ins}\n  out: {outs}")
        self._dev_in.open_port(i)
        self._dev_in.ignore_types(sysex=False, timing=False, active_sense=False)
        self._dev_in.set_callback(self._from_device)
        self._dev_out.open_port(o)

        # virtual pair facing MCC
        self._host_in = rtmidi.MidiIn(name=self.port_name)
        self._host_in.open_virtual_port(self.port_name)
        self._host_in.ignore_types(sysex=False, timing=False, active_sense=False)
        self._host_in.set_callback(self._from_host)
        self._host_out = rtmidi.MidiOut(name=self.port_name)
        self._host_out.open_virtual_port(self.port_name)

    @staticmethod
    def _already_published(names: List[str]) -> bool:
        return any("mfcap" in n.lower() for n in names)

    def stop(self) -> None:
        for p in (self._host_in, self._host_out, self._dev_in, self._dev_out):
            try:
                p.close_port()
            except Exception:
                pass
        if self._fh:
            self._fh.flush()
            self._fh.close()

    # ---------- bridging ----------

    def _record(self, message, direction: str) -> None:
        t = time.time() - self.t0
        self.last_event = time.time()
        row = {"t": round(t, 6), "dir": direction,
               "hex": " ".join(f"{b:02X}" for b in message), "len": len(message)}
        f = sx.parse(message, direction=direction, t=t)
        if f is not None:
            row.update({"seq": f.seq, "lenbyte": f.length,
                        "cmd": f.cmd, "cmd_name": f.label()})
        with self._lock:
            self.raw_events.append(row)
            if f is not None:
                self.frames.append(f)
        self._fh.write(json.dumps(row) + "\n")
        self._fh.flush()

    def _from_host(self, event, _data=None):
        message, _ = event
        self._record(message, "out")          # MCC -> device
        try:
            self._dev_out.send_message(message)
        except Exception:
            pass

    def _from_device(self, event, _data=None):
        message, _ = event
        self._record(message, "in")           # device -> MCC
        try:
            self._host_out.send_message(message)
        except Exception:
            pass

    # ---------- observation helpers used by the runner ----------

    def count(self, direction: Optional[str] = None) -> int:
        with self._lock:
            if direction is None:
                return len(self.raw_events)
            return sum(1 for r in self.raw_events if r["dir"] == direction)

    def quiet_for(self) -> float:
        return time.time() - self.last_event if self.last_event else 1e9

    def mark(self, label: str) -> None:
        """Write a divider into the capture so bursts stay separable later."""
        row = {"t": round(time.time() - self.t0, 6), "dir": "mark", "label": label}
        with self._lock:
            self.raw_events.append(row)
        self._fh.write(json.dumps(row) + "\n")
        self._fh.flush()

    def probe(self, timeout: float = 30.0) -> bool:
        """Did MCC actually adopt our virtual port? Autonomous verdict."""
        before = self.count("out")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.count("out") > before:
                return True
            time.sleep(0.2)
        return False
