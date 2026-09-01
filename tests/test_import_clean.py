"""The core imports with no rtmidi installed, and never drags it in.

Runs a subprocess whose import machinery blocks rtmidi outright (so the test
is valid even on machines where python-rtmidi IS installed), imports the
whole public surface plus both transport adapters, and asserts rtmidi never
entered sys.modules.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CHILD = r"""
import sys

class _BlockRtmidi:
    def find_module(self, name, path=None):
        if name == "rtmidi" or name.startswith("rtmidi."):
            return self
    def load_module(self, name):
        raise ImportError("rtmidi blocked for this test")

sys.meta_path.insert(0, _BlockRtmidi())

import microfreak
import microfreak.protocol
import microfreak.model
import microfreak.session
import microfreak.device
import microfreak.backup
import microfreak.library
import microfreak.sync
import microfreak.analysis
import microfreak.transport
import microfreak.transports
import microfreak.transports.simulated
import microfreak.transports.rtmidi as rt

assert not any(m == "rtmidi" or m.startswith("rtmidi.")
               for m in sys.modules), "rtmidi leaked into sys.modules"
assert rt.available() is False, "available() must be False with rtmidi blocked"

try:
    rt.list_ports()
except Exception as e:
    assert type(e).__name__ == "TransportUnavailableError", e
else:
    raise AssertionError("list_ports() should raise TransportUnavailableError")

try:
    microfreak.open_device()
except Exception as e:
    assert type(e).__name__ == "TransportUnavailableError", e
else:
    raise AssertionError("open_device() should raise TransportUnavailableError")

print("CHILD_OK version=%s" % microfreak.__version__)
"""


def main() -> None:
    proc = subprocess.run([sys.executable, "-c", CHILD], cwd=str(ROOT),
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise AssertionError("subprocess failed")
    assert "CHILD_OK" in proc.stdout, proc.stdout
    print("PASS  import microfreak succeeds with rtmidi blocked")
    print("PASS  rtmidi never enters sys.modules")
    print("PASS  transports.rtmidi degrades to TransportUnavailableError")


if __name__ == "__main__":
    main()
