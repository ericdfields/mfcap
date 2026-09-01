// Paths.swift — storage locations (architecture spec §10, §14.7).
//
// Library at Documents/Library/, backups at Documents/Backups/<stamp>/,
// history at Documents/history.json. UIFileSharingEnabled +
// LSSupportsOpeningDocumentsInPlace expose Documents in the Files app so
// libraries and backups move between iPad and Mac unchanged (they are the
// phase-0 formats, byte-compatible with the Python core). Practice-made
// backups get a "practice-" folder prefix (UX §11 identity separation) so
// they are never mistakable for hardware backups in a file listing.

import Foundation

struct AppPaths: Sendable {
    let libraryRoot: URL
    let backupsRoot: URL
    let historyURL: URL

    static func documents() -> AppPaths {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return AppPaths(libraryRoot: docs.appendingPathComponent("Library"),
                        backupsRoot: docs.appendingPathComponent("Backups"),
                        historyURL: docs.appendingPathComponent("history.json"))
    }

    /// An isolated, throwaway location — previews and tests only.
    static func ephemeral() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreakLibrarianPreview-\(UUID().uuidString)")
        return AppPaths(libraryRoot: root.appendingPathComponent("Library"),
                        backupsRoot: root.appendingPathComponent("Backups"),
                        historyURL: root.appendingPathComponent("history.json"))
    }

    /// "2026-09-01-143205"
    static func backupStamp(date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt.string(from: date)
    }

    /// New backup destination. Practice backups carry the "practice-" prefix.
    func newBackupFolder(identity: DeviceIdentity, date: Date = Date()) -> URL {
        let stamp = AppPaths.backupStamp(date: date)
        let name = identity.isPractice ? "practice-\(stamp)" : stamp
        return backupsRoot.appendingPathComponent(name)
    }
}

/// Which device an observation came from — stamped on snapshots, backups and
/// history (UX §4, §11). The app never diffs or restores across identities
/// without the explicit cross-identity warning.
enum DeviceIdentity: Equatable, Sendable, Codable {
    case none
    case hardware
    case practice(profile: String)

    var isPractice: Bool {
        if case .practice = self { return true }
        return false
    }

    /// "hardware" | "practice:factoryFresh" | "none"
    var stamp: String {
        switch self {
        case .none: return "none"
        case .hardware: return "hardware"
        case .practice(let profile): return "practice:\(profile)"
        }
    }

    /// Parse a backup folder name's identity ("practice-<stamp>" prefix).
    static func ofBackupFolder(named name: String) -> DeviceIdentity {
        name.hasPrefix("practice-") ? .practice(profile: "unknown") : .hardware
    }
}
