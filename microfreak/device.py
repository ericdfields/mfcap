"""MicroFreak: the librarian's device API.

Every device write is read back and hash-verified by default; verify=False
is the explicit per-call opt-out.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Union

from .backup import BackupSet, atomic_write_text
from .errors import (DeviceTimeoutError, MicroFreakError,
                     OperationCancelledError, ReplyMismatchError,
                     VerifyMismatchError)
from .model import (CancelToken, DeviceSnapshot, Preset, ProgressEvent,
                    ProgressFn, SlotRecord, TimingReport, WriteReport)
from .protocol import SLOTS, digest, validate_name
from .session import Session
from .transport import Transport


def _median(xs: List[float]) -> Optional[float]:
    """Median as mfcap.midi.backup computes it: sorted()[len // 2]."""
    if not xs:
        return None
    return round(sorted(xs)[len(xs) // 2], 1)


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


class MicroFreak:
    def __init__(self, transport: Transport, *, slots: int = SLOTS,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep):
        self.slots = slots
        self.clock = clock
        self._session = Session(transport, clock=clock, sleep=sleep)

    @property
    def session(self) -> Session:
        return self._session

    def close(self) -> None:
        self._session.close()

    def __enter__(self) -> "MicroFreak":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ------------------------------------------------------------- reads

    def name(self, slot: int) -> str:
        return self._session.read_name(slot).name

    def read(self, slot: int) -> Preset:
        info = self._session.read_name(slot)
        blob = self._session.read_blob(slot)
        return Preset(name=info.name, blob=blob, meta=info.meta)

    def snapshot(self, *, read_blobs: bool = True, keep_blobs: bool = False,
                 slots: Optional[Sequence[int]] = None,
                 progress: Optional[ProgressFn] = None,
                 cancel: Optional[CancelToken] = None) -> DeviceSnapshot:
        """Read names (and, by default, blobs + hashes) for the requested
        slots. Cancellation raises OperationCancelledError; no partial
        snapshot is returned."""
        slot_list = sorted(slots) if slots is not None else list(range(self.slots))
        total = len(slot_list)
        records: List[SlotRecord] = []
        name_ms: List[float] = []
        dump_ms: List[float] = []
        durations: List[float] = []
        t_start = self.clock()
        for done, slot in enumerate(slot_list):
            if cancel is not None and cancel.cancelled:
                raise OperationCancelledError(done, total)
            t_slot = self.clock()
            nm: Optional[str] = None
            meta: Optional[bytes] = None
            try:
                t0 = self.clock()
                info = self._session.read_name(slot)
                name_ms.append((self.clock() - t0) * 1000)
                nm, meta = info.name, info.meta
            except (DeviceTimeoutError, ReplyMismatchError):
                pass    # name=None, meta=None on the record
            sha: Optional[str] = None
            kept: Optional[bytes] = None
            if read_blobs:
                t0 = self.clock()
                blob = self._session.read_blob(slot)
                dump_ms.append((self.clock() - t0) * 1000)
                sha = digest(blob)
                if keep_blobs:
                    kept = blob
            records.append(SlotRecord(slot=slot, name=nm, sha256=sha,
                                      meta=meta, blob=kept))
            durations.append(self.clock() - t_slot)
            if progress is not None:
                elapsed = self.clock() - t_start
                med = sorted(durations)[len(durations) // 2]
                eta = med * (total - done - 1) if durations else None
                progress(ProgressEvent(done=done + 1, total=total, slot=slot,
                                       name=nm or "", elapsed_seconds=elapsed,
                                       eta_seconds=eta))
        elapsed = self.clock() - t_start
        timing = TimingReport(
            total_seconds=round(elapsed, 3),
            per_slot_seconds=round(elapsed / max(total, 1), 4),
            name_ms_median=_median(name_ms),
            dump_ms_median=_median(dump_ms))
        return DeviceSnapshot(taken_at=_iso_now(), records=tuple(records),
                              timing=timing)

    # ------------------------------------------- writes (verified by default)

    def write(self, slot: int, preset: Preset, *, verify: bool = True,
              cancel: Optional[CancelToken] = None) -> WriteReport:
        t0 = self.clock()
        info = self._session.write_preset(slot, preset, cancel=cancel)
        verified: Optional[bool] = None
        if verify:
            if info.name != preset.name:
                raise VerifyMismatchError(
                    slot, preset.sha256, None, preset.name, info.name,
                    None, len(preset.blob), 0)
            blob = self._session.read_blob(slot)
            actual = digest(blob)
            if actual != preset.sha256:
                n = min(len(preset.blob), len(blob))
                first = next((i for i in range(n)
                              if preset.blob[i] != blob[i]), n)
                raise VerifyMismatchError(
                    slot, preset.sha256, actual, preset.name, info.name,
                    first, len(preset.blob), len(blob))
            verified = True
        return WriteReport(slot=slot, sha256=preset.sha256, name=preset.name,
                           verified=verified,
                           duration_seconds=self.clock() - t0)

    def rename(self, slot: int, name: str, *, verify: bool = True) -> WriteReport:
        validate_name(name)
        t0 = self.clock()
        current = self._session.read_name(slot)          # current meta
        info = self._session.write_name(slot, name, current.meta)
        verified: Optional[bool] = None
        if verify:
            if info.name != name:
                raise VerifyMismatchError(
                    slot, "", None, name, info.name, None, 0, 0)
            verified = True
        return WriteReport(slot=slot, sha256="", name=name, verified=verified,
                           duration_seconds=self.clock() - t0)

    # ------------------------------------------------------ backup / restore

    def backup(self, dest: Union[str, Path], *,
               slots: Optional[Sequence[int]] = None, resume: bool = False,
               progress: Optional[ProgressFn] = None,
               cancel: Optional[CancelToken] = None) -> BackupSet:
        """Read every requested slot to the phase-0 on-disk format, persisting
        as it goes (each slot written before the next is read, so a cancelled
        pass leaves valid partial state). Reads only; never writes to the
        device."""
        dest = Path(dest)
        presets_dir = dest / "presets"
        presets_dir.mkdir(parents=True, exist_ok=True)
        index_path = dest / "index.json"
        if index_path.exists():
            index = json.loads(index_path.read_text())
            index.setdefault("presets", {})
            index.setdefault("timing", {})
        else:
            index = {"created": _iso_now(), "slots": self.slots,
                     "presets": {}, "timing": {}}

        slot_list = sorted(slots) if slots is not None else list(range(self.slots))
        total = len(slot_list)
        name_ms: List[float] = []
        dump_ms: List[float] = []
        durations: List[float] = []
        t_start = self.clock()
        for done, slot in enumerate(slot_list):
            if cancel is not None and cancel.cancelled:
                raise OperationCancelledError(done, total)
            bin_path = presets_dir / f"{slot:03d}.bin"
            if resume and bin_path.exists() and str(slot) in index["presets"]:
                continue
            t_slot = self.clock()
            t0 = self.clock()
            info = self._session.read_name(slot)
            name_ms.append((self.clock() - t0) * 1000)
            t0 = self.clock()
            blob = self._session.read_blob(slot)
            dump_ms.append((self.clock() - t0) * 1000)
            bin_path.write_bytes(blob)
            index["presets"][str(slot)] = {
                "slot": slot, "name": info.name, "bytes": len(blob),
                "sha256": digest(blob), "meta_hex": info.meta.hex()}
            atomic_write_text(index_path, json.dumps(index, indent=2))
            durations.append(self.clock() - t_slot)
            if progress is not None:
                elapsed = self.clock() - t_start
                med = sorted(durations)[len(durations) // 2]
                progress(ProgressEvent(done=done + 1, total=total, slot=slot,
                                       name=info.name, elapsed_seconds=elapsed,
                                       eta_seconds=med * (total - done - 1)))
        elapsed = self.clock() - t_start
        read_count = len(durations)
        index["timing"] = {
            "total_seconds": round(elapsed, 3),
            "per_slot_seconds": round(elapsed / max(read_count, 1), 4),
            "name_ms_median": _median(name_ms),
            "dump_ms_median": _median(dump_ms)}
        atomic_write_text(index_path, json.dumps(index, indent=2))
        return BackupSet.load(dest)

    def restore(self, source: BackupSet,
                slots: Optional[Sequence[int]] = None, *, verify: bool = True,
                progress: Optional[ProgressFn] = None,
                cancel: Optional[CancelToken] = None) -> List[WriteReport]:
        """Write presets from a BackupSet back to the device. Stops at the
        first raised error (a failing write path must not keep writing);
        reports for completed slots are attached to the exception as
        .completed when it is a MicroFreakError."""
        slot_list = sorted(slots) if slots is not None else source.covered_slots()
        total = len(slot_list)
        reports: List[WriteReport] = []
        durations: List[float] = []
        t_start = self.clock()
        for done, slot in enumerate(slot_list):
            try:
                if cancel is not None and cancel.cancelled:
                    raise OperationCancelledError(done, total)
                preset = source.preset(slot)
                t0 = self.clock()
                rep = self.write(slot, preset, verify=verify, cancel=cancel)
                durations.append(self.clock() - t0)
            except MicroFreakError as e:
                e.completed = reports        # type: ignore[attr-defined]
                raise
            reports.append(rep)
            if progress is not None:
                elapsed = self.clock() - t_start
                med = sorted(durations)[len(durations) // 2]
                progress(ProgressEvent(done=done + 1, total=total, slot=slot,
                                       name=rep.name, elapsed_seconds=elapsed,
                                       eta_seconds=med * (total - done - 1)))
        return reports
