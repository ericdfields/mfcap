"""microfreak — framework-agnostic core for a MicroFreak preset librarian.

Ground truth for every wire behavior: docs/write-protocol.md; the normative
API contract is docs/core-api.md. Standard library only; python-rtmidi is
touched only inside microfreak.transports.rtmidi, lazily.
"""
from __future__ import annotations

__version__ = "0.1.0"

from . import analysis, collections, protocol, sync          # noqa: F401
from .backup import BackupSet                                # noqa: F401
from .collections import (ApplyOptions, ApplyPlan, BankItem,  # noqa: F401
                          PlanAction, PresetCollection, Provenance,
                          ProvenanceKind, SlotPlan, plan_apply)
from .device import MicroFreak                               # noqa: F401
from .errors import (BlobSizeError, ChunkNotAckedError,      # noqa: F401
                     CollectionNotFoundError, DeviceNotFoundError,
                     DeviceTimeoutError, EntryNotFoundError, IntegrityError,
                     InvalidNameError, LibraryCorruptError, LibraryError,
                     MicroFreakError, OperationCancelledError, ProtocolError,
                     ReplyMismatchError, SlotOutOfRangeError,
                     TransportError, TransportUnavailableError,
                     VerifyMismatchError, WriteAbortedError, WriteError)
from .library import (Library, LibraryEntry, all_tags,       # noqa: F401
                      category_census)
from .model import (CancelToken, Category, DeviceSnapshot,   # noqa: F401
                    Preset, PresetRef, ProgressEvent, ProgressFn, SlotRecord,
                    TimingReport, WriteReport)
from .protocol import (BLOB_SIZE, CHUNK_COUNT, CHUNK_SIZE,   # noqa: F401
                       DUPLICATE_THRESHOLD, META_LEN, NAME_LEN, SLOTS,
                       SLOTS_PER_BANK, NameInfo)
from .session import Session                                 # noqa: F401
from .sync import SlotDiff, SlotStatus, SyncDiff, diff       # noqa: F401
from .transport import Transport                             # noqa: F401
from .model import Verdict                                   # noqa: F401
from .audition import AuditionSession                        # noqa: F401


def open_device(**open_kwargs) -> MicroFreak:
    """Discover and open the real device over rtmidi — the one line the CLI
    needs. Lazy-imports the rtmidi adapter, so this raises
    TransportUnavailableError when python-rtmidi is absent."""
    from .transports.rtmidi import RtMidiTransport
    return MicroFreak(RtMidiTransport.open(**open_kwargs))
