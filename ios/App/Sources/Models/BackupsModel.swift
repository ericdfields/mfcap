// BackupsModel.swift — the on-disk backup catalog (UX §16, §18.2).
//
// Backups are FreakCore phase-0 folders under Documents/Backups/<stamp>/ —
// portable to the Mac/Python tooling unchanged. Loading a set re-hashes
// every blob (BackupSet.load), so a listed-and-openable backup is a
// verified one; integrity failures surface as per-backup badges and are
// never auto-deleted. Writing to the device happens only through a
// confirmed restore plan (AppModelBackup).

import Foundation
import FreakCore

struct BackupSummary: Identifiable, Sendable, Equatable {
    let folderName: String
    let path: URL
    let createdAt: String            // core timestamp from index.json
    let coveredCount: Int
    let totalSlots: Int
    let identity: DeviceIdentity
    let sizeBytes: Int64

    var id: String { folderName }
    var isComplete: Bool { coveredCount >= totalSlots }

    /// "512/512" or "partial · 341/512" (UX §16.1).
    var coverageLabel: String {
        isComplete ? "\(coveredCount)/\(totalSlots)"
                   : "partial · \(coveredCount)/\(totalSlots)"
    }

    var createdDate: Date? { Format.parseCoreTimestamp(createdAt) }
}

@MainActor @Observable
final class BackupsModel {
    let root: URL
    private(set) var items: [BackupSummary] = []
    /// folderName → integrity/corruption detail (badge, never auto-delete).
    private(set) var loadFailures: [String: String] = [:]
    private(set) var scanning = false
    private var loadedSets: [String: BackupSet] = [:]

    init(root: URL) {
        self.root = root
    }

    // -------------------------------------------------------------- scan

    func refresh() async {
        scanning = true
        defer { scanning = false }
        let rootURL = root
        let result = await Task.detached(priority: .utility) {
            Self.scan(root: rootURL)
        }.value
        items = result.summaries
        loadFailures = result.failures
        loadedSets = result.sets
    }

    private nonisolated static func scan(root: URL)
        -> (summaries: [BackupSummary], failures: [String: String],
            sets: [String: BackupSet]) {
        var summaries: [BackupSummary] = []
        var failures: [String: String] = [:]
        var sets: [String: BackupSet] = [:]
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath {
            let name = folder.lastPathComponent
            do {
                let set = try BackupSet.load(folder)
                let covered = set.coveredSlots()
                summaries.append(BackupSummary(
                    folderName: name,
                    path: folder,
                    createdAt: set.createdAt,
                    coveredCount: covered.count,
                    totalSlots: SlotID.Layout.slots,
                    identity: DeviceIdentity.ofBackupFolder(named: name),
                    sizeBytes: folderSize(folder)))
                sets[name] = set
            } catch let error as FreakError {
                failures[name] = error.userMessage
            } catch {
                failures[name] = String(describing: error)
            }
        }
        summaries.sort { ($0.createdDate ?? .distantPast)
                       > ($1.createdDate ?? .distantPast) }
        return (summaries, failures, sets)
    }

    private nonisolated static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: url,
                                        includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey])
                .fileSize) ?? 0)
        }
        return total
    }

    // -------------------------------------------------------------- reads

    func summary(_ folderName: String) -> BackupSummary? {
        items.first { $0.folderName == folderName }
    }

    func set(_ folderName: String) -> BackupSet? {
        loadedSets[folderName]
    }

    func noteCompleted(_ set: BackupSet, folderName: String) {
        loadedSets[folderName] = set
    }

    /// Latest complete backup matching an identity, for freshness + imports.
    func latestComplete(identity: DeviceIdentity) -> BackupSummary? {
        items.first { $0.isComplete && $0.identity.isPractice == identity.isPractice }
    }

    /// Partial backups offering Resume (UX §16.1).
    var resumable: [BackupSummary] {
        items.filter { !$0.isComplete }
    }

    /// Backups whose records cover a slot, with sha match info (UX §7.7).
    func coverage(of slot: SlotID, sha256: String?)
        -> [(summary: BackupSummary, matches: Bool?)] {
        items.compactMap { summary in
            guard let set = loadedSets[summary.folderName],
                  set.covers(slot.raw) else { return nil }
            let recordSha = set.records().first { $0.slot == slot.raw }?.sha256
            let matches: Bool? = sha256.flatMap { current in
                recordSha.map { $0 == current }
            }
            return (summary, matches)
        }
    }

    /// The most recent backup holding EXACTLY these bytes at this slot —
    /// the honest-recoverability check (UX §9.2, §9.6).
    func backupHolding(slot: SlotID, sha256: String) -> BackupSummary? {
        for summary in items {
            guard let set = loadedSets[summary.folderName] else { continue }
            if set.records().contains(where: {
                $0.slot == slot.raw && $0.sha256 == sha256
            }) {
                return summary
            }
        }
        return nil
    }

    /// Guard facts for Delete (UX §16.1): is this the only complete backup?
    func deleteGuard(_ folderName: String) -> (name: String, onlyComplete: Bool)? {
        guard let summary = summary(folderName) else { return nil }
        let completeCount = items.filter(\.isComplete).count
        return (summary.folderName,
                summary.isComplete && completeCount == 1)
    }

    func delete(_ folderName: String) async {
        guard let summary = summary(folderName) else { return }
        try? FileManager.default.removeItem(at: summary.path)
        loadedSets[folderName] = nil
        await refresh()
    }

    // --------------------------------------- snapshot bridge (import/diff)

    /// A DeviceSnapshot built from a backup's records — WITHOUT blobs
    /// (diff/provenance use). Lazy blobs stay on disk.
    nonisolated static func snapshot(of set: BackupSet) -> DeviceSnapshot {
        DeviceSnapshot(takenAt: set.createdAt, records: set.records(),
                       timing: set.timing)
    }

    /// A DeviceSnapshot WITH blob bytes for Library.importSnapshot (which
    /// requires kept blobs). Reads every covered NNN.bin — run off main.
    /// Pre-meta phase-0 records (meta_hex absent) load their blob directly
    /// so the snapshot stays importable; their meta stays nil, which
    /// Library.importSnapshot skips by design — a legacy backup must not
    /// fail the whole import via BackupSet.preset's .integrity throw.
    nonisolated static func snapshotWithBlobs(of set: BackupSet) throws
        -> DeviceSnapshot {
        let records = try set.records().map { record -> SlotRecord in
            guard record.sha256 != nil else { return record }
            let blob: Data
            if record.meta != nil {
                blob = try set.preset(record.slot).blob
            } else {
                let binPath = set.path
                    .appendingPathComponent("presets")
                    .appendingPathComponent(String(format: "%03d.bin",
                                                   record.slot))
                blob = try Data(contentsOf: binPath)
            }
            return SlotRecord(slot: record.slot, name: record.name,
                              sha256: record.sha256, meta: record.meta,
                              blob: blob)
        }
        return DeviceSnapshot(takenAt: set.createdAt, records: records,
                              timing: set.timing)
    }
}
