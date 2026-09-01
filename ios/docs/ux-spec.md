The context is read — core API contract, wire protocol, and project voice are all clear. Here is the complete specification.

---

# MicroFreak Librarian — iPad UX Specification

**Scope:** Screens, flows, states, and the view-model contract for the SwiftUI iPad app in `/Users/ericbrookfield/Development/mfcap/ios`, built against a `FreakCore` protocol seam so the UI compiles and runs (in demo mode) before the Swift core lands. Structure and behavior only; no visual-brand direction.

**Ground truth referenced throughout:** `/Users/ericbrookfield/Development/mfcap/docs/core-api.md` and `/Users/ericbrookfield/Development/mfcap/docs/write-protocol.md`. Where this spec restates timing or protocol behavior, those documents win.

---

## 1. Design principles (derived from the protocol, not taste)

1. **Names are free; blobs are expensive.** A name read is ~1 ms; a blob is ~400 ms; a full hashed pass is ~3.5 minutes. Every screen is built names-first: the 512-slot list is interactive within ~2 s of connecting, and nothing silently starts a multi-minute read. Blob-scale work is always an explicit, progress-barred, cancellable operation.
2. **The full read pass is always a backup.** Since a hashed snapshot and a backup are the same wire traffic, the app has exactly one "read everything" operation, and it always persists to disk in the phase-0 backup format. Refreshing the sync view therefore *produces* a backup; backup freshness is a byproduct of using the app, not a chore.
3. **One transaction at a time, visibly.** The core session serializes; the app models this as a single explicit device-operation queue with one visible status surface. The UI never pretends the device can do two things at once.
4. **Emptiness is a verdict, not a fact.** A slot is "empty" only after a content judgment (sha duplicated ≥ 3× or blank read name) over a hashed snapshot. Until hashes exist, slots are *unjudged* and the UI says so. The string "Init" is never special.
5. **Every overwrite names its victim.** No write proceeds without showing the current occupant of the target slot (name + slot number), whether that occupant is recoverable (library / backup), and how fresh the latest full backup is.
6. **Demo mode is a first-class device, honestly paced.** The simulated device drives every screen, including realistic backup timing, so the whole app is buildable and testable with no synth attached. Demo is always visibly labeled and never entered or exited silently.

---

## 2. Slot identity

- **Core addressing:** 0-based `0…511`, `bank = slot / 128`, `pos = slot % 128` — never changes.
- **Display addressing:** 1-based `1…512`, matching the synth's panel display, which is the user's mental model.
- **Single conversion point:** a `SlotID` value type owns the mapping. Nothing else in the UI does arithmetic on slot numbers.

```swift
struct SlotID: Hashable, Comparable, Sendable {
    let raw: Int                    // 0…511, the core's number
    var display: Int { raw + 1 }    // 1…512, the panel's number
    var bank: Int { raw / 128 }     // 0…3
    var label: String               // "412" (display, 3-digit, monospaced digits)
    var bankLabel: String           // "Bank 4 · 385–512"
}
```

Diagnostics and error detail views show both forms once (`"slot 412 (core 411)"`); every list, dialog, and toast uses the display number only.

---

## 3. Information architecture and navigation

Three-column `NavigationSplitView`. Works in full screen, Split View, Slide Over (collapses to stack per standard behavior), and Stage Manager.

```
Sidebar                    Content                        Detail
───────────────────────    ───────────────────────────    ─────────────────────────
DEVICE                     SlotListView (512 rows,        SlotDetailView
  All Slots                sectioned by bank)             (or LibraryEntryDetail /
  Bank 1  · 1–128                                          SyncSlotDetail /
  Bank 2  · 129–256        LibraryListView                 BackupDetail)
  Bank 3  · 257–384        SyncListView
  Bank 4  · 385–512        BackupListView
LIBRARY
  All Presets
  <tag> …
SYNC
BACKUPS
───────────────────────
[Connection status footer]
```

- Sidebar bank items scroll the (always-complete) slot list to that section; they are jump targets, not filters.
- Library tags are sidebar children under Library; selecting one filters the library list.
- **Global status bar:** a `safeAreaInset(edge: .bottom)` strip across the whole split view. Left: connection state capsule (see §10). Right: the active device operation with a mini progress bar and pause/cancel, or "Idle". Tapping opens the **Operations popover** (current op, queued ops, recent completions/failures). This is the only place device busyness lives, so no screen invents its own spinner vocabulary for device traffic.
- Sheets (modal, full-height on iPad): `BackupProgressSheet`, `RestorePlanSheet`, `BulkApplyPlanSheet`, `SendPlanSheet` (multi-preset sends), `ConnectSheet`.

---

## 4. Data freshness model

The app tracks three tiers of knowledge about the device, all surfaced explicitly:

| Tier | How obtained | Cost | UI meaning |
|---|---|---|---|
| **Names** | names-only snapshot (`readBlobs=false`) | ~1–2 s for 512 | slot list populated; no emptiness/diff judgments |
| **Per-slot content** | single `read(slot)` | ~400 ms | detail view populated; that slot's sha known |
| **Full content** | full pass = **backup** | ~3.5 min, resumable | sync diff available; emptiness judged; backup fresh |

Rules:

