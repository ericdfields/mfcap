// FreshnessModel.swift — backup freshness as a first-class value (UX §4).
//
// The single source for every freshness line: sidebar footer, Sync header,
// and the footer of every destructive dialog. Every device write increments
// writesSinceBackup; a completed full backup resets it. Counters persist in
// UserDefaults (UX §18.3), keyed per device identity.

import Foundation

@MainActor @Observable
final class FreshnessModel {
    private(set) var latestCompleteBackup: BackupSummary?
    private(set) var writesSinceBackup = 0
    var namesAsOf: Date?

    private var identityStamp = DeviceIdentity.none.stamp

    private var defaultsKey: String { "MFWritesSinceBackup.\(identityStamp)" }

    func adoptIdentity(_ identity: DeviceIdentity) {
        identityStamp = identity.stamp
        writesSinceBackup = UserDefaults.standard.integer(forKey: defaultsKey)
    }

    func noteWrite() {
        writesSinceBackup += 1
        UserDefaults.standard.set(writesSinceBackup, forKey: defaultsKey)
    }

    func noteBackups(_ summaries: [BackupSummary], identity: DeviceIdentity) {
        latestCompleteBackup = summaries.first {
            $0.isComplete && $0.identity.isPractice == identity.isPractice
        }
    }

    func noteCompletedFullBackup(_ summary: BackupSummary) {
        latestCompleteBackup = summary
        writesSinceBackup = 0
        UserDefaults.standard.set(0, forKey: defaultsKey)
    }

    func reset() {
        writesSinceBackup = 0
        namesAsOf = nil
        latestCompleteBackup = nil
    }

    /// "Last full backup: today 14:32 · 3 writes since" /
    /// "No complete backup yet — Back Up Now (~3.5 min)" (UX §9.3).
    var dialogLine: String {
        guard let backup = latestCompleteBackup else {
            return "No complete backup yet — Back Up Now (~3.5 min)"
        }
        let when = backup.createdDate.map { Format.relativeAge($0) }
            ?? backup.createdAt
        let writes = writesSinceBackup == 1
            ? "1 write since" : "\(writesSinceBackup) writes since"
        return "Last full backup: \(when) · \(writes)"
    }

    /// "Names as of 14:32" — list-header provenance (UX §4).
    var namesLine: String? {
        namesAsOf.map { "Names as of \(Format.timeOfDay($0))" }
    }
}
