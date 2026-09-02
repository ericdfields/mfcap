// AppModelWrites.swift — every path that writes to the device (UX §8, §9).
//
// One rule set: nothing touches the wire without an OverwritePlan
// confirmation (drops are intent, not consent); every write goes through the
// core's verified-by-default overloads (no verification opt-out exists
// anywhere in the UI); verified success patches the cached snapshot in
// place; failure maps per UX §14 — with VerifyMismatch as the designed
// moment and torn-slot flags for mid-transfer failures.

import Foundation
import FreakCore

/// The tap-parity slot picker (UX §8.1 non-drag parity). Also serves the
/// library's local Assign Slot… flow.
struct SlotPickerRequest: Identifiable {
    enum Purpose {
        case send(transfers: [PresetTransfer])
        case assign(entryID: String)
    }

    let id = UUID()
    let purpose: Purpose
    let title: String
}

extension AppModel {

    // ============================================== victim facts (UX §9.1–2)

    /// What the confirmation previews for one target slot.
    func victimFacts(_ slot: SlotID) -> OverwritePlan.Victim {
        guard let row = slots.record(slot) else {
            return .unknown(knownName: nil)
        }
        switch row.judgment {
        case .expendable(let evidence):
            return .empty(evidence: evidence)
        case .real:
            let name = row.name ?? ""
            return .named(name, recoverable: recoverability(slot: slot,
                                                            row: row))
        case .unjudged:
            // A named-but-unhashed slot still previews its cached name;
            // judgment stays honest about not existing yet (§9.1).
            return .unknown(knownName: row.hasKnownName ? row.name : nil)
        case .unknown:
            return .unknown(knownName: nil)
        }
    }

    /// §9.2: exactly one recoverability sentence, checked against the
    /// library (sha match) then every backup (sha match at this slot).
    private func recoverability(slot: SlotID, row: SlotCacheRow)
        -> OverwritePlan.Recoverability {
        guard let sha = row.sha256 else { return .none }
        if let entry = libraryModel.entriesSharing(sha256: sha).first {
            return .library(entryName: entry.name)
        }
        if let backup = backups.backupHolding(slot: slot, sha256: sha) {
            return .backup(stamp: backup.folderName)
        }
        return .none
    }

    func makePlanItem(target: SlotID, incomingName: String,
                      incoming: OverwritePlan.Incoming) -> OverwritePlan.Item {
        OverwritePlan.Item(target: target, incomingName: incomingName,
                           incoming: incoming, victim: victimFacts(target))
    }

    // ==================================================== plan entry points

    /// Single send (drop, context menu, paste). `anchor` names the visible
    /// slot row a popover confirmation may attach to; flows that don't run
    /// at a visible row (Library/Sync sends, the slot picker) leave it nil
    /// and get a dialog from RootView instead.
    func requestSend(_ transfer: PresetTransfer, to slot: SlotID,
                     anchor: SlotID? = nil) {
        // Say it before the confirmation, not after it: a write to the
        // borrowed slot would be silently reverted by the audition's restore.
        if let reason = auditionBlockReason(for: slot) {
            toasts.show(reason, isError: true)
            return
        }
        let item = makePlanItem(target: slot,
                                incomingName: transfer.displayName,
                                incoming: incoming(for: transfer))
        let plan = OverwritePlan(
            kind: .send, items: [item],
            title: "Send '\(transfer.displayName)' to slot \(slot.display)",
            freshnessLine: freshness.dialogLine,
            isPracticeDevice: connection.isPractice)
        presentPlan(plan, anchor: anchor)
    }

    /// N presets → N consecutive slots (multi-drag / multi-select, UX §8.1).
    func requestSend(_ transfers: [PresetTransfer], startingAt slot: SlotID,
                     anchor: SlotID? = nil) {
        guard !transfers.isEmpty else { return }
        guard transfers.count > 1 else {
            if let only = transfers.first {
                requestSend(only, to: slot, anchor: anchor)
            }
            return
        }
        var items: [OverwritePlan.Item] = []
        for (offset, transfer) in transfers.enumerated() {
            let target = SlotID(slot.raw + offset)
            guard target.raw < SlotID.Layout.slots else { break }
            items.append(makePlanItem(target: target,
                                      incomingName: transfer.displayName,
                                      incoming: incoming(for: transfer)))
        }
        if let reason = items.lazy
            .compactMap({ self.auditionBlockReason(for: $0.target) }).first {
            toasts.show(reason, isError: true)
            return
        }
        let plan = OverwritePlan(
            kind: .send, items: items,
            title: "Send \(items.count) presets starting at slot \(slot.display)",
            freshnessLine: freshness.dialogLine,
            isPracticeDevice: connection.isPractice)
        presentPlan(plan)
    }

