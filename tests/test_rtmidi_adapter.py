"""RtMidiTransport's pure, hardware-free logic: SysEx reassembly in
_on_message (split frames, interleaved realtime/channel traffic, torn
partials), close() cancelling the callback before closing ports, and
_open_indices not leaking a half-opened port pair. No rtmidi involved —
stub port objects stand in for the backend."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from microfreak.errors import TransportError
from microfreak.transports.rtmidi import RtMidiTransport


class StubPort:
    def __init__(self, name="stub", fail_open=False):
        self.name = name
        self.fail_open = fail_open
        self.calls = []

    def ignore_types(self, **kw):
        self.calls.append(("ignore_types", kw))

    def set_callback(self, fn):
        self.calls.append(("set_callback",))
        self.callback = fn

    def cancel_callback(self):
        self.calls.append(("cancel_callback",))

    def open_port(self, i):
        if self.fail_open:
            raise RuntimeError("backend says no")
        self.calls.append(("open_port", i))

    def close_port(self):
        self.calls.append(("close_port",))

    def send_message(self, msg):
        self.calls.append(("send_message", bytes(msg)))


def make_transport():
    mi, mo = StubPort("in"), StubPort("out")
    t = RtMidiTransport(mi, mo, "in", "out")
    return t, mi, mo


def deliver(t, *messages):
    for m in messages:
        t._on_message((list(m), 0.0), None)


def drain(t):
    out = []
    while True:
        m = t.receive(0.0)
        if m is None:
            return out
        out.append(m)


SYX = bytes([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01, 0x01, 0x00, 0x15, 0xF7])


def main() -> None:
    # --- a complete SysEx in one callback ----------------------------------
    t, mi, mo = make_transport()
    deliver(t, SYX)
    assert drain(t) == [SYX]
    print("PASS  complete SysEx queued as one message")

    # --- one SysEx split across three callbacks ----------------------------
    t, _, _ = make_transport()
    deliver(t, SYX[:4], SYX[4:7], SYX[7:])
    assert drain(t) == [SYX]
    print("PASS  SysEx split across 3 callbacks reassembles byte-identically")

    # --- realtime bytes interleaved mid-SysEx are dropped, frame intact ----
    t, _, _ = make_transport()
    deliver(t, SYX[:5], bytes([0xF8]), SYX[5:])       # MIDI clock mid-frame
    assert drain(t) == [SYX], "realtime byte must not corrupt the partial"
    print("PASS  interleaved realtime (0xF8) ignored; buffered frame unharmed")

    # --- a complete channel message mid-SysEx passes through separately ----
    t, _, _ = make_transport()
    note_on = bytes([0x90, 0x40, 0x40])               # a key pressed mid-transfer
    deliver(t, SYX[:5], note_on, SYX[5:])
    got = drain(t)
    assert note_on in got, "the channel message must survive on its own"
    assert SYX in got, "the SysEx must reassemble around it"
    assert len(got) == 2
    print("PASS  interleaved note-on delivered separately; SysEx not spliced")

    # --- a new F0 while a partial is pending: the torn partial is dropped --
    t, _, _ = make_transport()
    deliver(t, SYX[:6])                               # transfer torn here
    deliver(t, SYX)                                   # fresh complete frame
    assert drain(t) == [SYX], "torn partial must be dropped, not merged"
    print("PASS  fresh SysEx after a torn partial: old bytes dropped, new intact")

    # --- torn partial then a fresh SPLIT SysEx still reassembles -----------
    t, _, _ = make_transport()
    deliver(t, SYX[:6], SYX[:4], SYX[4:])
    assert drain(t) == [SYX]
    print("PASS  fresh split SysEx after a torn partial reassembles cleanly")

    # --- close() cancels the callback before closing ports -----------------
    t, mi, mo = make_transport()
    t.close()
    assert ("cancel_callback",) in mi.calls
    order = [c[0] for c in mi.calls]
    assert order.index("cancel_callback") < order.index("close_port"), \
        "callback must be cancelled before the port closes"
    assert ("close_port",) in mo.calls
    print("PASS  close() cancels the rtmidi callback, then closes both ports")

    # --- _open_indices: input port not leaked when output open fails -------
    mi, mo = StubPort("in"), StubPort("out", fail_open=True)
    try:
        RtMidiTransport._open_indices(mi, mo, 0, 0, "in", "out")
        raise AssertionError("failed output open must raise")
    except TransportError:
        pass
    assert ("open_port", 0) in mi.calls
    assert ("close_port",) in mi.calls, \
        "the opened input port must be closed on the failure path"
    print("PASS  output-open failure closes the already-opened input port")


if __name__ == "__main__":
    main()
