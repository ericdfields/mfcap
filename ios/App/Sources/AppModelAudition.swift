// AppModelAudition.swift — the audition-queue builders (UX addendum §30).
//
// Audition is launched from whatever list is on screen, so the QUEUE is built
// from that list, not from the library's global facets. Each builder runs once
// (when the setup popover opens), never inside a view body.

import Foundation
import FreakCore

extension AppModel {

    /// The library list as it is currently faceted (category ∧ tags ∧ search
    /// ∧ the sidebar's single-tag child).
    func auditionRequestForLibrary(tag: String?) -> AuditionRequest {
        var label = "All Presets"
        if let tag { label = "#\(tag)" }
        let suffix = libraryFacetSuffix()
        if !suffix.isEmpty { label += " · " + suffix }
        return AuditionRequest(sourceLabel: label,
                               candidates: libraryModel.filtered(tag: tag))
    }

    /// Favorites (the list already has `favoritesOnly` applied).
    func auditionRequestForFavorites() -> AuditionRequest {
        var label = "Favorites"
        let suffix = libraryFacetSuffix()
        if !suffix.isEmpty { label += " · " + suffix }
        return AuditionRequest(sourceLabel: label,
                               candidates: libraryModel.filtered(tag: nil))
    }

    /// One entry — the "hear it now" path from a preset's detail.
    func auditionRequest(for entry: LibraryEntry) -> AuditionRequest {
        AuditionRequest(sourceLabel: "'\(entry.name)' · 1 preset",
                        candidates: [entry])
    }

    /// A collection, in slot order. Refs whose bytes are not in the library
    /// cannot carry a verdict, so they are counted and stated — never dropped
    /// silently (the same honesty as the Apply pre-flight's unresolvable rows).
    ///
    /// The label counts PRESETS, not slots: a collection that places the same
    /// preset in four slots auditions it once, and labelling it "4 presets"
    /// over a queue of one was two numbers disagreeing with no explanation.
    func auditionRequest(for coll: PresetCollection) -> AuditionRequest {
        var seen = Set<String>()
        var entries: [LibraryEntry] = []
        var unresolved = 0
        for raw in coll.coveredSlots() {
            guard let ref = coll.slots[raw] else { continue }
            guard let entry = libraryModel.entriesSharing(sha256: ref.sha256).first
            else {
                unresolved += 1
                continue
            }
            if seen.insert(entry.id).inserted { entries.append(entry) }
        }
        return AuditionRequest(
            sourceLabel: "\(coll.name) · \(entries.count) preset"
                + "\(entries.count == 1 ? "" : "s") from this collection"
                + (entries.count < coll.slots.count - unresolved
                   ? " (\(coll.slots.count) slots, repeats played once)" : ""),
            candidates: entries,
            unresolvedCount: unresolved)
    }

    /// "Bass · #dark · \"pluck\"" — the live facets, for the popover's
    /// second line. Empty when nothing is narrowed.
    private func libraryFacetSuffix() -> String {
        var parts: [String] = []
        if let category = libraryModel.categoryFilter {
            parts.append(category.displayName)
        }
        for tag in libraryModel.tagFilter.sorted() { parts.append("#\(tag)") }
        let query = libraryModel.searchText
            .trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { parts.append("\"\(query)\"") }
        return parts.joined(separator: " · ")
    }

    /// nil = allowed. Otherwise the reason a device write must be refused
    /// while a slot is on loan to a running audition.
    func auditionBlockReason() -> String? { audition.blockReason }

    /// nil = allowed. The reason a write to THIS slot must be refused: the
    /// audition's own restore would silently revert it, leaving the undo stack
    /// describing a slot state that no longer exists (UX addendum §30.4).
    func auditionBlockReason(for slot: SlotID) -> String? {
        guard audition.borrowedSlot == slot.raw else { return nil }
        return audition.blockReason
    }

