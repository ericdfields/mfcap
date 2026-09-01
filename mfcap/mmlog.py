"""Fallback capture route: Snoize MIDI Monitor's spy driver.

Used only when MCC refuses to adopt our virtual port. MIDI Monitor records
what any application sends to any destination, which is exactly what we need,
at the cost of one admin password (driver install) and one File > Save per
capture. The parser below is deliberately tolerant: it hunts for F0...F7 runs
anywhere in a line rather than depending on MIDI Monitor's column layout.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import List, Optional

from . import sysex as sx

HEXRUN = re.compile(r"(?:F0)(?:\s+[0-9A-Fa-f]{2})+\s+F7", re.IGNORECASE)
TIME = re.compile(r"^\s*(\d{1,2}:\d{2}:\d{2}\.\d+)")


def _direction(line: str) -> str:
    low = " " + " ".join(line.lower().split()) + " "
    if "spy" in low and " to " in low:
        return "out"
    if " to " in low and " from " not in low:
        return "out"
    if " from " in low:
        return "in"
    return "?"


def parse_log(path: Path) -> List[dict]:
    rows: List[dict] = []
    t_first: Optional[float] = None
    for line in Path(path).read_text(errors="replace").splitlines():
        runs = HEXRUN.findall(line)
        if not runs:
            continue
        t = None
        m = TIME.match(line)
        if m:
            h, mnt, s = m.group(1).split(":")
            t = int(h) * 3600 + int(mnt) * 60 + float(s)
            if t_first is None:
                t_first = t
            t -= t_first
        direction = _direction(line)
        for run in runs:
            data = bytes(int(b, 16) for b in run.split())
            row = {"t": round(t, 6) if t is not None else 0.0,
                   "dir": direction,
                   "hex": " ".join(f"{b:02X}" for b in data),
                   "len": len(data)}
            f = sx.parse(data, direction=direction, t=row["t"])
            if f is not None:
                row.update({"seq": f.seq, "lenbyte": f.length,
                            "cmd": f.cmd, "cmd_name": f.label()})
            rows.append(row)
    return rows


def convert(log_path: Path, out_path: Path) -> int:
    rows = parse_log(log_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    return len(rows)


def split_bursts(rows: List[dict], gap: float = 3.0) -> List[List[dict]]:
    """Group rows into bursts separated by at least `gap` seconds of silence.

    MIDI Monitor logs carry no case markers, but the five capture cases are
    performed one at a time with a pause between them, so silence is the
    marker. Rows without timestamps all land in one burst.
    """
    bursts: List[List[dict]] = []
    last_t: Optional[float] = None
    for r in rows:
        t = r.get("t") or 0.0
        if last_t is None or (t - last_t) >= gap:
            bursts.append([])
        bursts[-1].append(r)
        last_t = t
    return bursts


INSTALL_HINT = (
    "MIDI Monitor is the fallback capture route.\n"
    "  1. brew install --cask midi-monitor      (or snoize.com/MIDIMonitor)\n"
    "  2. Open it once. It will ask for an admin password to install the\n"
    "     spy driver. That password is the only privileged step in this\n"
    "     whole project, and it happens once.\n"
    "  3. Sources window: enable 'Spy on output to destinations'.\n"
    "  4. Filter to SysEx only, so the log stays readable."
)
