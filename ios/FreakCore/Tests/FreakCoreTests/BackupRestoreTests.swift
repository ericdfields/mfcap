// BackupRestoreTests.swift — backup/restore round-trip on the phase-0
// on-disk format, per-slot persistence + cancellation mid-backup, resume
// semantics, load-time integrity re-hash, old-index-without-meta_hex
// behavior, and restore's stop-at-first-failure with
// .restoreFailed(underlying:completed:).

import Foundation
import Testing
@testable import FreakCore

// straddles the 384 boundary and both ends of the device
private let backupSlots = [0, 1, 2, 3, 383, 384, 509, 510, 511]

private func backupOptions(slots: [Int]? = nil, resume: Bool = false) -> BackupOptions {
    var o = BackupOptions()
    o.slots = slots
    o.resume = resume
    return o
}

@Suite("Backup and restore")
struct BackupRestoreTests {

    @Test func roundTripWreckRestore() async throws {
        let work = tempDir("backup-roundtrip")
        defer { try? FileManager.default.removeItem(at: work) }

        let sim = SimulatedMicroFreak.factoryFresh()       // lag ON, the default
        let device = makeDevice(sim)
        var originals: [Int: Preset] = [:]
        for s in backupSlots {
            originals[s] = try await sim.peek(slot: s)
        }

        // ---- backup to the phase-0 on-disk format ------------------------
        let dest = work.appendingPathComponent("backup")
        let (reporter, collector) = collectingReporter()
        let bs = try await device.backup(to: dest,
                                         options: backupOptions(slots: backupSlots),
                                         progress: reporter)
        #expect(bs.coveredSlots() == backupSlots)
        let indexRaw = try Data(contentsOf: dest.appendingPathComponent("index.json"))
        let index = try JSONSerialization.jsonObject(with: indexRaw) as! [String: Any]
        let presets = index["presets"] as! [String: Any]
        for s in backupSlots {
            let entry = presets[String(s)] as! [String: Any]
            let want = originals[s]!
            #expect(entry["name"] as? String == want.name, "slot \(s)")
            #expect(entry["sha256"] as? String == want.sha256, "slot \(s)")
            #expect((entry["bytes"] as? NSNumber)?.intValue == Wire.blobSize)
            #expect(entry["meta_hex"] as? String == want.meta.hexString, "slot \(s)")
            let bin = dest.appendingPathComponent("presets")
                .appendingPathComponent(String(format: "%03d.bin", s))
            #expect(try Data(contentsOf: bin) == want.blob, "slot \(s)")
        }
        let events = await collector.value
        #expect(events.map(\.done) == Array(1...backupSlots.count))
        var faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")

        // ---- wreck the device --------------------------------------------
        for (i, s) in backupSlots.enumerated() {
            await sim.load(slot: s, preset: try Preset(
                name: "Wrecked \(i)", blob: blob7(100 + i),
                meta: Data(count: Wire.metaLength)))
        }
        for s in backupSlots {
            #expect(try await sim.peek(slot: s).blob != originals[s]!.blob)
            #expect(try await sim.peek(slot: s).name != originals[s]!.name)
        }

        // ---- restore: byte-identical, hash-verified ----------------------
        let loaded = try BackupSet.load(dest)
        let reports = try await device.restore(from: loaded)   // covered slots, verify on
        #expect(reports.map(\.slot) == backupSlots)
        #expect(reports.allSatisfy { $0.verified == true })
        for s in backupSlots {
            let got = try await sim.peek(slot: s)
            let want = originals[s]!
            #expect(got.blob == want.blob, "slot \(s) blob differs after restore")
            #expect(got.name == want.name, "slot \(s)")
            #expect(got.meta == want.meta, "slot \(s) meta not round-tripped")
        }
        faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")   // incl. payload[8]/[9] at 384+

        // restore is write traffic: one 0x15 go per slot
        let gos = await sim.wireLog().filter {
            $0.direction == .out && Wire.parse($0.raw)?.cmd == Wire.cmdGo
        }.count
        #expect(gos == backupSlots.count)

        // ---- tampered blob file: load re-hash names the bad slot ---------
        let victim = dest.appendingPathComponent("presets/384.bin")
        let good = try Data(contentsOf: victim)
        var tampered = [UInt8](good)
        tampered[100] ^= 0x01
        try Data(tampered).write(to: victim)
        let e = expectFreakError { try BackupSet.load(dest) }
        guard case .integrity(let path, let detail) = e else {
            Issue.record("tampered blob must fail the load re-hash, got \(String(describing: e))")
            return
        }
        #expect(path.contains("384") || detail.contains("384"))
        try good.write(to: victim)
        _ = try BackupSet.load(dest)                       // healthy again

        // ---- a second backup of the restored device matches the first ----
        let dest2 = work.appendingPathComponent("backup2")
        let bs2 = try await makeDevice(sim).backup(
            to: dest2, options: backupOptions(slots: backupSlots), progress: nil)
        for s in backupSlots {
            #expect(try bs2.preset(s) == (try loaded.preset(s)), "slot \(s)")
        }
    }

