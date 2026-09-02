#!/usr/bin/env python3
"""Convert Arturia MicroFreak sound banks (.mfprojz) into bundled seed data.

Turns a folder tree of MCC ``.mfprojz`` exports into a drop-in FreakCore
library that ships inside the app, so a brand-new install has a full,
browsable library and a shelf of ready-to-apply banks with **no device
attached**.

Output (a self-contained library folder, exactly the shape the core expects):

    <out>/
      manifest.json                 seed-bundle summary (counts + bank list)
      library/
        index.json                  schema-1 Library index (all placed presets)
        blobs/<sha256>.bin          deduped 4672-byte preset blobs
        collections/<id>.json       one PresetCollection per bank
      README.md                     hand-maintained (this tool never writes it)

Everything conforms to ``ios/docs/collections-categories-spec.md`` v1.0 (the
authoritative data-model spec), which pins the on-disk shapes as byte-
interoperable Python/Swift declarations:

  * **Library index** (spec §2.1): schema stays ``1``; each entry additively
    gains ``category`` (a lowercase Category *slug*) and ``favorite`` (bool);
    ``tags`` already existed. Old loaders ignore the new keys, so this index
    loads unchanged in ``microfreak.library.Library.open`` today (checked by
    ``--verify``). Seed entries are a *pool*: ``slot`` is ``null`` (the per-bank
    slot placement lives in the collections, exactly as ``PresetCollection``
    owns it).

  * **PresetCollection** (spec §4.1): ``library/collections/<id>.json`` with
    ``schema``, ``id`` (uuid4-hex shape), ``name``, ``created_at``,
    ``provenance {kind: "imported_bank", source}`` and ``slots`` — a JSON object
    keyed by the **decimal slot number as a string**, each value a ``PresetRef``
    ``{sha256, name, meta_hex}`` (spec §3). Iterate ascending by ``int(key)``.

  * **Import behavior** (spec §5.2): a bank item with ``blob is None`` OR
    ``slot is None`` is unplaceable and contributes no ref and no entry (this
    skips Init slots and the handful of malformed MCC filenames the verified
    parser cannot place); every placed item yields one ``PresetRef`` at its slot
    plus one library entry. **Downloaded packs arrive ``uncategorized``** —
    category is auto-filled from the device byte only on *device* import
    (spec §2.5), never here.

Determinism (the whole point of a regeneration tool): entry/collection ids are
content-derived (a ``sha256`` prefix in uuid4-hex shape, not a random UUID),
timestamps are a fixed constant, every list/dict is sorted and every JSON file
is written with ``sort_keys=True``. Re-running over the same inputs produces
byte-identical output.

Blob parsing is delegated to the VERIFIED ``tools/mbp_import`` parser; every
placed preset is round-tripped through ``microfreak.model.Preset`` (enforcing
the 4672-byte, 7-bit-clean, valid-name, 9-byte-meta invariants) and hashed with
``microfreak.protocol.digest`` so the seed can only contain presets the core
itself would accept.

Usage:
    python3 tools/convert_banks.py --out <seedbanks-dir> <input-folder> [...]
    python3 tools/convert_banks.py --out ios/App/Resources/SeedBanks \\
        "~/Downloads/Music Production" "~/Downloads/Ambient_Peaks_13e36e2350"

stdlib-only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# --- make the repo importable whether run as a script or a module ----------
_REPO_ROOT = Path(__file__).resolve().parent.parent
for _p in (str(_REPO_ROOT), str(_REPO_ROOT / "tools")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from mbp_import import MbpPreset, read_mfprojz          # verified Boost parser
from microfreak.model import Preset                      # core invariants
from microfreak.protocol import SLOTS, digest           # 512, sha256

# Seed-bundle envelope (NOT a core schema; the core discovers collections by
# scanning library/collections/*.json and never reads this manifest).
BUNDLE_FORMAT = 1
LIBRARY_SCHEMA = 1              # spec §2.1 — stays 1 (additive fields)
COLLECTION_SCHEMA = 1          # spec §4.1
SLOT_CAPACITY = SLOTS          # 512 — the device slot space

# Fixed, deterministic timestamp for every seed entry/collection. Format is the
# library interop rule ("yyyy-MM-dd'T'HH:mm:ss", local, no zone; spec §0). A
# seed marker, not a real capture time.
SEED_TIMESTAMP = "2022-01-01T00:00:00"

# --------------------------------------------------------------------------
# Category taxonomy -- THE single device-byte -> category table, mirroring
# ios/docs/collections-categories-spec.md §1.1 and the Arturia MicroFreak set.
#
# CONFIRMABLE AGAINST HARDWARE: the index->slug map is the one documented
# starting point but is NOT proven against ground truth (only a single captured
# device reply, slot 200 meta[7]=0x03, touches it). Confirm against a device,
# then correct in this ONE place; category is a user-editable attribute so a
# wrong auto-fill is always fixable.
#
# This table is the DEVICE-IMPORT auto-fill path only (spec §2.5). It is NOT
# used to categorize downloaded packs: per spec §5.2, imported-bank presets
# always arrive "uncategorized" for manual/bulk tagging, regardless of their
# meta bytes (the non-zero meta bytes seen in some packs are a Characteristics
# bitfield, not a category index -- see docs/arturia-taxonomy.md). The raw meta
# is preserved verbatim in every entry's meta_hex, so nothing is lost.
CATEGORY_SLUGS: List[str] = [
    "uncategorized",  # 0x00
    "bass",           # 0x01
    "brass",          # 0x02
    "keys",           # 0x03
    "lead",           # 0x04
    "organ",          # 0x05
    "pad",            # 0x06
    "percussion",     # 0x07
    "sequence",       # 0x08
    "sfx",            # 0x09
    "strings",        # 0x0A
    "template",       # 0x0B
    "vocoder",        # 0x0C
]
UNCATEGORIZED = "uncategorized"


def category_from_device_byte(byte: int) -> str:
    """Decode meta[7] to a Category slug (device-import path; spec §1.1).

    Bytes outside 0x00..0x0C -> uncategorized. NOTE: not used for pack seeding
    (packs are always uncategorized, spec §5.2); provided so the one documented
    table lives here in the regeneration tool too.
    """
    return CATEGORY_SLUGS[byte] if 0 <= byte < len(CATEGORY_SLUGS) else UNCATEGORIZED


# --------------------------------------------------------------------------
# Naming / ids


def bank_display_name(zip_path: Path) -> str:
    """A human bank name from the .mfprojz filename stem: strip a leading
    "Microfreak"/"MicroFreak" (+ separators), underscores -> spaces, collapse
    whitespace. Deterministic."""
    stem = zip_path.stem
    s = re.sub(r"^micro\s*freak[\s_]*", "", stem, flags=re.IGNORECASE)
    s = s.replace("_", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return s or stem


def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "bank"


def _hex_id(*parts: str) -> str:
    """Deterministic 32-char lowercase-hex id (uuid4-hex shape; spec §0)."""
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:32]


def entry_id(sha256: str, name: str, meta_hex: str) -> str:
    return _hex_id("entry", sha256, name, meta_hex)


def collection_id(display_name: str, source: str) -> str:
    return _hex_id("collection", display_name, source)


# --------------------------------------------------------------------------
# Conversion


class _EntryPool:
    """Accumulates unique library entries + writes deduped blob files
    (Library._ensure_blob: write iff absent)."""

    def __init__(self, blob_dir: Path):
        self.blob_dir = blob_dir
        self.entries: Dict[str, dict] = {}       # entry_id -> entry json
        self.blobs_written: set = set()          # sha256

    def ensure_blob(self, preset: Preset) -> str:
        sha = preset.sha256                       # microfreak.protocol.digest
        if sha not in self.blobs_written:
            path = self.blob_dir / f"{sha}.bin"
            if not path.exists():
                path.write_bytes(bytes(preset.blob))
            self.blobs_written.add(sha)
        return sha

    def add_entry(self, preset: Preset, sha: str, meta_hex: str) -> None:
        eid = entry_id(sha, preset.name, meta_hex)
        if eid not in self.entries:
            self.entries[eid] = {
                "id": eid,
                "name": preset.name,
                "sha256": sha,
                "meta_hex": meta_hex,
                "slot": None,                     # pool; collections own slots
                "added_at": SEED_TIMESTAMP,
                "tags": [],
                "category": UNCATEGORIZED,        # spec §5.2: packs arrive uncategorized
                "favorite": False,
            }


def convert(inputs: List[Path], out_dir: Path) -> dict:
    """Do the conversion; return a summary. Writes everything under out_dir
    except README.md (hand-maintained)."""
    lib_dir = out_dir / "library"
    blob_dir = lib_dir / "blobs"
    coll_dir = lib_dir / "collections"

    # Clean regenerable outputs; never touch README.md.
    for d in (blob_dir, coll_dir):
        if d.exists():
            shutil.rmtree(d)
    blob_dir.mkdir(parents=True, exist_ok=True)
    coll_dir.mkdir(parents=True, exist_ok=True)
    idx = lib_dir / "index.json"
    if idx.exists():
        idx.unlink()

    # Discover banks: every .mfprojz under every input, globally sorted by
    # (display name, source path) for stable ordering and slugs.
    found: List[Path] = []
    for root in inputs:
        found.extend(sorted(Path(root).rglob("*.mfprojz")))
    banks = sorted(set(found), key=lambda p: (bank_display_name(p).lower(), str(p)))

    pool = _EntryPool(blob_dir)
    collections: List[dict] = []
    slugs_seen: Dict[str, Path] = {}
    parsed_real = 0
    skipped_unplaceable = 0

    for zip_path in banks:
        name = bank_display_name(zip_path)
        slug = slugify(name)
        if slug in slugs_seen:
            raise ValueError(
                f"duplicate bank slug {slug!r}: {slugs_seen[slug]} vs {zip_path}")
        slugs_seen[slug] = zip_path
        cid = collection_id(name, zip_path.name)

        presets = read_mfprojz(zip_path)
        slots_json: Dict[str, dict] = {}
        for mp in presets:
            # spec §5.2 skip rule: blob is None OR slot is None -> no ref/entry.
            if mp.is_empty or mp.slot is None:
                if not mp.is_empty:
                    skipped_unplaceable += 1     # real preset, unplaceable filename
                continue
            parsed_real += 1
            key = str(mp.slot)
            if key in slots_json:
                # No collisions in the shipped banks; stay total + deterministic.
                continue
            preset = Preset(name=mp.name, blob=mp.blob, meta=mp.meta)
            meta_hex = bytes(mp.meta).hex()
            sha = pool.ensure_blob(preset)
            pool.add_entry(preset, sha, meta_hex)
            slots_json[key] = {                  # PresetRef (spec §3)
                "sha256": sha,
                "name": preset.name,
                "meta_hex": meta_hex,
            }

        collection = {
            "schema": COLLECTION_SCHEMA,
            "id": cid,
            "name": name,
            "created_at": SEED_TIMESTAMP,
            "provenance": {"kind": "imported_bank", "source": zip_path.name},
            "slots": slots_json,
        }
        _write_json(coll_dir / f"{cid}.json", collection)
        collections.append({
            "id": cid,
            "name": name,
            "slug": slug,
            "file": f"library/collections/{cid}.json",
            "source": zip_path.name,
            "preset_count": len(slots_json),
        })

    # Seed library index (spec §2.1) -- a real schema-1 index, loads today.
    entries_sorted = sorted(
        pool.entries.values(),
        key=lambda e: (e["sha256"], e["name"], e["meta_hex"]))
    _write_json(idx, {"schema": LIBRARY_SCHEMA, "entries": entries_sorted})

    manifest = {
        "bundle_format": BUNDLE_FORMAT,
        "kind": "seed_bundle",
        "generator": "tools/convert_banks.py",
        "spec": "ios/docs/collections-categories-spec.md v1.0",
        "library_root": "library",
        "library_index": "library/index.json",
        "blob_dir": "library/blobs",
        "collection_dir": "library/collections",
        "slot_capacity": SLOT_CAPACITY,
        "bank_count": len(collections),
        "placed_preset_count": sum(c["preset_count"] for c in collections),
        "parsed_real_preset_count": parsed_real + skipped_unplaceable,
        "skipped_unplaceable_count": skipped_unplaceable,
        "entry_count": len(entries_sorted),
        "blob_count": len(pool.blobs_written),
        "category_counts": {UNCATEGORIZED: len(entries_sorted)},
        "collections": sorted(collections, key=lambda c: c["id"]),
    }
    _write_json(out_dir / "manifest.json", manifest)

    return {
        "banks": len(collections),
        "real_presets_parsed": parsed_real + skipped_unplaceable,
        "presets_placed": manifest["placed_preset_count"],
        "skipped_unplaceable": skipped_unplaceable,
        "library_entries": manifest["entry_count"],
        "unique_blobs": manifest["blob_count"],
        "out_dir": str(out_dir),
    }


def _write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True)
    path.write_text(text + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# Verification -- proves the seed loads through the real core library and that
# every collection ref resolves to a valid Preset.


def verify(out_dir: Path) -> dict:
    from microfreak.library import Library        # production loader (spec §2)

    lib = Library.open(out_dir / "library")
    entries = {e.id: e for e in lib.entries()}
    for e in lib.entries():
        preset = lib.get(e.id)                     # re-hashes blob vs filename
        assert preset.sha256 == e.sha256, "index sha mismatch"

    manifest = json.loads((out_dir / "manifest.json").read_text())
    blob_dir = out_dir / "library" / "blobs"
    entry_shas = {e.sha256 for e in lib.entries()}
    slot_refs = 0
    for c in manifest["collections"]:
        coll = json.loads((out_dir / c["file"]).read_text())
        assert coll["schema"] == COLLECTION_SCHEMA
        assert coll["provenance"]["kind"] == "imported_bank"
        for key, ref in coll["slots"].items():
            slot = int(key)                        # keys are decimal-slot strings
            assert 0 <= slot < SLOT_CAPACITY, f"slot {slot} out of range"
            blob_path = blob_dir / f"{ref['sha256']}.bin"
            blob = blob_path.read_bytes()
            assert digest(blob) == ref["sha256"], "collection ref sha mismatch"
            # PresetRef.to_preset(blob) equivalent: rebuild + validate.
            Preset(name=ref["name"], blob=blob,
                   meta=bytes.fromhex(ref["meta_hex"]))
            assert ref["sha256"] in entry_shas, "ref blob has no library entry"
            slot_refs += 1
    return {"entries_loaded": len(entries), "collection_slot_refs": slot_refs}


# --------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, type=Path,
                    help="output SeedBanks directory")
    ap.add_argument("inputs", nargs="+", type=lambda s: Path(s).expanduser(),
                    help="folders to scan for .mfprojz banks")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the post-write core-loader verification")
    args = ap.parse_args(argv)

    out_dir = args.out.expanduser()
    summary = convert(args.inputs, out_dir)
    if not args.no_verify:
        summary["verify"] = verify(out_dir)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