    /// The tap-only path: open the picker instead of dragging (UX §13.3).
    func requestSlotPicker(for transfers: [PresetTransfer]) {
        guard !transfers.isEmpty else { return }
        let title = transfers.count == 1
            ? "Send '\(transfers[0].displayName)' to…"
            : "Send \(transfers.count) presets starting at…"
        slotPickerRequest = SlotPickerRequest(
            purpose: .send(transfers: transfers), title: title)
    }

    /// Library "Assign Slot…" — local only, the device is not touched.
    func requestAssignSlotPicker(entryID: String) {
        guard let entry = libraryModel.entry(id: entryID) else { return }
        slotPickerRequest = SlotPickerRequest(
            purpose: .assign(entryID: entryID),
            title: "Assign '\(entry.name)' to slot… (library only)")
    }

    /// "Send Preset Here…" on a device slot row: copy between slots
    /// (≤ 1 read + 1 verified write, UX §8.1) via the tap-parity picker.
    func requestSlotPickerForCopy(of slot: SlotID) {
        guard let row = slots.record(slot), row.hasKnownName else { return }
        requestSlotPicker(for: [PresetTransfer(source: .deviceSlot(slot),
                                               displayName: row.name ?? "")])
    }

    func incoming(for transfer: PresetTransfer)
        -> OverwritePlan.Incoming {
        switch transfer.source {
        case .library(let entryID):
            return .libraryEntry(id: entryID)
        case .deviceSlot(let slot):
            return .deviceSlot(slot)
        case .backup(let path, let slot):
            let folder = (path as NSString).lastPathComponent
            return .backupSlot(folderName: folder, slot: slot)
        case .file(let file):
            return .mfFile(file)
        }
    }

    /// A transfer's real bytes — the drag-out export and library drops use
    /// the same cheapest-honest-source path as any send.
    func resolveTransfer(_ transfer: PresetTransfer) async throws -> Preset {
        try await resolvePreset(incoming(for: transfer))
    }

    /// Present per §9.5 severity. Confirm executes; Read First re-plans.
    /// `anchor` (a visible slot row) lets popover severity render there;
    /// without one, RootView falls back to the dialog presentation.
    func presentPlan(_ plan: OverwritePlan, anchor: SlotID? = nil) {
        pendingConfirmation = PendingConfirmation(plan: plan,
                                                  anchor: anchor) {
            [weak self] in
            self?.execute(plan)
        }
    }

    /// "Read First" (~1 s) for an unjudged victim → re-render the dialog
    /// with the real victim (UX §9.1).
    func readFirstThenReplan(_ plan: OverwritePlan) {
        guard let item = plan.items.first else { return }
        pendingConfirmation = nil
        guard let task = readSlot(item.target) else { return }
        Task { @MainActor in
            _ = try? await task.value
            let refreshed = OverwritePlan(
                kind: plan.kind,
                items: plan.items.map {
                    self.makePlanItem(target: $0.target,
                                      incomingName: $0.incomingName,
                                      incoming: $0.incoming)
                },
                title: plan.title,
                freshnessLine: self.freshness.dialogLine,
                isPracticeDevice: plan.isPracticeDevice,
                backupFolderName: plan.backupFolderName)
            self.presentPlan(refreshed)
        }
    }

    /// §9.2 escape hatch: one read → library, then re-present the plan.
    func saveACopyFirst(_ plan: OverwritePlan) {
        guard let item = plan.items.first else { return }
        pendingConfirmation = nil
        saveToLibrary(item.target, tags: []) { [weak self] in
            self?.presentPlan(plan)
        }
    }

    // ============================================================ execution

