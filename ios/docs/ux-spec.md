# Freak Librarian — iPad UX Specification

**Version 2.0 — 2026-09-01.** Supersedes the v1 draft in full.

**Scope:** screens, flows, states, interaction rules, and the app-structure contract (navigation, view inventory, view-model responsibilities, state ownership) for the SwiftUI iPad app `FreakLibrarian` at `/Users/ericbrookfield/Development/mfcap/ios/App`, built on the `FreakCore` Swift package. Behavior and structure only; no visual-brand direction beyond the semantic color/badge roles defined here.

**Ground truth:** `/Users/ericbrookfield/Development/mfcap/docs/core-api.md` and `/Users/ericbrookfield/Development/mfcap/docs/write-protocol.md`. Where this spec restates timing or protocol behavior, those documents win. The UI never touches frames; it talks to FreakCore's slot/preset API only.

**App identity (required):** bundle id `com.ericbrookfield.freaklibrarian`, display name **"Freak Librarian"**, iPad-only, iPadOS 17.0+, landscape-first (portrait supported, never required). *Note: `App/project.yml` currently carries `com.ericbrookfield.microfreak-librarian` / "MicroFreak Librarian" — it must be brought to the values above in the next project pass.*

**User and posture:** one musician, standing at the synth, iPad Pro 13-inch on a stand or held in one arm, landscape. Often only one free hand, often mid-performance-prep. Frequently the synth is *not* plugged in — the app must be fully usable in Practice Mode against the simulated device.

---

## 1. Design principles (derived from the protocol, not taste)

1. **Names are free; blobs are expensive.** A name read is ~1 ms, a blob ~400 ms, a full hashed pass ~211 s. Every screen is names-first: the 512-slot browser is interactive within ~2 s of connecting; nothing ever silently starts a multi-minute read. Blob-scale work is always explicit, progress-barred, ETA'd, and cancellable.
2. **The full read pass is always a backup.** A hashed snapshot and a backup are the same wire traffic, so the app has exactly one "read everything" operation and it always persists in the phase-0 backup format. Refreshing the sync view *produces* a backup; backup freshness is a byproduct of using the app.
3. **One transaction at a time, visibly.** The core session serializes; the app models this as one device-operation queue with one status surface. The UI never pretends the device can do two things at once, and never invents a second spinner vocabulary.
4. **Emptiness is a verdict, not a fact.** A slot is "empty" only after a content judgment from the core (`findExpendable`: sha duplicated ≥ 3 times among the read records, or a blank successfully-read name). Until hashes exist a slot is *unjudged* and the UI says so. The string "Init" is never special; a failed name read is unknown, never empty.
5. **Every overwrite previews its victim.** No device write proceeds without showing what it replaces: the occupant's name, whether the slot is judged expendable, and whether the occupant's bytes are recoverable (library or backup). The sync diff computes; only the user writes.
6. **Practice Mode is a first-class device, honestly labeled and honestly paced.** Every screen, flow, and error state is reachable against `SimulatedMicroFreak`, and simulated state is never mistakable for hardware state (§11).
7. **Verified means verified.** Writes go through the core's read-back-and-hash-compare path, always; there is no "skip verification" control anywhere in the app. `WriteReport.verified` is `true` or the operation threw — the UI has no "maybe written" state.

---

## 2. Slot identity

- Core addressing: 0-based `0…511`; `bank = slot / 128`, `pos = slot % 128`.
- Display addressing: **1-based `1…512`**, matching the synth's panel — the user's mental model.
- One conversion point: the existing `SlotID` value type (`App/Sources/Support/SlotID.swift`) owns the mapping. No other UI code does slot arithmetic.

```
SlotID.raw        0…511   (core, wire, FreakCore API)
SlotID.display    1…512   (every list, dialog, toast, badge)
SlotID.bank       0…3     (display label "Bank 1 · 1–128" … "Bank 4 · 385–512")
```

Diagnostic detail views may show both once — `slot 412 (core 411)` — every other surface uses the display number only, 3-digit, monospaced digits.

---

## 3. Navigation model

Three-column `NavigationSplitView`, landscape-first. Works in full screen, Split View, Slide Over, and Stage Manager (columns collapse per standard SwiftUI behavior; nothing in this spec depends on a fixed width beyond the reachability rules in §13).

```
Sidebar                     Content column                 Detail column
─────────────────────────   ───────────────────────────    ─────────────────────────
DEVICE                      SlotListView                   SlotDetailView
  All Slots                   (512 rows, bank sections)
  Bank 1 · 1–128            LibraryListView                LibraryEntryDetailView
  Bank 2 · 129–256          SyncListView                   SyncSlotDetailView
  Bank 3 · 257–384          BackupListView                 BackupDetailView
  Bank 4 · 385–512          ConnectView (when no device
LIBRARY                       and Device is selected)
  All Presets
  <tag> …
SYNC
BACKUPS
─────────────────────────
[Connection status capsule]
```

- Sidebar bank rows are **jump targets**, not filters: they scroll the always-complete slot list to that section.
- Library tags appear as sidebar children; selecting one filters the library list. No folders in v1 (§6).
- **Global status bar** — a `safeAreaInset(edge: .bottom)` strip across the whole split view (`StatusBarView`). Left: connection capsule (§12). Center-left in Practice Mode: the practice capsule (§11). Right: the active device operation with mini progress bar and a Cancel/Pause control, or "Idle". Tapping opens the **Operations popover**: current op, queued ops, recent completions and failures. This is the only home of device busyness.
- **Practice banner** (§11) sits above the content column whenever the session is simulated.
- Sheets (modal): `BackupProgressSheet`, `RestorePlanSheet`, `BulkApplyPlanSheet`, `SendPlanSheet`, `ConnectSheet`. Alerts: single-target overwrite confirmation, error alerts per §14.

