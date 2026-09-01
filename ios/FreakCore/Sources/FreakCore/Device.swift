// Device.swift — FreakDeviceProtocol (the app-facing seam), MicroFreakDevice
// (port of device.py), and FreakDeviceFactory.
//
// The app holds `any FreakDeviceProtocol` and never learns whether it is
// hardware or the simulator. Every device write is read back and
// hash-verified by default; verify: false is the explicit per-call opt-out.

import Foundation

public struct SnapshotOptions: Sendable {
    public var readBlobs: Bool = true     // false = fast names-only pass (sha256 nil)
    public var keepBlobs: Bool = false    // true required for Library.importSnapshot
    public var slots: [Int]? = nil        // nil = all; sorted ascending before use

    public init() {}
}

public struct BackupOptions: Sendable {
    public var slots: [Int]? = nil
    public var resume: Bool = false       // skip slots already on disk with an index entry

    public init() {}
}

public protocol FreakDeviceProtocol: Sendable {
    var slotCount: Int { get }

    // reads
    func name(slot: Int) async throws -> String                       // ~1 ms on hardware
    func read(slot: Int) async throws -> Preset                       // ~400 ms on hardware
    func snapshot(options: SnapshotOptions,
                  progress: ProgressReporter?) async throws -> DeviceSnapshot

    // writes (verified by default via the extension overloads)
    func write(slot: Int, preset: Preset, verify: Bool) async throws -> WriteReport
    func rename(slot: Int, name: String, verify: Bool) async throws -> WriteReport

    // backup / restore
    func backup(to dest: URL, options: BackupOptions,
                progress: ProgressReporter?) async throws -> BackupSet
    func restore(from source: BackupSet, slots: [Int]?, verify: Bool,
                 progress: ProgressReporter?) async throws -> [WriteReport]

    func close() async
}

/// Default-argument overloads (protocols cannot declare defaults).
public extension FreakDeviceProtocol {
    func snapshot() async throws -> DeviceSnapshot {
        try await snapshot(options: SnapshotOptions(), progress: nil)
    }

    func snapshot(options: SnapshotOptions) async throws -> DeviceSnapshot {
        try await snapshot(options: options, progress: nil)
    }

    func write(slot: Int, preset: Preset) async throws -> WriteReport {
        try await write(slot: slot, preset: preset, verify: true)
    }

    func rename(slot: Int, name: String) async throws -> WriteReport {
        try await rename(slot: slot, name: name, verify: true)
    }

    func backup(to dest: URL) async throws -> BackupSet {
        try await backup(to: dest, options: BackupOptions(), progress: nil)
    }

    func restore(from source: BackupSet) async throws -> [WriteReport] {
        try await restore(from: source, slots: nil, verify: true, progress: nil)
    }
}

public final class MicroFreakDevice: FreakDeviceProtocol, Sendable {
    public let slotCount: Int
    public let session: FreakSession          // escape hatch, mirrors Python .session
    private let clock: any FreakClock

    public init(transport: any FreakTransport,
                slotCount: Int = Wire.slots,
                config: SessionConfig = SessionConfig(),
                clock: any FreakClock = SystemClock()) {
        self.slotCount = slotCount
        self.clock = clock
        self.session = FreakSession(transport: transport, config: config, clock: clock)
    }

    public func close() async {
        await session.close()
    }

    // ------------------------------------------------------------- reads

    public func name(slot: Int) async throws -> String {
        try await session.readName(slot: slot).name
    }

    public func read(slot: Int) async throws -> Preset {
        let info = try await session.readName(slot: slot)
        let blob = try await session.readBlob(slot: slot)
        return try Preset(name: info.name, blob: blob, meta: info.meta)
    }

