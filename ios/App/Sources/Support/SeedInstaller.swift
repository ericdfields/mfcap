// SeedInstaller.swift — first-run seeding of the bundled starter library
// (App/Resources/SeedBanks, README there).
//
// The bundle ships a complete, content-addressed FreakCore library — index,
// deduped blobs, and one PresetCollection per bank — as read-only app
// resources. On the very first launch (no user library yet) we copy that tree
// into the user's writable library directory so a brand-new install opens
// with a full browsable library and 18 ready-to-apply banks, no device
// attached. Because the store is content-addressed, this is safe and
// idempotent; a one-shot marker keeps it from ever clobbering user edits.
//
// Seeding is deliberately a plain directory copy of the phase-0 on-disk
// shape (data-model spec §0, §2.1, §4.1) — no bytes are inspected here; the
// app layer never parses library files itself (Library.open owns that).

import Foundation
import FreakCore

enum SeedInstaller {
    /// Bumped only if a future seed bundle must re-seed existing installs.
    static let marker = "MFSeedInstalled.v1"
    /// v2 folds the full MCC-store seed into libraries that already existed
    /// before the seed shipped (a fresh install gets everything via the copy
    /// path and needs no merge).
    static let mergeMarker = "MFSeedMerged.v2"

    /// Install the bundled seed into `libraryRoot`. On a fresh install (no
    /// library yet) the seed is copied wholesale. On an existing library the
    /// seed's collections are MERGED in once (idempotent, content-addressed),
    /// never overwriting the user's own entries. Runs before `Library.open`.
    static func installIfNeeded(libraryRoot: URL,
                                defaults: UserDefaults = .standard) {
        let fm = FileManager.default
        let indexPath = libraryRoot.appendingPathComponent("index.json").path
        // A user library already exists — never overwrite it. The bundled
        // seed is folded in later by `mergeIfNeeded` (async, needs an open
        // Library actor); here we only record that the copy path is done.
        if fm.fileExists(atPath: indexPath) {
            defaults.set(true, forKey: marker)
            return
        }
        guard !defaults.bool(forKey: marker) else { return }
        // No bundle present (unit tests, preview sandbox) — leave the marker
        // unset so a real install still seeds on a later launch.
        guard let seedLibrary = bundledSeedLibrary() else { return }
        do {
            try fm.createDirectory(
                at: libraryRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fm.fileExists(atPath: libraryRoot.path) {
                try fm.removeItem(at: libraryRoot)
            }
            try fm.copyItem(at: seedLibrary, to: libraryRoot)
            defaults.set(true, forKey: marker)
            defaults.set(true, forKey: mergeMarker)   // fresh copy already has it all
        } catch {
            // Copy failed (disk pressure, sandbox quirk): leave the library
            // absent so openOrCreate() makes an empty one — the app still
            // works, and seeding retries next launch (marker still unset).
        }
    }

    /// Fold the bundled seed's collections into an already-open user library,
    /// once (guarded by the v2 marker). Idempotent and content-addressed;
    /// never touches entries the user already has. A fresh install took the
    /// copy path and set the marker there, so this is a no-op for it.
    static func mergeIfNeeded(into library: Library,
                              defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: mergeMarker) else { return }
        guard let seedLibrary = bundledSeedLibrary() else { return }
        do {
            let seed = try Library.open(at: seedLibrary)
            try await library.mergeBundle(from: seed)
            defaults.set(true, forKey: mergeMarker)
        } catch {
            // Leave the marker unset so the merge retries on a later launch.
        }
    }

    /// One-time cleanup for libraries seeded/merged before dedup shipped: an
    /// early merge stacked the seed on top of a device-import, leaving exact
    /// duplicate patches (same content + name). Collapse them once.
    static let dedupeMarker = "MFDeduped.v1"

    @discardableResult
    static func dedupeIfNeeded(_ library: Library,
                               defaults: UserDefaults = .standard) async -> Bool {
        guard !defaults.bool(forKey: dedupeMarker) else { return false }
        do {
            let removed = try await library.dedupe()
            defaults.set(true, forKey: dedupeMarker)
            return removed > 0
        } catch {
            return false   // retry next launch (marker stays unset)
        }
    }

    /// The `library/` subfolder of the bundled `SeedBanks` folder reference,
    /// or nil when the resource is not in the bundle.
    static func bundledSeedLibrary() -> URL? {
        guard let base = Bundle.main.url(forResource: "SeedBanks",
                                         withExtension: nil) else { return nil }
        let lib = base.appendingPathComponent("library")
        let index = lib.appendingPathComponent("index.json")
        return FileManager.default.fileExists(atPath: index.path) ? lib : nil
    }
}