Navigation state (`SidebarSelection`, selected slot/entry/backup) lives in `AppModel` and is restorable via `SceneStorage` so a relaunch lands where the user left off (selection only — never a resumed device operation).

---

## 4. Data freshness model

Three tiers of knowledge about the device, all surfaced explicitly, none ever implied:

| Tier | How obtained | Cost | Unlocks |
|---|---|---|---|
| **Names** | names-only snapshot (`readBlobs: false`) | ~1–2 s / 512 | browsable slot list; search; rename |
| **Per-slot content** | single `read(slot)` | ~400 ms | that slot's sha, judgment, full detail |
| **Full content** | full pass = backup | ~211 s, resumable | sync diff; emptiness judged everywhere; fresh backup |

Rules:

- On connect (hardware or practice): the app automatically runs the names-only snapshot. This is the **only** device operation ever started without an explicit user action.
- Every verified write returns name + sha in its `WriteReport`; the app **patches the cached snapshot in place**, so the sync diff stays live after applies with zero re-reads. A rename patches the cached name.
- Every cached record carries `lastConfirmed: Date`. The synth can be edited from its own panel at any time, so list headers state provenance, never truth: "Names as of 14:32 · Refresh".
- **Backup freshness is a first-class value** (`FreshnessModel`): `latestCompleteBackup: (date, path)?` and `writesSinceBackup: Int` (each device write increments; a completed full backup resets). Shown in the sidebar footer, the Sync header, and inside every destructive dialog.
- Snapshots and backups are stamped with a device identity — `hardware` or `practice:<profile>` — and the app never diffs, restores, or "undoes" across identities without the explicit cross-identity warning (§11).

---

## 5. Device slot browser (`SlotListView`)

The home screen. All 512 slots, always — never paged, never truncated, populated from cache instantly on revisit.

**Row anatomy** (`SlotRowView`, ≥ 52 pt tall):

```
[413] Bass Prophet                                   ●   ↔   ⟳
  │     │                                            │   │   └ activity: queued/running op on this slot
  │     │                                            │   └── sync badge (only when a current diff exists):
  │     │                                            │       added / changed / missing / in-sync / empty
  │     └ name (23-char max, monospaced-friendly)    └────── judgment dot (§10): filled = real preset,
  └ display number, 3-digit, monospaced                      outline+dim = expendable, hollow = unjudged
```

- Sectioned by bank, sticky headers ("Bank 4 · 385–512"), with per-section counts once judged ("97 presets · 31 empty").
- **Search** (`.searchable`): filters by name substring and slot number over the cached names — instant, zero device traffic. Search never triggers reads.
- **Lazy blob detail:** rows never trigger blob reads. Selecting a row shows `SlotDetailView`; if that slot's sha is unknown, the detail offers the explicit ~1 s **Read Slot** action (§7). Scrolling the list costs nothing.
- A slot whose name read failed (`name == nil`) renders "— read failed" with the unknown (hollow) dot — never "empty" — and offers Retry in its context menu and detail view.
- **Toolbar:** Refresh Names (shows relative age), search, Select (multi-select), Back Up Now.
- **Context menu / swipe actions per row:** Save to Library · Send Preset Here… · Rename · Read Now (single ~1 s hash of just this slot) · Show in Sync · Copy / Paste (paste = send, with the §9 confirmation).
- **Multi-select:** Save N to Library (instant when bytes are already on disk from the latest backup; otherwise a plan sheet stating "~400 ms × N") · Send N presets starting at slot… (plan sheet listing every target and victim).

**States**

- *Initial names pass:* numbered rows render immediately with redacted name placeholders; names stream in (~2 s total — shimmer, not a wait screen).
- *Device busy (exclusive long op):* list stays fully browsable from cache; per-row device actions disabled with the reason inline ("Backup running — 2:10 left"); progress lives in the status bar only.
- *Disconnected:* list remains, desaturated; header banner "Showing last known state from 14:32 — no device." Device actions disabled; library-side actions (save-from-cache, browse) still work.
- *Names pass failed:* inline banner with the mapped error (§14) + Retry; already-read rows stay populated.

---

## 6. Local library (`LibraryListView`, `LibraryEntryDetailView`)

The local collection — fully functional with no device attached. Backed by FreakCore's `Library` (content-addressed blobs + index).

**v1 scope, kept honest:** flat list + **tags** (the core already stores them) + one optional **slot assignment** per entry. **No folders, no smart groups, no ratings, no iCloud sync** in v1 — none of it exists in the core, and the UI does not fake it. Tags are plain strings, assigned in the entry detail, filterable from the sidebar; that is the entire organizational model.

**Row:** name · tag chips · slot-claim chip ("→ 413" or none) · sync hint when a current diff exists (in-sync / differs / not on device).

