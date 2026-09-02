// AppModelCollections.swift — collection intents: create-from-device,
// import-bank, and Apply/Switch (UX addendum §26, §27; data-model spec §5, §6).
//
// The diff computes (pure `planApply`); only an explicit, §9-confirmed Switch
// writes. Execution runs through the core's cancellable `applyCollection` as a
// single `.long` device operation — exactly like `executeRestore` — so the
// switch surfaces determinate aggregate progress and a working Cancel on the
// global status bar, verified writes, cancel between slots, and stop-at-first-
// failure, while this layer never touches frames or bytes.

import Foundation
import FreakCore

/// The create-from-device name prompt (NewCollectionSheet).
struct NewCollectionRequest: Identifiable {
    let id = UUID()
    var defaultName: String
    var isPractice: Bool
}

extension AppModel {

    func refreshCollections() {
        Task { @MainActor in
            await self.collectionsModel.refresh(from: self.libraryModel.library)
        }
    }

    /// The detail view's live readiness line — the same pure diff the
    /// pre-flight uses, so the two never disagree (UX addendum §26.4). nil
    /// when the device isn't hashed (no honest count to show yet).
    func collectionChangeSummary(_ coll: PresetCollection) -> String? {
        guard let snapshot = slots.hashedSnapshot(),
              let plan = try? planApply(collection: coll, snapshot: snapshot,
                                        options: ApplyOptions()) else { return nil }
        let n = plan.writeCount + plan.clearCount
        return "Switching now changes \(n) of \(plan.totalSlots) slots "
            + "(~\(Int(plan.estimatedSeconds.rounded())) s)."
    }

    // ===================================================== create from device

    /// "Create from Device…" (UX addendum §26.2). A faithful arrangement needs
    /// every slot's sha + meta — a full hashed pass, which IS a backup (§1.2).
    func requestNewCollectionFromDevice() {
        guard connection.hasDevice else {
            toasts.show("Connect a device to snapshot an arrangement.",
                        isError: true)
            return
        }
        if slots.hasHashedSnapshot {
            promptNewCollectionName()
        } else {
            deviceAlert = DeviceAlert(
                title: "Read the device first",
                message: "Capturing an arrangement reads every slot "
                    + "(~3½ minutes) and keeps it as a backup. The device is "
                    + "never modified.",
                primaryLabel: "Read Device & Snapshot",
                primary: { [weak self] in self?.readDeviceThenPromptCollection() })
        }
    }

    private func readDeviceThenPromptCollection() {
        runFullBackup { [weak self] result in
            guard let self, case .success = result else { return }
            self.promptNewCollectionName()
        }
    }

    private func promptNewCollectionName() {
        newCollectionRequest = NewCollectionRequest(
            defaultName: "Snapshot \(AppPaths.backupStamp())",
            isPractice: connection.isPractice)
    }

