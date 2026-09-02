"""Audition: play through a queue of presets on the real synth, one tap each.

The MicroFreak plays whatever preset is selected on its panel, so to hear a
library preset it has to be ON the device. This session borrows one
expendable slot (see analysis.pick_scratch_slot) as the audition slot:

    start()   read + keep the slot's original preset
    next()    verified-write the next queued preset there, then Bank Select +
              Program Change so the synth loads it (~0.5 s total)
    verdict() file the judgement on the library entry (Keep / Try later / ...)
    stop()    restore the slot's original, verified — the device is left as
              it was found, always, even after an exception mid-queue

Nothing is auditioned "in place": the user's own slots are never touched.
The device confirms neither Program Change nor panel state over MIDI, so a
selection that "doesn't take" (the device's Program Change Receive setting is
off) is a UI concern — the flow itself cannot detect it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Sequence

from .device import MicroFreak
from .library import Library, LibraryEntry
from .model import Preset, Verdict


@dataclass
class AuditionSession:
    device: MicroFreak
    library: Library
    queue: List[LibraryEntry]
    slot: int                       # the borrowed audition slot (0-based)
    channel: int = 0
    original: Optional[Preset] = None
    index: int = -1                 # position of the preset currently on the device
    started: bool = False
    restored: bool = False
    history: List[tuple] = field(default_factory=list)   # (entry_id, Verdict)

    # ------------------------------------------------------------ lifecycle

    def start(self) -> Preset:
        """Save what is in the audition slot now. Idempotent."""
        if not self.started:
            self.original = self.device.read(self.slot)
            self.started = True
        return self.original  # type: ignore[return-value]

    @property
    def current(self) -> Optional[LibraryEntry]:
        return self.queue[self.index] if 0 <= self.index < len(self.queue) else None

    @property
    def remaining(self) -> int:
        return max(0, len(self.queue) - (self.index + 1))

    def next(self) -> Optional[LibraryEntry]:
        """Put the next queued preset on the synth. None when the queue is
        exhausted (the device still holds the last auditioned preset until
        stop())."""
        if not self.started:
            self.start()
        if self.index + 1 >= len(self.queue):
            return None
        self.index += 1
        entry = self.queue[self.index]
        preset = self.library.get(entry.id)
        self.device.write(self.slot, preset)         # verified by default
        self.device.select(self.slot, self.channel)
        return entry

    def verdict(self, verdict: Verdict, entry: Optional[LibraryEntry] = None) -> LibraryEntry:
        """File a verdict for the current (or given) preset."""
        target = entry or self.current
        if target is None:
            raise ValueError("nothing is being auditioned")
        updated = self.library.set_verdict(target.id, verdict)
        self.history.append((target.id, verdict))
        return updated

    def stop(self) -> Optional[Preset]:
        """Restore the audition slot's original preset (verified). Safe to
        call more than once, and from a finally-block."""
        if self.started and not self.restored and self.original is not None:
            self.device.write(self.slot, self.original)
            self.restored = True
        return self.original

    # ------------------------------------------------------------ helpers

    @staticmethod
    def unrated(entries: Sequence[LibraryEntry]) -> List[LibraryEntry]:
        """The natural audition queue: everything not yet judged."""
        return [e for e in entries if e.verdict == Verdict.UNRATED]
