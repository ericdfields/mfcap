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

enum SeedInstaller {
    /// Bumped only if a future seed bundle must re-seed existing installs.
    static let marker = "MFSeedInstalled.v1"

    /// Install the bundled seed into `libraryRoot` iff it has never run and
    /// the user has no library yet. Runs before `Library.open`.
    static func installIfNeeded(libraryRoot: URL,
                                defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: marker) else { return }
        let fm = FileManager.default
        let indexPath = libraryRoot.appendingPathComponent("index.json").path
        // A user library already exists — never overwrite it; just record
        // that seeding is done so it is not attempted again.
        if fm.fileExists(atPath: indexPath) {
            defaults.set(true, forKey: marker)
            return
        }
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
        } catch {
            // Copy failed (disk pressure, sandbox quirk): leave the library
            // absent so openOrCreate() makes an empty one — the app still
            // works, and seeding retries next launch (marker still unset).
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