    func execute(_ plan: OverwritePlan) {
        pendingConfirmation = nil
        // The choke point every single and batch write shares (send, paste,
        // undo/redo, bulk sync): the audition's own restore would revert a
        // write to the borrowed slot and leave the undo stack describing a
        // state that no longer exists (UX addendum §30.4).
        if let reason = plan.items.lazy
            .compactMap({ self.auditionBlockReason(for: $0.target) }).first {
            toasts.show(reason, isError: true)
            return
        }
        if plan.items.count == 1, let item = plan.items.first {
            executeSingle(item, plan: plan)
        } else {
            executeBatch(plan)
        }
    }

    private func executeSingle(_ item: OverwritePlan.Item, plan: OverwritePlan) {
        Task { @MainActor in
            do {
                let incoming = try await self.resolvePreset(item.incoming)
                let victimBytes = await self.resolveVictimBytes(item.target)
                let report = try await self.enqueueVerifiedWrite(
                    slot: item.target, preset: incoming)
                self.afterVerifiedWrite(slot: item.target, preset: incoming,
                                        report: report,
                                        victimBytes: victimBytes,
                                        recordUndo: plan.kind != .undo)
            } catch let error as FreakError {
                self.presentWriteFailure(error, slot: item.target,
                                         incomingName: item.incomingName) {
                    self.executeSingle(item, plan: plan)
                }
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// Sequential batch; stops at the first failure (core restore semantics
    /// mirrored, UX §17 bulk apply / §8.1 multi-send).
    private func executeBatch(_ plan: OverwritePlan) {
        let run = BatchRunState(plan: plan)
        sendPlanRun = run
        Task { @MainActor in
            for item in plan.items where item.disabledReason == nil {
                if run.cancelled {
                    run.finished = true
                    self.history.record(.cancelledBatch, slot: item.target,
                                        identity: self.deviceIdentity,
                                        summary: "Batch cancelled before this slot")
                    return
                }
                run.markRunning(item.target)
                do {
                    let incoming = try await self.resolvePreset(item.incoming)
                    let victimBytes = await self.resolveVictimBytes(item.target)
                    let report = try await self.enqueueVerifiedWrite(
                        slot: item.target, preset: incoming)
                    self.afterVerifiedWrite(slot: item.target, preset: incoming,
                                            report: report,
                                            victimBytes: victimBytes,
                                            recordUndo: false, quiet: true)
                    run.markDone(item.target)
                } catch let error as FreakError {
                    run.markFailed(item.target, error.userMessage)
                    self.presentWriteFailure(
                        error, slot: item.target,
                        incomingName: item.incomingName,
                        batchContext: "Stopped here — \(run.doneCount) of "
                            + "\(plan.writeCount) slots done",
                        retryFrom: {
                            self.retryBatchRemaining(run)
                        }) {
                            self.retryBatchRemaining(run)
                        }
                    run.finished = true
                    return
                } catch {
                    run.markFailed(item.target, String(describing: error))
                    run.finished = true
                    self.toasts.show(String(describing: error), isError: true)
                    return
                }
            }
            run.finished = true
            self.toasts.show("Wrote \(run.doneCount) slots — all verified")
        }
    }

    func retryBatchRemaining(_ run: BatchRunState) {
        let remaining = Set(run.remaining.map(\.raw))
        guard !remaining.isEmpty else { return }
        var items = run.plan.items.filter { remaining.contains($0.target.raw) }
        if let failed = run.failure?.slot,
           let failedItem = run.plan.items.first(where: {
               $0.target == failed
           }) {
            items.insert(failedItem, at: 0)
        }
        let plan = OverwritePlan(kind: run.plan.kind, items: items,
                                 title: run.plan.title,
                                 freshnessLine: freshness.dialogLine,
                                 isPracticeDevice: run.plan.isPracticeDevice,
                                 backupFolderName: run.plan.backupFolderName)
        executeBatch(plan)
    }

    // ------------------------------------------------------ preset resolving

    func resolvePreset(_ incoming: OverwritePlan.Incoming) async throws
        -> Preset {
        switch incoming {
        case .preset(let preset):
            return preset
        case .libraryEntry(let id):
            return try await libraryModel.preset(id: id)
        case .deviceSlot(let slot):
            return try await bytesForSlot(slot)
        case .backupSlot(let folderName, let slot):
            guard let set = backups.set(folderName) else {
                throw FreakError.integrity(path: folderName,
                                           detail: "backup no longer loadable")
            }
            return try set.preset(slot.raw)
        case .mfFile(let file):
            return try file.preset()
        }
    }

    /// A slot's bytes, cheapest source first: a backup already holding this
    /// exact sha (disk, instant) → else one ~400 ms device read.
    func bytesForSlot(_ slot: SlotID) async throws -> Preset {
        if let sha = slots.record(slot)?.sha256,
           let summary = backups.backupHolding(slot: slot, sha256: sha),
           let set = backups.set(summary.folderName),
           let preset = try? set.preset(slot.raw) {
            return preset
        }
        guard let device else {
            throw FreakError.transport(detail: "no device connected")
        }
        let raw = slot.raw
        let task = operations.enqueue("Reading slot \(slot.display)",
                                      kind: .quick, slot: slot) { _ in
            try await device.read(slot: raw)
        }
        let preset = try await task.value
        slots.applyRead(slot, preset: preset)
        return preset
    }

    /// Undo eligibility (§9.6): only when the victim's EXACT bytes are held
    /// locally right now. Never reads the device.
    private func resolveVictimBytes(_ slot: SlotID) async -> Preset? {
        guard let row = slots.record(slot), let sha = row.sha256 else {
            return nil
        }
        if let entry = libraryModel.entriesSharing(sha256: sha).first,
           let preset = try? await libraryModel.preset(id: entry.id) {
            return preset
        }
        if let summary = backups.backupHolding(slot: slot, sha256: sha),
           let set = backups.set(summary.folderName),
           let preset = try? set.preset(slot.raw) {
            return preset
        }
        return nil
    }

    // ------------------------------------------------------------ the write

    /// The queued verified write — four visible phases (UX §8.2). The
    /// 7-frame burst is not cancellable (too short; a mid-burst cancel
    /// tears the slot).
    func enqueueVerifiedWrite(slot: SlotID, preset: Preset) async throws
        -> WriteReport {
        guard let device else {
            throw FreakError.transport(detail: "no device connected")
        }
        slots.setBusy(slot, true)
        defer { slots.setBusy(slot, false) }
        let raw = slot.raw
        let task = operations.enqueue(
            "Writing '\(preset.name)' to slot \(slot.display)",
            kind: .quick, slot: slot) { _ in
            // Verified by default — write + read-back + hash compare in core.
            try await device.write(slot: raw, preset: preset)
        }
        return try await task.value
    }

    private func afterVerifiedWrite(slot: SlotID, preset: Preset,
                                    report: WriteReport,
                                    victimBytes: Preset?,
                                    recordUndo: Bool,
                                    quiet: Bool = false) {
        slots.applyVerifiedWrite(slot, name: report.name,
                                 sha256: report.sha256, meta: preset.meta)
        freshness.noteWrite()
        history.record(.verifiedWrite, slot: slot, identity: deviceIdentity,
                       summary: "Verified write '\(report.name)'",
                       sha256: report.sha256)
        recomputeSync()

        if recordUndo, let victimBytes {
            undoStack.record(OverwriteRecord(
                slot: slot, victim: victimBytes, incoming: preset,
                description: "Sent '\(preset.name)' to slot \(slot.display)"))
        }
        guard !quiet else { return }
        let detail = "sha \(Format.shaPrefix(report.sha256, length: 8))"
        let message =
            "Sent '\(report.name)' to slot \(slot.display) — verified · \(detail)"
        if recordUndo && victimBytes != nil {
            toasts.show(message, actionLabel: "Undo", duration: 10) {
                [weak self] in self?.undoLast()
            }
        } else {
            toasts.show(message)
        }
    }

    // ===================================================== failure surfaces

    /// UX §14: verify-mismatch is the designed moment; chunk/mid-transfer
    /// failures flag the slot torn; everything else maps to toast/alert.
    func presentWriteFailure(_ error: FreakError, slot: SlotID,
                             incomingName: String,
                             batchContext: String? = nil,
                             retryFrom: (@MainActor () -> Void)? = nil,
                             writeAgain: @escaping @MainActor () -> Void) {
        switch error {
        case .verifyMismatch(let mismatch):
            slots.setVerifyFailed(slot)
            history.record(.verifyFailure, slot: slot,
                           identity: deviceIdentity,
                           summary: "Verify failed for '\(incomingName)'")
            verifyMismatch = VerifyMismatchPresentation(
                mismatch: mismatch, slot: slot,
                batchContext: batchContext,
                retryFromLabel: retryFrom != nil
                    ? "Retry From Slot \(slot.display)" : nil,
                retryFrom: retryFrom,
                writeAgain: writeAgain)
        case .chunkNotAcked(_, let chunkIndex):
            slots.setTorn(slot)
            history.record(.tornWrite, slot: slot, identity: deviceIdentity,
                           summary: "Write failed mid-transfer (chunk \(chunkIndex))")
            deviceAlert = tornAlert(
                slot: slot,
                message: "Write to slot \(slot.display) failed mid-transfer "
                    + "(chunk \(chunkIndex) unacknowledged). The slot's "
                    + "contents are unreliable.",
                writeAgain: writeAgain)
        case .writeAborted(let stage, _, _):
            let torn: Bool
            let phrase: String
            switch stage {
            case .nameWrite, .open:
                torn = false
                phrase = "failed before any preset data was sent"
            case .go, .chunk:
                torn = true
                phrase = "failed during transfer"
            case .finalRead:
                torn = true
                phrase = "failed reading the slot back after transfer"
            }
            if torn {
                slots.setTorn(slot)
                history.record(.tornWrite, slot: slot,
                               identity: deviceIdentity,
                               summary: "Write aborted (\(stage.rawValue))")
            }
            deviceAlert = tornAlert(
                slot: slot,
                message: "Write to slot \(slot.display) \(phrase).",
                writeAgain: writeAgain)
        case .operationCancelled:
            break  // expected path (UX §14)
        case .transport, .transportUnavailable:
            handleTransportLoss(error)
        default:
            toasts.show("Couldn't write slot \(slot.display): "
                + error.userMessage, isError: true, actionLabel: "Retry") {
                writeAgain()
            }
        }
    }

    private func tornAlert(slot: SlotID, message: String,
                           writeAgain: @escaping @MainActor () -> Void)
        -> DeviceAlert {
        let covered = !backups.coverage(of: slot, sha256: nil).isEmpty
        var secondaryLabel: String?
        var secondary: (@MainActor () -> Void)?
        if covered {
            secondaryLabel = "Restore from Backup"
            secondary = { [weak self] in
                self?.requestRestoreSlotFromBackup(slot)
            }
        }
        return DeviceAlert(
            title: "Write to slot \(slot.display) failed",
            message: message,
            primaryLabel: "Write Again",
            primary: writeAgain,
            secondaryLabel: secondaryLabel,
            secondary: secondary)
    }

    // ============================================================== rename

    /// Device rename in place (UX §8.3): name frame + refresh read only —
    /// no blob traffic. On failure the row reverts (we only patch on
    /// success) and the slot is NOT flagged torn.
    func renameSlot(_ slot: SlotID, to name: String) {
        guard let device else { return }
        // Renaming the borrowed slot renames the audition preset sitting in
        // it, and stop() then writes the original back over the whole thing.
        if let reason = auditionBlockReason(for: slot) {
            toasts.show(reason, isError: true)
            return
        }
        guard NameRules.isValid(name) else {
            toasts.show(NameRules.ruleCopy, isError: true)
            return
        }
        let oldName = slots.record(slot)?.name ?? ""
        guard name != oldName else { return }
        slots.setBusy(slot, true)
        let raw = slot.raw
        let task = operations.enqueue("Renaming slot \(slot.display)",
                                      kind: .quick, slot: slot) { _ in
            try await device.rename(slot: raw, name: name)
        }
        Task { @MainActor in
            defer { self.slots.setBusy(slot, false) }
            do {
                let report = try await task.value
                self.slots.patchName(slot, name: report.name)
                self.freshness.noteWrite()
                self.history.record(.rename, slot: slot,
                                    identity: self.deviceIdentity,
                                    summary: "Renamed '\(oldName)' → '\(report.name)'")
                self.recomputeSync()
                self.toasts.show("Renamed slot \(slot.display): "
                    + "'\(oldName)' → '\(report.name)'")
            } catch let error as FreakError {
                self.toasts.show("Rename failed: \(error.userMessage)",
                                 isError: true, actionLabel: "Retry") {
                    self.renameSlot(slot, to: name)
                }
            } catch {
                self.toasts.show("Rename failed: "
                    + "\(String(describing: error))", isError: true)
            }
        }
    }

    // ====================================================== save to library

    /// Save a device slot into the library (UX §5 context menu). Bytes come
    /// from the cheapest honest source (backup sha match, else one read).
    func saveToLibrary(_ slot: SlotID, tags: [String],
                       then completion: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                let entry = try await self.libraryModel.add(preset, slot: slot,
                                                            tags: tags)
                self.toasts.show("Saved '\(entry.name)' to the library")
                self.recomputeSync()
                completion?()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// Multi-select "Save N to Library" (UX §5): instant when every blob is
    /// already on disk from a backup; otherwise states the ~400 ms × N read
    /// cost first — a multi-second device read never starts silently.
    func saveManyToLibrary(_ slotIDs: [SlotID]) {
        guard !slotIDs.isEmpty else { return }
        let needsRead = slotIDs.filter { slot in
            guard let sha = slots.record(slot)?.sha256,
                  backups.backupHolding(slot: slot, sha256: sha) != nil else {
                return true
            }
            return false
        }
        let run: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            for slot in slotIDs { self.saveToLibrary(slot, tags: []) }
        }
        guard !needsRead.isEmpty else {
            run()
            return
        }
        let seconds = Double(needsRead.count) * 0.4
        deviceAlert = DeviceAlert(
            title: "Save \(slotIDs.count) presets to the library?",
            message: "\(needsRead.count) of them are not on disk yet and "
                + "need a ~400 ms device read each — about "
                + "\(Format.estimate(seconds)). The device is never modified.",
            primaryLabel: "Save \(slotIDs.count) Presets",
            primary: run)
    }

    /// Drops onto the library list (UX §8.1: slot row → library list saves
    /// to library; .mfpreset file → library imports it). Local + additive —
    /// no §9 guard needed.
    func saveTransferToLibrary(_ transfer: PresetTransfer) {
        Task { @MainActor in
            do {
                let preset = try await self.resolveTransfer(transfer)
                var slot: SlotID?
                if case .deviceSlot(let source) = transfer.source {
                    slot = source
                }
                let entry = try await self.libraryModel.add(preset, slot: slot,
                                                            tags: [])
                self.toasts.show("Saved '\(entry.name)' to the library")
                self.recomputeSync()
            } catch let error as FreakError {
                self.toasts.show("Couldn't save to library: "
                    + error.userMessage, isError: true)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    // ======================================================== undo (§9.6)

    func undoLast() {
        guard let record = undoStack.popForUndo() else { return }
        let item = makePlanItem(target: record.slot,
                                incomingName: record.victim.name,
                                incoming: .preset(record.victim))
        let plan = OverwritePlan(kind: .undo, items: [item],
                                 title: "Undo — \(record.description)",
                                 freshnessLine: freshness.dialogLine,
                                 isPracticeDevice: connection.isPractice)
        // Undo was §9-consented when offered; it executes directly and is
        // confirmed by its own verified toast.
        execute(plan)
    }

    func redoLast() {
        guard let record = undoStack.popForRedo() else { return }
        let item = makePlanItem(target: record.slot,
                                incomingName: record.incoming.name,
                                incoming: .preset(record.incoming))
        let plan = OverwritePlan(kind: .undo, items: [item],
                                 title: "Redo — \(record.description)",
                                 freshnessLine: freshness.dialogLine,
                                 isPracticeDevice: connection.isPractice)
        execute(plan)
    }

    // ======================================================== copy / paste

    func copySlot(_ slot: SlotID) {
        guard let row = slots.record(slot), row.hasKnownName else { return }
        copyBuffer = PresetTransfer(source: .deviceSlot(slot),
                                    displayName: row.name ?? "")
        toasts.show("Copied '\(row.name ?? "")'")
    }

    func pasteInto(_ slot: SlotID) {
        guard let buffer = copyBuffer else { return }
        // Identical guard rails (UX §5); anchored — paste comes from the
        // visible row's own context menu.
        requestSend(buffer, to: slot, anchor: slot)
    }
}
