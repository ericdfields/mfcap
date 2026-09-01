"""Driving MIDI Control Center without a person in the chair.

MCC has no scripting interface, so this is coordinate replay - but done in the
way that costs a human the least:

  * ONE calibration pass. You hover the pointer over each control and press
    return. No clicking, no typing coordinates, about ninety seconds.
  * Coordinates are stored relative to MCC's window origin, so moving or
    reopening the window does not invalidate them.
  * Every replayed action verifies itself against the MIDI wire. If a drag
    produces no traffic, the run does not silently continue with a bad
    capture - it falls back to asking you to do that one action by hand.

Requires `cliclick` (brew install cliclick) and, the first time, macOS
Accessibility permission for the terminal. Both are one-time.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional, Tuple

MCC_APP = "MIDI Control Center"

# The controls a capture run needs to touch. Order is the calibration order.
CONTROLS = [
    ("device_entry", "the MicroFreak row in MCC's device list (left side)"),
    ("local_preset_a", "the FIRST preset you'll send, in the local/library list"),
    ("local_preset_b", "a DIFFERENT preset in the local/library list"),
    ("local_preset_init", "an init or empty preset in the local/library list"),
    ("device_slot_a", "device slot 509 in the device preset list (scratch)"),
    ("device_slot_b", "device slot 510 in the device preset list (scratch)"),
    ("store_button", "the Store / Send-to-device button (skip if MCC has none)"),
]


def have_cliclick() -> bool:
    return shutil.which("cliclick") is not None


def _osa(script: str, timeout: float = 10.0) -> str:
    r = subprocess.run(["osascript", "-e", script], capture_output=True,
                       text=True, timeout=timeout)
    return r.stdout.strip()


def mcc_running() -> bool:
    return _osa(f'application "{MCC_APP}" is running') == "true"


def launch_mcc() -> bool:
    try:
        subprocess.run(["open", "-a", MCC_APP], check=True, timeout=20)
    except (subprocess.CalledProcessError, OSError, subprocess.TimeoutExpired):
        return False
    for _ in range(30):
        if mcc_running():
            return True
        time.sleep(1)
    return False


def mcc_window_origin() -> Optional[Tuple[int, int]]:
    script = f'''
    tell application "System Events"
      if not (exists process "{MCC_APP}") then return ""
      tell process "{MCC_APP}"
        if (count of windows) is 0 then return ""
        set p to position of window 1
        return (item 1 of p as string) & "," & (item 2 of p as string)
      end tell
    end tell'''
    try:
        out = _osa(script)
    except subprocess.TimeoutExpired:
        return None
    if not out or "," not in out:
        return None
    x, y = out.split(",")
    return int(float(x)), int(float(y))


def pointer() -> Tuple[int, int]:
    out = subprocess.run(["cliclick", "p"], capture_output=True, text=True).stdout
    # cliclick prints e.g. "123,456"
    digits = "".join(c for c in out if c.isdigit() or c in ",-")
    x, y = digits.split(",")[:2]
    return int(x), int(y)


@dataclass
class Calibration:
    path: Path
    origin: Tuple[int, int] = (0, 0)
    points: Dict[str, Tuple[int, int]] = None   # relative to window origin

    def __post_init__(self):
        if self.points is None:
            self.points = {}

    def load(self) -> bool:
        if not self.path.exists():
            return False
        data = json.loads(self.path.read_text())
        self.origin = tuple(data.get("origin", (0, 0)))
        self.points = {k: tuple(v) for k, v in data.get("points", {}).items()}
        return bool(self.points)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(
            {"origin": list(self.origin),
             "points": {k: list(v) for k, v in self.points.items()},
             "saved": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=2))

    def absolute(self, key: str) -> Optional[Tuple[int, int]]:
        """Re-anchor to wherever the MCC window is right now."""
        if key not in self.points:
            return None
        now = mcc_window_origin() or self.origin
        rx, ry = self.points[key]
        return now[0] + rx, now[1] + ry


def calibrate(cal: Calibration, ask, info) -> bool:
    """One hover-and-return pass over every control. No clicking."""
    if not have_cliclick():
        return False
    origin = mcc_window_origin()
    if origin is None:
        return False
    cal.origin = origin
    info("Hover the pointer over each control and press return. Don't click.")
    for key, description in CONTROLS:
        answer = ask(f"point at {description}")
        if answer == "skip":
            continue
        x, y = pointer()
        cal.points[key] = (x - origin[0], y - origin[1])
        info(f"  {key} -> +{x - origin[0]},+{y - origin[1]}")
    cal.save()
    return bool(cal.points)


class MccAuto:
    """Replay of calibrated actions, each one verified against MIDI traffic."""

    def __init__(self, cal: Calibration, wire_count):
        self.cal = cal
        self.wire_count = wire_count   # callable -> frames seen so far

    def usable(self) -> bool:
        return have_cliclick() and bool(self.cal.points) and mcc_running()

    def _run(self, args: list) -> bool:
        try:
            subprocess.run(["cliclick"] + args, check=True, timeout=30)
            return True
        except (subprocess.CalledProcessError, OSError, subprocess.TimeoutExpired):
            return False

    def click(self, key: str) -> bool:
        pos = self.cal.absolute(key)
        if pos is None:
            return False
        return self._run([f"c:{pos[0]},{pos[1]}"])

    def drag(self, src: str, dst: str) -> bool:
        a, b = self.cal.absolute(src), self.cal.absolute(dst)
        if a is None or b is None:
            return False
        mid = ((a[0] + b[0]) // 2, (a[1] + b[1]) // 2)
        return self._run([
            f"m:{a[0]},{a[1]}", "w:120",
            f"dd:{a[0]},{a[1]}", "w:200",
            f"m:{mid[0]},{mid[1]}", "w:150",
            f"m:{b[0]},{b[1]}", "w:250",
            f"du:{b[0]},{b[1]}",
        ])

    def send_preset(self, local_key: str, slot_key: str,
                    settle: float = 8.0) -> bool:
        """Drag a library preset onto a device slot, then confirm on the wire.

        Returns True only if MIDI traffic actually happened. A silent drag is
        a failed drag, and the caller escalates to a human for that one action.
        """
        before = self.wire_count()
        subprocess.run(["open", "-a", MCC_APP], capture_output=True)
        time.sleep(0.6)
        if not self.drag(local_key, slot_key):
            return False
        if self.cal.absolute("store_button"):
            time.sleep(0.5)
            self.click("store_button")
        deadline = time.time() + settle
        while time.time() < deadline:
            if self.wire_count() > before:
                return True
            time.sleep(0.2)
        return False