    /// Read names (and, by default, blobs + hashes) for the requested slots.
    /// Cancellation throws .operationCancelled; no partial snapshot is ever
    /// returned. Name read failures of kind .deviceTimeout / .replyMismatch
    /// are swallowed (the record gets name nil, meta nil); everything else
    /// propagates.
    public func snapshot(options: SnapshotOptions,
                         progress: ProgressReporter?) async throws -> DeviceSnapshot {
        defer { progress?.finish() }
        let slotList = options.slots.map { $0.sorted() } ?? Array(0..<slotCount)
        let total = slotList.count
        var records: [SlotRecord] = []
        var nameMs: [Double] = []
        var dumpMs: [Double] = []
        var durations: [Double] = []
        let tStart = clock.now
        for (done, slot) in slotList.enumerated() {
            if Task.isCancelled {
                throw FreakError.operationCancelled(done: done, total: total)
            }
            let tSlot = clock.now
            var nm: String? = nil
            var meta: Data? = nil
            do {
                let t0 = clock.now
                let info = try await session.readName(slot: slot)
                nameMs.append((clock.now - t0) * 1000)
                nm = info.name
                meta = info.meta
            } catch let e as FreakError {
                switch e {
                case .deviceTimeout, .replyMismatch:
                    break    // name = nil, meta = nil on the record
                default:
                    throw e
                }
            }
            var sha: String? = nil
            var kept: Data? = nil
            if options.readBlobs {
                let t0 = clock.now
                let blob = try await session.readBlob(slot: slot)
                dumpMs.append((clock.now - t0) * 1000)
                sha = Wire.digest(blob)
                if options.keepBlobs {
                    kept = blob
                }
            }
            records.append(SlotRecord(slot: slot, name: nm, sha256: sha,
                                      meta: meta, blob: kept))
            durations.append(clock.now - tSlot)
            if let progress {
                let elapsed = clock.now - tStart
                let med = durations.sorted()[durations.count / 2]
                progress.report(ProgressEvent(
                    done: done + 1, total: total, slot: slot, name: nm ?? "",
                    elapsedSeconds: elapsed,
                    etaSeconds: med * Double(total - done - 1)))
            }
        }
        let elapsed = clock.now - tStart
        let timing = TimingReport(
            totalSeconds: roundTo(elapsed, places: 3),
            perSlotSeconds: roundTo(elapsed / Double(max(total, 1)), places: 4),
            nameMsMedian: median(nameMs),
            dumpMsMedian: median(dumpMs))
        return DeviceSnapshot(takenAt: isoNow(), records: records, timing: timing)
    }

    // ------------------------------------------ writes (verified by default)

