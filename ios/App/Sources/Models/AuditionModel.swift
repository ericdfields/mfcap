// AuditionModel.swift — the app-side driver for FreakCore.AuditionSession:
// borrow one expendable slot, play through a queue one tap at a time, file
// each verdict, put the slot back.
//
// Audition is a FEATURE, not a place: the queue is handed in explicitly by
// whatever list the user is looking at (a collection, the library with its
// live facets, favorites, one entry). This model no longer knows anything
// about LibraryModel's filters.
//
// Every device touch goes through the DeviceOperationQueue (quick ops, FIFO
// with everything else), so a running backup or collection switch simply
// queues the audition behind it and the busy line explains why.
//
// SAFETY: from the moment the borrowed slot's original has been READ until it
// has been written back, that slot holds someone else's preset.
// `needsRestore` is that promise; the app refuses device switches (while a
// device is still attached), disconnects, applies, restores, backups and any
// write to the borrowed slot while it is true, and the standing banner in
// RootView is how the user gets back.
//
// Three rules keep the promise honest, all of them learned from ways the
// earlier version could lose a preset:
//   1. A FAILED restore keeps the session. `AuditionSession.stop()` is
//      documented safe to call again and still holds the only in-memory copy
//      of the original — throwing that away on a timeout lost the preset.
//   2. A FAILED start (the original never read) releases the session, because
//      nothing was borrowed and the blocks would otherwise never lift.
//   3. The original is written to disk (AppModel.persistAuditionLoan) the
//      moment it is read, so a crash, a force-quit or an iPadOS termination
//      leaves a recoverable record instead of a silently occupied slot.

import Foundation
import Observation
import FreakCore

/// One prepared audition: what would be played, where it came from, and how
/// many of them are still unjudged. Built ONCE when the setup popover opens
/// (never inside a view body) so a 966-entry library is never re-sorted per
/// pass. The unrated/all choice itself belongs to the popover — this struct
/// only supplies the candidates and the counts it labels them with.
struct AuditionRequest: Identifiable {
    let id = UUID()
    /// "Ambient Peaks · 32 presets in this collection", "All Presets", …
    var sourceLabel: String
    /// Already in display order.
    var candidates: [LibraryEntry]
    /// Collection refs with no matching library entry — stated, never dropped
    /// silently (verdicts are filed on library entry ids).
    var unresolvedCount: Int = 0

    /// `AuditionSession.unrated` stays the single definition of "unrated" so
    /// the app and the Python core cannot drift.
    var unratedCandidates: [LibraryEntry] {
        AuditionSession.unrated(candidates)
    }
}

@MainActor @Observable
final class AuditionModel {
    enum Phase: Equatable {
        case idle
        case starting          // reading the slot's original
        case loading           // writing + selecting the next preset
        case playing           // a preset is on the synth; awaiting a verdict
        case exhausted         // queue done; slot not yet restored
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var current: LibraryEntry?
    private(set) var remaining = 0
    private(set) var total = 0
    private(set) var judged = 0
    /// What the running session is playing through, for the session header
    /// and the minimized banner.
    private(set) var sourceLabel = ""
    /// The slot the PICKER is pointed at (0-based). Defaults to the highest
    /// slot the browser judged expendable. Once a session is running, read
    /// `borrowedSlot` instead — this one is still bound to a Picker.
    var slot = SlotID.Layout.slots - 1
    /// Drives the full-screen session presentation. Minimize clears it without
    /// ending the session — the slot stays borrowed and the banner says so.
    var presented = false
    /// Set by AuditionSessionView's onAppear/onDisappear. RootView's standing
    /// loan banner is suppressed only while the cover is ACTUALLY on screen,
    /// so a cover that fails to present can never leave a live loan with no
    /// reachable Stop.
    private(set) var coverVisible = false

    private var session: AuditionSession?
    private weak var app: AppModel?
    /// The session's device went away mid-flight; a restore has to be written
    /// through whatever device is connected now, not through the dead one.
    private var lostDevice = false
    /// A restore write is already in flight — Stop is tappable from both the
    /// session screen and the standing banner, and a second restore would
    /// write the original twice.
    private var restoring = false
    /// Which device lent the slot. A restore is only ever written back to a
    /// device of the same identity — putting a hardware preset into the
    /// practice sim would consume the only copy.
    private var loanIdentity: DeviceIdentity = .none

    /// The slot the RUNNING session borrowed — captured when the session was
    /// constructed and never written again, so a later touch of the picker's
    /// `slot` can no longer redirect a restore into a slot that was never
    /// borrowed. nil when nothing is on loan.
    private(set) var borrowedSlot: Int?