- On connect (real or demo): run a names-only snapshot automatically. This is the only device operation the app ever starts without being asked.
- Every verified write returns the written name + sha in its `WriteReport`, so the app **patches its cached snapshot in place** after each write. The sync diff stays live after applies with zero re-reads.
- A rename patches the cached name.
- Each cached slot record carries `lastConfirmed: Date`. The device can be edited from its front panel while connected, so the app never claims real-time truth: list headers show "Names as of 14:32 — Refresh (⌘R)".
- **Backup freshness** is a first-class value: `latestCompleteBackup: (date, path)?` plus `writesSinceBackup: Int` (every device write increments it; a completed full backup resets it). Shown in the sidebar Device footer, the Sync header, and inside every destructive dialog.

---

## 5. Screens

### 5.1 Connect / No Device

Shown as content when state is `noDevice` and nothing else is selected, and always reachable from the status capsule.

- **Layout:** centered column — device glyph, "No MicroFreak connected", the list of visible MIDI endpoints (auto-refreshing via CoreMIDI notifications), a **Connect** button per plausible endpoint, and a prominent **Use Demo Device** button with a profile picker (see §12).
- Hot-plug: a device appearing triggers a non-modal banner anywhere in the app: "MicroFreak detected — Connect?" Never auto-connects, never interrupts a running demo operation.
- **States:**
  - *Empty (no endpoints):* "Connect the MicroFreak by USB." + Use Demo Device.
  - *Connecting:* endpoint row shows an inline spinner; cancellable.
  - *Error:* `DeviceNotFoundError` → lists every port seen ("Saw: IAC Bus 1, KeyStep…") so the user can tell a cable problem from a wrong-port problem. `TransportError` → "MIDI backend failed" + Retry + details disclosure.

### 5.2 Device Slot Browser (`SlotListView`)

The home screen. All 512 slots, always — never paged, never truncated.

**Row anatomy** (`SlotRowView`):

```
[413] Bass Prophet                          ● ↔ ⟳
 │     │                                     │ │  └ activity: this slot has a queued/running op
 │     │                                     │ └── sync badge (only when a current diff exists):
 │     │                                     │     added / changed / missing / in-sync / empty
 │     └ name; italic "Init"-style dimming   └──── judgment dot: occupied / empty / unjudged
 │       is NEVER applied by name — only          (hollow when unjudged)
 │       by content judgment
 └ 3-digit display number, monospaced
```