    public func write(slot: Int, preset: Preset, verify: Bool) async throws -> WriteReport {
        let t0 = clock.now
        let info = try await session.writePreset(slot: slot, preset: preset)
        var verified: Bool? = nil
        if verify {
            if info.name != preset.name {
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: preset.sha256, actualSha256: nil,
                    expectedName: preset.name, actualName: info.name,
                    firstDifference: nil, expectedLength: preset.blob.count,
                    actualLength: 0))
            }
            let blob = try await session.readBlob(slot: slot)
            let actual = Wire.digest(blob)
            if actual != preset.sha256 {
                let expected = [UInt8](preset.blob)
                let got = [UInt8](blob)
                let n = min(expected.count, got.count)
                let first = (0..<n).first { expected[$0] != got[$0] } ?? n
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: preset.sha256, actualSha256: actual,
                    expectedName: preset.name, actualName: info.name,
                    firstDifference: first, expectedLength: expected.count,
                    actualLength: got.count))
            }
            verified = true
        }
        return WriteReport(slot: slot, sha256: preset.sha256, name: preset.name,
                           verified: verified, durationSeconds: clock.now - t0)
    }

    public func rename(slot: Int, name: String, verify: Bool) async throws -> WriteReport {
        try Wire.validateName(name)
        let t0 = clock.now
        let current = try await session.readName(slot: slot)          // current meta
        let info = try await session.writeName(slot: slot, name: name, meta: current.meta)
        var verified: Bool? = nil
        if verify {
            if info.name != name {
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: "", actualSha256: nil,
                    expectedName: name, actualName: info.name,
                    firstDifference: nil, expectedLength: 0, actualLength: 0))
            }
            verified = true
        }
        return WriteReport(slot: slot, sha256: "", name: name,
                           verified: verified, durationSeconds: clock.now - t0)
    }

    // ------------------------------------------------------ backup / restore

    /// Read every requested slot to the phase-0 on-disk format, persisting
    /// as it goes — each slot is on disk before the next is read, so a
    /// cancelled pass leaves valid partial state. Reads only; never writes
    /// to the device.
    public func backup(to dest: URL, options: BackupOptions,
                       progress: ProgressReporter?) async throws -> BackupSet {
        defer { progress?.finish() }
        let fm = FileManager.default
        let presetsDir = dest.appendingPathComponent("presets")
        try fm.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        let indexPath = dest.appendingPathComponent("index.json")
        var index: [String: Any]
        if fm.fileExists(atPath: indexPath.path) {
            let raw = try Data(contentsOf: indexPath)
            index = (try JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
            if index["presets"] == nil { index["presets"] = [String: Any]() }
            if index["timing"] == nil { index["timing"] = [String: Any]() }
        } else {
            index = ["created": isoNow(), "slots": slotCount,
                     "presets": [String: Any](), "timing": [String: Any]()]
        }
        var presets = (index["presets"] as? [String: Any]) ?? [:]

        let slotList = options.slots.map { $0.sorted() } ?? Array(0..<slotCount)
        let total = slotList.count
        var nameMs: [Double] = []
        var dumpMs: [Double] = []
        var durations: [Double] = []
        let tStart = clock.now
        for (done, slot) in slotList.enumerated() {
            if Task.isCancelled {
                throw FreakError.operationCancelled(done: done, total: total)
            }
            let binPath = presetsDir.appendingPathComponent(String(format: "%03d.bin", slot))
            if options.resume && fm.fileExists(atPath: binPath.path)
                && presets[String(slot)] != nil {
                continue
            }
            let tSlot = clock.now
            var t0 = clock.now
            let info = try await session.readName(slot: slot)  // NOT swallowed here —
            nameMs.append((clock.now - t0) * 1000)             // a backup wants to know
            t0 = clock.now
            let blob = try await session.readBlob(slot: slot)
            dumpMs.append((clock.now - t0) * 1000)
            try blob.write(to: binPath)
            presets[String(slot)] = ["slot": slot, "name": info.name,
                                     "bytes": blob.count,
                                     "sha256": Wire.digest(blob),
                                     "meta_hex": info.meta.hexString]
            index["presets"] = presets
            try AtomicFile.write(try jsonData(index), to: indexPath)
            durations.append(clock.now - tSlot)
            if let progress {
                let elapsed = clock.now - tStart
                let med = durations.sorted()[durations.count / 2]
                progress.report(ProgressEvent(
                    done: done + 1, total: total, slot: slot, name: info.name,
                    elapsedSeconds: elapsed,
                    etaSeconds: med * Double(total - done - 1)))
            }
        }
        let elapsed = clock.now - tStart
        let readCount = durations.count
        index["timing"] = [
            "total_seconds": roundTo(elapsed, places: 3),
            "per_slot_seconds": roundTo(elapsed / Double(max(readCount, 1)), places: 4),
            "name_ms_median": median(nameMs).map { $0 as Any } ?? NSNull(),
            "dump_ms_median": median(dumpMs).map { $0 as Any } ?? NSNull(),
        ] as [String: Any]
        try AtomicFile.write(try jsonData(index), to: indexPath)
        return try BackupSet.load(dest)
    }

    /// Write presets from a BackupSet back to the device. Stops at the first
    /// thrown error — a failing write path must not keep writing — and any
    /// FreakError (cancellation included) is rethrown as
    /// .restoreFailed(underlying:completed:).
    public func restore(from source: BackupSet, slots: [Int]?, verify: Bool,
                        progress: ProgressReporter?) async throws -> [WriteReport] {
        defer { progress?.finish() }
        let slotList = slots.map { $0.sorted() } ?? source.coveredSlots()
        let total = slotList.count
        var reports: [WriteReport] = []
        var durations: [Double] = []
        let tStart = clock.now
        for (done, slot) in slotList.enumerated() {
            let rep: WriteReport
            do {
                if Task.isCancelled {
                    throw FreakError.operationCancelled(done: done, total: total)
                }
                let preset = try source.preset(slot)
                let t0 = clock.now
                rep = try await write(slot: slot, preset: preset, verify: verify)
                durations.append(clock.now - t0)
            } catch let e as FreakError {
                throw FreakError.restoreFailed(underlying: e, completed: reports)
            }
            reports.append(rep)
            if let progress {
                let elapsed = clock.now - tStart
                let med = durations.sorted()[durations.count / 2]
                progress.report(ProgressEvent(
                    done: done + 1, total: total, slot: slot, name: rep.name,
                    elapsedSeconds: elapsed,
                    etaSeconds: med * Double(total - done - 1)))
            }
        }
        return reports
    }
}

// ----------------------------------------------------------- device factory

public enum FreakDeviceFactory {
    /// Practice mode: MicroFreakDevice over SimulatedMicroFreak.factoryFresh.
    /// Instant, offline, 269 duplicated Init slots among named pseudo-presets
    /// — the full UI (browse, backup, sync, expendability badges) works on
    /// the couch.
    public static func practice(initCopies: Int = 269, seed: Int = 0) -> any FreakDeviceProtocol {
        MicroFreakDevice(transport: SimulatedMicroFreak.factoryFresh(
            initCopies: initCopies, seed: seed))
    }

    #if canImport(CoreMIDI)
    /// Hardware: MicroFreakDevice over CoreMIDITransport.open(hints:exclude:).
    /// Throws .deviceNotFound / .transport — the connect screen shows the
    /// endpoint lists carried in .deviceNotFound and offers practice mode as
    /// the fallback.
    public static func hardware(hints: [String] = CoreMIDITransport.defaultHints)
        throws -> any FreakDeviceProtocol {
        MicroFreakDevice(transport: try CoreMIDITransport.open(hints: hints))
    }
    #endif
}
