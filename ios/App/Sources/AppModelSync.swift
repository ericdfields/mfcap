// AppModelSync.swift — sync-view intents (UX §17).
//
// Sync compares the device against ONE baseline COLLECTION the user chose.
// The diff computes; only explicit user actions write. The full read pass IS
// a backup (UX §1.2): Read Device & Compare runs the one "read everything"
// operation, which persists in the phase-0 format — refreshing the sync view
// produces a backup as a byproduct.
//
// There is exactly ONE definition of "how does my device differ from this
// collection": the core's decision table. The Sync screen renders its
// read-only half (`computeDiff`); Apply renders its write half (`planApply`)
// through the existing CollectionApplyPlanSheet.

import Foundation
import FreakCore

extension AppModel {

    /// The collection Sync is comparing against: the user's explicit pick, or
    /// a defensible default. Never an arbitrary collection — a wrong default
    /// is how the merged-mash baseline happened in the first place.
    var resolvedSyncBaseline: PresetCollection? {
        if let syncBaselineID,
           let coll = collectionsModel.collection(id: syncBaselineID) {
            return coll
        }
        // Fall back to the newest snapshot of THIS device identity — the one
        // collection that provably describes this device's own arrangement.
        return collectionsModel.collections
            .filter { $0.provenance.kind == .deviceSnapshot
                && $0.provenance.source.hasPrefix("practice")
                    == deviceIdentity.isPractice }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Recompute the pure diff from the cached hashed snapshot + the chosen
    /// baseline collection, then mirror badges onto the browser rows.
    func recomputeSync() {
        let snapshot = slots.hashedSnapshot()
        let provenance: SyncModel.Provenance? = snapshot == nil ? nil
            : SyncModel.Provenance(date: slots.hashedAsOf,
                                   backupStamp: slots.hashedProvenance)
        sync.recompute(snapshot: snapshot, baseline: resolvedSyncBaseline,
                       provenance: provenance)
        slots.applySyncBadges(sync.badges)
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

    /// `unlisted` / any row → Save to Library — instant, bytes already on
    /// disk from the snapshot-backup. Additive; no guard. The catalog is a
    /// flat set of unique patches, so this claims NO slot: where the preset
    /// belongs on the device is a collection's business.
    func syncSaveRowToLibrary(_ diff: SlotDiff) {
        let slot = SlotID(diff.slot)
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                let entry = try await self.libraryModel.add(preset, slot: nil,
                                                            tags: [])
                self.toasts.show("Saved '\(entry.name)' to the library")
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    /// `changed` / `missing` → Send the collection's preset to the device
    /// (verified write, full §9 dialog). The baseline is a PresetRef, so the
    /// bytes are resolved from the library first; a ref whose blob is gone
    /// surfaces the same sentence collection Apply uses, never a silent skip.
    func syncSendBaselineRow(_ diff: SlotDiff) {
        guard let ref = diff.baseline else { return }
        let slot = SlotID(diff.slot)
        // Say it before the confirmation, not after it: a write to the
        // borrowed slot would be silently reverted by the audition's restore.
        if let reason = auditionBlockReason(for: slot) {
            toasts.show(reason, isError: true)
            return
        }
        Task { @MainActor in
            do {
                let preset = try await self.libraryModel.presetForRef(ref)
                let item = self.makePlanItem(target: slot,
                                             incomingName: ref.name,
                                             incoming: .preset(preset))
                let plan = OverwritePlan(
                    kind: .send, items: [item],
                    title: "Send '\(ref.name)' to slot \(slot.display)",
                    freshnessLine: self.freshness.dialogLine,
                    isPracticeDevice: self.connection.isPractice)
                self.presentPlan(plan)          // §9 confirmation, then write
            } catch {
                // Say only what was actually checked: this path resolves
                // through `presetForRef`, which reads the library's blob
                // store and nothing else. Backups are never consulted here,
                // so promising they were sends the user re-importing when
                // the real remedy is to restore the missing blob.
                self.toasts.show(
                    "'\(ref.name)' can't be sent — its bytes aren't in your "
                    + "library — re-import the bank or re-snapshot the device",
                    isError: true)
            }
        }
    }

    /// `changed` / name-only / `unlisted` → Update the collection from the
    /// device — a LOCAL edit of the baseline collection, never a device
    /// write. "The device is right; remember it this way."
    ///
    /// The bytes come off the device or a backup, so they are NOT yet in the
    /// library's blob store. `storePreset` puts them there and mints the ref;
    /// a ref built straight from `PresetRef(preset:)` would name a blob that
    /// does not exist, and `planApply` folds an unresolvable ref to SKIP — so
    /// "Make Device Match '<name>'" would silently skip exactly the slots the
    /// user adopted, forever.
    func syncAdoptRowIntoBaseline(_ diff: SlotDiff) {
        guard let baseline = sync.baseline,
              let library = libraryModel.library else { return }
        let slot = SlotID(diff.slot)
        Task { @MainActor in
            do {
                let preset = try await self.bytesForSlot(slot)
                var slotsMap = baseline.slots
                slotsMap[diff.slot] = try await library.storePreset(preset)
                try await library.saveCollection(PresetCollection(
                    id: baseline.id, name: baseline.name,
                    createdAt: baseline.createdAt,
                    provenance: baseline.provenance, slots: slotsMap))
                await self.collectionsModel.refresh(from: library)
                self.toasts.show("'\(baseline.name)' now expects "
                    + "'\(preset.name)' at slot \(slot.display)")
                self.recomputeSync()
            } catch let error as FreakError {
                self.surfaceQuickError(error, slot: slot)
            } catch {
                self.toasts.show(String(describing: error), isError: true)
            }
        }
    }

    // ============================================ catalog-side bulk action

    /// "Save unlisted presets to Library…" — the local, additive half the old
    /// bulk-apply sheet used to carry. Never a device write; never a slot
    /// claim. Presets whose exact bytes are already catalogued are skipped.
    func saveUnlistedToLibrary() {
        guard let diff = sync.diff else { return }
        let rows = diff.byStatus(.unlisted).filter {
            guard let sha = $0.device?.sha256 else { return false }
            return libraryModel.entriesSharing(sha256: sha).isEmpty
        }
        guard !rows.isEmpty else {
            toasts.show("Every preset outside this collection is already in "
                + "your library.")
            return
        }
        Task { @MainActor in
            var saved = 0
            for row in rows {
                let slot = SlotID(row.slot)
                do {
                    let preset = try await self.bytesForSlot(slot)
                    _ = try await self.libraryModel.add(preset, slot: nil,
                                                        tags: [])
                    saved += 1
                } catch let error as FreakError {
                    self.surfaceQuickError(error, slot: slot)
                } catch {
                    self.toasts.show(String(describing: error), isError: true)
                }
            }
            if saved > 0 {
                self.toasts.show("Saved \(saved) preset\(saved == 1 ? "" : "s") "
                    + "to the library")
            }
            self.recomputeSync()
        }
    }
}