    /// The safety predicate: true from the moment a session exists until the
    /// borrowed slot has been put back. Everything that could write the slot,
    /// swap the device, or tear it down consults this.
    var needsRestore: Bool { session != nil }

    /// Slots the browser currently judges expendable, highest first — the
    /// safe choices for the audition slot.
    func expendableSlots(_ app: AppModel) -> [Int] {
        app.slots.rows.filter { $0.judgment.isExpendable }
            .map(\.slot.raw).sorted(by: >)
    }

    /// Point the picker at the best default. With nothing judged expendable
    /// the picker offers the highest slot only, so the binding has to hold
    /// that same slot — otherwise Start would silently borrow a stale one the
    /// popover never displayed.
    func adoptDefaultSlot(_ app: AppModel) {
        guard !needsRestore else { return }
        slot = expendableSlots(app).first ?? (SlotID.Layout.slots - 1)
    }

    func coverAppeared() { coverVisible = true }
    func coverDisappeared() { coverVisible = false }

    // ------------------------------------------------------------ lifecycle

    /// Start a session over an EXPLICIT queue. The guard is `session == nil`,
    /// not a phase test: a failed session still holds the borrowed slot's
    /// original, and starting over it would discard that original forever.
    func start(_ app: AppModel, queue: [LibraryEntry], sourceLabel: String) {
        guard session == nil, let device = app.device,
              let library = app.libraryModel.library else { return }
        guard !queue.isEmpty else { return }
        // An unsettled loan from an earlier session still owns the record on
        // disk; borrowing again would overwrite the only saved copy of that
        // slot's original.
        if let reason = app.auditionStartBlockReason() {
            app.toasts.show(reason, isError: true)
            return
        }
        self.app = app
        self.sourceLabel = sourceLabel
        lostDevice = false
        loanIdentity = app.deviceIdentity
        total = queue.count
        remaining = queue.count
        judged = 0
        current = nil
        phase = .starting
        presented = true
        let raw = slot
        let s = AuditionSession(device: device, library: library,
                                queue: queue, slot: raw)
        session = s
        borrowedSlot = raw
        let slotID = SlotID(raw)
        app.slots.setBusy(slotID, true)
        let task = app.operations.enqueue("Audition: saving slot \(slotID.display)",
                                          kind: .quick, slot: slotID) { _ in
            try await s.start()
        }
        Task {
            do {
                let original = try await task.value
                // The borrowed original now exists in exactly one place until
                // this lands on disk.
                app.persistAuditionLoan(slot: slotID, preset: original,
                                        sourceLabel: sourceLabel)
                await advance()
            } catch {
                // The read never landed, so NOTHING was borrowed: release the
                // session. Keeping it here left `needsRestore` true forever
                // over an untouched slot — Apply, backup, restore and the
                // device switch all locked behind a session with no original.
                app.slots.setBusy(slotID, false)
                session = nil
                borrowedSlot = nil
                fail(error)
            }
        }
    }

    /// File the verdict for the preset on the synth, then load the next one.
    func pick(_ verdict: Verdict) {
        guard phase == .playing, let s = session, let app else { return }
        phase = .loading
        Task {
            do {
                _ = try await s.verdict(verdict)
                judged += 1
                await app.libraryModel.refresh()
                await advance()
            } catch {
                fail(error)
            }
        }
    }

    /// Move on without judging.
    func skip() {
        guard phase == .playing else { return }
        phase = .loading
        Task { await advance() }
    }