    /// nil = an audition may start. Otherwise why not — a live loan, or one
    /// left unsettled by an earlier session: starting a new audition would
    /// overwrite the only saved copy of that slot's original.
    func auditionStartBlockReason() -> String? {
        if let reason = audition.blockReason { return reason }
        if let loan = pendingAuditionLoan {
            return "Slot \(SlotID(loan.slot).display) still holds an audition "
                + "preset from an earlier session — put it back first."
        }
        return nil
    }

    // ================================================= the outstanding loan

    /// Keep the borrowed original on disk for as long as the loan is open.
    /// Called once, the moment the audition has read it.
    func persistAuditionLoan(slot: SlotID, preset: Preset,
                             sourceLabel: String) {
        let loan = AuditionLoan(slot: slot.raw, identity: deviceIdentity,
                                sourceLabel: sourceLabel, preset: preset)
        // Written here and now, not off an unordered detached task: a ~6 KB
        // atomic write, and interleaving it with clearAuditionLoan() could
        // resurrect a record for a slot that is already back.
        AuditionLoanStore.save(loan, to: paths.auditionLoanURL)
        history.record(.observed, slot: slot, identity: deviceIdentity,
                       summary: "Audition borrowed the slot — saved '"
                           + "\(preset.name)'",
                       sha256: preset.sha256)
    }

    /// The slot is verifiably back: the record has done its job.
    func clearAuditionLoan() {
        pendingAuditionLoan = nil
        AuditionLoanStore.clear(paths.auditionLoanURL)
    }

    /// Surface whatever is on disk as an outstanding loan — used when a
    /// session gives up on restoring now, so the promise survives in the one
    /// place that outlives the process.
    func adoptPendingLoanFromDisk() {
        pendingAuditionLoan = AuditionLoanStore.load(paths.auditionLoanURL)
    }

    /// "Put it back" on the recovery banner: one verified write of the saved
    /// original, then the record is dropped.
    func restorePendingAuditionLoan() {
        guard let loan = pendingAuditionLoan else { return }
        let slot = SlotID(loan.slot)
        guard device != nil else {
            toasts.show("Connect the MicroFreak to put slot "
                + "\(slot.display) back.", isError: true)
            return
        }
        guard deviceIdentity.isPractice == loan.identity.isPractice else {
            toasts.show("Slot \(slot.display) was borrowed from a different "
                + "device. Connect that one to put it back.", isError: true)
            return
        }
        let preset: Preset
        do {
            preset = try loan.preset()
        } catch {
            toasts.show("The saved copy of slot \(slot.display) can't be "
                + "read — restore that slot from a backup instead.",
                isError: true)
            return
        }
        Task { @MainActor in
            do {
                let report = try await self.enqueueVerifiedWrite(slot: slot,
                                                                 preset: preset)
                self.slots.applyVerifiedWrite(slot, name: report.name,
                                              sha256: report.sha256,
                                              meta: preset.meta)
                self.history.record(.restore, slot: slot,
                                    identity: self.deviceIdentity,
                                    summary: "Put back the audition loan "
                                        + "'\(report.name)'",
                                    sha256: report.sha256)
                self.freshness.noteWrite()
                self.recomputeSync()
                self.clearAuditionLoan()
                self.toasts.show("Slot \(slot.display) put back — verified.")
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// "Discard" — the user says the slot is fine as it is. Confirmed first:
    /// this throws away the only saved copy of what was there before.
    func discardPendingAuditionLoan() {
        guard let loan = pendingAuditionLoan else { return }
        let slot = SlotID(loan.slot)
        deviceAlert = DeviceAlert(
            title: "Forget the saved copy of slot \(slot.display)?",
            message: "'\(loan.name)' was saved when the audition borrowed "
                + "that slot. Forgetting it means this app no longer holds a "
                + "copy — only your backups would.",
            primaryLabel: "Forget It",
            primary: { [weak self] in self?.clearAuditionLoan() })
    }
}
