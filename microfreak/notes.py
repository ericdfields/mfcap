"""PresetNote: a spoken or typed note about ONE library entry, stored in a
per-entry sidecar file. Pinned by docs/voice-notes.md §1; the Swift core
(ios/FreakCore/Sources/FreakCore/Notes.swift) carries the identical format.

    <root>/
      index.json
      blobs/<sha256>.bin
      collections/<collection id>.json
      notes/<entry id>.json          <-- this file's format

WHY A SIDECAR AND NOT A FIELD ON LibraryEntry (§0): `library.py::_entry_to_json`
builds a FIXED dict and every write path rewrites EVERY entry through it. A
`note` field on LibraryEntry would be silently destroyed — no error, no diff,
just gone — the first time any Python tooling touched a library the iPad had
written. A separate file per entry, mirroring the existing
`collections/<id>.json` precedent, is what whole-index rewrites cannot reach.
Keyed on `entry.id` (uuid4 hex): it is minted at `add()`, survives rename
(unlike `name`/`slot`) and is unique (unlike `sha256`, which two entries may
share).

THE TRUST RULES (§3), which this module exists to keep:

  1. `text` is VERBATIM and IMMUTABLE. What the transcriber finalized is what is
     stored, forever — never cleaned, re-cased, punctuation-fixed or
     regenerated. A user correction is the SIBLING `text_corrected`; the
     original stays, which is the only way a user can tell a mishearing from a
     mistake they made.
  2. Proposals are ADVISORY. The extractor writes into `proposals` and nowhere
     else; a transcript never changes a preset attribute on its own.
  3. The sidecar is PROVENANCE, never a second source of truth. An accepted
     proposal is written to its canonical home through the existing setters
     (`set_verdict` / `set_category` / `set_tags`), so every filter, census,
     Swift consumer and .mfpreset export sees it unchanged. NO READER ANYWHERE
     MAY CONSULT notes/ TO DETERMINE AN ENTRY'S VERDICT, CATEGORY OR TAGS.
     Delete notes/ and the library is exactly as correct as before; only the
     provenance is gone.

AND THE NO-AUDIO RULE (§1.5): NO RAW AUDIO IS EVER WRITTEN TO DISK. Not a temp
file, not a ring buffer, not a debug build. `audio_start`/`audio_end` are
session-relative SECONDS on the capture clock — a timeline offset, never a
pointer. There is no file they name and no file they could name. No field here
may ever hold audio or a path to audio.

Extraction lives in `microfreak.vocab`, which imports this module for its value
types; the one dependency back the other way (`PresetNote.new` calling
`vocab.extract`) is a deliberately function-local import.
"""
from __future__ import annotations

import dataclasses
import enum
import time
import uuid
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

from .errors import LibraryCorruptError

NOTE_SCHEMA = 1


# ------------------------------------------------------------------- source

class NoteSource(enum.Enum):
    """How a note was captured. Exactly these two values in schema 1."""
    VOICE = "voice"
    TYPED = "typed"

    @classmethod
    def from_str(cls, s: str) -> "NoteSource":
        """Parse a file value. Unknown -> VOICE (forward compatibility, the same
        idiom as `ProvenanceKind.from_str`); a document carrying an unknown
        source is a newer schema, which the §1.2 gate already makes read-only."""
        try:
            return cls(s)
        except ValueError:
            return cls.VOICE

    @property
    def slug(self) -> str:
        return self.value


# ---------------------------------------------------------------- proposals

