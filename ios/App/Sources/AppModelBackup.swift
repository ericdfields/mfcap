// AppModelBackup.swift — backup and restore intents (UX §16).
//
// One "read everything" operation: a full pass always persists in the
// phase-0 backup format (UX §1.2). Pause IS cancel — the on-disk partial is
// the pause state (per-slot persistence); Resume runs with resume: true and
// skips intact slots. Restore stops at the first failure (core semantics)
// and surfaces the completed list, the failing slot, and Retry From Slot N.

import Foundation
import FreakCore

/// The running/paused backup shown by BackupProgressSheet + the status bar.
@MainActor @Observable
final class BackupRunState: Identifiable {
    enum Purpose: Equatable { case manual, compare }
    enum Phase: Equatable {
        case running
        case paused(done: Int, total: Int)
        case failed(String)
        case done
    }

    let id = UUID()
    let folderName: String
    let purpose: Purpose
    let isResume: Bool
    var progress: ProgressEvent?
    var phase: Phase = .running
    var timing: TimingReport?
    var task: Task<BackupSet, Error>?

    init(folderName: String, purpose: Purpose, isResume: Bool) {
        self.folderName = folderName
        self.purpose = purpose
        self.isResume = isResume
    }

    /// Pause is cancel; the partial on disk is the pause state (UX §16.1).
    func pause() { task?.cancel() }
}

enum BackupOutcome {
    case success
    case cancelled
    case failure(String)
}

/// Restore entry: which backup, and the §16.2 scope step's inputs.
struct RestorePlanRequest: Identifiable {
    enum Scope: Hashable {
        case fullDevice
        case selectedSlots([Int])
        case differingSlots         // needs a current hashed snapshot
        case singleSlot(SlotID)
    }

    let id = UUID()
    let folderName: String
    var scope: Scope = .fullDevice
}

extension AppModel {

    // ============================================================== backup

    /// "Back Up Now" (Device + Backups toolbars, ⌘B). Pre-flight copy lives
    /// in the views: reads all 512 slots; the device is never modified.
    func backUpNow() {
        guard sync.state != .comparing else { return }
        // Belt-and-braces behind the disabled buttons/⌘B: never enqueue a
        // second full pass behind a running exclusive long op.
        guard operations.exclusiveLongOp == nil else { return }
        runFullBackup { _ in }
    }

    func resumeBackup(_ folderName: String) {
        runFullBackup(resumeFolder: folderName) { _ in }
    }

    /// The one full-pass operation (manual backup AND sync compare).
    func runFullBackup(resumeFolder: String? = nil,
                       purpose: BackupRunState.Purpose = .manual,
                       onComplete: @escaping @MainActor (BackupOutcome) -> Void) {
        guard let device else {
            onComplete(.failure("No device connected"))
            return
        }
        let dest: URL
        let folderName: String
        if let resumeFolder,
           let summary = backups.summary(resumeFolder) {
            dest = summary.path
            folderName = resumeFolder
        } else {
            dest = paths.newBackupFolder(identity: deviceIdentity)
            folderName = dest.lastPathComponent
        }
        let options: BackupOptions = {
            var o = BackupOptions()
            o.resume = resumeFolder != nil
            return o
        }()

        let run = BackupRunState(folderName: folderName, purpose: purpose,
                                 isResume: resumeFolder != nil)
        backupRun = run
        backupInterruptedBanner = nil
        showBackupProgressSheet = true

        let task = operations.enqueue(
            "Backing up", kind: .long,
            onProgress: { [weak run] event in
                run?.progress = event
            }
        ) { progress in
            try await device.backup(to: dest, options: options,
                                    progress: progress)
        }
        run.task = task

        Task { @MainActor in
            do {
                let set = try await task.value
                self.backups.noteCompleted(set, folderName: folderName)
                await self.backups.refresh()
                run.phase = .done
                run.timing = set.timing

                let summary = self.backups.summary(folderName)
                if let summary, summary.isComplete {
                    self.freshness.noteCompletedFullBackup(summary)
                } else {
                    self.freshness.noteBackups(self.backups.items,
                                               identity: self.deviceIdentity)
                }
                // A hashed pass and a backup are the same wire traffic —
                // adopt it as the hashed snapshot tier (UX §1.2, §4).
                self.slots.applySnapshot(
                    BackupsModel.snapshot(of: set), hashed: true,
                    provenance: folderName)
                self.recomputeSync()
                let total = set.timing.totalSeconds
                self.toasts.show("Backup complete — "
                    + "\(Int(total.rounded())) s total · "
                    + Format.throughput(perSlotSeconds: set.timing.perSlotSeconds))
                onComplete(.success)
            } catch let error as FreakError {
                await self.backups.refresh()
                self.freshness.noteBackups(self.backups.items,
                                           identity: self.deviceIdentity)
                if case .operationCancelled(let done, let total) = error {
                    // Paused — the partial IS valid and resumable (UX §16.1).
                    run.phase = .paused(done: done, total: total)
                    onComplete(.cancelled)
                } else {
                    run.phase = .failed(error.userMessage)
                    if case .transport = error {
                        self.handleTransportLoss(error)
                        let at = (run.progress?.done).map { " at slot \($0)" } ?? ""
                        self.backupInterruptedBanner =
                            "Backup interrupted\(at) — Resume?"
                    } else {
                        self.surfaceQuickError(error, slot: nil)
                    }
                    onComplete(.failure(error.userMessage))
                }
            } catch {
                run.phase = .failed(String(describing: error))
                onComplete(.failure(String(describing: error)))
            }
        }
    }

