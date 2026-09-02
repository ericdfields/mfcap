"""Parse Arturia MIDI Control Center MicroFreak exports into library/collection data.

MCC stores presets as Boost text-serialization archives:
  - `.mbp`      one preset
  - `.mfprojz`  a zip of `.mbp` files, a whole sound bank / project

A full preset archive carries, in order after the archive header:
    <namelen> <name>            preset name (namelen ASCII chars)
    <a> <b> <c>                 three small ints (bookkeeping)
    <metalen> <metahex>         metadata, metalen hex chars (== 18 -> 9 bytes)
    <d> <e>                     two ints
    <itemver> <bloblen> <bytes> the preset blob: bloblen decimal byte values

VERIFIED 2026-09-01: the <bloblen>=4672 blob is byte-for-byte the same format
as a MicroFreak SysEx dump (microfreak.protocol.BLOB_SIZE) — the parameter-name
table aligns offset-for-offset against a real device backup blob, and the
9-byte meta matches the device's meta field. Empty/Init preset slots serialize
with no blob array (a short archive); they carry only a name.

Slot position comes from the filename prefix: "07-Voltage Forms-A7.mbp" and the
sub-bank letter place it in the MicroFreak's 512-slot space.
"""
from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, List, Optional

BLOB_SIZE = 4672
_HEADER = re.compile(
    r'serialization::archive\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s')
# filename like "07-Voltage Forms-A7.mbp" or "132-Tokyo88 V3-C4.mbp"
_FNAME = re.compile(r'^(\d+)-.*?-([A-E])(\d+)\.mbp$', re.IGNORECASE)
_BANK_OFFSET = {"A": 0, "B": 128, "C": 256, "D": 384, "E": 384}  # E rare; clamp


@dataclass(frozen=True)
class MbpPreset:
    name: str
    meta: bytes                 # 9 bytes, or b"" for an empty slot
    blob: Optional[bytes]       # 4672 bytes, or None for an empty/Init slot
    order: int                  # 1-based sequence within the bank (filename prefix)
    slot: Optional[int]         # 0-based MF slot from sub-bank+index, if derivable
    source: str                 # originating filename

    @property
    def is_empty(self) -> bool:
        return self.blob is None


def _slot_from_name(fname: str) -> Optional[int]:
    m = _FNAME.match(Path(fname).name)
    if not m:
        return None
    bank, idx = m.group(2).upper(), int(m.group(3))
    base = _BANK_OFFSET.get(bank)
    if base is None or not (1 <= idx <= 128):
        return None
    return base + idx - 1


def parse_mbp_text(txt: str, order: int = 0, source: str = "") -> MbpPreset:
    m = _HEADER.search(txt)
    if not m:
        raise ValueError("not a MicroFreak Boost archive")
    namelen = int(m.group(1))
    rest = txt[m.end():]
    name = rest[:namelen]
    toks = rest[namelen:].split()
    # toks: a b c metalen metahex d e itemver [bloblen bytes...]
    meta = b""
    blob: Optional[bytes] = None
    if len(toks) >= 5:
        try:
            metalen = int(toks[3])
            metahex = toks[4]
            if len(metahex) == metalen and metalen % 2 == 0:
                meta = bytes.fromhex(metahex)
        except (ValueError, IndexError):
            pass
    # locate the blob array: the token BLOB_SIZE followed by that many ints
    for i, t in enumerate(toks):
        if t == str(BLOB_SIZE) and len(toks) - i - 1 >= BLOB_SIZE:
            candidate = toks[i + 1:i + 1 + BLOB_SIZE]
            try:
                blob = bytes(int(x) for x in candidate)
                break
            except ValueError:
                continue
    return MbpPreset(name=name.strip(), meta=meta, blob=blob,
                     order=order, slot=_slot_from_name(source), source=source)


def read_mfprojz(path: Path) -> List[MbpPreset]:
    """Every preset in a .mfprojz bank, in filename order."""
    out: List[MbpPreset] = []
    with zipfile.ZipFile(path) as z:
        names = sorted(n for n in z.namelist() if n.lower().endswith(".mbp"))
        for order, n in enumerate(names, 1):
            txt = z.read(n).decode("latin-1")
            out.append(parse_mbp_text(txt, order=order, source=n))
    return out


def read_mbp(path: Path) -> MbpPreset:
    return parse_mbp_text(Path(path).read_text(errors="replace"),
                          order=1, source=Path(path).name)


def load_any(path: Path) -> List[MbpPreset]:
    p = Path(path)
    if p.suffix.lower() == ".mfprojz":
        return read_mfprojz(p)
    if p.suffix.lower() == ".mbp":
        return [read_mbp(p)]
    raise ValueError(f"unsupported: {p.suffix}")


def iter_presets(root: Path) -> Iterator[tuple[Path, MbpPreset]]:
    """Walk a folder tree yielding (bank_path, preset) for every MCC export."""
    root = Path(root)
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() in (".mfprojz", ".mbp"):
            try:
                for pr in load_any(path):
                    yield path, pr
            except (ValueError, zipfile.BadZipFile):
                continue


if __name__ == "__main__":
    import sys
    for bank, pr in iter_presets(Path(sys.argv[1])):
        if not pr.is_empty:
            print(f"{bank.name} :: slot={pr.slot} {pr.name!r} "
                  f"meta={pr.meta.hex()} blob={len(pr.blob or b'')}")
