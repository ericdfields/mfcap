"""mfcap - MicroFreak capture harness.

Phase 0 toolkit: back up the device, capture MIDI Control Center writing
presets, decode the write protocol, and prove it with a write/read-back gate.

Design rule: every step tries to run itself first. A human is asked only when
autonomy has actually failed, and is then told exactly one thing to do.
"""
__version__ = "0.1.0"
