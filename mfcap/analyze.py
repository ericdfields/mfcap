"""Turn captures into a proposed write-frame specification.

The five captures in the plan are chosen so that pairwise diffs isolate one
variable each. This module does that alignment mechanically, then hunts for
the two things most likely to block a first write: an address field and a
checksum.

It proposes. It does not conclude - verify.py is what decides, by writing to
the device and reading the bytes back.
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import sysex as sx


def load(path: Path) -> List[dict]:
    rows = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def bursts(rows: List[dict], gap: float = 0.75) -> List[List[dict]]:
    """Split a capture into activity bursts separated by silence."""
    out: List[List[dict]] = []
    current: List[dict] = []
    last_t = None
    for r in rows:
        if r.get("dir") == "mark":
            if current:
                out.append(current)
                current = []
            last_t = None
            continue
        if last_t is not None and r["t"] - last_t > gap:
            out.append(current)
            current = []
        current.append(r)
        last_t = r["t"]
    if current:
        out.append(current)
    return out


def outbound(rows: List[dict]) -> List[dict]:
    return [r for r in rows if r.get("dir") == "out" and "cmd" in r]


def shape(rows: List[dict]) -> List[Tuple[int, int, int]]:
    """(cmd, len byte, payload size) per frame - the structural fingerprint."""
    out = []
    for r in rows:
        payload = len(r["hex"].split()) - 10   # F0 + 5 header + seq + len + cmd + F7
        out.append((r["cmd"], r["lenbyte"], max(payload, 0)))
    return out


def payload(r: dict) -> bytes:
    b = bytes(int(x, 16) for x in r["hex"].split())
    return b[9:-1]


def diff_positions(a: bytes, b: bytes) -> List[int]:
    n = min(len(a), len(b))
    return [i for i in range(n) if a[i] != b[i]]


def align(cap_a: List[dict], cap_b: List[dict]) -> List[Tuple[dict, dict]]:
    """Pair frames by index within matching structural shape."""
    pairs = []
    for x, y in zip(cap_a, cap_b):
        if x["cmd"] == y["cmd"]:
            pairs.append((x, y))
    return pairs


def find_address_field(same_preset_slot_a: List[dict],
                       same_preset_slot_b: List[dict],
                       slot_a: int, slot_b: int) -> Dict:
    """Same bytes, two slots: whatever differs is the address."""
    bank_a, pos_a = sx.addr(slot_a)
    bank_b, pos_b = sx.addr(slot_b)
    hits = []
    for i, (x, y) in enumerate(align(same_preset_slot_a, same_preset_slot_b)):
        px, py = payload(x), payload(y)
        for j in diff_positions(px, py):
            hits.append({
                "frame_index": i, "cmd": f"0x{x['cmd']:02X}", "byte_offset": j,
                "value_a": px[j], "value_b": py[j],
                "matches_position": px[j] == pos_a and py[j] == pos_b,
                "matches_bank": px[j] == bank_a and py[j] == bank_b,
            })
    confident = [h for h in hits if h["matches_position"] or h["matches_bank"]]
    return {"candidates": hits, "confident": confident,
            "verdict": "address field located" if confident
                       else "no byte tracked the slot number - look at frame ordering instead"}


CHECKSUM_TESTS = {
    "sum_mod_128": lambda d: sum(d) & 0x7F,
    "sum_neg_mod_128": lambda d: (-sum(d)) & 0x7F,
    "xor": lambda d: _xor(d),
    "sum_mod_256_low7": lambda d: (sum(d) & 0xFF) & 0x7F,
}


def _xor(d: bytes) -> int:
    v = 0
    for b in d:
        v ^= b
    return v & 0x7F


def hunt_checksum(frames: List[dict]) -> Dict:
    """For each frame, test whether a trailing byte is a checksum of the rest."""
    results = Counter()
    tested = 0
    for r in frames:
        p = payload(r)
        if len(p) < 3:
            continue
        tested += 1
        body, tail = p[:-1], p[-1]
        for name, fn in CHECKSUM_TESTS.items():
            if fn(body) == tail:
                results[name] += 1
    return {"frames_tested": tested, "hits": dict(results),
            "verdict": (max(results, key=results.get) + " looks like the checksum"
                        if results and max(results.values()) >= max(tested - 1, 1)
                        else "no simple checksum on the last payload byte")}


def payload_boundary(preset_a: List[dict], preset_b: List[dict]) -> Dict:
    """Different presets, same slot: where the content starts and stops."""
    spans = []
    for i, (x, y) in enumerate(align(preset_a, preset_b)):
        px, py = payload(x), payload(y)
        d = diff_positions(px, py)
        spans.append({"frame_index": i, "cmd": f"0x{x['cmd']:02X}",
                      "payload_len": len(px),
                      "first_differing_byte": d[0] if d else None,
                      "last_differing_byte": d[-1] if d else None,
                      "identical": not d})
    header = [s for s in spans if s["identical"]]
    return {"frames": spans,
            "constant_frames": len(header),
            "verdict": f"{len(header)} of {len(spans)} frames are content-independent "
                       f"(handshake/header); the rest carry preset bytes"}


def report(captures: Dict[str, Path], slots: Tuple[int, int],
           out_path: Path) -> str:
    """Write a markdown findings report from the five capture files."""
    loaded = {k: outbound(load(v)) for k, v in captures.items() if Path(v).exists()}
    lines = ["# MicroFreak write protocol - capture findings", ""]

    for name, rows in loaded.items():
        lines += [f"## capture: {name}", "",
                  f"- outbound MicroFreak frames: {len(rows)}",
                  f"- command histogram: {dict(Counter('0x%02X' % r['cmd'] for r in rows))}",
                  f"- structural shape (first 12): {shape(rows)[:12]}", ""]

    if "slot_a" in loaded and "slot_b" in loaded:
        res = find_address_field(loaded["slot_a"], loaded["slot_b"], *slots)
        # Emit the rewrite map the gate needs, so nobody has to transcribe it.
        rewrites = [{"frame_index": h["frame_index"], "offset": h["byte_offset"],
                     "kind": "position" if h["matches_position"] else "bank"}
                    for h in res["confident"]]
        (Path(out_path).parent / "rewrites.json").write_text(json.dumps(rewrites, indent=2))
        lines += ["## address field", "", f"**{res['verdict']}**", "",
                  f"Rewrite map written to `rewrites.json` "
                  f"({len(rewrites)} byte{'' if len(rewrites) == 1 else 's'}) - "
                  f"pass it straight to `mfcap verify --rewrites`.", ""]
        for h in res["confident"][:20]:
            lines.append(f"- frame {h['frame_index']} ({h['cmd']}) byte {h['byte_offset']}: "
                         f"{h['value_a']} -> {h['value_b']} "
                         f"({'position' if h['matches_position'] else 'bank'})")
        if not res["confident"]:
            for h in res["candidates"][:20]:
                lines.append(f"- unexplained: frame {h['frame_index']} ({h['cmd']}) "
                             f"byte {h['byte_offset']}: {h['value_a']} -> {h['value_b']}")
        lines.append("")

    if "preset_a" in loaded and "preset_b" in loaded:
        res = payload_boundary(loaded["preset_a"], loaded["preset_b"])
        lines += ["## payload boundary", "", f"**{res['verdict']}**", ""]
        for s in res["frames"][:24]:
            span = "identical" if s["identical"] else \
                   f"bytes {s['first_differing_byte']}..{s['last_differing_byte']}"
            lines.append(f"- frame {s['frame_index']} ({s['cmd']}, {s['payload_len']}B): {span}")
        lines.append("")

    for name, rows in loaded.items():
        res = hunt_checksum(rows)
        lines += [f"## checksum hunt: {name}", "",
                  f"- {res['frames_tested']} frames tested, hits: {res['hits']}",
                  f"- **{res['verdict']}**", ""]

    lines += ["## next", "",
              "Feed the proposed frame layout to `mfcap verify --slot <scratch>`.",
              "That writes a known preset, reads it back, and compares SHA-256.",
              "Nothing here is believed until that passes.", ""]

    text = "\n".join(lines)
    Path(out_path).write_text(text)
    return text
