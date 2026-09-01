"""pick_scratch_slot judges emptiness by content, not name.

A stock MicroFreak names every unused slot "Init", so blank-name detection
finds nothing and the run used to claim the device was full.
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mfcap import verify as vf


def make_index(entries) -> Path:
    presets = {str(i): {"slot": i, "name": name, "bytes": 4672, "sha256": sha}
               for i, (name, sha) in enumerate(entries)}
    f = Path(tempfile.mkdtemp()) / "index.json"
    f.write_text(json.dumps({"slots": len(entries), "presets": presets}))
    return f


def main() -> None:
    # 6 slots: two real presets, one user preset duplicated twice, three factory Inits
    idx = make_index([
        ("Juicer", "aaa"), ("Trapped", "bbb"),
        ("My Pad", "ccc"), ("My Pad", "ccc"),          # duplicated ONLY twice - hands off
        ("Init", "fff"), ("Init", "fff"),
    ])
    assert vf.pick_scratch_slot(idx, prefer_from=0) is None, \
        "two Init copies must not qualify (threshold is three)"
    print("PASS  a preset duplicated twice is never chosen")

    idx = make_index([
        ("Juicer", "aaa"),
        ("Init", "fff"), ("Init", "fff"), ("Init", "fff"), ("Init", "fff"),
        ("My Pad", "ccc"),
    ])
    a = vf.pick_scratch_slot(idx, prefer_from=0)
    b = vf.pick_scratch_slot(idx, prefer_from=0, exclude=(a,))
    assert (a, b) == (4, 3), f"expected highest Inits (4, 3), got {(a, b)}"
    print("PASS  mass-duplicated Init slots picked highest-first, exclusion works")

    idx = make_index([("Juicer", "aaa"), ("", "bbb"), ("Init", "fff")])
    assert vf.pick_scratch_slot(idx, prefer_from=0) == 1
    print("PASS  a blank-named slot still qualifies")


if __name__ == "__main__":
    main()