@dataclass(frozen=True)
class NoteProposal:
    """One advisory extraction hit (§1.6). `value` is drawn from a CLOSED set —
    `Verdict.slug`, `Category.slug`, or one of the 18 exact Arturia
    characteristic display strings — because the extractor is table-driven and
    can never invent a value."""
    value: str
    # `[span_start, span_end)` Unicode code point offsets into the VERBATIM
    # `text` — not the normalized form, and not `text_corrected`.
    span_start: int
    span_end: int
    # A match-strength tier from the fixed §2.8 table, in [0, 1]. Not a
    # probability, and never from a model.
    confidence: float
    # False at write time. Becomes True at the moment the user taps to confirm
    # AND the canonical setter succeeds. NEVER flipped back: a later user change
    # to the entry does not rewrite history here. It records what the user
    # confirmed, not what the entry currently says.
    accepted: bool = False

    def accepting(self, accepted: bool = True) -> "NoteProposal":
        """Copy with `accepted` set — the only field a caller may change."""
        return dataclasses.replace(self, accepted=bool(accepted))

    def span_text(self, text: str) -> Optional[str]:
        """The proposal's slice of a verbatim string, or None when the span does
        not address it (a corrected text, a foreign file)."""
        if not 0 <= self.span_start < self.span_end <= len(text):
            return None
        return text[self.span_start:self.span_end]


@dataclass(frozen=True)
class NoteProposals:
    """The whole advisory layer for one note (§1.6). Always present, never null:
    `verdict` and `category` are single-valued (a proposal or None); `tags` is
    always a tuple, unique by value and ordered by FIRST APPEARANCE in `text`."""
    verdict: Optional[NoteProposal] = None
    category: Optional[NoteProposal] = None
    tags: Tuple[NoteProposal, ...] = ()

    @property
    def is_empty(self) -> bool:
        return self.verdict is None and self.category is None and not self.tags

    @property
    def verdict_value(self):
        """The proposed verdict as the core type. `unrated` is never proposed,
        so a value that does not parse yields None rather than a false
        UNRATED."""
        from .model import Verdict
        if self.verdict is None:
            return None
        parsed = Verdict.from_slug(self.verdict.value)
        return None if parsed is Verdict.UNRATED else parsed

    @property
    def category_value(self):
        """The proposed category as the core type. `uncategorized` is never
        proposed, so an unparseable value yields None."""
        from .model import Category
        if self.category is None:
            return None
        parsed = Category.from_slug(self.category.value)
        return None if parsed is Category.UNCATEGORIZED else parsed

    @property
    def tag_values(self) -> Tuple[str, ...]:
        """The proposed characteristics, first-appearance order."""
        return tuple(p.value for p in self.tags)


NoteProposals.EMPTY = NoteProposals()


# --------------------------------------------------------------------- note

@dataclass(frozen=True)
class PresetNote:
    id: str                    # uuid4 hex — lowercase, 32 chars, NO hyphens
    recorded_at: str           # "%Y-%m-%dT%H:%M:%S", LOCAL time, no zone
                               # suffix, no fractional seconds — byte-identical
                               # in shape to added_at / created_at
    source: NoteSource
    text: str                  # VERBATIM and IMMUTABLE (§3 rule 1)
    text_corrected: Optional[str]   # a user correction; explicitly None when
                                    # the user has not corrected it. `text` is
                                    # never overwritten.
    locale: str                # BCP-47 id of the transcriber locale, e.g.
                               # "en-US". For a typed note, the app's locale.
    session_id: str            # uuid4 hex; one value per audition session,
                               # shared by every note captured in it
    audio_start: float         # seconds, SESSION-RELATIVE. A timeline offset,
                               # never a pointer to audio.
    audio_end: Optional[float]  # seconds, session-relative. None only for a
                                # typed note: a voice note is only persisted
                                # from a finalized result, which always carries
                                # a complete range.
    device_identity: str       # "hardware", "practice:<profile>", or "none"
    proposals: NoteProposals = field(default_factory=NoteProposals)

    @classmethod
    def new(cls, *, source: NoteSource, text: str, locale: str,
            session_id: str, audio_start: float, audio_end: Optional[float],
            device_identity: str,
            proposals: Optional[NoteProposals] = None) -> "PresetNote":
        """Mint a fresh note: uuid4 hex id, local ISO `recorded_at`, and —
        unless the caller supplies its own — proposals extracted from `text` by
        `microfreak.vocab.extract` under `locale`."""
        from .vocab import extract      # local: vocab imports this module
        return cls(id=uuid.uuid4().hex,
                   recorded_at=time.strftime("%Y-%m-%dT%H:%M:%S"),
                   source=source, text=text, text_corrected=None,
                   locale=locale, session_id=session_id,
                   audio_start=float(audio_start),
                   audio_end=None if audio_end is None else float(audio_end),
                   device_identity=device_identity,
                   proposals=(proposals if proposals is not None
                              else extract(text, locale=locale)))

    def correcting(self, corrected: Optional[str]) -> "PresetNote":
        """Attach (or clear) a user correction. `text` is untouched — that is
        the point of the field."""
        return dataclasses.replace(self, text_corrected=corrected)

    def recording_acceptance(self, proposals: NoteProposals) -> "PresetNote":
        """Record that the user confirmed proposals — after the canonical setter
        succeeded. Nothing else about the note changes."""
        return dataclasses.replace(self, proposals=proposals)


