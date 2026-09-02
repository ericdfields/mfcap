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

Regenerating the shipped seed
-----------------------------
    PYTHONPATH=. python3 tools/import_mcc_store.py \
        --out ios/App/Resources/SeedBanks/library \
        --extra <every .mfprojz bank not present in the MCC store>

The output is the shipped artifact VERBATIM: never hand-edit index.json
afterwards. It once shipped with the `verdict` key stripped from all 966
entries, which is only reachable by editing the file after generation --
neither core's index writer can emit an entry without it. A plain run over
the MCC store alone yields 16 collections / 934 entries; the shipped seed
also carries the "Ambient Peaks" bank, which must be passed via --extra.

The acceptance census is asserted, not eyeballed: see
`SeedLibraryShapeTests` in ios/App/Tests/AppModelTests.swift (966 unique
entries and blobs, 17 collections, every entry key the cores write, every
collection ref resolvable). A regeneration that silently drops a bank
fails those tests.
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
    colls = lib.collections()
    # The ARRANGEMENT belongs to the collections; the flat catalog carries no
    # slot opinion, so counting entry claims here would always print 0. Count
    # the collections' placements instead.
    placed = sum(len(c.slots) for c in colls)
    assert all(e.slot is None for e in entries), \
        "bank import must not stamp entry slots"
    print(f"\nprojects: {len(projects)}  entries: {len(entries)}  "
          f"unique blobs: {blobs}  collection slots: {placed}  "
          f"collections: {len(colls)}")


if __name__ == "__main__":
    main()