    /// Restore the slot's original and end the session. Safe at any phase, and
    /// safe to call again after a failure — the session (and its original) is
    /// kept until the write actually succeeds.
    func stop() {
        guard let s = session, let raw = borrowedSlot, let app else {
            reset()
            return
        }
        guard !restoring else { return }
        // `raw` is the session's own slot, captured at construction: `slot` is
        // still bound to the setup popover's Picker, so a later touch there
        // must not redirect the restore into a slot that was never borrowed.
        let slotID = SlotID(raw)
        // The session's transport died: the original has to go back through
        // whatever device is connected NOW. Without one — or with a different
        // KIND of device — say so and keep the session (and the banner) alive
        // rather than spending the only copy of the original on the wrong synth.
        let fallback: (any FreakDeviceProtocol)?
        if lostDevice {
            guard let live = app.device else {
                app.toasts.show("Reconnect the MicroFreak to put slot "
                    + "\(slotID.display) back, or restore that slot from a "
                    + "backup.", isError: true)
                return
            }
            guard app.deviceIdentity.isPractice == loanIdentity.isPractice else {
                app.toasts.show("Slot \(slotID.display) was borrowed from a "
                    + "different device. Connect that one to put it back, or "
                    + "restore the slot from a backup.", isError: true)
                return
            }
            fallback = live
        } else {
            fallback = nil
        }
        let task = app.operations.enqueue("Audition: restoring slot \(slotID.display)",
                                          kind: .quick, slot: slotID) { _ in
            if let fallback {
                guard let original = await s.original else { return }
                _ = try await fallback.write(slot: raw, preset: original)
            } else {
                _ = try await s.stop()
            }
        }
        restoring = true
        Task {
            defer { restoring = false }
            do {
                _ = try await task.value
                app.slots.setBusy(slotID, false)
                app.clearAuditionLoan()
                app.toasts.show("Audition ended — slot \(slotID.display) restored. "
                                + "\(judged) verdict\(judged == 1 ? "" : "s") filed.")
                reset()
            } catch {
                // NO reset() here. The slot still holds the audition preset and
                // `s` still holds the only in-memory copy of its original
                // (`AuditionSession.stop()` only marks itself restored on a
                // successful write and is documented safe to call again).
                // Dropping the session would clear `needsRestore`, hide the
                // banner, lift every write block over an occupied slot, and
                // make Retry impossible.
                app.slots.setBusy(slotID, false)
                app.toasts.show("Slot \(slotID.display) could not be put back: "
                    + "\(error.localizedDescription) The saved original is "
                    + "kept — try Stop again, or restore that slot from a "
                    + "backup.", isError: true)
                fail(error, message: "Slot \(slotID.display) could not be put "
                     + "back: \(error.localizedDescription) The original is "
                     + "still saved — try Stop again.")
            }
        }
    }

    /// Give up on putting the slot back NOW, without pretending it is back.
    /// Only safe because the borrowed original was written to disk when it was
    /// read: the standing promise moves from this session to AppModel's
    /// pending-loan record, which survives a relaunch.
    func abandon() {
        guard let app, let raw = borrowedSlot else { reset(); return }
        let slotID = SlotID(raw)
        app.slots.setBusy(slotID, false)
        app.adoptPendingLoanFromDisk()
        reset()
        app.toasts.show("Slot \(slotID.display) still holds the audition "
            + "preset. Its saved original is kept — put it back from the "
            + "banner when the device is ready.", isError: true)
    }

    /// The transport went away mid-session (unplug, backend failure). The slot
    /// is still borrowed, so the session — and `needsRestore` — survive; only
    /// the route back changes.
    func deviceLost() {
        guard let raw = borrowedSlot else { return }
        lostDevice = true
        phase = .failed("Device disconnected — slot \(SlotID(raw).display) "
            + "still holds an audition preset. Reconnect, then Stop to put it "
            + "back, or restore that slot from a backup.")
    }

    /// "Slot 512 is on loan to an audition; stop it first." — nil when there
    /// is nothing borrowed.
    var blockReason: String? {
        guard let raw = borrowedSlot else { return nil }
        return "Slot \(SlotID(raw).display) is on loan to an audition — "
            + "stop it first."
    }

    // ------------------------------------------------------------ internals

    private func advance() async {
        guard let s = session, let raw = borrowedSlot, let app else { return }
        phase = .loading
        let slotID = SlotID(raw)
        let task = app.operations.enqueue("Audition: loading next preset",
                                          kind: .quick, slot: slotID) { _ in
            try await s.next()
        }
        do {
            let entry = try await task.value
            // deviceLost() (or a Stop) may have landed while this was
            // suspended. Its phase carries the instructions for getting the
            // slot back; a stale success must not overwrite it and re-arm
            // Skip and the verdict chips against a dead transport.
            guard session === s, !lostDevice else { return }
            if let entry {
                current = entry
                remaining = await s.remaining
                phase = .playing
            } else {
                phase = .exhausted
            }
        } catch {
            fail(error)
        }
    }

    /// Record a failure — and, when the cause is a transport loss raised by an
    /// audition op, tell AppModel about it. Nothing else routes it: the
    /// operation queue re-throws, so without this the app kept reporting
    /// "Connected" over a dead cable and Stop wrote through the dead session.
    private func fail(_ error: Error, message: String? = nil) {
        phase = .failed(message ?? error.localizedDescription)
        guard let app, let freak = error as? FreakError else { return }
        switch freak {
        case .transport, .transportUnavailable:
            app.handleTransportLoss(freak)
        default:
            break
        }
    }

    private func reset() {
        session = nil
        borrowedSlot = nil
        restoring = false
        current = nil
        phase = .idle
        remaining = 0
        total = 0
        judged = 0
        sourceLabel = ""
        presented = false
        lostDevice = false
        loanIdentity = .none
    }
}
