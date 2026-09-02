"""Preset attributes: Category device-byte decode + slug round-trip,
additive index back-compat load (old indexes without category/favorite/tags),
category/tag/favorite round-trip through the library, import auto-fill from
meta[7], and the pure category_census / all_tags read helpers."""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.device import MicroFreak
from microfreak.library import Library, all_tags, category_census
from microfreak.model import Category
from microfreak.transports.simulated import SimulatedMicroFreak


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, dt):
        self.now += max(dt, 1e-4)


def main() -> None:
    work = Path(tempfile.mkdtemp(prefix="mfcap-test-attrs-"))
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work: Path) -> None:
    # --- device-byte decode: the one hardware-confirmable table --------------
    expected = ["uncategorized", "bass", "brass", "keys", "lead", "organ",
                "pad", "percussion", "sequence", "sfx", "strings", "template",
                "vocoder"]
    for byte, slug in enumerate(expected):
        assert Category.from_device_byte(byte).slug == slug, (byte, slug)
    for byte in (0x0D, 0x10, 0x7F, 200):
        assert Category.from_device_byte(byte) is Category.UNCATEGORIZED, byte
    assert Category.from_device_byte(0x03) is Category.KEYS   # slot-200 ground truth
    print("PASS  Category.from_device_byte maps 0x00..0x0C and clamps the rest")

    # --- slug round-trip + forward-compat + display ---------------------------
    for slug in expected:
        assert Category.from_slug(slug).slug == slug
    assert Category.from_slug("future_cat") is Category.UNCATEGORIZED
    assert Category.SFX.display_name == "SFX"
    assert Category.PAD.display_name == "Pad"
    print("PASS  slug round-trips; unknown slug -> uncategorized (forward compat)")

    # --- old index (no category/favorite/tags) loads with defaults -----------
    old_root = work / "oldlib"
    (old_root / "blobs").mkdir(parents=True)
    donor = SimulatedMicroFreak.factory_fresh()
    a = donor.peek(0)
    (old_root / "blobs" / (a.sha256 + ".bin")).write_bytes(bytes(a.blob))
    old_index = {"schema": 1, "entries": [{
        "id": "e0", "name": a.name, "sha256": a.sha256,
        "meta_hex": bytes(a.meta).hex(), "slot": 0,
        "added_at": "2026-01-01T00:00:00"}]}     # NO tags/category/favorite
    (old_root / "index.json").write_text(json.dumps(old_index))
    lib_old = Library.open(old_root)
    e = lib_old.entries()[0]
    assert e.category is Category.UNCATEGORIZED and e.favorite is False
    assert e.tags == ()
    print("PASS  old index without category/favorite/tags loads with defaults")

    # re-saving the old index writes the new keys with their defaults
    lib_old.set_favorite(e.id, False)            # touches -> _save()
    reread = json.loads((old_root / "index.json").read_text())
    assert reread["entries"][0]["category"] == "uncategorized"
    assert reread["entries"][0]["favorite"] is False
    assert reread["entries"][0]["tags"] == []
    print("PASS  a re-saved old index gains category/favorite/tags keys")

    # --- category/tag/favorite round-trip through add + editors --------------
    root = work / "lib"
    lib = Library.create(root)
    b, c = donor.peek(1), donor.peek(2)
    eb = lib.add(b, slot=1, tags=("ambient", "pad"),
                 category=Category.PAD, favorite=True)
    assert eb.category is Category.PAD and eb.favorite is True
    assert eb.tags == ("ambient", "pad")

    ec = lib.add(c)
    ec = lib.set_category(ec.id, Category.BASS)
    ec = lib.set_favorite(ec.id, True)
    ec = lib.set_tags(ec.id, ["deep", "sub"])
    assert ec.category is Category.BASS and ec.favorite is True
    assert ec.tags == ("deep", "sub")

    lib2 = Library.open(root)
    got = {e.id: e for e in lib2.entries()}
    assert got[eb.id].category is Category.PAD and got[eb.id].favorite is True
    assert got[ec.id].category is Category.BASS
    assert got[ec.id].tags == ("deep", "sub")
    print("PASS  category/favorite/tags round-trip through add, editors, reopen")

    # --- census + tag universe (pure helpers the UI reads) -------------------
    census = category_census(lib2.entries())
    assert set(census) == set(Category)                 # every category key present
    assert census[Category.PAD] == 1 and census[Category.BASS] == 1
    assert census[Category.UNCATEGORIZED] == 0
    assert sum(census.values()) == len(lib2.entries())
    assert all_tags(lib2.entries()) == ["ambient", "deep", "pad", "sub"]
    print("PASS  category_census counts every category; all_tags is sorted-unique")

    # --- import_snapshot auto-fills category from meta[7] --------------------
    sim = SimulatedMicroFreak.factory_fresh(slots=16, init_copies=0)
    fc = FakeClock()
    dev = MicroFreak(sim, slots=16, clock=fc, sleep=fc.sleep)
    snap = dev.snapshot(read_blobs=True, keep_blobs=True)
    lib3 = Library.create(work / "lib3")
    added = lib3.import_snapshot(snap, skip_expendable=False)
    by_slot = {e.slot: e for e in added}
    # factory_fresh sets a named slot's category byte to slot % 0x0C
    assert by_slot[3].category is Category.from_device_byte(3)   # KEYS
    assert by_slot[3].category is Category.KEYS
    assert by_slot[0].category is Category.UNCATEGORIZED         # byte 0
    assert by_slot[5].category is Category.ORGAN                 # byte 5
    assert all(e.favorite is False and e.tags == () for e in added)
    print("PASS  import_snapshot auto-fills category from meta[7]; fav/tags stay default")


if __name__ == "__main__":
    main()
