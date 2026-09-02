"""Import the entire MIDI Control Center local store into a seed library.

MCC keeps the user's whole MicroFreak library as .mbp files under
    /Library/Arturia/MIDI Control Center/Templates/MicroFreak/Local/User/
one folder per project (commercial banks + the user's own device dumps), plus
"N.0 Likes" smart-folders that re-list rated presets.

This turns that store into a drop-in FreakCore seed bundle:
  - one PresetCollection per real project (origin = collection membership)
  - blobs deduped across every project (shared presets stored once)
  - ratings recovered from the Likes folders -> favorite (5.0) + a rating:N tag

Category is left Uncategorized on purpose: the .mbp meta bytes are NOT the
device category byte (see docs/arturia-taxonomy.md), so auto-decoding would
mis-tag. Category stays editable in the app.
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path

from microfreak.collections import BankItem
from microfreak.library import Library

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mbp_import import parse_mbp_text  # noqa: E402

SMART_FOLDERS = {"3.0 Likes", "4.0 Likes", "5.0 Likes", "All Custom Patches"}


def _presets_in(project_dir: Path):
    for mbp in sorted(project_dir.rglob("*.mbp")):
        try:
            yield parse_mbp_text(mbp.read_text(errors="replace"), source=mbp.name)
        except Exception:
            continue




def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--store", default="/Library/Arturia/MIDI Control Center/"
                    "Templates/MicroFreak/Local/User")
    ap.add_argument("--out", required=True)
    ap.add_argument("--extra", nargs="*", default=[],
                    help=".mfprojz banks to import as extra collections "
                         "(e.g. a downloaded pack never imported into MCC)")
    args = ap.parse_args()

    store = Path(args.store)
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    lib = Library.create(out / "library")

    projects = sorted(p for p in store.iterdir()
                      if p.is_dir() and p.name not in SMART_FOLDERS)
    total_placed = 0
    for proj in projects:
        items = [BankItem(slot=p.slot, name=p.name, meta=p.meta, blob=p.blob)
                 for p in _presets_in(proj) if p.blob is not None and p.slot is not None]
        if not items:
            continue
        coll, added = lib.collection_from_bank(items, name=proj.name, source=proj.name)
        total_placed += len(added)
        print(f"  collection {proj.name!r}: {len(added)} presets")

    from mbp_import import read_mfprojz  # noqa: E402
    for extra in args.extra:
        ep = Path(extra)
        items = [BankItem(slot=p.slot, name=p.name, meta=p.meta, blob=p.blob)
                 for p in read_mfprojz(ep) if p.blob is not None and p.slot is not None]
        if items:
            name = ep.stem.replace("_", " ")
            _, added = lib.collection_from_bank(items, name=name, source=ep.name)
            total_placed += len(added)
            print(f"  collection {name!r} (extra): {len(added)} presets")

    # NOTE: the "N.0 Likes" folders are empty reference stubs (no blob), so
    # ratings cannot be recovered by content and are not imported. Favorites
    # remain a first-class app feature the user drives manually.

    entries = lib.entries()
    blobs = len({e.sha256 for e in entries})
    placed = sum(1 for e in entries if e.slot is not None)
    print(f"\nprojects: {len(projects)}  entries: {len(entries)}  "
          f"unique blobs: {blobs}  slot-placed: {placed}  "
          f"collections: {len(lib.collections())}")


if __name__ == "__main__":
    main()
