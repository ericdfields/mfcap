"""Locks the App-test golden fixture (ios/App/Tests/Fixtures/bank_import.json)
to the VERIFIED tools/mbp_import.py parser.

The Swift .mfprojz/.mbp reader (App/Sources/Support/MFProjzImport.swift) is
checked against this fixture's 'expected' values. This test re-runs the raw
fixture bytes through the reference Python parser and asserts they still match
what the fixture records — so the fixture can never silently drift from the
verified parser (regenerate with: python3 tools/gen_vectors.py)."""
import base64
import hashlib
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))

import mbp_import

FIXTURE = REPO / "ios/App/Tests/Fixtures/bank_import.json"


def _expected(pr) -> dict:
    return {
        "slot": pr.slot,
        "name": pr.name,
        "meta_hex": pr.meta.hex(),
        "blob_sha256": (None if pr.blob is None
                        else hashlib.sha256(pr.blob).hexdigest()),
        "is_empty": pr.is_empty,
    }


def run() -> None:
    assert FIXTURE.exists(), (
        f"missing {FIXTURE} — run python3 tools/gen_vectors.py")
    doc = json.loads(FIXTURE.read_text())

    # ---- standalone .mbp ----------------------------------------------------
    m = doc["mbp"]
    mbp_bytes = base64.b64decode(m["bytes_b64"])
    pr = mbp_import.parse_mbp_text(mbp_bytes.decode("latin-1"),
                                   order=1, source=m["filename"])
    assert _expected(pr) == m["expected"], (_expected(pr), m["expected"])
    assert not pr.is_empty and len(pr.blob) == mbp_import.BLOB_SIZE
    print(f"PASS  .mbp fixture matches the verified parser: slot={pr.slot} "
          f"{pr.name!r}")

    # ---- .mfprojz -----------------------------------------------------------
    z = doc["mfprojz"]
    projz_bytes = base64.b64decode(z["bytes_b64"])
    with tempfile.NamedTemporaryFile(suffix=".mfprojz", delete=False) as f:
        f.write(projz_bytes)
        path = Path(f.name)
    try:
        parsed = mbp_import.read_mfprojz(path)
    finally:
        path.unlink()

    got = [_expected(pr) for pr in parsed]
    assert got == z["expected"], (got, z["expected"])
    # the non-.mbp archive member contributed nothing; sorted-name order holds
    assert [e["name"] for e in got] == [
        "Twin Peaks", "Voltage Forms", "Tokyo88 V3", "Init"]
    assert [e["slot"] for e in got] == [3, 6, 258, 39]   # global filename-prefix slots
    assert got[-1]["is_empty"] and got[-1]["blob_sha256"] is None
    # every non-empty blob is exactly 4672 bytes and hash-stable
    for pr in parsed:
        if not pr.is_empty:
            assert len(pr.blob) == mbp_import.BLOB_SIZE
    print(f"PASS  .mfprojz fixture matches the verified parser: "
          f"{len(parsed)} members, empty slot skipped for refs")


if __name__ == "__main__":
    run()
