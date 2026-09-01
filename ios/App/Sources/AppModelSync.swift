// AppModelSync.swift — sync-view intents (UX §17).
//
// The diff computes; only explicit user actions write. The full read pass IS
// a backup (UX §1.2): Read Device & Compare runs the one "read everything"
// operation, which persists in the phase-0 format — refreshing the sync view
// produces a backup as a byproduct.

import Foundation
import FreakCore

extension AppModel {

    /// Recompute the pure diff from the cached hashed snapshot + library,
    /// then mirror badges onto the browser rows.
    func recomputeSync() {
        let snapshot = slots.hashedSnapshot()
        let provenance: SyncModel.Provenance? = snapshot == nil ? nil
            : SyncModel.Provenance(date: slots.hashedAsOf,
                                   backupStamp: slots.hashedProvenance)
        Task { @MainActor in
            await self.sync.recompute(snapshot: snapshot,
                                      library: self.libraryModel.library,
                                      provenance: provenance)
            self.slots.applySyncBadges(self.sync.badges)
        }
    }

    /// Restore the hashed tier from the latest complete same-identity backup
    /// once names are known (UX §18.3) — marked with the backup's age.
    func adoptHashedTierFromLatestBackup() {
        guard let latest = backups.latestComplete(identity: deviceIdentity),
              let set = backups.set(latest.folderName) else { return }
        slots.adoptHashedTier(records: set.records(),
                              asOf: latest.createdDate,
                              provenance: latest.folderName)
        recomputeSync()
    }

    /// "Read Device & Compare" — the full pass, kept as a backup (UX §17).
    func readDeviceAndCompare() {
        sync.beginComparing()
        runFullBackup { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // runFullBackup already applied the hashed snapshot and
                // recomputed; nothing more to do.
                break
            case .cancelled:
                self.sync.reset()
                self.recomputeSync()
            case .failure(let message):
                self.sync.failCompare(message)
            }
        }
    }

    // ================================================ per-row actions (§17)

    /// `added` → Import to Library — instant, bytes already on disk from the
    /// snapshot-backup. Additive; no guard.
    func syncImportRow(_ diff: SlotDiff) {
        let slot = SlotID(diff.slot)
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                let entry = try await self.libraryModel.add(preset, slot: slot,
                                                            tags: [])
                self.toasts.show("Imported '\(entry.name)' to the library")
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// `changed` → Push Library → Device (verified write, full §9 dialog).
    func syncPushRow(_ diff: SlotDiff) {
        guard let entry = diff.library else { return }
        requestSend(PresetTransfer(source: .library(entryID: entry.id),
                                   displayName: entry.name),
                    to: SlotID(diff.slot))
    }

    /// `changed` → Pull Device → Library — instant; the new entry takes the
    /// slot claim; the old entry is kept with its claim cleared (stated in
    /// the row copy, UX §17).
    func syncPullRow(_ diff: SlotDiff) {
        let slot = SlotID(diff.slot)
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                let entry = try await self.libraryModel.add(preset, slot: slot,
                                                            tags: [])
                self.toasts.show("Pulled '\(entry.name)' into the library — "
                    + "it now claims slot \(slot.display)")
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// `missing` → Send to Device (verified write; §9 popover — the victim
    /// is expendable, evidence shown).
    func syncSendRow(_ diff: SlotDiff) {
        guard let entry = diff.library else { return }
        requestSend(PresetTransfer(source: .library(entryID: entry.id),
                                   displayName: entry.name),
                    to: SlotID(diff.slot))
    }

    // ==================================================== bulk apply (§17)

    func openBulkApply() {
        bulkApplyPlan = sync.buildBulkPlan()
    }

    /// Execute the Apply… sheet's confirmed selection: imports/pulls are
    /// local library adds; sends/pushes become one confirmed batch write
    /// that stops at the first failure.
    func runBulkApply(imports: [SlotDiff], sends: [SlotDiff],
                      conflicts: [Int: BulkApplyPlan.ConflictChoice]) {
        bulkApplyPlan = nil
        var pulls: [SlotDiff] = []
        var pushes: [SlotDiff] = []
        if let diff = sync.diff {
            for row in diff.byStatus(.differs) {
                switch conflicts[row.slot] ?? .skip {
                case .pull: pulls.append(row)
                case .push: pushes.append(row)
                case .skip: break
                }
            }
        }

        // Local, additive side first — instant.
        let importRows = imports + pulls
        Task { @MainActor in
            var imported = 0
            for row in importRows {
                let slot = SlotID(row.slot)
                do {
                    let preset = try await self.bytesForSlot(slot)
                    _ = try await self.libraryModel.add(preset, slot: slot,
                                                        tags: [])
                    imported += 1
                } catch let error as FreakError {
                    self.surfaceQuickError(error, slot: slot)
                } catch {
                    self.toasts.show(String(describing: error), isError: true)
                }
            }
            if imported > 0 {
                self.toasts.show("Imported \(imported) preset\(imported == 1 ? "" : "s") to the library")
            }
            self.recomputeSync()

            // Device side: one batch behind the §9 plan the sheet confirmed.
            let writeRows = sends + pushes
            guard !writeRows.isEmpty else { return }
            let items: [OverwritePlan.Item] = writeRows.compactMap { row in
                guard let entry = row.library else { return nil }
                return self.makePlanItem(
                    target: SlotID(row.slot),
                    incomingName: entry.name,
                    incoming: .libraryEntry(id: entry.id))
            }
            let plan = OverwritePlan(
                kind: .bulkSync, items: items,
                title: "Apply sync changes",
                freshnessLine: self.freshness.dialogLine,
                isPracticeDevice: self.connection.isPractice)
            self.execute(plan)
        }
    }
}
