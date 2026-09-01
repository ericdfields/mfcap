# `microfreak` core API (v0.1.0)

Reference documentation for the `microfreak` package — the framework- and
host-agnostic core of the MicroFreak preset librarian. This document is also
the contract a port implements: the Swift/iPad or Pi implementation reads
this, not the Python. Wire behaviors restate
[write-protocol.md](write-protocol.md), which is ground truth; where the two
could ever disagree, that one wins.

The package is standard library only. `python-rtmidi` is touched in exactly
one module (`microfreak.transports.rtmidi`), lazily, so `import microfreak`
succeeds with no rtmidi installed. Everything is synchronous; callers that
want concurrency wrap threads around it.

```bash
pip install -e .              # the core, no dependencies
pip install -e '.[rtmidi]'    # + python-rtmidi, for real hardware
```

---

## Quick start

### Open a device

```python
import microfreak

mf = microfreak.open_device()        # rtmidi discovery + open, one line
print(mf.name(0))                    # name of slot 0, e.g. "Bass Prophet"
mf.close()
```

`open_device()` lazy-imports the rtmidi adapter; without python-rtmidi
installed it raises `TransportUnavailableError`. For development and tests,
inject the simulated device instead — same API, no hardware, instant:

```python
from microfreak import MicroFreak
from microfreak.transports.simulated import SimulatedMicroFreak

mf = MicroFreak(SimulatedMicroFreak.factory_fresh())
```

`MicroFreak` is a context manager, so `with microfreak.open_device() as mf:`
closes the transport on the way out.

### Back up every slot

```python
def show(ev):
    eta = f", eta {ev.eta_seconds:.0f}s" if ev.eta_seconds else ""
    print(f"{ev.done}/{ev.total}  slot {ev.slot:03d}  {ev.name!r}{eta}")

backup = mf.backup("backups/2026-09-01", progress=show)
print(f"{backup.timing.total_seconds:.0f}s total, "
      f"{backup.timing.dump_ms_median} ms/dump")
```

A full 512-slot pass is a ~3.5 minute operation on hardware (dump ≈ 400
ms/slot). The backup persists as it goes — each slot is on disk before the
next is read — so a cancelled or interrupted pass leaves valid partial
state, and `resume=True` picks up where it stopped. Backup only ever reads;
it never writes to the device.

### Write a preset, verified

```python
preset = backup.preset(300)          # a Preset: name + 4672-byte blob + meta
report = mf.write(412, preset)       # verify=True is the default
assert report.verified               # read back and hash-matched
```

Every device write is read back and hash-verified by default: after the
gate-verified 7-frame write sequence, the core reads the slot's name and
blob back and compares name and SHA-256 against what it sent. A mismatch
raises `VerifyMismatchError` (with `first_difference` when the blob
differs) — `report.verified` is never `False`, because a failed verify
raises instead. `verify=False` is the explicit per-call opt-out
(`report.verified` is then `None`).

### Diff the device against a library

```python
from microfreak import Library, SlotStatus, diff

lib = Library.open("library")
snap = mf.snapshot()                 # names + blobs + hashes, all 512 slots
d = diff(snap, lib)

for row in d.by_status(SlotStatus.DIFFERS):
    print(f"slot {row.slot}: device {row.device.name!r} != "
          f"library {row.library.name!r}")
for row in d.by_status(SlotStatus.DEVICE_ONLY):
    print(f"slot {row.slot}: {row.device.name!r} not in library")
```

The diff is pure — it computes and never writes. Executing it is the caller
composing `mf.write(...)` / `lib.add(...)` calls per row.

---

## Top-level exports

`import microfreak` gives you:

- `open_device()`, `MicroFreak`, `Session`, `Transport`
- `Preset`, `SlotRecord`, `DeviceSnapshot`, `TimingReport`, `WriteReport`,
  `ProgressEvent`, `ProgressFn`, `CancelToken`, `NameInfo`
- `BackupSet`, `Library`, `LibraryEntry`
- `diff`, `SyncDiff`, `SlotDiff`, `SlotStatus`
- the `analysis`, `protocol`, `sync` submodules
- the constants `SLOTS`, `SLOTS_PER_BANK`, `BLOB_SIZE`, `CHUNK_SIZE`,
  `CHUNK_COUNT`, `META_LEN`, `NAME_LEN`, `DUPLICATE_THRESHOLD`