    /// Commit the create-from-device: build a collection off the current
    /// hashed snapshot (data-model spec §5.1). The library is not modified.
    func createCollectionFromDevice(name: String) {
        newCollectionRequest = nil
        guard let library = libraryModel.library,
              let snapshot = slots.hashedSnapshot() else {
            toasts.show("Need a full device read first.", isError: true)
            return
        }
        Task { @MainActor in
            do {
                let coll = try await library.collectionFromSnapshot(
                    snapshot, name: name, source: self.deviceIdentity.stamp)
                await self.collectionsModel.refresh(from: library)
                self.toasts.show("Saved '\(coll.name)' — \(coll.slots.count) "
                    + "presets from this device.")
            } catch let error as FreakError {
                self.toasts.show("Couldn't snapshot: \(error.userMessage)",
                                 isError: true)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    // ========================================================= import a bank

    /// "Import Bank…" (UX addendum §26.3). Parses an MCC export entirely on
    /// disk (no device), adds one Uncategorized library entry per placed
    /// preset, and creates an IMPORTED_BANK collection mapping the slots.
    func importBank(url: URL) {
        Task { @MainActor in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let library = libraryModel.library else { return }
            do {
                let data = try Data(contentsOf: url)
                let items = try MFProjzImport.parse(
                    data: data, filename: url.lastPathComponent)
                let name = url.deletingPathExtension().lastPathComponent
                let (coll, added) = try await library.collectionFromBank(
                    items, name: name, source: url.lastPathComponent)
                await self.libraryModel.refresh()
                await self.collectionsModel.refresh(from: library)
                self.recomputeSync()
                self.toasts.show("Imported '\(coll.name)' — \(added.count) "
                    + "presets added (Uncategorized) · \(coll.slots.count) "
                    + "slots mapped.")
            } catch FreakError.protocolViolation(let detail) {
                self.toasts.show("Not a MicroFreak bank — \(detail)",
                                 isError: true)
            } catch let error as FreakError {
                self.toasts.show("Import failed: \(error.userMessage)",
                                 isError: true)
            } catch {
                self.toasts.show("Import failed: \(String(describing: error))",
                                 isError: true)
            }
        }
    }

    // ========================================================= apply / switch

    /// Entry point for Apply/Switch — every path funnels here so the §11
    /// cross-identity gate cannot be bypassed (UX addendum §27.5).
    func requestCollectionApply(id: String,
                                crossIdentityConfirmed: Bool = false) {
        guard let coll = collectionsModel.collection(id: id) else { return }
        guard connection.hasDevice else {
            toasts.show("Connect a device to switch.", isError: true)
            return
        }
        if !crossIdentityConfirmed, isCrossIdentity(coll) {
            deviceAlert = DeviceAlert(
                title: "Cross-identity switch",
                message: crossIdentityMessage(coll),
                primaryLabel: "Continue Anyway",
                primary: { [weak self] in
                    self?.requestCollectionApply(id: id,
                                                 crossIdentityConfirmed: true)
                })
            return
        }
        guard slots.hasHashedSnapshot else {
            deviceAlert = DeviceAlert(
                title: "Read the device first",
                message: "An accurate, minimal switch compares the device's "
                    + "current contents (~3½ minutes, kept as a backup).",
                primaryLabel: "Read Device & Compare",
                primary: { [weak self] in
                    self?.readDeviceThenApply(id: id) })
            return
        }
        Task { @MainActor in
            if let plan = await self.buildCollectionApplyPlan(collection: coll) {
                self.collectionApplyRequest = plan
            }
        }
    }

    private func readDeviceThenApply(id: String) {
        runFullBackup { [weak self] result in
            guard let self, case .success = result else { return }
            self.requestCollectionApply(id: id, crossIdentityConfirmed: true)
        }
    }

    /// A collection carries its provenance identity; a device_snapshot from a
    /// practice device applied to hardware (or vice versa) is cross-identity.
    /// Imported banks / manual collections carry no identity — no gate.
    private func isCrossIdentity(_ coll: PresetCollection) -> Bool {
        guard coll.provenance.kind == .deviceSnapshot else { return false }
        let fromPractice = coll.provenance.source.hasPrefix("practice")
        return fromPractice != deviceIdentity.isPractice
    }

    private func crossIdentityMessage(_ coll: PresetCollection) -> String {
        coll.provenance.source.hasPrefix("practice")
            ? "This collection was snapshotted from a practice device, not "
                + "your MicroFreak."
            : "This collection came from hardware, but you are connected to a "
                + "practice device."
    }

    /// Build the pre-flight: the pure core diff (`planApply`) plus §9 victim
    /// previews and the pre-resolved bytes for each changed slot (data-model
    /// spec §6.3). Slots whose bytes aren't on disk are pre-disabled.
    func buildCollectionApplyPlan(collection coll: PresetCollection) async
        -> CollectionApplyPlan? {
        guard let snapshot = slots.hashedSnapshot(),
              let library = libraryModel.library else { return nil }
        let plan: ApplyPlan
        do {
            plan = try planApply(collection: coll, snapshot: snapshot,
                                 options: ApplyOptions())
        } catch {
            toasts.show("Couldn't plan the switch: "
                + "\(String(describing: error))", isError: true)
            return nil
        }

        var resolved: [String: Preset] = [:]
        var unresolvable: [Int] = []
        var items: [OverwritePlan.Item] = []
        for sp in plan.changes() {
            let slot = SlotID(sp.slot)
            guard let ref = sp.incoming else { continue }
            let key = CollectionApplyPlan.refKey(ref)
            if let cached = resolved[key] {
                items.append(OverwritePlan.Item(
                    target: slot, incomingName: ref.name,
                    incoming: .preset(cached), victim: victimFacts(slot)))
            } else if let preset = try? await library.presetForRef(ref) {
                resolved[key] = preset
                items.append(OverwritePlan.Item(
                    target: slot, incomingName: ref.name,
                    incoming: .preset(preset), victim: victimFacts(slot)))
            } else {
                unresolvable.append(sp.slot)
                var item = OverwritePlan.Item(
                    target: slot, incomingName: ref.name,
                    incoming: .deviceSlot(slot), victim: victimFacts(slot))
                item.disabledReason =
                    "bytes not in the library or any backup — re-import or "
                    + "re-snapshot"
                items.append(item)
            }
        }
        let overwrite = OverwritePlan(
            kind: .applyCollection, items: items,
            title: "Switch to '\(coll.name)'",
            freshnessLine: freshness.dialogLine,
            isPracticeDevice: connection.isPractice)
        return CollectionApplyPlan(
            collectionID: coll.id, collectionName: coll.name, plan: plan,
            overwrite: overwrite, resolved: resolved,
            unresolvableSlots: unresolvable, isPractice: connection.isPractice)
    }

    /// Execute a confirmed Switch through the core's cancellable
    /// `applyCollection` path — ONE `.long` device operation, exactly like
    /// `executeRestore`. Because it is `.long`, it surfaces a determinate
    /// progress bar and a working Cancel in the global status bar (UX addendum
    /// §27; the hard "progress + cancellation in both core and UI" rule). The
    /// core writes only the resolvable changed slots, ascending; unresolvable
    /// ones are folded to SKIP so they never abort the run. Cancellation is
    /// Task cancellation (Cancel → `.operationCancelled` → `.applyFailed`);
    /// it stops at the first failure with Retry From Slot N.
    func executeCollectionApply(_ applyPlan: CollectionApplyPlan) {
        guard device != nil else { return }
        collectionApplyRequest = nil
        runCollectionApply(applyPlan, from: nil)
    }

    private func runCollectionApply(_ applyPlan: CollectionApplyPlan,
                                    from startSlot: SlotID?) {
        guard let device else { return }

        // The plan the core executes: only resolvable changed slots, at or
        // after startSlot on a retry. Everything else becomes SKIP, so
        // `changes()` (what applyCollection writes) holds exactly the slots we
        // can and want to write. Diff and estimate stay owned by the pre-flight
        // ApplyPlan; this is only the execution filter.
        let unresolvable = Set(applyPlan.unresolvableSlots)
        let minSlot = startSlot?.raw ?? 0
        let execSlots = applyPlan.plan.slots.map { sp -> SlotPlan in
            let changed = sp.action == .write || sp.action == .clear
            if changed, !unresolvable.contains(sp.slot), sp.slot >= minSlot {
                return sp
            }
            return SlotPlan(slot: sp.slot, action: .skip,
                            incoming: nil, victim: nil)
        }
        let writeCount = execSlots.filter { $0.action == .write }.count
        let clearCount = execSlots.filter { $0.action == .clear }.count
        let execPlan = ApplyPlan(
            slots: execSlots, writeCount: writeCount, clearCount: clearCount,
            skipCount: execSlots.count - writeCount - clearCount,
            totalSlots: applyPlan.plan.totalSlots,
            estimatedSeconds: applyPlan.plan.estimatedSeconds)

        let changes = execPlan.changes()
        guard !changes.isEmpty else {
            toasts.show("Nothing to switch — no writable changed slots.")
            return
        }

        // Pre-resolved bytes: the resolver is a pure lookup inside the
        // (Sendable) closure — never a mid-apply actor hop. Also mapped by slot
        // for the post-write meta patch.
        let resolved = applyPlan.resolved
        var presetBySlot: [Int: Preset] = [:]
        for sp in changes {
            if let ref = sp.incoming,
               let p = resolved[CollectionApplyPlan.refKey(ref)] {
                presetBySlot[sp.slot] = p
            }
        }

        let run = BatchRunState(plan: applyPlan.overwrite)
        collectionRun = run
        let name = applyPlan.collectionName

        // Progress events ride a bufferingNewest(1) stream and are DISPLAY-only
        // here; row state and the journal are reconciled from the returned
        // WriteReports (success) or error.completed (failure), which are exact.
        let task = operations.enqueue(
            "Switching \(changes.count) slots", kind: .long,
            onProgress: { [weak run] event in
                run?.markDone(SlotID(event.slot))
            }
        ) { progress in
            try await device.applyCollection(
                plan: execPlan,
                resolve: { ref in
                    guard let preset =
                        resolved[CollectionApplyPlan.refKey(ref)] else {
                        throw FreakError.integrity(
                            path: ref.name,
                            detail: "preset bytes not resolved for switch")
                    }
                    return preset
                },
                verify: true, progress: progress)
        }

        Task { @MainActor in
            do {
                let reports = try await task.value
                run.finished = true
                for report in reports {
                    self.applyCollectionReport(report,
                                               presetBySlot: presetBySlot,
                                               collectionName: name)
                }
                self.recomputeSync()
                self.toasts.show("Switched to '\(name)' — \(reports.count) "
                    + "slots written, all verified")
            } catch let error as FreakError {
                run.finished = true
                self.handleCollectionApplyFailure(
                    error, run: run, applyPlan: applyPlan,
                    presetBySlot: presetBySlot)
            } catch {
                run.finished = true
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// Reconcile one verified WriteReport into the slot cache + journal.
    private func applyCollectionReport(_ report: WriteReport,
                                       presetBySlot: [Int: Preset],
                                       collectionName: String) {
        let slot = SlotID(report.slot)
        collectionRun?.markDone(slot)
        slots.applyVerifiedWrite(slot, name: report.name,
                                 sha256: report.sha256,
                                 meta: presetBySlot[report.slot]?.meta)
        freshness.noteWrite()
        history.record(.verifiedWrite, slot: slot, identity: deviceIdentity,
                       summary: "Applied from collection '\(collectionName)'",
                       sha256: report.sha256)
    }

    /// Mirror of `handleRestoreFailure`: reconcile the completed reports, then
    /// map the outcome. A user Cancel (`.operationCancelled`) leaves the
    /// completed rows standing and is never a red surface; a genuine failure
    /// stops at the failing slot with Retry From Slot N (UX addendum §27.4).
    private func handleCollectionApplyFailure(
        _ error: FreakError, run: BatchRunState,
        applyPlan: CollectionApplyPlan, presetBySlot: [Int: Preset]) {
        guard case .applyFailed(let underlying, let completed) = error else {
            if case .operationCancelled = error {
                toasts.show("Switch stopped — \(run.doneCount) slots written")
            } else {
                surfaceQuickError(error, slot: nil)
            }
            return
        }
        for report in completed {
            applyCollectionReport(report, presetBySlot: presetBySlot,
                                  collectionName: applyPlan.collectionName)
        }
        recomputeSync()

        if case .operationCancelled = underlying {
            toasts.show("Switch stopped — \(completed.count) of "
                + "\(applyPlan.writableCount) slots written")
            return
        }

        // The failing slot: the first resolvable changed slot not completed.
        let doneSet = Set(completed.map(\.slot))
        let unresolvable = Set(applyPlan.unresolvableSlots)
        let failing = applyPlan.plan.changes().first {
            !unresolvable.contains($0.slot) && !doneSet.contains($0.slot)
        }
        guard let failing else {
            surfaceQuickError(underlying, slot: nil)
            return
        }
        let failingSlot = SlotID(failing.slot)
        run.markFailed(failingSlot, underlying.userMessage)
        let context = "Switch stopped here — \(completed.count) of "
            + "\(applyPlan.writableCount) written"
        presentWriteFailure(
            underlying, slot: failingSlot,
            incomingName: failing.incoming?.name ?? "",
            batchContext: context,
            retryFrom: { [weak self] in
                self?.runCollectionApply(applyPlan, from: failingSlot)
            }) { [weak self] in
                self?.runCollectionApply(applyPlan, from: failingSlot)
            }
    }

    // ===================================================== device-slot favorite

    /// Favorite a device slot (UX addendum §24.2). Favorite is a library
    /// attribute, so: matching library entry → toggle it; no entry yet → Save
    /// to Library first (auto-category from the device byte) then favorite.
    /// A names-only row has no sha to match and is refused with the reason.
    func toggleFavoriteForSlot(_ slot: SlotID) {
        guard let sha = slots.record(slot)?.sha256 else {
            toasts.show("Read this slot first to favorite it.", isError: true)
            return
        }
        if let entry = libraryModel.entriesSharing(sha256: sha).first {
            Task { await libraryModel.toggleFavorite(id: entry.id) }
            return
        }
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                let bytes = Array(preset.meta)
                let category: FreakCore.Category = bytes.count >= 8
                    ? FreakCore.Category.fromDeviceByte(bytes[7]) : .uncategorized
                let entry = try await self.libraryModel.add(
                    preset, slot: slot, tags: [], category: category,
                    favorite: true)
                self.toasts.show("Saved '\(entry.name)' and added it to "
                    + "Favorites.")
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }
}