    // ============================================================= restore

    /// Restore entry — EVERY restore path funnels through here, so the §11
    /// cross-identity warning cannot be bypassed: restoring a practice
    /// backup to hardware (or vice versa) always demands the explicit
    /// "Continue Anyway" first.
    func requestRestore(from folderName: String,
                        scope: RestorePlanRequest.Scope = .fullDevice,
                        crossIdentityConfirmed: Bool = false) {
        if !crossIdentityConfirmed,
           let summary = backups.summary(folderName),
           summary.identity.isPractice != deviceIdentity.isPractice {
            let message = summary.identity.isPractice
                ? "This backup came from a practice device, not your "
                    + "MicroFreak."
                : "This backup came from hardware, but you are connected to "
                    + "a practice device."
            deviceAlert = DeviceAlert(
                title: "Cross-identity restore",
                message: message,
                primaryLabel: "Continue Anyway",
                primary: { [weak self] in
                    self?.requestRestore(from: folderName, scope: scope,
                                         crossIdentityConfirmed: true)
                })
            return
        }
        restorePlanRequest = RestorePlanRequest(folderName: folderName,
                                                scope: scope)
    }

    /// Per-slot restore from SlotDetailView / torn-slot recovery: newest
    /// covering backup, preferring one from the connected device's identity
    /// (a cross-identity fallback still triggers the §11 warning).
    func requestRestoreSlotFromBackup(_ slot: SlotID) {
        let covering = backups.coverage(of: slot, sha256: nil)
        let sameIdentity = covering.first {
            $0.summary.identity.isPractice == deviceIdentity.isPractice
        }
        guard let pick = sameIdentity ?? covering.first else {
            toasts.show("No backup covers slot \(slot.display).", isError: true)
            return
        }
        requestRestore(from: pick.summary.folderName,
                       scope: .singleSlot(slot))
    }

    /// Build the §16.2 plan: every planned write lists its victim; slots the
    /// backup cannot faithfully restore (missing meta) are pre-disabled with
    /// the core's own sentence. Runs the automatic ~2 s names refresh first
    /// when cached names are older than 10 minutes.
    func buildRestorePlan(_ request: RestorePlanRequest) async
        -> OverwritePlan? {
        guard let set = backups.set(request.folderName) else { return nil }

        // Fresh victims: auto names refresh when stale (UX §16.2).
        if let asOf = slots.namesAsOf,
           Date().timeIntervalSince(asOf) > 600,
           let task = refreshNames() {
            _ = try? await task.value
        } else if slots.namesAsOf == nil, let task = refreshNames() {
            _ = try? await task.value
        }

        let records = set.records()
        let covered = Set(set.coveredSlots())
        let slotsWanted: [Int]
        switch request.scope {
        case .fullDevice:
            slotsWanted = set.coveredSlots()
        case .selectedSlots(let raw):
            slotsWanted = raw.sorted().filter(covered.contains)
        case .singleSlot(let slot):
            slotsWanted = covered.contains(slot.raw) ? [slot.raw] : []
        case .differingSlots:
            slotsWanted = set.coveredSlots().filter { raw in
                guard let current = slots.record(SlotID(raw))?.sha256 else {
                    return true   // unjudged counts as differing until read
                }
                let backupSha = records.first { $0.slot == raw }?.sha256
                return backupSha != current
            }
        }

        let items: [OverwritePlan.Item] = slotsWanted.map { raw in
            let slot = SlotID(raw)
            let record = records.first { $0.slot == raw }
            var item = makePlanItem(
                target: slot,
                incomingName: record?.name ?? "",
                incoming: .backupSlot(folderName: request.folderName,
                                      slot: slot))
            if record?.meta == nil {
                item.disabledReason =
                    "no meta recorded — re-backup to restore this slot"
            }
            return item
        }
        return OverwritePlan(
            kind: .restore, items: items,
            title: "Restore from \(request.folderName)",
            freshnessLine: freshness.dialogLine,
            isPracticeDevice: connection.isPractice,
            backupFolderName: request.folderName)
    }