- every exception type (see [Errors](#errors))

---

## Value types (`microfreak.model`)

All frozen dataclasses with primitive fields, so a Swift port is a
transliteration.

### `Preset`

One preset: `name` (str), `blob` (exactly 4672 bytes), `meta` (exactly 9
opaque bytes). `meta` is mandatory — it has no default, so every `Preset`
traces to a real read (device, backup, or library). Construction validates
all three fields. `preset.sha256` is the hex SHA-256 of the blob;
`preset.renamed("New Name")` returns a copy.

`meta` is the long-0x52 payload bytes 3..11 verbatim as read from a device.
It is round-tripped verbatim on write except the two positional bytes the
codec recomputes for the target slot (see
[the long-0x52 payload](#the-long-0x52-payload-byte-by-byte)).

### `SlotRecord`

One slot as observed: `slot`, `name` (None = name read failed), `sha256`
(None = blob not read), `meta` (None only when the name read failed),
`blob` (None unless the snapshot kept blobs).

### `DeviceSnapshot`

`taken_at` (ISO 8601), `records` (tuple of `SlotRecord`, ascending slot
order, covering only the requested slots), `timing` (a `TimingReport`).
`snap.record(slot)` finds one record; `snap.has_hashes` is True when every
record carries a sha.

### `WriteReport`

`slot`, `sha256` of the blob sent (`""` for a rename — no blob traffic),
`name`, `verified` (True = read back and matched; None = verify skipped;
False never occurs — a mismatch raises), `duration_seconds`.

### `ProgressEvent` / `ProgressFn`

Long operations accept `progress=` callbacks receiving
`ProgressEvent(done, total, slot, name, elapsed_seconds, eta_seconds)`.
The ETA is median-based, the same math as phase-0 `mfcap.midi.backup`.

### `CancelToken`

Cooperative cancellation: `token.cancel()` from any thread; long operations
poll `token.cancelled` between slots and between write chunks and raise
`OperationCancelledError(done, total)`. Worst-case cancel latency is one
dump/ack timeout. Cancelling mid-write tears the slot — recovery is "write
again".

---

## The device API (`MicroFreak`)

```python
MicroFreak(transport, *, slots=512, clock=time.monotonic, sleep=time.sleep)
```

Wraps a `Session` around any `Transport`. `clock` and `sleep` are
injectable for tests. Context manager; `close()` closes the transport.

### Reads

- `name(slot) -> str` — one name read (~1 ms on hardware).
- `read(slot) -> Preset` — name + meta + blob (~400 ms on hardware).
- `snapshot(*, read_blobs=True, keep_blobs=False, slots=None,
  progress=None, cancel=None) -> DeviceSnapshot` — read names (and, by
  default, blobs + hashes) for the requested slots. `read_blobs=False` is
  the fast names-only pass (records carry `sha256=None`);
  `keep_blobs=True` retains blob bytes on the records (required for
  `Library.import_snapshot`). A failed name read yields `name=None,
  meta=None` on that record rather than aborting. Cancellation raises
  `OperationCancelledError`; no partial snapshot is returned.

### Writes (verified by default)

- `write(slot, preset, *, verify=True, cancel=None) -> WriteReport` — the
  gate-verified 7-frame sequence, then (by default) name and blob read-back
  with SHA-256 comparison. Mismatch raises `VerifyMismatchError`.
- `rename(slot, name, *, verify=True) -> WriteReport` — reads the slot's
  current meta, sends the long 0x52 name frame plus a refresh read (exactly
  what MIDI Control Center sends for a rename — no blob traffic), verifies
  the read-back name. `WriteReport.sha256` is `""`.

### Backup / restore

- `backup(dest, *, slots=None, resume=False, progress=None, cancel=None)
  -> BackupSet` — reads every requested slot into the phase-0 on-disk
  format (see [On-disk schemas](#on-disk-schemas)), persisting per slot as
  it goes. `resume=True` skips slots already on disk with an intact index
  entry. Reads only; never writes to the device.
- `restore(source, slots=None, *, verify=True, progress=None, cancel=None)
  -> list[WriteReport]` — writes presets from a `BackupSet` back to the
  device. `slots=None` means every covered slot. Stops at the first raised
  error — a failing write path must not keep writing — and attaches the
  reports for already-completed slots to the exception as `.completed`
  (on any `MicroFreakError`).

---

## Transports

### The seam

`Transport` is a `typing.Protocol` — any object with these three methods
works, no registration needed:

```python
send(message: bytes) -> None            # one complete SysEx F0..F7, atomically
receive(timeout: float) -> bytes | None # next complete inbound message,
                                        # or None on timeout
close() -> None
```

See [Porting the core](#porting-the-core) for the full contract.

### `microfreak.transports.rtmidi` — real hardware

The only module in the package that touches python-rtmidi, and only inside
functions, so importing it costs nothing without rtmidi installed.

- `available() -> bool` — can python-rtmidi be imported? Never raises.
- `list_ports() -> {"inputs": [...], "outputs": [...]}`
- `find_microfreak(hints=DEVICE_HINTS, exclude="mfcap")` — `(input, output)`
  port names of the first match, or None. The `exclude` filter skips
  mfcap's own virtual proxy ports.
- `RtMidiTransport.open(hints=..., exclude=...)` — discover and open;
  raises `DeviceNotFoundError` (listing every port seen) on no match.
- `RtMidiTransport.open_ports(in_name, out_name)` — explicit picker by
  exact port name.

The adapter turns rtmidi's push callback into the poll model with an
internal `queue.Queue`, reassembles SysEx messages split across callbacks,
and wraps every backend exception in `TransportError` (chained).

### `microfreak.transports.simulated` — the offline device

`SimulatedMicroFreak` is a stdlib-only in-memory MicroFreak faithful to
write-protocol.md. It implements `Transport` synchronously: `send()` runs
the device state machine inline; `receive()` pops a FIFO outbox and returns
None immediately when empty, so offline tests are instant.

```python
SimulatedMicroFreak(*, slots=512, reply_lag=True, fail_chunk_at=None)
SimulatedMicroFreak.factory_fresh(*, init_copies=269, seed=0, **kw)
```

- `reply_lag=True` (the default, so every offline test exercises the
  defense): the reply to name-read N is held and emitted only when
  name-read N+1 arrives. The held reply is rendered from device state at
  emission time — the behavior of a device that is slow to answer, not one
  that answers wrong. Deliberately harsher than hardware (where a lone read
  IS answered); don't tune real-time lag behavior against the sim.
- Write-path acks mirror the captures: the long 0x52, the short 0x52 open,
  the 0x15 go and every chunk are each acked with a device-shape 0x18
  (len 0x00, empty payload, seq echoing the acked frame). Inbound long-0x52
  writes are validated against the captured outbound convention
  (payload[8]=pos, payload[9]=0x06, payload[3] without the reply-only 0x10
  bit); deviations land in `faults`.
- `factory_fresh()` reproduces the reference device's shape: named
  pseudo-presets in the low slots plus `init_copies` identical "Init"
  blobs, with meta bytes positionally correct (including the payload[9]
  flip at slot 384) — so expendability and header-leak tests are real.
- Test back doors: `load(slot, preset)` and `peek(slot) -> Preset` set and
  inspect state directly; `faults` collects protocol violations the sim
  observed (a torn or short commit leaves the slot untouched and appends
  here, so a broken writer fails verification instead of passing);
  `wire_log` records `("out"|"in", raw)` in the host's direction
  convention.
- `fail_chunk_at=N`: the write chunk with 0-based cumulative index N —
  counted across the sim's lifetime, so use a fresh sim per torn-write
  scenario — and every later one receive no 0x18 ack. Drives
  `ChunkNotAckedError` and torn-write tests.

---

## Backup on disk (`BackupSet`)

A loaded, hash-verified phase-0 backup directory — byte-compatible with
what `mfcap backup` writes, so existing backups open unchanged.

- `BackupSet.load(path)` — parses `index.json` and re-hashes **every** blob
  file against its recorded sha; the first bad slot is named in the raised
  `IntegrityError`. An unparseable index raises `LibraryCorruptError`.
- `covers(slot)`, `covered_slots()`, `records()` (name + sha + meta per
  covered slot, blobs lazy), `preset(slot) -> Preset`, `.timing`,
  `.created_at`, `.path`.
- `meta_hex` (18 hex chars = the 9 meta bytes) is an additive field over
  the phase-0 schema. An old index without it still loads — records carry
  `meta=None` and remain usable for diff/analysis — but `preset(slot)` on
  such a slot raises `IntegrityError("no meta recorded; re-backup to
  restore this slot")`, because a `Preset` without real meta cannot be
  written back faithfully.
- Creation goes through `MicroFreak.backup` only; there is no
  `BackupSet.create` taking a device. One mutation path.

---

## The library (`Library`)

A local folder of content-addressed preset blobs plus an index — the
librarian's collection, independent of any device.

```python
lib = Library.create("library")        # or Library.open("library")
entry = lib.add(preset, slot=42, tags=("bass", "live-set"))
lib.rename_entry(entry.id, "Fat Bass v2")
preset_back = lib.get(entry.id)        # re-hashed on every read
```

- `LibraryEntry`: `id` (uuid4 hex, minted at `add()`, survives renames),
  `name`, `sha256`, `meta_hex`, `slot` (this library's desired device slot,
  or None), `added_at`, `tags`.
- `add(preset, *, slot=None, tags=())` — the blob file is written only if
  absent (269 factory Inits cost one file); a new entry is always created,
  so two entries may share one blob sha under different names.
- At most one entry per slot: assigning a slot (via `add` or
  `assign_slot`) clears any other entry's claim to it.
- `remove(entry_id)` deletes the blob file only when no remaining entry
  references it.
- Reads: `entries()`, `entry(id)`, `get(id) -> Preset` (every get
  re-hashes the blob against its filename — `IntegrityError` on rot),
  `find_by_sha(sha)`, `has_blob(sha)`, `slot_map() -> {slot: entry}`.
- `import_snapshot(snapshot, *, skip_expendable=True, threshold=3)` —
  bulk-import a device snapshot. Requires kept blobs
  (`snapshot(read_blobs=True, keep_blobs=True)`). Each imported entry is
  assigned its source slot. Skips expendable slots (when asked), records
  whose name read failed (no meta to round-trip), and records for which an
  entry with identical `(sha256, name)` already exists. Returns the
  entries actually added.
- Index writes are atomic (temp file + `os.replace`). Single-writer
  assumption; no cross-process locking.

---

## Sync diff (`microfreak.sync`)

```python
diff(snapshot, library, *, threshold=3) -> SyncDiff
```

Pure and deterministic: no baseline state, computes and never writes. Per
snapshot record, with `ex` = slot expendable within the snapshot and `lib`
= library entry assigned to the slot:

| condition | `SlotStatus` | meaning |
|---|---|---|
| no lib, ex | `EMPTY` | expendable on device, nothing assigned |
| no lib, not ex | `DEVICE_ONLY` (`"added"`) | real preset on device, not in library |
| lib, shas equal | `IN_SYNC` | |
| lib, ex | `LIBRARY_ONLY` (`"missing"`) | assigned in library, device slot expendable |
| otherwise | `DIFFERS` (`"changed"`) | both real, contents differ |

Every considered record must carry a sha — a hash-less snapshot raises
`ValueError`, because refusing beats guessing. `SyncDiff.slots` is one
`SlotDiff(slot, status, device, library)` per snapshot record, ascending;
`by_status(status)` filters. The core never auto-writes from a diff.

---

## Analysis (`microfreak.analysis`)

Pure functions over `SlotRecord`s from anywhere (snapshot, backup).

- `sha_census(records) -> {sha: count}` — how many slots hold each blob.
- `find_expendable(records, *, threshold=3) -> set[slot]` — a slot is
  expendable when its successfully-read name is blank/whitespace-only **or**
  its exact bytes occur at least `threshold` times among the given records.
  Threshold is 3, not 2, so a user's own single duplicated preset is never
  chosen. Never a `name == "Init"` string match — the MicroFreak ships
  unused slots as factory Init presets, so emptiness is a content
  judgement, not a name one. Unknown is never expendable: `sha256=None`
  (content unread) and `name=None` (the name read FAILED — what
  `MicroFreak.snapshot` records after a swallowed timeout) both disqualify
  the respective rule.
- `pick_scratch_slot(records, *, prefer_from=500, exclude=()) ->
  Optional[slot]` — the safest slot to write into: the highest expendable
  slot ≥ `prefer_from`, else the highest expendable overall, else None
  (the caller asks the human). Preserves the proven phase-0
  `mfcap.verify.pick_scratch_slot` semantics exactly (asserted by test).

---

## The session (`Session`)

Most callers never touch `Session` directly — `MicroFreak` owns one — but
its invariants are the core's spine:

```python
Session(transport, *, name_timeout=1.0, dump_timeout=1.5, ack_timeout=1.0,
        name_retries=3, clock=time.monotonic, sleep=time.sleep)
```

- One `Session` per transport; one transaction at a time. Every public
  method holds one internal lock, so concurrent callers queue instead of
  interleaving chunk streams (which are unaddressed and unmatchable by
  design).
- The addressed-request seq counter lives here: 1..127, wrapping, never
  emitting 0. The write burst carries its own seq stream, verbatim from
  the captures: the "go" frame is seq 0 and the chunks continue from it,
  `(i + 1) % 128` — wrapping through 0 (owned by `chunk_frames`).
- `_transact_addressed` is the single function in the package allowed to
  inspect a 0x52 reply; `read_name`, `write_name`'s read-back, and
  `write_preset`'s first and last frames all pass through it. The
  reply-lag bug cannot be reintroduced without deleting it.
- Clock and sleep are injectable; there is no module-level mutable state
  anywhere in the package.

Public methods: `read_name(slot) -> NameInfo`, `read_blob(slot) -> bytes`,
`write_preset(slot, preset, cancel=None) -> NameInfo` (the raw 7-frame
sequence; comparison is the caller's job), `write_name(slot, name, meta)
-> NameInfo`, `close()`.

---

## The protocol codec (`microfreak.protocol`)

Wire constants and the pure, stateless codec — no I/O anywhere.

| name | value | meaning |
|---|---|---|
| `PREFIX` | `F0 00 20 6B 07 01` | F0 + Arturia + MicroFreak device id + 0x01 |
| `CMD_OPEN` | `0x19` | name read (trailer `0x00`) / dump open (trailer `0x01`) |
| `CMD_NEXT` | `0x18` | pull next chunk (reads); device's per-chunk ack (writes) |
| `CMD_CHUNK_MORE` | `0x16` | chunk, more to come |
| `CMD_CHUNK_LAST` | `0x17` | chunk, last one (commit, on writes) |
| `CMD_GO` | `0x15` | write "go": seq 0, len 0, empty payload |
| `CMD_NAME` | `0x52` | long form: name+meta (35 B); short form `[bank,pos,0x01]`: open write |
| `SLOTS` | 512 | firmware 5.x |
| `SLOTS_PER_BANK` | 128 | `bank = slot // 128`, `pos = slot % 128` |
| `HIGH_BANK_BOUNDARY` | 384 | long-0x52 payload[9]: 0 below, 1 at/above |
| `BLOB_SIZE` | 4672 | 146 × 32; the blob you write is the blob you read |
| `CHUNK_SIZE` | 32 | every chunk, no exceptions |
| `CHUNK_COUNT` | 146 | 145 × `0x16` + 1 × `0x17` |
| `NAME_PAYLOAD_LEN` | 35 | long 0x52: 12-byte header + 23-byte name |
| `NAME_OFFSET` / `NAME_LEN` | 12 / 23 | name field inside the long-0x52 payload |
| `META_LEN` | 9 | long-0x52 payload[3..11] |
| `DUPLICATE_THRESHOLD` | 3 | content-based expendability (3, not 2) |
| `NO_CHECKSUM` | True | **no checksum exists; nothing computes one, ever** |

Frame envelope: `F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7`.
The `<len>` bytes are the gate-verified literals: name read `0x03`, dump
open `0x01`, pull-next `0x01` (payload `[0x00]`), chunks `0x20`, long 0x52
`0x23`, short 0x52 `0x03`, go `0x00`. All payload bytes are 7-bit.

Builders (seq always explicit — this module counts nothing):
`read_name_req`, `open_dump_req`, `pull_next_req`, `name_write_frame`,
`open_write_frame`, `go_frame`, `chunk_frames(blob) -> [bytes]`.
Parsers/helpers: `parse(raw) -> Frame | None` (None for non-MicroFreak
traffic), `decode_name_reply(frame) -> NameInfo`, `is_chunk`,
`is_last_chunk`, `is_ack`, `assemble_blob(chunks) -> bytes`,
`digest(blob) -> sha256 hex`, `validate_name`, `addr(slot) -> (bank, pos)`,
`slot_of(bank, pos) -> slot`.

Names: at most 23 printable-ASCII characters (`0x20..0x7E`), NUL-padded on
the wire. Decoding: `payload[12:]` split at the first NUL, printable-ASCII
filtered, stripped (verified against hardware fixtures).

### The long-0x52 payload, byte by byte

| offset | content | on write (`name_write_frame`) |
|---|---|---|
| 0 | bank | **recomputed** from the target slot |
| 1 | pos | **recomputed** |
| 2 | `0x00` | fixed |
| 3 | flags = `meta[0]`; bit `0x10` is reply-only (device sets it for slots ≥ 128) | `meta[0] & ~0x10` — the reply bit is **cleared**; no captured write carries it |
| 4..7 | opaque (flags/bookkeeping) = `meta[1..4]` | **verbatim** round-trip |
| 8 | pos, again | **recomputed** (`meta[5]` ignored) |
| 9 | replies: 0 if slot < 384 else 1 | **constant `0x06`** — every captured outbound write, all slots (`meta[6]` ignored) |
| 10 | category = `meta[7]` | **verbatim** |
| 11 | attribute = `meta[8]`, often printable (`0x32`/`0x33`) | **verbatim** |
| 12..34 | name, ASCII, NUL-padded, 23 bytes | replaced by the target name |

`meta` throughout the API is exactly `payload[3..11]` (9 bytes) as read
from a device. It is opaque, has no default, and every `Preset` traces to
a real read.

**Address invariant (structural):** slot addresses appear **only** in 0x19
and 0x52 frames, always as the first two payload bytes. Chunk frames carry
no address, and no API in the package accepts or returns a slot for a
chunk — a chunk payload may coincidentally begin `03 7F`, so
"pattern-match an address inside a chunk" must not be expressible.

---

## Errors

Nothing else escapes the public API: adapters wrap every backend exception
in `TransportError` (chained); the session and device layers raise only
these.

```
MicroFreakError
├─ ProtocolError                malformed/unexpected frame
│  ├─ SlotOutOfRangeError       slot ∉ 0..511 (.slot)
│  ├─ BlobSizeError             blob/assembly != 4672 (.expected, .actual)
│  └─ InvalidNameError          non-ASCII or > 23 chars
├─ TransportError               backend failure, chained
│  ├─ TransportUnavailableError python-rtmidi not installed
│  └─ DeviceNotFoundError       no matching port (.inputs, .outputs)
├─ DeviceTimeoutError           silence (.stage "name_read"|"dump", .slot)
├─ ReplyMismatchError           lag never resolved after retries
│                               (.requested_slot, .replied_slot, .attempts)
├─ WriteError
│  ├─ ChunkNotAckedError        no 0x18 (.slot, .chunk_index)
│  ├─ WriteAbortedError         (.stage ∈ {"name_write","open","go",
│  │                             "chunk","final_read"}, .slot, .chunks_sent)
│  └─ VerifyMismatchError       (.slot, .expected/.actual sha256 and name,
│                                .first_difference, .expected/.actual_len)
├─ OperationCancelledError      (.done, .total) [+ .completed on restore]
├─ IntegrityError               stored data fails its own hash (.path, .detail)
└─ LibraryError
   ├─ EntryNotFoundError        (.entry_id)
   └─ LibraryCorruptError       unparseable/unsupported index (.path, .detail)
```

---

## On-disk schemas

### Backup (phase-0 format, byte-compatible with `mfcap backup`)

```
<dest>/
  index.json      {"created": ISO8601, "slots": N,
                   "presets": {"<slot>": {"slot", "name", "bytes",
                                          "sha256", "meta_hex"}},
                   "timing": {"total_seconds", "per_slot_seconds",
                              "name_ms_median", "dump_ms_median"}}
  presets/NNN.bin 4672-byte blob, zero-padded 3-digit slot number
```

### Library

```
<root>/
  index.json          {"schema": 1, "entries": [{"id", "name", "sha256",
                       "meta_hex", "slot", "added_at", "tags"}]}
  blobs/<sha256>.bin  content-addressed 4672-byte blobs
```

---

## Porting the core

The iPad app (Swift over CoreMIDI) and the Pi device (Python or otherwise,
over ALSA) reimplement or rehost this core. A port reproduces four things:
the transport contract, the three request/reply state machines, the
invariants, and the quirks. The Python is the reference implementation;
this section is the checklist. Wire ground truth remains
[write-protocol.md](write-protocol.md).

### 1. The transport contract

The transport is the only platform-specific seam. Three operations:

```
send(message)             one complete SysEx message F0..F7, atomically
receive(timeout) -> msg?  next complete inbound message, or nothing on timeout
close()
```

- **Poll model, deliberately.** The core is synchronous and spawns no
  threads. Push-style backends (CoreMIDI `MIDIReadProc`, ALSA events,
  rtmidi callbacks) buffer into an internal queue inside the adapter — a
  `queue.Queue` in Python; a locked array + semaphore in Swift.
- Arrival order preserved; the transport buffers and never drops.
- The transport's only jobs are byte movement and message-boundary
  reassembly (backends may split one SysEx across callbacks — reassemble
  F0..F7 before delivering). No parsing, filtering, matching, retries, or
  threading above the seam.
- Discovery (finding the MicroFreak among ports) is a per-backend factory
  concern, not part of the interface.
- Adapters catch every backend exception and re-raise the port's
  equivalent of `TransportError`, chained.

Port the simulated device too — it is stdlib-only and defined entirely by
observable wire behavior, so a Swift `SimulatedMicroFreak` lets the whole
librarian be developed and tested on the couch, no synth in sight. Keep
`reply_lag` on by default so every test exercises the defense.

### 2. The three state machines

#### Name read (with the lag rule)

```
host:   0x19 [bank, pos, 0x00]                       (len 0x03)
device: 0x52 [35-byte payload]                       ...eventually
```

**Reply-lag rule:** under rapid back-to-back name reads the device's
replies lag one request behind. Every 0x52 reply embeds the slot it
describes (payload[0..1]); a reply is matched to a request **only** by
that embedded address, never by arrival order or seq. Procedure — and make
it a single chokepoint, the only code in the port allowed to inspect a
0x52 reply:

1. Drain all stale inbound frames.
2. Send the request. Wait up to `name_timeout` for a long-0x52 frame.
3. Reply's embedded slot == requested slot → success.
4. Reply names a different slot → it is stale; discard it and resend
   immediately (counts as one attempt).
5. Silence for the whole window → resend (counts as one attempt).
6. After `name_retries` (default 3) total attempts: if any reply was seen
   → `ReplyMismatchError`; total silence → `DeviceTimeoutError`.

#### Dump read

```
host:   0x19 [bank, pos, 0x01]                       (len 0x01) open
loop:   host:   0x18 [0x00]                          (len 0x01) pull
        device: 0x16 [32 bytes]                                 chunk
until:  device: 0x17 [32 bytes]                                 last chunk
```

Strict lockstep, one outstanding request. 146 chunks × 32 bytes must
total exactly 4672 (error otherwise). Non-chunk frames arriving during a
dump are stale and discarded. No chunk within `dump_timeout` → timeout
error.

#### Write (the gate-verified 7-frame sequence)

| # | dir | frame | notes |
|---|-----|-------|-------|
| 1 | → | `0x19 [bank,pos,0x00]` | name read via the lag chokepoint; result discarded (fidelity to MCC) |
| 2 | →← | long `0x52` (35 B) | name + meta; device acks with `0x18` (awaited) |
| 3 | →← | short `0x52 [bank,pos,0x01]` | open blob write; acked with `0x18` (awaited) |
| 4 | →← | `0x15`, seq 0, len 0 | go; acked with `0x18` (awaited) |
| 5 | →← | `0x16` ×145, each answered by device `0x18` | ack awaited per chunk (`ack_timeout`); missing ack is an error naming the chunk index |
| 6 | →← | `0x17` ×1, acked | commit |
| 7 | → | `0x19 [bank,pos,0x00]` | read back via the lag chokepoint |

Device acks are len `0x00`, empty payload, seq echoing the acked frame
(the host's pull-next `0x18` during reads is len `0x01`, payload `[0x00]`).
No checksum is computed at any point; none exists. Cancellation is polled
before each chunk; cancelling mid-write tears the slot (recovery: write
again). **Rename** is frames 2 + 7 only — exactly what MCC sends: the long
0x52 plus a refresh read, no blob traffic.

### 3. The invariants

- **Seq counter:** 1..127, wrapping, never emitting 0; 0 appears only in
  the go frame. Owned by the session, nowhere else.
- **One transaction at a time** per session; serialize callers with a
  lock. Chunk streams are unaddressed and unmatchable — interleaving must
  be impossible, not merely avoided.
- **Addresses only in 0x19/0x52 frames**, always the first two payload
  bytes. Make the chunk API address-free so matching an address inside a
  chunk is not expressible.
- **Meta round-trips verbatim** except the direction-dependent header
  bytes recomputed on every name write: payload[3] has the reply-only
  `0x10` bit cleared, payload[8] is the target pos, and payload[9] is the
  constant `0x06` (replies carry the ≥384 flag there instead).
- **Every write is read back and hash-verified by default**; opt-out is
  explicit and per-call. A verify result is "verified" or an error — never
  a silently-false flag.
- **Names:** ≤ 23 printable-ASCII characters, NUL-padded on the wire,
  never inside the blob.
- **No checksum**, anywhere, ever.
- **Blob size is exactly 4672**; reject anything else before it reaches
  the wire.
- **Restore stops at the first failure** — a failing write path must not
  keep writing — while reporting what already completed.
- Timeout defaults that work on hardware: name 1.0 s, dump 1.5 s, ack
  1.0 s, 3 name attempts. Make clock and sleep injectable so the state
  machines are testable without real time.

### 4. The quirks

- **Reply lag** (above) is the quirk most likely to corrupt a librarian:
  without the embedded-address match, a fast slot browser labels every
  preset with its neighbor's name. The Python proof: 512 rapid reads on
  the lagged simulator, every slot labeled correctly.
- **"Empty" slots don't exist.** Unused slots are factory Init presets —
  name "Init", identical blobs (269 of 512 on the reference device).
  Emptiness is a content judgement: sha duplicated ≥ 3 times, or a blank
  successfully-read name (a FAILED name read is unknown, never empty).
  Never match the string "Init"; users rename presets to anything.
- **Throughput:** name read ≈ 1 ms, dump ≈ 400 ms, full 512-slot pass
  ≈ 211 s. Design the UI around it: a names-only refresh is interactive; a
  full hash pass is a progress-bar operation (hence `ProgressEvent` with a
  median-based ETA, and per-slot persistence so interruption is cheap).
- **Renames are name-frame-only.** Don't rewrite 4672 bytes to change a
  name; MCC doesn't.

### 5. Open assumptions

The first hardware session against this core must confirm two encoded
assumptions before they are treated as proven:

1. per-chunk 0x18 ack pacing under our timing (the gate replayed at MCC's
   pace);
2. the outbound long-0x52 header (payload[3] reply-bit cleared,
   payload[8]=pos, payload[9]=0x06) taken verbatim from the four captured
   MCC writes — all to slots ≥ 384; a retargeted hardware write BELOW the
   boundary has not yet been performed.