- Sectioned by bank with sticky headers ("Bank 4 · 385–512").
- Judgment dot and sync badge appear only when a hashed snapshot exists; otherwise the row shows name + hollow dot. A tooltip/long-press explains "Content not read yet — run a backup or open the slot."
- A slot whose name read failed (`name == nil`) shows "— read failed" and is treated as *unknown* (never empty, per the core's rule); tapping offers Retry.
- **Toolbar:** Refresh Names (⌘R, shows relative age), search field (`.searchable`, filters by name/number within the cached names — instant, no device traffic), multi-select (Edit / two-finger drag / ⌘-click).
- **Context menu / swipe actions per slot:** Save to Library, Send Preset Here… (picker over library), Rename (⏎), Copy (⌘C), Paste (⌘V, = send with guard rails), Show in Sync, Read Now (single 400 ms read to hash/judge just this slot).
- **Multi-select actions:** Save N to Library (plan sheet; ~400 ms × N unless bytes already on disk from the latest backup — then instant), Send N presets starting at slot … (plan sheet).
- **States:**
  - *Loading (initial names pass):* rows render immediately as numbered placeholders with redacted names; names stream in (the pass is ~1–2 s, so this is a shimmer, not a wait screen).
  - *Device busy (exclusive op running, e.g. backup):* the list stays fully browsable from cache; per-slot device actions are disabled with the reason inline ("Backup in progress — 2:10 left"); the status bar owns the progress.
  - *Stale after disconnect:* list remains, desaturated, header banner "Showing last known state from 14:32 — device disconnected." All device actions disabled; library-side actions still work.
  - *Error (names pass failed):* inline banner "Couldn't read names: device stopped responding" + Retry; rows that were read stay populated.

### 5.3 Slot Detail (`SlotDetailView`)

Selected slot in the detail column.

- Header: display number, editable name field (rename, §5.7), bank, judgment, sync status vs library (if diff exists).
- Content panel: sha256 (abbreviated, expandable), meta hex, last confirmed time, "identical to N other slots" when the census knows (this is how "empty" is explained honestly), which library entry claims this slot, and which backups cover it (with per-backup sha match/mismatch).
- If the blob/sha is unknown: a **Read Slot** button ("~1 second") replaces the content panel — blobs are lazy, and this is the lazy trigger.
- Actions: Save to Library (with tags), Send to Another Slot…, Rename, Restore this slot from backup… (picker over covering backups), Overwrite from Library… .
- *Loading:* content panel skeleton for the ~400 ms read with the queue position if queued. *Error:* read failure inline with Retry; a `VerifyMismatchError` history badge if this slot's last write failed verification (§9).

### 5.4 Library Browser (`LibraryListView` + `LibraryEntryDetailView`)

The local collection — fully functional with no device at all.

**Row:** name · tags · assigned slot chip ("→ 413" or none) · on-device status when a diff exists (in-sync / differs / not sent).

- Toolbar: search (name, tag), sort (name / added / slot), New from file (imports `.mfpreset` / raw 4672-byte blob via file importer), tag manager.
- Context menu: Send to Slot…, Assign Slot (no traffic — sets the entry's desired slot; the *diff* then shows it as "missing" until sent), Clear Slot Assignment, Rename Entry (local, instant, no device dialog), Duplicate Entry, Tags…, Export (share sheet as `.mfpreset`), Delete.
- **Delete guard rail:** names the entry, states whether its blob is shared with other entries ("the blob stays; 2 other entries use it") or will be removed, and whether it is currently in-sync on the device ("still on the device in slot 413 — deleting the library copy does not touch the device").
- **Slot claim rule surfaced:** assigning a slot that another entry claims shows "This replaces 'Old Bass' as the preset assigned to slot 413 (library only — the device is not touched)."
- Entry detail: name, sha, meta, tags, assigned slot, added date, provenance (imported from device slot N on date / from file), sync status, actions as above.
- **States:** *Empty:* "Your library is empty" + three CTAs: "Save presets from the device" (jumps to device browser multi-select), "Import the whole device" (runs `importSnapshot` off the latest backup — requires one; offers to run it), "Import a file." *Loading:* instant (local disk) — no designed loading state beyond first-launch index parse. *Error:* `IntegrityError` on an entry (blob fails its hash) → entry row gets a corruption badge; detail explains the file path and offers Remove Entry / Re-import from device if in-sync copy exists. `LibraryCorruptError` on open → full-screen error naming the index path, offering to move the folder aside and start fresh (never silently deletes).

### 5.5 Sync Diff View (`SyncListView`)

The heart of the librarian: device vs library, per slot.

**Precondition banner (the honest gate):** the diff requires a fully hashed snapshot. Header always shows provenance: "Compared against device contents read 12 min ago (backup 2026-09-01-1432) · 3 writes since." If no hashed snapshot exists or it is older than the last unpatched change, the list is replaced by a CTA state: "To compare, the app reads every slot (~3.5 minutes) and saves it as a backup." → **Read Device & Compare** (runs backup → diff). Because verified writes patch the snapshot (§4), applying diff rows does *not* invalidate the diff.

**Layout:** one row per slot with a non-`inSync` status by default; a filter bar with counts toggles each status: `Added (device only) 12 · Changed 3 · Missing (library only) 5 · In sync 223 · Empty 269`.

**Row:**

```
[413]  device: "Bass Prophet"   ↔ changed ↔   library: "Bass Prophet v2"     [Pull ←] [→ Push]
[097]  device: "Weird Organ"      added        library: —                    [Import ←]
[510]  device: (empty)            missing      library: "Fat Bass"           [→ Send]
```

Per-status single-row actions (every one is explicit; the diff never auto-writes, mirroring the core):

| Status | Action(s) | Cost | Guard rail |
|---|---|---|---|
| `added` (DEVICE_ONLY) | **Import to library** | instant (bytes on disk from the snapshot-backup) | none — additive |
| `missing` (LIBRARY_ONLY) | **Send to device** | ~1 s verified write | names the slot's current (empty-judged) content; §6 |
| `changed` (DIFFERS) | **Push library → device** / **Pull device → library** | push ~1 s; pull instant | push: full overwrite dialog naming the device preset. Pull: creates a *new* library entry claiming the slot; dialog states the old entry loses its slot claim but is kept |
| `inSync` | none (row is informational) | — | — |
| `empty` | none by default; row explains the judgment ("blob identical to 268 other slots") | — | — |

**Bulk apply:** toolbar **Apply…** opens `BulkApplyPlanSheet`:

- Sections by action type: "Import 12 to library", "Send 5 to device", "Conflicts (3)".
- Imports and sends are pre-checked; **conflicts (`changed`) are never pre-resolved** — each conflict row requires an explicit per-row direction choice (Push / Pull / Skip, default Skip).
- Every device-write row shows its victim: "510 · replaces empty slot" / "413 · replaces 'Bass Prophet'".
- Footer: totals, estimated time ("5 writes ≈ 5 s"), backup freshness line, and the destructive confirm button labeled with the write count: **"Write 5 Slots to Device"**.
- Execution runs as one queued operation with per-row progress ticks in the sheet; a failed write stops the batch (mirroring restore semantics), marks completed rows done, and offers Retry Remaining.

**Sync detail** (`SyncSlotDetailView`, on row selection): both sides' names/shas, judgment evidence, and the same actions with full context.

**States:** *No snapshot:* CTA state above. *Empty result (everything in sync):* "Device and library match — 243 presets in sync, 269 empty slots" with timestamp. *Snapshot running:* progress state inherited from the backup operation (this screen shows the same progress inline). *Stale:* header ages; turns into a warning ("compared 3 days ago") past 24 h with a Re-read button. *No library yet:* points at the library empty state ("Import the whole device" is one tap from here).

### 5.6 Send Preset to Slot — the drag

The flagship interaction. All payloads move through one `Transferable` type:

```swift
struct PresetTransfer: Transferable, Codable, Sendable {
    enum Source: Codable { case library(entryID: String)
                           case deviceSlot(SlotID)          // blob may need a read on drop
                           case backup(path: String, slot: SlotID) }
    let source: Source
    let displayName: String
    // FileRepresentation (.mfpreset) exported lazily for drags leaving the app
}
```

**Drag sources:** library rows (multi-drag supported), device slot rows (if the blob isn't cached locally, the drop performs a single ~400 ms read first — the drop target shows "reading…" during it), backup detail rows.

**Drop targets and semantics:**

| Drop | Meaning | Traffic |
|---|---|---|
| Library entry → device slot row | send to that slot | 1 verified write |
| N library entries → device slot row | send to consecutive slots starting there → `SendPlanSheet` listing every target + victim | N writes |
| Device slot → library list | save to library (entry assigned to source slot) | 1 read if uncached |
| Device slot → device slot | copy preset between slots | 1 read (if uncached) + 1 write |
| `.mfpreset` file (Files app / another window) → library or slot row | import / send | 0 / 1 write |
| Library or slot row → outside the app | export `.mfpreset` | 0 |

**Drop feedback:** the hovered slot row shows a destination ring plus a live caption of the consequence — `"Send 'Fat Bass v2' here — replaces 'Perc Organ'"` or `"…— replaces empty slot"`. Springloading: hovering a sidebar bank item mid-drag scrolls the list there.

**The drop is intent, not consent.** Every drop that writes to the device raises the overwrite confirmation (§6) — a compact popover anchored at the drop row for empty-judged targets (one tap: **Send**), the full dialog for occupied or unjudged targets. Escape cancels; nothing has touched the wire before confirmation.

**Non-drag equivalents (parity required):** context menu "Send to Slot…" opens a slot picker (the 512-list in a sheet, with `pickScratchSlot` preselecting the suggested safe slot when one exists and the picker filtered to "empty first"); copy/paste (⌘C a library entry or slot, ⌘V on a slot row) goes through the identical confirmation.

After any successful send: toast "Sent 'Fat Bass v2' to slot 510 — verified", with **Undo** when the victim is recoverable (§6).

### 5.7 Rename

- **Inline:** Return (or context menu → Rename) on a slot row or library row swaps the name label for a `TextField`. Live validation: printable ASCII only (illegal characters rejected at input), counter appears at 18/23, hard stop at 23. Escape cancels; Return commits.
- Device rename is queued as a quick op (name-frame only, no blob — per the protocol, ~instant), verified by read-back; the row shows a subtle progress overlay until the `WriteReport` returns, then the cache patches. Failure (`VerifyMismatchError` on the name, or timeout) reverts the row to the old name with an error toast + Retry.
- Library rename is local and instant; if the entry is in-sync with a device slot, a follow-up inline prompt offers "Also rename on device?" (default: no — the library and device may intentionally diverge; the diff will show `changed`? No — a rename changes name only, not sha, so the diff still reads `inSync` by content; the row's name mismatch is shown as a secondary hint "names differ" without changing sync status). This name-vs-content distinction is stated in the sync detail view.
- Renames are low-risk but never silent: the toast names both ("Renamed slot 413: 'Bass Prophet' → 'Bass Prophet v2'").

### 5.8 Backup (`BackupListView`, `BackupProgressSheet`)

**Backup list:** newest first; each row: date/time, coverage ("512/512" or "partial · 341/512" with a Resume button), size, source (manual / sync pass), verified badge (BackupSet.load re-hashes on open). Detail view: per-slot table (number, name, sha), Restore… entry point, Export folder (share sheet), Delete (guard: names it; extra warning if it is the *only* complete backup).

**Start:** toolbar **Back Up Now** (⌘B) anywhere in the Device or Backups sections. Pre-flight line: "Reads all 512 slots, ~3.5 minutes. The device is not modified." (Backup never writes — say so, it removes fear.)

**Progress sheet** (also mirrored in the global status bar so the sheet can be dismissed and the backup keeps running):

- Determinate bar `done/total`, current slot number + name streaming by, elapsed, median-based ETA from `ProgressEvent`, throughput ("398 ms/slot").
- **Pause** — implemented as cancel; the on-disk partial state *is* the pause state (per-slot persistence). Resumes via `resume=true`, skipping completed slots. Copy: "Paused — 341 of 512 saved. Resume anytime."
- **Cancel** — same mechanism, framed as stopping: keeps the partial backup, labeled partial in the list.
- Interruption (app suspended past its background allowance, device unplugged, transport error): identical outcome — a partial, resumable backup plus a banner on return: "Backup interrupted at slot 342 — Resume?" Nothing is ever lost or invalid.
- While a backup runs, the device queue blocks other device ops (§3); Pause is the escape hatch if the user urgently needs a write.

### 5.9 Restore (`RestorePlanSheet`)

Entered from a backup's detail view ("Restore…"), or per-slot from `SlotDetailView` ("Restore this slot from backup…").

**Scope step:** Full device (all covered slots) / Selected slots (multi-select table) / "Only slots that differ from this backup" (requires a current hashed snapshot; offers to read first).

**Plan step:** every planned write listed with its victim: `"413 ← 'Bass Prophet' (backup) — replaces 'Bass Prophet v2' (on device now)"`. If cached names are older than 10 minutes, a quick names refresh (~2 s) runs automatically before the plan renders, so victims are named from fresh data. Footer: write count, estimate (~1 s/slot verified), backup freshness of *other* backups ("your newest full backup is this one" / "newer backup exists from …"), destructive confirm labeled **"Restore N Slots"**. A full-512 restore adds one final alert: "This overwrites every preset on the device. 512 slots." — Confirm / Cancel.

**Execution:** progress identical to backup's (done/total, current slot, ETA), each write verified. **Stops at the first failure** (core semantics): the sheet then shows completed count, the failing slot and error, and remaining slots, with **Retry from slot N** (restore with the remaining slot list) and Close. A slot torn by a failed write is flagged in the browser (§9) until a successful re-write.

Restores from a backup lacking `meta_hex` for a slot (old phase-0 index): that slot appears in the plan pre-disabled with "no meta recorded — re-backup to restore this slot" (the core's own message).

---

## 6. Destructive-action guard rails (unified rules)

One component (`OverwriteConfirmation`) renders every device-write confirmation, so the rules cannot drift per screen:

1. **Name the victim, always.** Title: `Replace "Perc Organ" in slot 413?` For empty-judged targets: `Send to slot 510? (empty)` with the judgment evidence one tap away. For *unjudged* targets: `Slot 413 — contents unknown` and the dialog offers **Read First** (~1 s) as the primary action, with "Overwrite Anyway" secondary.
2. **State recoverability.** One of: "The current preset is in your library ('Perc Organ')" / "…is in backup 2026-09-01-1432" / **"…is not in your library or any backup — it will be lost"** (bold path). When unrecoverable, the dialog offers **Save a Copy First** (single read → library, ~1 s) as a one-tap escape.
3. **Surface backup freshness.** Footer line in every such dialog: "Last full backup: today 14:32 (3 writes since)" or "No complete backup yet — consider backing up first (⌘B)" with a Back Up Now shortcut.
4. **Confirm buttons state the action and count**, never "OK": "Replace Preset", "Write 5 Slots", "Restore 512 Slots".
5. **Severity scales:** empty-judged target → anchored one-tap popover; single occupied/unjudged target → alert-style dialog; bulk/restore → full plan sheet; full-device restore → plan sheet + final alert.
6. **Undo where honest.** After any overwrite whose victim's exact bytes exist locally (backup covering the slot with matching sha, or a library blob), a 10 s toast offers **Undo**, and ⌘Z works via `UndoManager` — undo enqueues a verified write of the victim back. When bytes are not held, no undo is offered and none was promised.
7. **Writes are verified by default and the UI never opts out.** There is no "skip verification" surface in v1; `verify=false` exists in the core for tooling, not for this app.
8. **Cancellation honesty:** cancelling mid-write tears the slot (core behavior). The Cancel control on single writes is disabled during the ~1 s burst (too short to matter); batch operations cancel *between* slots only. If a tear does occur (transport failure mid-chunk), §9's torn-slot handling engages.

---

## 7. Keyboard and pointer support

Full hardware-keyboard operation of the browsing and sending flows.

| Key | Context | Action |
|---|---|---|
| ↑ / ↓ | any list | move selection |
| ⌥↑ / ⌥↓ | slot list | previous / next bank section |
| type-ahead | any list | select by name/number prefix |
| ⏎ | slot / library row | rename inline |
| Space | slot / library row | toggle detail focus (quick look) |
| ⌘C / ⌘V | slot & library rows | copy preset / paste (= send, with confirmation) |
| ⌘F | any list | focus search |
| ⌘R | device section | refresh names |
| ⌘B | anywhere | Back Up Now |
| ⌘Z / ⇧⌘Z | anywhere | undo/redo overwrites (§6.6) |
| Delete | library row | delete entry (guarded) |
| ⌘1…⌘4 | anywhere | sidebar sections Device / Library / Sync / Backups |
| Esc | dialogs, drag, inline rename | cancel |
| Tab | split view | move focus between columns (`focusSection`) |

Pointer: rows get hover highlight; drag affordances per §5.6; context menus everywhere a swipe action exists (parity rule: every swipe action has a context-menu and keyboard path).

---

## 8. Empty / loading / error state catalog

| Screen | Empty | Loading | Error |
|---|---|---|---|
| Connect | no endpoints → instructions + Demo CTA | endpoint connecting spinner | ports-seen list; retry |
| Slot browser | n/a (512 rows always) | redacted names streaming (~2 s) | banner + retry; partial names kept |
| Slot detail | unread blob → "Read Slot" CTA | 400 ms skeleton + queue position | inline retry; torn/verify-failed badges |
| Library | 3-CTA teaching state | none (local) | corruption badges; index-corrupt full screen |
| Sync | no snapshot → cost-stating CTA; all-in-sync → success summary | backup progress inline | diff precondition failures (hashless snapshot is impossible by construction — the app only diffs off backups) |
| Backups | "No backups yet — first one takes ~3.5 min" + CTA | list is local; progress sheet for active | partial rows w/ Resume; `IntegrityError` on open names the bad slot file |
| Restore plan | backup covers 0 requested slots → explain | quick names refresh before plan | stop-at-first-failure state w/ Retry-from |
| Status bar | "Idle" | current op + mini progress | last op failed chip → Operations popover |

---

## 9. Error mapping (core → UX)

| Core error | Surface | Behavior |
|---|---|---|
| `DeviceNotFoundError` | Connect screen | list every seen port; retry |
| `TransportError` / unplug mid-op | status bar + banner | op fails cleanly; state → `noDevice`; cache kept, marked stale; resumable ops resumable |
| `DeviceTimeoutError` | toast on quick ops; op-failure state on long ops | "Device stopped responding (slot N, name read)" + Retry; suggest cable/power after 2nd consecutive |
| `ReplyMismatchError` | silent single retry, then toast | the lag defense already retried; surfacing means something is really wrong |
| `VerifyMismatchError` | modal alert | "Write to slot 413 did not verify — the device holds different data than was sent." Details: expected/actual sha, first difference. Actions: Write Again / Leave. Slot badged "verify failed" until a clean verified write |
| `ChunkNotAckedError` / `WriteAbortedError` | modal alert | slot is **torn**: badge "torn — contents unreliable" in the browser; alert offers Write Again (primary) / Restore from Backup (if covered); badge persists until a verified write succeeds |
| `OperationCancelledError` | expected path | pause/partial framing (§5.8); on restore, `.completed` renders the done list |
| `IntegrityError` | per-entry / per-backup badges | names the file; never auto-deletes |
| `InvalidNameError` | prevented at input | unreachable in practice; if raised, toast with the rule (≤ 23 printable ASCII) |
| `SlotOutOfRangeError`, `BlobSizeError` | assertion-level | programmer error; generic failure toast + log |

---

## 10. Connection state machine

```swift
enum ConnectionState: Equatable, Sendable {
    case noDevice(seen: [MIDIEndpointInfo])
    case connecting(endpoint: MIDIEndpointInfo)
    case connected(DeviceInfo)          // port names; slots=512 assumed, --slots analog in settings
    case demo(DemoProfile)
    // error is an event that lands in .noDevice(seen:) with a banner, not a resting state
}
```

- Status capsule (sidebar footer + status bar): "MicroFreak · Connected", "Connecting…", "No Device", "Demo Mode · Factory Fresh" (distinct tint; always visible in demo).
- Transitions only via explicit user action or transport failure. Attach while in demo → banner offering to switch; switching mid-operation is refused until the op finishes or is paused. Detach while connected → §9 transport row. Demo → real keeps the library and backups (they are device-independent); the slot cache and diff are dropped (different device identity — each snapshot/backup records which device identity produced it, `real` vs `demo:<profile>`, and the app never diffs or restores across identities without an explicit warning).

---

## 11. SwiftUI view structure and the view-model layer

### 11.1 View tree

```
MicroFreakLibrarianApp
└─ WindowGroup
   └─ RootView                                  // owns AppModel via @State, injects via .environment
      ├─ NavigationSplitView
      │  ├─ SidebarView                          // SidebarSelection (device(bank?), library(tag?), sync, backups)
      │  ├─ ContentColumn                        // switch on selection
      │  │   ├─ SlotListView        → SlotRowView, BankSectionHeader
      │  │   ├─ LibraryListView     → LibraryRowView
      │  │   ├─ SyncListView        → SyncRowView, SyncFilterBar, SyncProvenanceHeader
      │  │   ├─ BackupListView      → BackupRowView
      │  │   └─ ConnectView                      // when .noDevice and device section selected
      │  └─ DetailColumn
      │      ├─ SlotDetailView
      │      ├─ LibraryEntryDetailView
      │      ├─ SyncSlotDetailView
      │      └─ BackupDetailView
      ├─ .safeAreaInset(bottom): StatusBarView   // ConnectionCapsule + ActiveOperationView → OperationsPopover
      ├─ .sheet: BackupProgressSheet | RestorePlanSheet | BulkApplyPlanSheet | SendPlanSheet | ConnectSheet
      ├─ .alert: OverwriteConfirmation (single-target form) | error alerts (§9)
      └─ .onDrop / .draggable wiring via PresetTransfer (Transferable)
```

### 11.2 The protocol seam (what FreakCore must eventually provide)

The UI target defines these protocols and value types itself; FreakCore later conforms. `DemoDeviceSession` (the Swift port of `SimulatedMicroFreak`) conforms first, which is what makes the app buildable before the core exists.

```swift
// MARK: Value types — direct transliterations of microfreak.model (all Sendable, Equatable)

struct Preset      { let name: String; let blob: Data /*4672*/; let meta: Data /*9*/
                     var sha256: String; func renamed(_ n: String) -> Preset }
struct SlotRecord  { let slot: SlotID; let name: String?; let sha256: String?
                     let metaHex: String?; let blob: Data? }
struct DeviceSnapshot { let takenAt: Date; let records: [SlotRecord]
                        let deviceIdentity: DeviceIdentity  // real | demo(profile)
                        func record(_ s: SlotID) -> SlotRecord?; var hasHashes: Bool }
struct WriteReport { let slot: SlotID; let sha256: String  // "" for rename
                     let name: String; let verified: Bool? // true or nil; false never occurs
                     let duration: TimeInterval }
struct ProgressEvent { let done: Int; let total: Int; let slot: SlotID
                       let name: String?; let elapsed: TimeInterval; let eta: TimeInterval? }
typealias ProgressHandler = @Sendable (ProgressEvent) -> Void

enum SlotStatus: String { case empty, added /*deviceOnly*/, inSync, missing /*libraryOnly*/, changed /*differs*/ }
struct SlotDiffRow { let slot: SlotID; let status: SlotStatus
                     let device: SlotRecord?; let library: LibraryEntry? }
struct SyncDiff    { let rows: [SlotDiffRow]; func rows(_ s: SlotStatus) -> [SlotDiffRow] }

struct LibraryEntry { let id: String; let name: String; let sha256: String; let metaHex: String?
                      let slot: SlotID?; let addedAt: Date; let tags: [String] }

enum FreakError: Error {  // mirrors the core hierarchy; carries the payloads §9 needs
    case deviceNotFound(inputs: [String], outputs: [String])
    case transport(underlying: Error), timeout(stage: String, slot: SlotID?)
    case replyMismatch(requested: SlotID, replied: SlotID, attempts: Int)
    case chunkNotAcked(slot: SlotID, chunkIndex: Int)
    case writeAborted(stage: String, slot: SlotID, chunksSent: Int)
    case verifyMismatch(slot: SlotID, expectedSHA: String, actualSHA: String,
                        expectedName: String, actualName: String, firstDifference: Int?)
    case cancelled(done: Int, total: Int, completed: [WriteReport])
    case integrity(path: String, detail: String)
    case invalidName(String), entryNotFound(String), libraryCorrupt(path: String, detail: String)
}

// MARK: Device session — one per open transport; the actor serializes (the core's lock)

protocol DeviceSession: Actor {
    nonisolated var identity: DeviceIdentity { get }
    func name(of slot: SlotID) async throws -> String                       // ~1 ms
    func read(_ slot: SlotID) async throws -> Preset                        // ~400 ms
    func snapshot(readBlobs: Bool, keepBlobs: Bool, slots: [SlotID]?,
                  progress: ProgressHandler?) async throws -> DeviceSnapshot
    func write(_ preset: Preset, to slot: SlotID) async throws -> WriteReport   // verified, always
    func rename(_ slot: SlotID, to name: String) async throws -> WriteReport   // name frame only
    func backup(to dir: URL, slots: [SlotID]?, resume: Bool,
                progress: ProgressHandler?) async throws -> BackupSetHandle    // reads only
    func restore(from backup: BackupSetHandle, slots: [SlotID]?,
                 progress: ProgressHandler?) async throws -> [WriteReport]     // stops at first failure
    func close() async
}
// Cancellation contract: all long methods poll Task.isCancelled between slots
// (mapped onto the core's CancelToken) and throw FreakError.cancelled.

// MARK: Discovery / connection

protocol DeviceConnecting: Sendable {
    var endpointEvents: AsyncStream<[MIDIEndpointInfo]> { get }   // fires on attach/detach
    func connect(to endpoint: MIDIEndpointInfo?) async throws -> any DeviceSession // nil = discover
    func makeDemo(_ profile: DemoProfile) -> any DeviceSession
}

// MARK: Library (local; usable with no device)

protocol LibraryStoring: Actor {
    func entries() throws -> [LibraryEntry]
    func preset(for id: String) throws -> Preset                  // re-hashed; .integrity on rot
    func add(_ p: Preset, slot: SlotID?, tags: [String]) throws -> LibraryEntry
    func renameEntry(_ id: String, to name: String) throws -> LibraryEntry
    func assignSlot(_ id: String, slot: SlotID?) throws           // clears any other claim
    func setTags(_ id: String, tags: [String]) throws
    func remove(_ id: String) throws
    func slotMap() throws -> [SlotID: LibraryEntry]
    func importSnapshot(_ s: DeviceSnapshot, skipExpendable: Bool) throws -> [LibraryEntry]
    nonisolated var changes: AsyncStream<Void> { get }
}

// MARK: Backups on disk

protocol BackupCataloging: Actor {
    func list() throws -> [BackupSummary]        // createdAt, coveredSlots, isComplete, identity, path
    func open(_ id: BackupID) throws -> BackupSetHandle   // load() re-hashes; throws .integrity
    func delete(_ id: BackupID) throws
    nonisolated var changes: AsyncStream<Void> { get }
}
protocol BackupSetHandle: Sendable {
    var summary: BackupSummary { get }
    func covers(_ slot: SlotID) -> Bool
    func records() -> [SlotRecord]               // names+shas+meta; blobs lazy
    func preset(_ slot: SlotID) throws -> Preset // throws .integrity when metaHex absent
}

// MARK: Pure functions (no protocol needed — free functions the UI can stub trivially)

func syncDiff(snapshot: DeviceSnapshot, entries: [LibraryEntry], threshold: Int = 3) -> SyncDiff
func expendableSlots(in records: [SlotRecord], threshold: Int = 3) -> Set<SlotID>
func pickScratchSlot(in records: [SlotRecord], preferFrom: SlotID, excluding: Set<SlotID>) -> SlotID?
func shaCensus(_ records: [SlotRecord]) -> [String: Int]
func validateName(_ s: String) -> Result<String, FreakError>   // ≤23 printable ASCII
```

### 11.3 View models (`@MainActor @Observable`; views bind to these, never to the seam directly)

```swift
@MainActor @Observable final class AppModel {
    var connection: ConnectionState
    let operations: DeviceOperationQueue
    let slots: SlotBrowserModel
    let library: LibraryModel
    let sync: SyncModel
    let backups: BackupsModel
    let freshness: FreshnessModel        // latestCompleteBackup, writesSinceBackup, namesAsOf
    // intents
    func connect(_ endpoint: MIDIEndpointInfo?) ; func startDemo(_ p: DemoProfile) ; func disconnect()
}

@MainActor @Observable final class DeviceOperationQueue {
    enum Kind { case quick, exclusiveLong }              // long ops block; quick ops FIFO behind them
    struct Running { let title: String; let progress: ProgressEvent?; let cancellable: Bool }
    var current: Running?
    var pending: [PendingDescriptor]
    var recent: [CompletedDescriptor]                    // feeds the Operations popover
    @discardableResult
    func enqueue<T>(_ title: String, kind: Kind,
                    _ body: @escaping (any DeviceSession) async throws -> T) -> Task<T, Error>
    func cancelCurrent()
}

@MainActor @Observable final class SlotBrowserModel {
    struct Row { let id: SlotID; var name: LoadState<String>   // .loading/.loaded/.failed
                 var sha: String?; var judgment: Judgment      // .unjudged/.empty(evidence)/.occupied
                 var syncStatus: SlotStatus?; var flags: Set<SlotFlag> } // .torn, .verifyFailed, .busy
    var rows: [Row]; var namesAsOf: Date?; var searchText: String
    func refreshNames() ; func readSlot(_ id: SlotID)
    func rename(_ id: SlotID, to: String)
    func saveToLibrary(_ ids: [SlotID], tags: [String])
    func send(_ transfer: PresetTransfer, to: SlotID) -> OverwritePlan   // plan feeds the confirmation UI
    func confirm(_ plan: OverwritePlan)                                  // the only path to the wire
    func applySnapshot(_ s: DeviceSnapshot) ; func patch(with report: WriteReport)
}

@MainActor @Observable final class SyncModel {
    enum State { case needsSnapshot(estimate: TimeInterval)
                 case comparing(ProgressEvent)                            // the backup pass
                 case ready(SyncDiff, provenance: SnapshotProvenance)
                 case failed(FreakError) }
    var state: State ; var filter: Set<SlotStatus>
    func readDeviceAndCompare()                                           // backup → diff
    func apply(_ row: SlotDiffRow, direction: ApplyDirection) -> OverwritePlan?  // nil = local-only (import/pull)
    func bulkPlan(selections: [SlotDiffRow: ApplyDirection]) -> BulkApplyPlan
    func execute(_ plan: BulkApplyPlan)
}

@MainActor @Observable final class BackupsModel {
    var items: [BackupSummary] ; var active: ProgressEvent? ; var resumable: BackupSummary?
    func backUpNow() ; func pause() ; func resume(_ id: BackupID)
    func restorePlan(from: BackupID, scope: RestoreScope) async -> RestorePlan   // names victims (quick refresh)
    func executeRestore(_ plan: RestorePlan)
    func delete(_ id: BackupID)
}

struct OverwritePlan {         // one struct powers §6 for singles, bulks, and restores
    struct Item { let target: SlotID; let incomingName: String
                  let victim: Victim   // .empty(evidence) | .named(String, recoverable: Recoverability) | .unknown
                }
    let items: [Item]; let estimatedDuration: TimeInterval
    let backupFreshness: FreshnessSnapshot
    var severity: Severity     // .popover / .dialog / .planSheet / .planSheetPlusFinalAlert
}
```

Threading contract: VMs hop to the `DeviceSession` actor via `DeviceOperationQueue.enqueue` only; `ProgressHandler` events are re-dispatched to `@MainActor` by the queue; VMs are the only writers of their own state. Library/backup `changes` streams drive invalidation.

---

## 12. Demo mode specifics

- `DemoDeviceSession` wraps the Swift port of `SimulatedMicroFreak` (`reply_lag` on, per the porting checklist) behind the same `DeviceSession` protocol.
- **Profiles:** `factoryFresh` (named low slots + 269 identical Inits — the reference device's shape, so emptiness judgments are real), `livedIn` (scattered user presets, few expendables), `full` (zero expendables — exercises the "no scratch slot, ask the human" path), `flaky` (injected timeouts, a `failChunkAt` torn write — for building §9's error states without hardware).
- **Honest pacing by default:** the demo session sleeps ~1 ms/name and ~400 ms/blob so progress bars, ETAs, pause/resume, and the 3.5-minute backup are experienced truthfully. A Settings toggle "Fast demo timing (20×)" exists for development.
- Demo snapshots/backups are stamped `demo:<profile>` and never diffed or restored against a real device without an explicit cross-identity warning (§10).
- Every screen, flow, dialog, drag, and error state in this spec must be reachable in demo mode; that is the UI's definition of done before hardware testing.

---

## 13. Open questions (flagged, not blocking)

1. **Background execution:** a 3.5-minute backup exceeds iPadOS's default background allowance; v1 accepts pause-on-suspend (resume is cheap and designed-for). Investigate audio-session or extended-execution entitlements later.
2. **Rename verify blind spot:** the protocol notes back-to-back same-slot reads can't distinguish a lagged reply (write-protocol.md, "Quirks"). The UI treats a verified rename as verified; if hardware sessions show phantom verifies, add a delayed re-read.
3. **Slot 384 boundary and per-chunk pacing** are core-level open assumptions (core-api §5); no UI impact beyond trusting `WriteReport`.
4. **Multiple libraries / iCloud sync of the library folder** — out of scope for v1; the `LibraryStoring` seam doesn't preclude it.

---

**Summary of key decisions:** The app is built names-first around the protocol's cost asymmetry — the 512-slot browser is live in ~2 seconds while every blob-scale operation is an explicit, resumable, progress-barred queue item, and the one "read everything" operation is always persisted as a backup, so sync freshness and backup freshness are the same thing. All device traffic flows through a single serialized `DeviceOperationQueue` against a `DeviceSession` actor protocol, with verified writes patching the cached snapshot in place, and a `DemoDeviceSession` (simulated device, reply-lag on, honest pacing) conforming first so the entire UI — including every error and torn-write state — is buildable and demoable before FreakCore exists. Destructive safety is centralized in one `OverwritePlan`/confirmation component enforcing invariant rules: every overwrite names its victim and its recoverability, backup freshness appears in every destructive dialog, drops and pastes are intent rather than consent, and undo is offered exactly when the victim's bytes are actually held.