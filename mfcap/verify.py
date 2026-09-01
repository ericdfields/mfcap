"""The gate: write -> read back -> hashes match.

The shortcut that makes this cheap: we do not need to *understand* the write
protocol to prove we can use it. We replay MCC's own captured burst with the
address bytes rewritten to a scratch slot. If the preset lands there and reads
back byte-identical to the one MCC wrote, the write path is real and the
address field is confirmed - both at once, before anyone has decoded a single
parameter.

Order of operations is non-negotiable:
  1. full backup exists                (mfcap backup)
  2. scratch slot's own contents saved  (here)
  3. replay
  4. read back, compare
  5. restore the scratch slot           (always, even on failure)
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from microfreak import analysis as _analysis
from microfreak.model import SlotRecord

from . import sysex as sx
from .midi import Device, Reader


@dataclass
class Rewrite:
    """One byte to patch during replay: which frame, which payload offset."""
    frame_index: int
    offset: int
    kind: str        # "bank" or "position"


def _frames_from_capture(rows: List[dict]) -> List[Tuple[float, bytes]]:
    out = []
    for r in rows:
        if r.get("dir") != "out" or "cmd" not in r:
            continue
        data = bytes(int(x, 16) for x in r["hex"].split())
        out.append((r["t"], data))
    return out


def replay(dev: Device, rows: List[dict], target_slot: int,
           rewrites: List[Rewrite], pace: str = "ack",
           ack_timeout: float = 1.0, max_gap: float = 0.25) -> int:
    """Replay a captured write burst, retargeted at target_slot.

    pace="ack"   wait for the device to answer each frame (safest)
    pace="timed" reproduce the capture's own inter-frame gaps
    """
    bank, pos = sx.addr(target_slot)
    frames = _frames_from_capture(rows)
    by_index: Dict[int, List[Rewrite]] = {}
    for rw in rewrites:
        by_index.setdefault(rw.frame_index, []).append(rw)

    sent = 0
    prev_t = frames[0][0] if frames else 0.0
    for i, (t, data) in enumerate(frames):
        msg = bytearray(data)
        for rw in by_index.get(i, []):
            idx = 9 + rw.offset          # payload starts at byte 9
            if idx < len(msg) - 1:
                msg[idx] = bank if rw.kind == "bank" else pos
        dev.drain()
        dev.send(list(msg))
        sent += 1
        if pace == "ack":
            deadline = time.time() + ack_timeout
            while time.time() < deadline:
                if dev.quiet_for() < 0.05:
                    break
                time.sleep(0.01)
            time.sleep(0.01)
        else:
            time.sleep(min(max(t - prev_t, 0.0), max_gap))
        prev_t = t
    return sent


def run_gate(dev: Device, capture_rows: List[dict], source_slot: int,
             scratch_slot: int, rewrites: List[Rewrite],
             out_dir: Path, log, expected_blob: Optional[bytes] = None) -> dict:
    """Full gate run with restore. Returns a verdict dict.

    expected_blob, when given, is the authoritative expectation - the blob
    assembled from the capture's own chunk frames. Reading the source slot
    instead is a trap: anything written to that slot after the capture (c4
    drags init onto the same slot, for instance) silently changes the
    expectation and fails a write that actually worked.
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    reader = Reader(dev)
    result = {"source_slot": source_slot, "scratch_slot": scratch_slot,
              "passed": False, "stage": "start"}

    if expected_blob:
        log("expectation: blob assembled from the capture's own chunks")
        expected = expected_blob
    else:
        log(f"reading source slot {source_slot} (what MCC wrote)")
        expected = reader.preset(source_slot)
    if not expected:
        result["stage"] = "source read failed"
        return result
    result["expected_sha256"] = sx.digest(expected)
    (out_dir / "expected.bin").write_bytes(expected)

    log(f"saving scratch slot {scratch_slot} so it can be put back")
    original = reader.preset(scratch_slot)
    if original:
        (out_dir / "scratch_original.bin").write_bytes(original)
        result["scratch_original_sha256"] = sx.digest(original)
    else:
        log("scratch slot did not read back - treating as empty")

    try:
        log(f"replaying captured write into slot {scratch_slot}")
        result["frames_sent"] = replay(dev, capture_rows, scratch_slot, rewrites)
        result["stage"] = "replayed"
        time.sleep(1.0)

        log("reading it back")
        got = reader.preset(scratch_slot)
        if not got:
            result["stage"] = "readback failed"
            return result
        (out_dir / "readback.bin").write_bytes(got)
        result["readback_sha256"] = sx.digest(got)
        result["passed"] = (result["readback_sha256"] == result["expected_sha256"])
        result["stage"] = "compared"
        if not result["passed"]:
            n = min(len(expected), len(got))
            result["first_difference"] = next(
                (i for i in range(n) if expected[i] != got[i]), n)
            result["length_expected"] = len(expected)
            result["length_readback"] = len(got)
    finally:
        # Deliberately no automatic restore. An unproven write path is exactly
        # the wrong tool for putting something back, and a scratch slot chosen
        # by `pick_scratch_slot` was empty or expendable to begin with.
        if original:
            result["restore_note"] = (
                f"Slot {scratch_slot} previously held {len(original)} bytes, saved to "
                "scratch_original.bin. Restore it through MCC, or through this "
                "toolkit once the write path has passed the gate.")
            log(result["restore_note"])

    (out_dir / "verdict.json").write_text(json.dumps(result, indent=2))
    return result


def pick_scratch_slot(backup_index: Path, prefer_from: int = 500,
                      exclude: tuple = ()) -> Optional[int]:
    """Choose the safest slot to write into: highest-numbered expendable one.

    "Empty" is judged by content, not name: the MicroFreak ships every unused
    slot as a factory Init preset with a name ("Init"), so a blank name never
    happens on a stock device. A slot is expendable if its exact bytes occur
    at least three times in the backup - overwriting one copy of a
    mass-duplicated blob loses nothing unique. (Three, not two, so a user's
    own single duplicated preset is never chosen.) Blank-named slots also
    qualify.

    Only falls back to asking a human if no slot qualifies, and then it is
    the caller's job to put that choice in front of them.

    The judgement itself lives in microfreak.analysis (find_expendable /
    pick_scratch_slot); this is the phase-0 index.json adapter around it.
    """
    data = json.loads(Path(backup_index).read_text())
    records = [SlotRecord(slot=int(k), name=v.get("name"),
                          sha256=v.get("sha256"), meta=None, blob=None)
               for k, v in data.get("presets", {}).items()]
    return _analysis.pick_scratch_slot(records, prefer_from=prefer_from,
                                       exclude=exclude)
