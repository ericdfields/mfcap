"""Synthesizing writes - the first phase 1 capability.

The gate proved MCC's captured burst can be replayed to any slot. This module
goes one step further: it takes a captured burst as a *template* and swaps in
arbitrary content, so the toolkit can write any preset blob to any slot.

Observed write sequence (fw 5.x, captured 2026-09-01, gate-verified):

    -> 0x19  open [bank, pos, 0x00]          name read (MCC refreshes its list)
    -> 0x52  [bank, pos, 0x00, ...hdr..., name padded to 23 bytes]   name+meta
    -> 0x52  [bank, pos, 0x01]               opens the blob write
    -> 0x15  []                              go (seq 0, len 0)
    -> 0x16  32-byte chunk                   x145, device acks each with 0x18
    -> 0x17  32-byte chunk                   the last one
    -> 0x19  open [bank, pos, 0x00]          name read back

The name travels only in the 0x52 frame; the 4672-byte blob only in chunks.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import List, Optional

from . import sysex as sx
from .verify import Rewrite

NAME_OFFSET = 12          # name position inside the long 0x52 payload
NAME_FIELD_LEN = 23


def template_target(rows: List[dict]) -> Optional[int]:
    """Which slot does this captured burst write to? Read its write-open frame."""
    for r in rows:
        if r.get("dir") == "out" and r.get("cmd") == 0x52:
            p = bytes(int(x, 16) for x in r["hex"].split())[9:-1]
            if len(p) == 3 and p[2] == 0x01:
                return p[0] * sx.SLOTS_PER_BANK + p[1]
    return None


def address_rewrites(rows: List[dict]) -> List[Rewrite]:
    """Rewrite map for a captured write burst, derived from its own frames.

    Address bytes live only in 0x19 (open) and 0x52 (name / write-open)
    frames, never in chunks - chunk payloads can start with any bytes.
    """
    target = template_target(rows)
    if target is None:
        return []
    bank, pos = sx.addr(target)
    out = []
    i = -1
    for r in rows:
        if r.get("dir") != "out" or "cmd" not in r:
            continue
        i += 1
        if r["cmd"] not in (0x19, 0x52):
            continue
        p = bytes(int(x, 16) for x in r["hex"].split())[9:-1]
        if len(p) >= 2 and p[0] == bank and p[1] == pos:
            out.append(Rewrite(frame_index=i, offset=0, kind="bank"))
            out.append(Rewrite(frame_index=i, offset=1, kind="position"))
    return out


def synth_rows(template: List[dict], blob: bytes,
               name: Optional[str] = None) -> List[dict]:
    """Template burst + new content = a write burst for that content.

    Chunk payload sizes are kept exactly as captured; the blob must match the
    template's total chunk capacity. Addresses are NOT changed here - replay()
    retargets them via address_rewrites(), same as the gate.
    """
    chunk_sizes = []
    for r in template:
        if r.get("dir") == "out" and r.get("cmd") in (0x16, 0x17):
            chunk_sizes.append(len(r["hex"].split()) - 10)
    if sum(chunk_sizes) != len(blob):
        raise ValueError(f"template carries {sum(chunk_sizes)} content bytes, "
                         f"blob is {len(blob)}")

    out: List[dict] = []
    pos = 0
    for r in template:
        r = dict(r)
        if r.get("dir") == "out" and r.get("cmd") in (0x16, 0x17):
            raw = bytes(int(x, 16) for x in r["hex"].split())
            n = len(raw) - 10
            raw = raw[:9] + blob[pos:pos + n] + raw[-1:]
            pos += n
            r["hex"] = " ".join(f"{b:02X}" for b in raw)
        elif (name is not None and r.get("dir") == "out" and r.get("cmd") == 0x52
              and len(r["hex"].split()) > 20):
            raw = bytearray(int(x, 16) for x in r["hex"].split())
            field = name.encode("ascii", "replace")[:NAME_FIELD_LEN]
            field = field + b"\x00" * (NAME_FIELD_LEN - len(field))
            start = 9 + NAME_OFFSET
            raw[start:start + NAME_FIELD_LEN] = field
            r["hex"] = " ".join(f"{b:02X}" for b in raw)
        out.append(r)
    return out