    /// Cancellation mid-backup: each slot is on disk before the next is
    /// read, so the interrupted pass leaves valid, loadable partial state —
    /// and resume finishes the job reading only the missing slots.
    @Test func cancelledBackupLeavesResumablePartialState() async throws {
        let work = tempDir("backup-cancel")
        defer { try? FileManager.default.removeItem(at: work) }
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        // cancel right after slot index 2's dump completes (3rd dump open)
        let counter = Counter()
        let wire = SelfCancellingTransport(sim) { f in
            f.cmd == Wire.cmdOpen && f.data.last == 1 && counter.increment() == 3
        }
        let device = makeDevice(wire)
        let dest = work.appendingPathComponent("backup")
        let slots = [0, 1, 2, 3, 4, 5]
        let task = Task {
            try await device.backup(to: dest, options: backupOptions(slots: slots),
                                    progress: nil)
        }
        await #expect(throws: FreakError.operationCancelled(done: 3, total: 6)) {
            try await task.value
        }
        // the partial state is valid and loadable: slots 0..2 are on disk
        let partial = try BackupSet.load(dest)
        #expect(partial.coveredSlots() == [0, 1, 2])
        #expect(try partial.preset(2) == (try await sim.peek(slot: 2)))
        // resume completes the pass, re-reading only the missing slots
        let resumed = try await makeDevice(sim).backup(
            to: dest, options: backupOptions(slots: slots, resume: true), progress: nil)
        #expect(resumed.coveredSlots() == slots)
        let dumpOpens = await sim.wireLog().filter {
            guard $0.direction == .out, let f = Wire.parse($0.raw) else { return false }
            return f.cmd == Wire.cmdOpen && f.data.last == 1
        }.count
        #expect(dumpOpens == 6, "3 before the cancel + 3 on resume")
    }

    @Test func resumeSkipsPersistedSlots() async throws {
        let work = tempDir("backup-resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let dest = work.appendingPathComponent("backup")
        _ = try await device.backup(to: dest, options: backupOptions(slots: [0, 1]),
                                    progress: nil)
        let dumpsBefore = await sim.wireLog().filter {
            guard $0.direction == .out, let f = Wire.parse($0.raw) else { return false }
            return f.cmd == Wire.cmdOpen && f.data.last == 1
        }.count
        #expect(dumpsBefore == 2)
        let bs = try await device.backup(
            to: dest, options: backupOptions(slots: [0, 1, 2], resume: true),
            progress: nil)
        let dumpsAfter = await sim.wireLog().filter {
            guard $0.direction == .out, let f = Wire.parse($0.raw) else { return false }
            return f.cmd == Wire.cmdOpen && f.data.last == 1
        }.count
        #expect(dumpsAfter == 3, "resume must re-read only the missing slot")
        #expect(bs.coveredSlots() == [0, 1, 2], "the resumed index merges old and new slots")
    }

    @Test func loadFailuresAndOldIndexes() async throws {
        let work = tempDir("backup-load")
        defer { try? FileManager.default.removeItem(at: work) }

        // missing index -> .libraryCorrupt
        let e1 = expectFreakError { try BackupSet.load(work.appendingPathComponent("nope")) }
        guard case .libraryCorrupt = e1 else {
            Issue.record("expected .libraryCorrupt, got \(String(describing: e1))")
            return
        }

        // build a healthy one-slot backup
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let dest = work.appendingPathComponent("backup")
        let bs = try await makeDevice(sim).backup(
            to: dest, options: backupOptions(slots: [5]), progress: nil)
        #expect(bs.covers(5) && !bs.covers(6))
        #expect(throws: FreakError.slotOutOfRange(slot: 6)) {
            try bs.preset(6)
        }
        let records = bs.records()
        #expect(records.count == 1 && records[0].slot == 5)
        #expect(records[0].name == "Patch 005" && records[0].meta != nil)
        #expect(records[0].blob == nil, "records are lazy: no blob")

        // strip meta_hex (a pre-meta phase-0 index): still loads, still
        // diffs, but preset() refuses with the re-backup message
        let indexPath = dest.appendingPathComponent("index.json")
        var index = try JSONSerialization.jsonObject(
            with: Data(contentsOf: indexPath)) as! [String: Any]
        var presets = index["presets"] as! [String: Any]
        var entry = presets["5"] as! [String: Any]
        entry.removeValue(forKey: "meta_hex")
        presets["5"] = entry
        index["presets"] = presets
        try AtomicFile.write(try jsonData(index), to: indexPath)
        let old = try BackupSet.load(dest)
        #expect(old.covers(5))
        #expect(old.records()[0].meta == nil)
        let e2 = expectFreakError { try old.preset(5) }
        guard case .integrity(_, let detail) = e2 else {
            Issue.record("expected .integrity, got \(String(describing: e2))")
            return
        }
        #expect(detail.contains("no meta recorded"))
    }

    // ------------------------------------------------ restore stop semantics

    @Test func restoreStopsAtFirstFailure() async throws {
        let work = tempDir("restore-stop")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let dest = work.appendingPathComponent("backup")
        let bs = try await makeDevice(source).backup(
            to: dest, options: backupOptions(slots: [1, 2, 3]), progress: nil)

        // chunk cumulative index 151 = slot 2's chunk 5 goes unacked
        let target = SimulatedMicroFreak.factoryFresh(replyLag: false,
                                                      failChunkAt: 146 + 5)
        let device = makeDevice(target)
        let e = await expectFreakErrorAsync {
            try await device.restore(from: bs)
        }
        guard case .restoreFailed(let underlying, let completed) = e else {
            Issue.record("expected .restoreFailed, got \(String(describing: e))")
            return
        }
        #expect(completed.map(\.slot) == [1], "only slot 1 completed")
        #expect(completed.allSatisfy { $0.verified == true })
        #expect(underlying == .chunkNotAcked(slot: 2, chunkIndex: 5))
        // slot 1 restored, slots 2/3 untouched by the failing pass
        #expect(try await target.peek(slot: 1).blob == (try await source.peek(slot: 1)).blob)
    }

    @Test func restoreWrapsCancellation() async throws {
        let work = tempDir("restore-cancel")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let dest = work.appendingPathComponent("backup")
        let bs = try await makeDevice(source).backup(
            to: dest, options: backupOptions(slots: [1, 2]), progress: nil)
        let device = makeDevice(SimulatedMicroFreak.factoryFresh(replyLag: false))
        let task = Task { () throws -> [WriteReport] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.restore(from: bs)
        }
        await #expect(throws: FreakError.restoreFailed(
            underlying: .operationCancelled(done: 0, total: 2), completed: [])) {
            try await task.value
        }
    }
}
