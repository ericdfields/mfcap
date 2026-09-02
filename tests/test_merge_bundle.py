"""Library.merge_bundle: folds a seed library into an existing one, idempotently."""
import sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.library import Library
from microfreak.model import Preset
from microfreak.collections import BankItem


def _preset(tag: int, name: str) -> Preset:
    return Preset(name=name, blob=bytes([tag % 256]) * 4672, meta=b"\x00" * 9)


def run() -> None:
    root = Path(tempfile.mkdtemp())
    # a "seed" library with two bank collections
    seed = Library.create(root / "seed")
    seed.collection_from_bank([BankItem(slot=0, name="A", meta=b"\x00"*9, blob=_preset(1,"A").blob),
                               BankItem(slot=1, name="B", meta=b"\x00"*9, blob=_preset(2,"B").blob)],
                              name="Bank One", source="one")
    seed.collection_from_bank([BankItem(slot=5, name="C", meta=b"\x00"*9, blob=_preset(3,"C").blob)],
                              name="Bank Two", source="two")

    # an existing user library with its own preset
    user = Library.create(root / "user")
    user.add(_preset(9, "MyOwn"), slot=100)
    before_entries = len(user.entries())

    n1 = user.merge_bundle(seed)
    assert n1 == 2, f"expected 2 collections merged, got {n1}"
    assert len(user.collections()) == 2
    assert len(user.entries()) == before_entries + 3, "3 seed presets should be added"
    assert any(e.name == "MyOwn" for e in user.entries()), "user's own preset must survive"
    print("PASS  merge adds all seed collections + presets, keeps user data")

    # idempotent: a second merge changes nothing
    n2 = user.merge_bundle(seed)
    assert n2 == 0, f"re-merge should add 0, got {n2}"
    assert len(user.collections()) == 2
    assert len(user.entries()) == before_entries + 3
    print("PASS  re-merge is a no-op (idempotent by collection id)")

    # blobs are content-addressed: reopening keeps everything resolvable
    reopened = Library.open(root / "user" )
    for c in reopened.collections():
        for ref in c.slots.values():
            reopened.preset_for_ref(ref)  # raises on missing/rot
    print("PASS  every merged collection ref resolves after reopen")


def run_dedupe() -> None:
    import tempfile as _tf
    from microfreak.library import Library as _L
    from microfreak.model import Preset as _P, Category as _C
    root = Path(_tf.mkdtemp())
    lib = _L.create(root / "d")
    # same content+name added three times (as merge/import would) collapses to 1
    for _ in range(3):
        lib.add(_P(name="Dup", blob=b"\x07"*4672, meta=b"\x00"*9), slot=None, dedupe=True)
    assert len(lib.entries()) == 1, [e.name for e in lib.entries()]
    # a genuinely different name with same blob stays separate
    lib.add(_P(name="Other", blob=b"\x07"*4672, meta=b"\x00"*9), dedupe=True)
    assert len(lib.entries()) == 2
    print("PASS  dedupe add reuses (sha,name); distinct name kept")

    # repair pass on a library that already has exact dups
    lib2 = _L.create(root / "r")
    a = lib2.add(_P(name="X", blob=b"\x01"*4672, meta=b"\x00"*9), slot=5)
    lib2.set_favorite(a.id, True)
    lib2.add(_P(name="X", blob=b"\x01"*4672, meta=b"\x00"*9), tags=["pad"])  # dup, no dedupe
    assert len(lib2.entries()) == 2
    removed = lib2.dedupe()
    assert removed == 1 and len(lib2.entries()) == 1
    e = lib2.entries()[0]
    assert e.favorite and "pad" in e.tags and e.slot == 5, e  # attributes merged
    print("PASS  dedupe() repair collapses exact dups, merges attributes")


if __name__ == "__main__":
    run()
    run_dedupe()