def canonical_order(notes: Sequence[PresetNote]) -> List[PresetNote]:
    """The §1.3 canonical order both cores write: ascending by `recorded_at`,
    ties by `audio_start`, ties by `id` lexicographically. Readers may rely on
    it."""
    return sorted(notes, key=lambda n: (n.recorded_at, n.audio_start, n.id))


# ----------------------------------------------------------------- document

@dataclass(frozen=True)
class NoteDocument:
    """One `notes/<entry_id>.json` file (§1.3)."""
    schema: int                     # the version READ FROM DISK — not
                                    # necessarily this core's
    entry_id: str
    notes: Tuple[PresetNote, ...]

    @property
    def is_read_only(self) -> bool:
        """§1.2, the forward-compatibility gate: a core reading a sidecar whose
        schema is GREATER than the version it knows must treat that file as
        read-only. It may display the notes it understands; it MUST NOT rewrite
        the file. That gate is the whole protection against the §0 failure mode
        happening again inside the sidecar, and it is what makes it safe not to
        round-trip unknown keys."""
        return self.schema > NOTE_SCHEMA


# -------------------------------------------------------------------- codec

def _round3(x: float) -> float:
    """At most 3 decimal places (§1.5).

    The Swift core's `roundTo(_:places:)` computes the identical value, so the
    two cores never write different numbers for the same note. (What they can
    still differ on is the TOKEN for an integral value — Python's json writes
    `0.0`, Swift's JSONSerialization normalizes it to `0` — exactly as they
    already differ on key order in every other file the two cores share. Both
    parse back to the same number; no reader can tell.)
    """
    return round(float(x), 3)