- Toolbar: search (name, tag) · sort (name / date added / slot) · Import File (`.mfpreset` or raw 4672-byte blob via file importer) · Import Device… (runs `importSnapshot` off the latest complete backup; offers to run a backup if none exists; expendable slots skipped by default, stated in the sheet).
- Context menu: Send to Slot… · Assign Slot… (local only — sets the entry's desired slot; the diff then shows `missing` until sent) · Clear Slot Assignment · Rename (inline, local, instant) · Duplicate · Tags… · Export (share sheet, `.mfpreset`) · Delete.
- **Slot-claim rule surfaced:** assigning a slot another entry claims shows "This replaces 'Old Bass' as the preset assigned to slot 413. Library only — the device is not touched." (The core clears the other claim.)
- **Delete guard:** names the entry; states whether the blob file survives ("2 other entries share these bytes") or is removed; states device impact honestly ("still on the device in slot 413 — deleting the library copy does not touch the device").

**States:** *Empty* — teaching state with three CTAs: "Save presets from the device", "Import the whole device" (via backup), "Import a file". *Loading* — local disk; no designed wait beyond first index parse. *Errors* — `IntegrityError` on an entry: corruption badge on the row, detail names the blob path, offers Remove Entry or Re-import (when an in-sync device copy exists); `LibraryCorruptError` on open: full-screen error naming the index path, offering to move the folder aside and start fresh — never silently deletes anything.

---

## 7. Preset detail (`SlotDetailView` / `LibraryEntryDetailView`)

One layout serves both, differing only in the action row. Fields, top to bottom:

1. **Name** — large, editable in place (§8.2 rename flow for device slots; instant local rename for library entries). Character counter appears at 18/23.
2. **Slot / claim line** — device: "Slot 413 · Bank 4"; library: assigned-slot chip or "no slot assigned".
3. **Judgment line** (device slots) — "Preset" / "Empty — identical to 268 other slots" / "Empty — blank name" / "Unjudged — content not read yet" / "Unknown — name read failed". The evidence is the copy; the app never says just "empty".
4. **Category byte** — the preset's meta byte 7 (long-0x52 payload[10]), shown as `Category 0x0B` with a friendly label *only* when the (hardware-verified) mapping table in `Formatters.swift` knows it; otherwise raw hex with an info popover: "Category as stored by the synth. Labels appear once the mapping is confirmed against hardware." Meta is round-tripped verbatim by the core; **v1 never edits the category byte** — display only.
5. **SHA-256** — first 12 chars shown, monospaced; tap to expand full hash / copy. Absent → the **Read Slot** button ("about 1 second") replaces this block; that is the lazy-blob trigger, and it also patches the browser row's judgment.
6. **Meta** — collapsed "Advanced" disclosure: 18-char meta hex, attribute byte, last-confirmed timestamp.
7. **Cross-references** — device slot: which library entry claims this slot; which backups cover it (per-backup sha match/mismatch chips). Library entry: provenance ("imported from device slot 97 on 2026-09-01" / "imported from file"), duplicate-sha note ("bytes shared with 2 other entries").
8. **Slot history** (device slots) — reverse-chronological journal of what *this app* has observed and done to this slot, from the local history store (§15): snapshot observations (name/sha seen), verified writes (source preset + name + sha), renames (old → new), restores (which backup), verify failures, torn writes, cancels. Each row: icon, one-line summary, relative time. Capped display at 20 with "Show all". Header caveat, always visible: "History of this app's activity — changes made on the synth itself appear only as differences at the next read."

**Actions (device slot):** Save to Library (with tags) · Send to Another Slot… · Rename · Overwrite from Library… · Restore this slot from backup… (picker over covering backups). **Actions (library entry):** Send to Slot… · Assign Slot · Export · Duplicate · Delete.

**States:** unread blob → Read Slot CTA (above); reading → 400 ms skeleton with queue position if queued; read failed → inline error + Retry; slot flagged `verifyFailed` or `torn` → the persistent badge and its recovery actions (§14).

---

## 8. Writing to the device

### 8.1 Send / drag a preset to a slot

All payload movement goes through one `Transferable` type (`PresetTransfer`, already in `App/Sources/Models/`): source is a library entry, a device slot, or a backup row; the display name rides along for drop feedback; an `.mfpreset` file representation is exported lazily for drags leaving the app.

**Drag sources:** library rows (multi-drag supported) · device slot rows (if the blob isn't cached, the *drop* performs one ~400 ms read first — the target shows "reading…") · backup detail rows.

**Drop targets and semantics:**

| Drop | Meaning | Wire cost |
|---|---|---|
| Library entry → slot row | send to that slot | 1 verified write (~1 s) |
| N library entries → slot row | send to N consecutive slots → `SendPlanSheet` | N verified writes |
| Slot row → library list | save to library, entry assigned to source slot | 1 read if uncached |
| Slot row → slot row | copy between slots | ≤1 read + 1 verified write |
| `.mfpreset` file → library / slot row | import / send | 0 / 1 write |
| Row → outside the app | export `.mfpreset` | 0 |

**Drop feedback:** hovered slot row shows a destination ring plus a live consequence caption — "Send 'Fat Bass v2' here — replaces 'Perc Organ'" or "… — replaces empty slot (Init-duplicate)". Hovering a sidebar bank row mid-drag springloads the list to that bank.

**The drop is intent, not consent.** Every drop that would write raises the §9 confirmation *anchored at the drop row* — a one-tap popover when the victim is judged expendable, the full dialog otherwise. Nothing touches the wire before confirmation; Esc or tap-outside cancels.

**Non-drag parity (required):** context-menu "Send to Slot…" opens a slot picker — the 512-row list in a sheet, empty-judged slots grouped first, with the core's `pickScratchSlot` suggestion preselected when one exists ("Suggested: slot 509 — empty"). Copy/paste on rows goes through the identical confirmation. Every drag flow must be completable by taps alone (§13).

### 8.2 Verified-write feedback

A single write is one queued quick op with four visible phases on the target row and in the status bar:

1. **Queued** — row activity glyph; status bar shows position if behind a long op.
2. **Writing** — indeterminate ring on the row (~0.5 s; the 7-frame burst is not cancellable — too short, and a mid-burst cancel tears the slot).
3. **Verifying** — ring continues; label in the Operations popover flips to "verifying".
4. **Verified** — row flashes a checkmark; toast: **"Sent 'Fat Bass v2' to slot 510 — verified"** with the sha's first 8 chars in the detail line, plus **Undo** when the victim's exact bytes are held locally (§9.6). The cached snapshot patches; the sync row (if any) flips to `in-sync`; slot history gains a "verified write" event.

Failure at any phase surfaces per §14 — most importantly the `VerifyMismatchError` moment, which gets its own treatment. There is no silent success and no unverified success.

### 8.3 Rename in place

- **Enter:** tap the name in a detail view, or Return / context-menu Rename on a row. The label becomes a `TextField` in place.
- **Validation while typing:** printable ASCII only (illegal characters rejected at input with a brief shake), counter from 18/23, hard stop at 23. Esc cancels, Return commits.
- **Device rename** is a quick op — the core sends the name frame plus refresh read only (no blob traffic, per the wire protocol). The row shows a subtle progress overlay until the `WriteReport` returns, then the cache patches and a toast confirms: "Renamed slot 413: 'Bass Prophet' → 'Bass Prophet v2'". On failure (timeout or name verify mismatch) the row **reverts to the old name** with an error toast + Retry; the slot is *not* flagged torn (renames carry no blob).
- **Library rename** is local and instant. If the entry is content-in-sync with a device slot, an inline follow-up offers "Also rename on device?" (default no). The spec's honesty rule: a name difference never changes sync status — the diff is content-based — so the sync row shows a secondary "names differ" hint, explained in `SyncSlotDetailView`.

---

## 9. Destructive-action guard rails (one component, one set of rules)

One component renders every device-write confirmation, driven by the existing `OverwritePlan` model, so the rules cannot drift per screen:

1. **Preview the victim, always** — name and expendability, before confirming. Title: `Replace "Perc Organ" in slot 413?`. Expendable victim: `Send to slot 510? Currently: empty (identical to 268 other slots)` — the judgment evidence is in the dialog, not behind it. **Unjudged victim:** `Slot 413 — contents unknown`, and the primary action is **Read First** (~1 s, then the dialog re-renders with the real victim); "Overwrite Anyway" is secondary.
2. **State recoverability.** Exactly one of: "The current preset is in your library ('Perc Organ')" · "…is in backup 2026-09-01 14:32" · **"…is not in your library or any backup — it will be lost."** When unrecoverable, the dialog offers **Save a Copy First** (one read → library) as a one-tap escape.
3. **Backup freshness footer** in every such dialog: "Last full backup: today 14:32 · 3 writes since" or "No complete backup yet — Back Up Now (~3.5 min)".
4. **Confirm buttons state the action and count**, never "OK": "Replace Preset", "Write 5 Slots", "Restore 512 Slots".
5. **Severity scales with blast radius:** expendable single target → popover anchored at the row, one tap; occupied or unjudged single target → alert dialog; bulk send / bulk apply / restore → full plan sheet listing every target and victim; full-device restore → plan sheet **plus** a final alert ("This overwrites every preset on the device — 512 slots").
6. **Undo only where honest.** After an overwrite whose victim's exact bytes are held locally (library blob, or a covering backup with matching sha), a 10 s toast offers **Undo** (and the system undo gesture works, via `UndoStack`); undo enqueues a verified write of the victim back and is itself confirmed by the verified toast. When the bytes are not held, no undo is offered and none was implied.
7. **No verification opt-out** anywhere in the UI.
8. **Cancellation honesty:** single writes cannot be cancelled mid-burst; batch operations cancel *between* slots (worst-case latency one ack/dump timeout, per the core). If a transport failure tears a slot mid-write anyway, §14's torn-slot handling engages.

---

## 10. Expendable-slot visual language

Judged state is a semantic role rendered identically everywhere (browser, pickers, plan sheets, sync rows):

| Judgment | Dot | Row treatment | Copy on inspection |
|---|---|---|---|
| Real preset | filled dot | full-contrast name | — |
| **Expendable ("empty")** | **outline dot** | **name dimmed + "empty" micro-chip** | "identical to N other slots" / "blank name" |
| Unjudged | hollow dashed dot | full-contrast name, no chip | "content not read yet — Read Now or run a backup" |
| Unknown (name read failed) | hollow dot + "!" | "— read failed" placeholder | "name read failed — Retry" |

Rules: dimming is **only** ever applied by content judgment, never by the string "Init"; expendable styling appears only while a hashed snapshot backs it; the slot picker groups expendable slots first and labels the `pickScratchSlot` suggestion; color is never the sole carrier (dot shape + chip text survive grayscale and VoiceOver reads the judgment).

---

## 11. Practice Mode

User-facing name: **Practice Mode** (internal: `DemoDevice` wrapping FreakCore's `SimulatedMicroFreak`; the code name is invisible to users).

- **Entry:** the Connect screen's "Practice Mode" button (always available, no hardware needed), with a profile picker:
  - `Factory Fresh` (default) — the reference device's shape: real-looking named presets in the low slots plus **269 identical Init blobs**, meta positionally correct, so emptiness judgments, census counts, and the sync diff behave exactly as against Eric's actual synth.
  - `Lived In` — scattered user presets, few expendables.
  - `Full` — zero expendables; exercises the "no scratch slot — ask the human" path.
  - `Flaky` — injected timeouts and a `failChunkAt` torn write; exists so every §14 error surface is reachable without hardware.
- **The banner (never mistakable for hardware):** whenever the session is simulated, a persistent, non-dismissable banner spans the top of the content column: **"PRACTICE MODE — simulated MicroFreak (Factory Fresh). Nothing here touches hardware."** Distinct tint reserved for practice only (suggested: violet), diagonal-striped leading edge so it survives grayscale. The status-bar connection capsule echoes it ("Practice · Factory Fresh") with the same tint. The banner appears on every device-flavored surface: browser, slot detail, sync, backup progress, restore plans, every overwrite dialog (the dialog footer gains "Practice device — no hardware will change").
- **Honest pacing by default:** the practice session sleeps ~1 ms/name and ~400 ms/blob so progress bars, ETAs, cancel, and the ~3.5-minute backup are experienced truthfully. Settings toggle "Fast practice timing (20×)" for development; the banner appends "(fast)" when on.
- Reply-lag stays **on** (the sim default) — practice mode exercises the same defenses as hardware.
- **Identity separation:** practice snapshots/backups are stamped `practice:<profile>` (§4). Switching practice → hardware keeps the library and backups (device-independent) but drops the slot cache and diff; restoring a `practice:*` backup to hardware (or vice versa) demands the cross-identity warning: "This backup came from a practice device, not your MicroFreak."
- A hardware MicroFreak appearing while in Practice Mode raises a passive banner ("MicroFreak detected — Switch?"); switching mid-operation is refused until the operation finishes or is cancelled. Never auto-switches.

---

## 12. Connect flow (`ConnectView`, `ConnectSheet`)

Shown as the content column when no session exists and Device is selected; also reachable any time from the status capsule.

- **Layout (landscape, centered column, actions in the lower half per §13):** device glyph · "No MicroFreak connected" · live list of MIDI endpoints (auto-refreshing via CoreMIDI setup notifications from `FreakMIDI`) with a Connect button per plausible endpoint · divider · **Practice Mode** button + profile picker.
- Endpoint list labels the likely match ("MicroFreak — likely match") using the same hints as the core's discovery; other endpoints are listed but never auto-picked.
- Hot-plug: a device appearing triggers a passive banner anywhere in the app — "MicroFreak detected — Connect?" Never auto-connects.
- **States:** *no endpoints* — "Connect the MicroFreak by USB." + Practice Mode; *connecting* — inline spinner on the row, cancellable; *failed* — §14's `DeviceNotFoundError` treatment (lists every port seen, so a cable problem is distinguishable from a wrong-port problem) or `TransportError` (retry + details disclosure).

**Connection state machine** (owned by `AppModel`):

```
noDevice(seen: [Endpoint]) → connecting(Endpoint) → connected(hardware)
noDevice → practice(profile)
any → noDevice        (unplug/transport failure: cache kept, marked stale; running op fails cleanly per §14)
practice ⇄ hardware   (explicit user action only; refused mid-operation)
```

Status capsule strings: "MicroFreak · Connected" / "Connecting…" / "No Device" / "Practice · <profile>" (practice tint).

---

## 13. One-handed reachability rules

The user is standing, iPad landscape on a stand, one free hand. Binding rules for every screen:

1. **Primary actions live in the lower half and near the vertical edges** — toolbars that matter (Back Up Now, Apply, Confirm) render as bottom-anchored bars in sheets, never top-center. The status bar (bottom) is the global control surface.
2. **Confirmations anchor at the point of interaction** (popover at the touched row), so confirm-after-tap requires no reach across the screen. Full plan sheets put Confirm/Cancel bottom-trailing.
3. **No interaction requires two simultaneous touches.** Drag-and-drop always has a tap-only path of equal capability (§8.1 parity rule). Multi-select uses Edit-mode checkboxes, not held modifiers.
4. **Targets:** minimum 44 pt; list rows ≥ 52 pt; the browser's per-row primary tap is the whole row.
5. **Handedness-neutral:** nothing is exclusive to a left- or right-edge gesture; swipe actions exist on both edges (leading: Save to Library; trailing: Send Here… / Rename) and every swipe action is also in the context menu.
6. **Reachability of the 512-row list:** sidebar bank jumps + section index; flick-scroll never required to reach a bank.
7. Destructive confirm buttons are **never** placed where the resting thumb falls during scrolling (no full-width bottom-edge destructive buttons without a preceding deliberate tap).
8. Hardware keyboard is fully supported (arrows, type-ahead select, Return = rename, Space = detail focus, ⌘F search, ⌘R refresh names, ⌘B back up, ⌘Z undo, Esc cancel) but never required.

---

## 14. Error surfaces — every core error, mapped

One mapping table; the UI has no unmapped error path. "Toast" = transient, non-blocking, with an action button. "Alert" = modal. Every failed op also lands in the Operations popover's recent list with full detail.

| Core error | Surface | Behavior |
|---|---|---|
| `DeviceNotFoundError` | Connect screen inline | Lists every input/output seen (from the error payload) so the user can tell cable vs. wrong-port. Retry. |
| `TransportUnavailableError` | Connect screen inline | "MIDI is unavailable on this device." (CoreMIDI variant; effectively unreachable on iPad — mapped anyway.) |
| `TransportError` (incl. unplug mid-op) | Status bar + banner | Op fails cleanly; state → `noDevice`; cache kept and marked stale; a resumable op (backup) shows its Resume affordance on reconnect. Details disclosure shows the chained backend error. |
| `DeviceTimeoutError` | Toast (quick ops) / op-failure state (long ops) | "Device stopped responding (slot 413, name read)" + Retry. Two consecutive timeouts → suggest checking cable/power. |
| `ReplyMismatchError` | Toast, after the core's own retries | The lag defense already retried 3×; surfacing means something is genuinely wrong: "Device is answering for the wrong slot — unplug/replug and retry." Retry button. |
| `ChunkNotAckedError` | Alert + torn-slot flag | "Write to slot 413 failed mid-transfer (chunk 87 unacknowledged). The slot's contents are unreliable." Actions: **Write Again** (primary) · Restore from Backup (when covered) · Close. Row badge "torn" until a verified write succeeds. Slot history logs it. |
| `WriteAbortedError` | Alert + torn-slot flag (stage `chunk`/`go`/`open`) or plain alert (stage `name_write`/`final_read`, no blob torn) | Same recovery actions; copy names the stage in plain words ("failed before any preset data was sent" vs. "failed during transfer"). |
| `VerifyMismatchError` | **The designed moment — see below** | |
| `OperationCancelledError` | Expected path, not an error surface | Backup: "Paused — 341 of 512 saved" partial framing (§16). Restore: the `.completed` reports render as the done-list in the plan sheet. Never a red surface. |
| `IntegrityError` | Per-entry / per-backup badges | Names the file path and detail; offers Remove / Re-import where §6 applies; the "no meta recorded — re-backup to restore this slot" case renders that exact sentence on the disabled restore row. Never auto-deletes. |
| `EntryNotFoundError` | Toast | "That preset is no longer in the library." List refreshes. (Race with an external edit; effectively internal.) |
| `LibraryCorruptError` | Full-screen on library open | Names the index path; offers Move Aside & Start Fresh / Quit. Never silently deletes. |
| `InvalidNameError` | Prevented at input (§8.3) | If it ever surfaces: toast stating the rule ("names: up to 23 plain ASCII characters"). |
| `SlotOutOfRangeError`, `BlobSizeError`, `ProtocolError` | Generic failure toast + log | Programmer/foreign-data errors. Blob-size on file import gets a specific line: "Not a MicroFreak preset (expected 4672 bytes, got N)." |

### The `VerifyMismatchError` moment

The one error that means *the synth now holds something other than what we sent*. It must be scary enough to stop the user and calm enough to be acted on. Modal alert-style sheet, anchored to the slot, practice/hardware banner visible:

```
⚠︎  Slot 413 didn't verify

The preset was sent, but reading the slot back returned different
data. What is on the MicroFreak in slot 413 right now is NOT
"Fat Bass v2".

   Sent       Fat Bass v2 · sha 9f3a01b2c4d6 · 4,672 bytes
   Read back  Fat Bass v2 · sha 77e01ac9d001 · 4,672 bytes
   First difference at byte 1,024

Your library copy of "Fat Bass v2" is safe. Nothing else was
written.

   [ Write Again ]        ← primary
   [ Read Slot 413 ]      ← inspect what is actually there
   [ Close ]
```

Rules: the sheet always states the blast radius ("nothing else was written") and the safety of the source; name and sha lines render only the fields that actually differ (from the error payload: expected/actual name, expected/actual sha, `firstDifference`, lengths); a read-back that failed entirely renders "Read back — no response" instead of fake values. **No auto-retry** — retrying a write is a deliberate act. On Close, the slot carries a persistent "verify failed" badge (distinct from "torn") in the browser and detail until a clean verified write lands; the slot history records the failure. During a batch (restore/bulk apply) the batch has already stopped at this failure (core semantics); the sheet gains the batch context line "Restore stopped here — 41 of 96 slots done" and a **Retry From Slot 413** action.

---

## 15. Slot history (local journal)

- **Store:** `history.json` in the app's Documents dir, one journal per device identity (`hardware`, `practice:<profile>`), written by `AppModel` on each event, capped at 50 events/slot (oldest dropped). Not part of FreakCore; purely an app-side observation log.
- **Events recorded:** snapshot observation (name, sha when read) · verified write (source: library entry / backup slot / device slot copy; name; sha) · rename (old → new) · restore (backup id) · verify failure · torn write · cancelled batch touching the slot.
- **Rendered** in `SlotDetailView` §7.8. Never rendered as truth about the synth: the header caveat is mandatory copy.
- History is excluded from cross-identity views (a practice journal never shows under hardware).

---

## 16. Backup and restore

### 16.1 Backup (`BackupListView`, `BackupProgressSheet`)

- **List:** newest first; each row: date/time · coverage ("512/512" or "partial · 341/512" with **Resume**) · size · source (manual / sync pass) · identity chip when `practice:*`. Detail: per-slot table (number, name, sha), Restore… entry, Export folder (share sheet), Delete (guard names it; extra warning when it is the only complete backup).
- **Start:** **Back Up Now** in the Device and Backups toolbars. Pre-flight line, always: "Reads all 512 slots, about 3½ minutes. **The device is never modified by a backup.**"
- **Progress sheet** (dismissable — the operation continues; the status bar mirrors it):
  - Determinate bar `done/total` · current slot number + name streaming by · elapsed · **ETA from the core's median-based `ProgressEvent.eta`** · throughput ("398 ms/slot", from the running median).
  - ETA display rules: show "estimating…" until the core supplies a non-nil ETA; render as `m:ss`; update at most once per second; on completion show the `TimingReport` line ("211 s total · median 398 ms/slot").
  - **Pause** — implemented as cancel; the on-disk partial *is* the pause state (per-slot persistence). Copy: "Paused — 341 of 512 saved. Resume anytime." Resume runs `resume: true`, skipping intact slots.
  - **Cancel** — same mechanism framed as stopping; keeps the partial, labeled partial in the list.
  - Interruption (suspension past the background allowance, unplug, transport error) → identical outcome: partial, resumable, plus a banner on return: "Backup interrupted at slot 342 — Resume?" Nothing is ever lost or invalid.
- A running backup blocks other device ops (§1.3); Pause is the escape hatch when the user urgently needs a write.

### 16.2 Restore (`RestorePlanSheet`)

Entered from a backup's detail ("Restore…") or per-slot from `SlotDetailView`.

- **Scope step:** Full device · Selected slots (multi-select table) · "Only slots that differ from this backup" (needs a current hashed snapshot; offers to read first).
- **Plan step:** every planned write lists its victim per §9: `413 ← "Bass Prophet" (backup) — replaces "Bass Prophet v2" (on device, not expendable, in library)`. If cached names are older than 10 minutes, an automatic ~2 s names refresh runs before the plan renders so victims are named from fresh data. Footer: write count · estimate (~1 s/slot verified, median-based once running) · backup-freshness line · confirm button **"Restore N Slots"**; full-512 adds the final alert (§9.5). Slots the backup cannot faithfully restore (missing `meta_hex`) appear pre-disabled with the core's own sentence: "no meta recorded — re-backup to restore this slot."
- **Execution:** progress identical to backup (done/total, current slot, median ETA, cancel-between-slots). **Stops at the first failure** (core semantics): the sheet then shows the completed list (from `.completed` on the error), the failing slot with its §14 surface, and the remaining slots, with **Retry From Slot N** and Close. A torn slot is badged until re-written.

---

## 17. Sync view (`SyncListView`, `SyncSlotDetailView`)

Device vs. library, one row per slot, straight from the core's `SyncDiff` — the diff computes; **only explicit user actions write**.

**Precondition banner (the honest gate):** the diff needs a fully hashed snapshot. Header always shows provenance: "Compared against device read 12 min ago (backup 2026-09-01 14:32) · 3 writes since." With no hashed snapshot, the list is replaced by the CTA state: "To compare, the app reads every slot (~3½ minutes) and keeps it as a backup." → **Read Device & Compare**. Because verified writes patch the snapshot (§4), applying rows does not invalidate the diff.

**Filter bar with live counts**, each status toggleable; default shows everything except `in-sync` and `empty`:

```
Added 12 · Changed 3 · Missing 5 · In sync 223 · Empty 269
```

**Rows and per-status actions** (statuses map 1:1 to core `SlotStatus`):

| Status (core) | Row reads | Explicit action(s) | Guard |
|---|---|---|---|
| `added` (DEVICE_ONLY) | `[097] device "Weird Organ" · not in library` | **Import to Library** (instant — bytes already on disk from the snapshot-backup) | none — additive |
| `changed` (DIFFERS) | `[413] device "Bass Prophet" ≠ library "Bass Prophet v2"` | **Push Library → Device** (verified write) / **Pull Device → Library** (instant; new entry takes the slot claim; old entry kept, claim cleared — stated) | push: full §9 dialog naming the device preset |
| `missing` (LIBRARY_ONLY) | `[510] library "Fat Bass" · device slot empty` | **Send to Device** (verified write) | §9 popover — victim is expendable, evidence shown |
| `in-sync` | informational | none | — |
| `empty` | informational; row explains the judgment ("identical to 268 other slots") | none by default | — |

**Bulk apply:** toolbar **Apply…** opens `BulkApplyPlanSheet`: sections "Import 12 to library" (pre-checked), "Send 5 to device" (pre-checked, each row shows its victim + expendability), "Conflicts (3)" — **conflicts are never pre-resolved**: each `changed` row requires an explicit Push / Pull / Skip choice, default Skip. Footer: totals · time estimate ("5 writes ≈ 5 s") · backup-freshness line · confirm labeled **"Write 5 Slots to Device"**. Execution is one queued op with per-row ticks; a failed write stops the batch (core restore semantics), marks completed rows, offers Retry Remaining.

**`SyncSlotDetailView`:** both sides' names and shas, judgment evidence, name-vs-content note ("names differ; contents identical" for renamed in-sync rows), slot history excerpt, and the same explicit actions with full context.

**States:** no snapshot → CTA above · everything in sync → "Device and library match — 223 in sync, 269 empty" + timestamp · compare running → the backup's progress inline (same op) · stale → header ages, warning tone past 24 h with Re-read · no library → routes to the library empty state.

---

## 18. App structure

### 18.1 View inventory

```
FreakLibrarianApp (App/Sources/MicroFreakLibrarianApp.swift)
└─ WindowGroup
   └─ RootView                          owns AppModel (@State), injects via .environment
      ├─ NavigationSplitView
      │  ├─ SidebarView                 SidebarSelection: device(bank?) | library(tag?) | sync | backups
      │  ├─ Content column (switch on selection)
      │  │   ├─ SlotListView           → SlotRowView, BankSectionHeader
      │  │   ├─ LibraryListView        → LibraryRowView
      │  │   ├─ SyncListView           → SyncRowView, SyncFilterBar, SyncProvenanceHeader
      │  │   ├─ BackupListView         → BackupRowView
      │  │   └─ ConnectView
      │  └─ Detail column
      │      ├─ SlotDetailView         → SlotHistoryList, CategoryByteRow, ShaRow
      │      ├─ LibraryEntryDetailView
      │      ├─ SyncSlotDetailView
      │      └─ BackupDetailView
      ├─ PracticeBanner                 (overlay, top of content, §11)
      ├─ .safeAreaInset(bottom): StatusBarView → ConnectionCapsule, ActiveOperationView, OperationsPopover
      ├─ .sheet: BackupProgressSheet | RestorePlanSheet | BulkApplyPlanSheet | SendPlanSheet | ConnectSheet
      ├─ .alert / .popover: OverwriteConfirmation (from OverwritePlan) | VerifyMismatchSheet | error alerts
      └─ drag/drop wiring via PresetTransfer (Transferable)
```

### 18.2 View-model responsibilities (`@MainActor @Observable`; views bind to these, never to FreakCore directly)

| Model (existing file under `App/Sources/`) | Owns | Never does |
|---|---|---|
| `AppModel` (+ `AppModelSync`, `AppModelBackup`, `AppModelWrites` extensions) | connection state machine; the single **device-operation queue** (quick FIFO behind exclusive long ops, cancel current, recent-ops list); device identity; slot-history journal; wiring child models | UI layout decisions; direct frame access |
| `SlotBrowserModel` | the 512-row cache (name load-state, sha, judgment, sync badge, flags `torn`/`verifyFailed`/`busy`); names-as-of; search text; refreshNames / readSlot / rename / saveToLibrary intents; snapshot apply + per-write patch | writing without an `OverwritePlan` confirmation (`confirm(plan)` is the only path to the wire) |
| `LibraryModel` | entries cache mirroring the `Library` actor; tag list; import/export intents; delete/assign-slot guards' facts | touching the device |
| `SyncModel` | diff state machine: `needsSnapshot(estimate)` → `comparing(ProgressEvent)` → `ready(SyncDiff, provenance)` / `failed`; filter set; per-row and bulk apply **plan builders** (returning `OverwritePlan` / `BulkApplyPlan`) | executing a plan itself — execution goes through `AppModel`'s queue after confirmation |
| `BackupsModel` | backup catalog; active backup progress; resumable detection; restore plan builder (with the automatic names refresh); delete guard facts | writing to the device outside a confirmed restore plan |
| `FreshnessModel` | `latestCompleteBackup`, `writesSinceBackup`, `namesAsOf` — the single source for every freshness line | — |
| `ToastCenter` | transient toasts incl. undo-carrying ones | modal decisions |
| `OverwritePlan` / `UndoStack` / `PresetTransfer` (value types) | one plan schema for singles, bulks, restores (items = target + incoming name + victim{name, expendable-with-evidence, recoverability} + severity + freshness snapshot); honest undo eligibility; drag payloads | — |

**Threading contract:** view models are the only writers of their own state; all device work is enqueued on `AppModel`'s queue, which hops to the FreakCore device actor and re-dispatches `ProgressEvent`s to `@MainActor` (the existing `ProgressBridge`); cancellation maps UI Cancel onto the core's `CancelToken` (long ops poll between slots/chunks; worst-case latency one timeout). Library/backup change streams drive invalidation.

### 18.3 What state lives where

| State | Home | Persistence |
|---|---|---|
| Device truth | the synth (or `SimulatedMicroFreak`) | — (the app only ever holds observations) |
| Slot cache (names, shas, judgments, flags) | `SlotBrowserModel` in memory | dropped on identity switch; rebuilt from names pass; hashed tier restored from the latest backup's records at launch (marked with its age) |
| Library | FreakCore `Library` folder | `Documents/library/` (index.json + content-addressed blobs; atomic index writes) |
| Backups | FreakCore `BackupSet` folders | `Documents/backups/<timestamp>/` (phase-0 format, per-slot persistence, resumable) |
| Sync diff | `SyncModel`, recomputed from snapshot + library | never persisted (cheap and pure; provenance is what matters) |
| Slot history | `AppModel` journal | `Documents/history.json`, per identity, capped |
| Freshness counters | `FreshnessModel` | `UserDefaults` |
| Navigation selection, filters, practice profile, fast-timing toggle | `AppModel` / views | `SceneStorage` / `AppStorage` |
| In-flight operation | `AppModel` queue only | never persisted; interruption resolves to the resumable on-disk state (backups) or a clean failure (writes) |

---

## 19. Accessibility baseline

- Dynamic Type through XL on all rows (rows grow; the slot number column stays fixed-width numeric).
- VoiceOver: rows read "slot 413, Bass Prophet, in sync" / "slot 510, empty — identical to 268 other slots"; judgment and badges are traits, not color; drag flows have the tap-parity path (§13.3) so every action is rotor-reachable.
- All state colors pass contrast in light and dark; practice tint + stripe survives grayscale (§11).
- Reduced Motion: shimmer and row flashes become opacity fades.

---

## 20. Open questions (flagged, not blocking v1)

1. **Background execution:** a ~3.5-minute backup exceeds the default background allowance; v1 accepts pause-on-suspend (resume is designed-for and cheap). Extended-execution entitlements can be investigated later.
2. **Rename verify blind spot:** back-to-back same-slot reads cannot distinguish a lagged reply (write-protocol.md, Quirks). The UI treats a verified rename as verified; if hardware sessions show phantom verifies, add a delayed re-read.
3. **Category-byte label mapping** ships empty until verified against hardware (§7.4); the raw-hex display is the honest default.
4. **Per-chunk ack pacing and sub-384 writes** are core-level open assumptions (core-api §5 of "Porting the core"); no UI impact beyond trusting `WriteReport`.
5. **App identity mismatch** in `project.yml` (§ header) needs the rename pass to `com.ericbrookfield.freaklibrarian` / "Freak Librarian".
