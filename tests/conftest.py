"""pytest fixtures for the few test modules that take parameters.

The suite's own convention (README) is plain scripts: every file has a `main()`
and is run as `python3 tests/test_x.py`. That stays the supported way to run
them, and nothing here is needed for it — conftest.py is imported by pytest and
by nothing else.

It exists because pytest DOES collect `tests/test_notes_vocab.py`: its test
functions are module-level and named `test_*`, so pytest picks them up, and the
eight that take `cases` or `work` were erroring at setup with "fixture not
found" while the run still reported green ("10 passed, 8 errors"). Those eight
are the extractor-parity and sidecar data-safety tests — precisely the coverage
that must not be able to look green without running. Supplying the two fixtures
makes a pytest run execute them for real instead of skipping past them.

Each work-dir test builds its own subdirectory under `work`, so a per-test
`tmp_path` gives the same isolation the script runner's single temp dir does.
"""
import json
from pathlib import Path

import pytest

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "note_extraction.json"


@pytest.fixture(scope="session")
def cases():
    """The shared extractor fixture — the same file the Swift core loads."""
    return json.loads(FIXTURE.read_text())


@pytest.fixture
def work(tmp_path: Path) -> Path:
    """A scratch directory for the sidecar/library tests."""
    return tmp_path