def _seconds(value, fallback: Optional[float]) -> Optional[float]:
    """A seconds field, coerced the way the index reader coerces its own
    optional fields: anything that is not a number falls back rather than
    raising.

    `float(d["audio_start"])` on a hand-edited or foreign sidecar raised a bare
    ValueError/TypeError out of this module — neither the documented fallback
    behaviour of `note_from_json` nor the contracted LibraryCorruptError, and
    not what the Swift core does with the same bytes (it falls back). Both
    cores now fall back to the same value.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return fallback
    try:
        f = float(value)
    except (TypeError, ValueError, OverflowError):
        return fallback
    return f if f == f and f not in (float("inf"), float("-inf")) else fallback


def _proposal_to_json(p: NoteProposal) -> dict:
    return {"value": p.value, "span": [p.span_start, p.span_end],
            "confidence": p.confidence, "accepted": bool(p.accepted)}


def _proposal_from_json(d: Optional[dict]) -> Optional[NoteProposal]:
    if not isinstance(d, dict) or not isinstance(d.get("value"), str):
        return None
    span = d.get("span") or []
    ok = (isinstance(span, list) and len(span) == 2
          and all(isinstance(v, int) and not isinstance(v, bool) for v in span))
    return NoteProposal(value=d["value"],
                        span_start=span[0] if ok else 0,
                        span_end=span[1] if ok else 0,
                        confidence=_seconds(d.get("confidence"), 0.0) or 0.0,
                        accepted=bool(d.get("accepted", False)))


def _proposals_to_json(p: NoteProposals) -> dict:
    return {
        "verdict": _proposal_to_json(p.verdict) if p.verdict else None,
        "category": _proposal_to_json(p.category) if p.category else None,
        "tags": [_proposal_to_json(t) for t in p.tags],
    }


def _proposals_from_json(d: Optional[dict]) -> NoteProposals:
    d = d if isinstance(d, dict) else {}
    tags = d.get("tags") or []
    parsed = [_proposal_from_json(t) for t in tags] if isinstance(tags, list) else []
    return NoteProposals(verdict=_proposal_from_json(d.get("verdict")),
                         category=_proposal_from_json(d.get("category")),
                         tags=tuple(t for t in parsed if t is not None))


def note_to_json(n: PresetNote) -> dict:
    """One note object (§1.4). Explicit `null` rather than an omitted key, the
    way index.json writes `"slot": null`."""
    return {
        "id": n.id,
        "recorded_at": n.recorded_at,
        "source": n.source.value,
        "text": n.text,
        "text_corrected": n.text_corrected,
        "locale": n.locale,
        "session_id": n.session_id,
        "audio_start": _round3(n.audio_start),
        "audio_end": None if n.audio_end is None else _round3(n.audio_end),
        "device_identity": n.device_identity,
        "proposals": _proposals_to_json(n.proposals),
    }


def note_from_json(d: dict, *, path: str = "<notes>") -> PresetNote:
    """Parse one note object. `id` and `text` are required (a note without them
    names nothing and says nothing); every other key falls back the way the
    index reader does, so an older writer's file still loads — including the
    numeric ones, which never raise out of this module and never differ from
    what the Swift core reads out of the same bytes."""
    if not isinstance(d, dict) or not isinstance(d.get("id"), str) \
            or not isinstance(d.get("text"), str):
        raise LibraryCorruptError(path, f"bad note: {d!r}")
    corrected = d.get("text_corrected")
    audio_end = d.get("audio_end")
    return PresetNote(
        id=d["id"],
        recorded_at=d.get("recorded_at") or "",
        source=NoteSource.from_str(d.get("source") or "voice"),
        text=d["text"],
        text_corrected=corrected if isinstance(corrected, str) else None,
        locale=d.get("locale") or "",
        session_id=d.get("session_id") or "",
        audio_start=_seconds(d.get("audio_start"), 0.0) or 0.0,
        audio_end=None if audio_end is None else _seconds(audio_end, None),
        device_identity=d.get("device_identity") or "none",
        proposals=_proposals_from_json(d.get("proposals")))


def note_document_to_json(doc: NoteDocument) -> dict:
    return {"schema": doc.schema, "entry_id": doc.entry_id,
            "notes": [note_to_json(n) for n in doc.notes]}


def note_document_from_json(d: dict, *, path: str = "<notes>") -> NoteDocument:
    """Parse a sidecar document. Unparseable -> LibraryCorruptError, the same
    error the collection reader raises (§1.1).

    A schema GREATER than this core's is NOT an error (§1.2): it parses to a
    document whose `is_read_only` is True, which the write path refuses to
    overwrite.
    """
    schema = d.get("schema") if isinstance(d, dict) else None
    if not isinstance(schema, int) or isinstance(schema, bool) or schema < 1:
        raise LibraryCorruptError(path, f"unsupported schema: {schema!r}")
    if not isinstance(d.get("entry_id"), str):
        raise LibraryCorruptError(path, "bad notes: missing entry_id")
    raw = d.get("notes")
    if not isinstance(raw, list):
        raise LibraryCorruptError(path, "bad notes: missing notes array")
    return NoteDocument(schema=schema, entry_id=d["entry_id"],
                        notes=tuple(note_from_json(n, path=path) for n in raw))
