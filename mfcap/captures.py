"""The capture run: five deliberate MCC actions, diffed against each other.

Each case is a Step. Every Step tries the automated route first (calibrated
MCC replay) and only escalates to a person when that fails - and when it does,
it detects its own completion from MIDI traffic, so nobody has to walk back to
the keyboard to press return.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

from .operator import Operator, Step


@dataclass
class Case:
    key: str
    title: str
    local: str          # calibration key for the source preset
    slot: str           # calibration key for the destination slot
    instruction: str    # what to tell a human if automation is unavailable
    why: str


def build_cases(slot_a: int, slot_b: int) -> List[Case]:
    return [
        Case("c1_presetA_slotA", "preset A to the first scratch slot",
             "local_preset_a", "device_slot_a",
             f"In MCC, drag your first preset onto device slot {slot_a} and let it send.",
             "baseline: one complete write, start to finish"),
        Case("c2_presetA_slotB", "the SAME preset to the second scratch slot",
             "local_preset_a", "device_slot_b",
             f"In MCC, drag the SAME preset you just used onto device slot {slot_b}.",
             "identical payload, different destination - whatever changes is the address field"),
        Case("c3_presetB_slotA", "a DIFFERENT preset to the first scratch slot",
             "local_preset_b", "device_slot_a",
             f"In MCC, drag a DIFFERENT preset onto device slot {slot_a}.",
             "same destination, different payload - finds where content starts and stops"),
        Case("c4_init_slotA", "an init/empty preset to the first scratch slot",
             "local_preset_init", "device_slot_a",
             f"In MCC, drag an init or empty preset onto device slot {slot_a}.",
             "reveals padding and default structure"),
        Case("c5_rename", "a rename-only change",
             "local_preset_a", "device_slot_a",
             f"In MCC, rename the preset in device slot {slot_a} (change one letter) and save it.",
             "shows whether the name is written separately or rides inside the blob"),
    ]


def split_capture(master: Path, out_dir: Path) -> Dict[str, Path]:
    """Split the single running capture into one file per case, by markers."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    files: Dict[str, Path] = {}
    current: Optional[str] = None
    buf: List[str] = []

    def flush():
        if current and buf:
            p = out_dir / f"{current}.jsonl"
            p.write_text("".join(buf))
            files[current] = p

    for line in Path(master).read_text().splitlines(True):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("dir") == "mark":
            label = row.get("label", "")
            if label.startswith("begin:"):
                flush()
                current = label.split(":", 1)[1]
                buf = []
            elif label.startswith("end:"):
                flush()
                current = None
                buf = []
            continue
        if current:
            buf.append(line)
    flush()
    return files


def run_cases(op: Operator, proxy, mcc, cases: List[Case],
              settle: float = 2.0, timeout: float = 900.0) -> Dict[str, int]:
    """Execute every case, automated where possible, guided where not."""
    counts: Dict[str, int] = {}

    for case in cases:
        baseline = proxy.count()
        proxy.mark(f"begin:{case.key}")

        def auto(c=case):
            if mcc is None or not mcc.usable():
                return False
            return mcc.send_preset(c.local, c.slot)

        def done(c=case, base=baseline):
            # the burst has started and the wire has been quiet since
            return proxy.count() > base + 2 and proxy.quiet_for() > settle

        step = Step(
            name=case.title,
            instruction=case.instruction,
            auto=auto if case.key != "c5_rename" else None,   # rename has no drag to replay
            done_when=done,
            why=case.why,
            timeout=timeout,
        )
        ok = op.run(step)

        # settle, then close the case out
        end = time.time() + settle + 1.0
        while time.time() < end and proxy.quiet_for() < settle:
            time.sleep(0.1)
        proxy.mark(f"end:{case.key}")
        counts[case.key] = proxy.count() - baseline
        if counts[case.key] == 0:
            op.warn(f"{case.title}: no MIDI traffic recorded - this capture is empty")
        else:
            op.ok(f"{case.title}: {counts[case.key]} messages captured")
        if not ok:
            op.warn(f"{case.title}: not confirmed, continuing anyway")

    return counts