    /// Execute a confirmed restore through the core's restore path: verified
    /// writes, stop at first failure, `.completed` reports on error.
    func executeRestore(_ plan: OverwritePlan) {
        guard let device,
              let folderName = plan.backupFolderName,
              let set = backups.set(folderName) else { return }
        restorePlanRequest = nil
        let run = BatchRunState(plan: plan)
        restoreRun = run
        let wanted = plan.items.filter { $0.disabledReason == nil }
            .map(\.target.raw)
        guard !wanted.isEmpty else { return }

        // Progress events ride a bufferingNewest(1) stream and may be
        // dropped under load — they are DISPLAY-ONLY here. Row state and the
        // history journal are reconciled from the returned WriteReports
        // (success path) or error.completed (failure path), which are exact.
        let task = operations.enqueue(
            "Restoring \(wanted.count) slots", kind: .long,
            onProgress: { [weak run] event in
                run?.markDone(SlotID(event.slot))
            }
        ) { progress in
            try await device.restore(from: set, slots: wanted, verify: true,
                                     progress: progress)
        }

        Task { @MainActor in
            do {
                let reports = try await task.value
                run.finished = true
                for report in reports {
                    let slot = SlotID(report.slot)
                    run.markDone(slot)
                    self.noteRestoredSlot(slot, folderName: folderName)
                    self.slots.applyVerifiedWrite(slot,
                                                  name: report.name,
                                                  sha256: report.sha256,
                                                  meta: nil)
                    self.freshness.noteWrite()
                }
                self.recomputeSync()
                self.toasts.show("Restored \(reports.count) slots — all verified")
            } catch let error as FreakError {
                run.finished = true
                self.handleRestoreFailure(error, run: run, plan: plan)
            } catch {
                run.finished = true
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    private func noteRestoredSlot(_ slot: SlotID, folderName: String) {
        history.record(.restore, slot: slot, identity: deviceIdentity,
                       summary: "Restored from backup \(folderName)")
    }

    private func handleRestoreFailure(_ error: FreakError, run: BatchRunState,
                                      plan: OverwritePlan) {
        guard case .restoreFailed(let underlying, let completed) = error else {
            if case .operationCancelled = error {
                // Expected path: the completed rows stand; never red (UX §14).
                toasts.show("Restore stopped — \(run.doneCount) slots done")
            } else {
                surfaceQuickError(error, slot: nil)
            }
            return
        }
        for report in completed {
            let slot = SlotID(report.slot)
            run.markDone(slot)
            if let folder = plan.backupFolderName {
                noteRestoredSlot(slot, folderName: folder)
            }
            slots.applyVerifiedWrite(slot, name: report.name,
                                     sha256: report.sha256, meta: nil)
            freshness.noteWrite()
        }
        recomputeSync()

        if case .operationCancelled = underlying {
            // Cancel-between-slots: the completed reports render as the
            // done-list; never a red surface (UX §14).
            toasts.show("Restore stopped — \(completed.count) of "
                + "\(plan.writeCount) slots done")
            return
        }

        // The failing slot: first planned slot that didn't complete.
        let doneSet = Set(completed.map(\.slot))
        let failing = plan.items.first {
            $0.disabledReason == nil && !doneSet.contains($0.target.raw)
        }
        guard let failing else {
            surfaceQuickError(underlying, slot: nil)
            return
        }
        run.markFailed(failing.target, underlying.userMessage)
        let context = "Restore stopped here — \(completed.count) of "
            + "\(plan.writeCount) slots done"
        presentWriteFailure(
            underlying, slot: failing.target,
            incomingName: failing.incomingName,
            batchContext: context,
            retryFrom: { [weak self] in
                self?.retryRestore(plan, from: failing.target)
            }) { [weak self] in
                self?.retryRestore(plan, from: failing.target)
            }
    }

    /// "Retry From Slot N" (UX §16.2).
    func retryRestore(_ plan: OverwritePlan, from slot: SlotID) {
        let items = plan.items.filter { $0.target.raw >= slot.raw }
        let rest = OverwritePlan(kind: .restore, items: items,
                                 title: plan.title,
                                 freshnessLine: freshness.dialogLine,
                                 isPracticeDevice: plan.isPracticeDevice,
                                 backupFolderName: plan.backupFolderName)
        executeRestore(rest)
    }

    // ======================================================= import device

    /// Library "Import Device…" — off the latest complete backup; offers to
    /// run a backup when none exists (UX §6). Expendable slots skipped by
    /// default, stated in the sheet.
    func importDeviceToLibrary(skipExpendable: Bool) {
        guard let latest = backups.latestComplete(identity: deviceIdentity),
              let set = backups.set(latest.folderName) else {
            deviceAlert = DeviceAlert(
                title: "No complete backup yet",
                message: "Importing the whole device works from a backup. "
                    + "Run one now (~3½ minutes)? The device is never "
                    + "modified by a backup.",
                primaryLabel: "Back Up Now",
                primary: { [weak self] in self?.backUpNow() })
            return
        }
        Task { @MainActor in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try BackupsModel.snapshotWithBlobs(of: set)
                }.value
                let added = try await self.libraryModel.importSnapshot(
                    snapshot, skipExpendable: skipExpendable)
                self.toasts.show("Imported \(added.count) presets from "
                    + "backup \(latest.folderName)")
                self.recomputeSync()
            } catch let error as FreakError {
                self.toasts.show("Import failed: \(error.userMessage)",
                                 isError: true)
            } catch {
                self.toasts.show("Import failed: "
                    + "\(String(describing: error))", isError: true)
            }
        }
    }
}
