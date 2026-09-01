// Device.swift — the MicroFreakDevice actor (device.py).
//
// The concurrency keystone. Python's blocking-synchronous core is preserved
// verbatim INSIDE an actor whose executor is a dedicated dispatch queue, so
// blocking waits never touch the cooperative thread pool. Actor isolation
// replaces the Python lock — "one transaction at a time" is compiler-
// enforced because every entry point is actor-isolated and chunk-stream
// interleaving is unexpressible from outside. Every method is synchronous
// inside (a transliteration of device.py) and `async throws` at every call
// site by actor semantics.
//
// Every device write is read back and hash-verified by default;
// verify: false is the explicit per-call opt-out.

import Foundation

public actor MicroFreakDevice {
    public nonisolated let slots: Int

    private let session: FreakSession                 // non-Sendable, actor-confined
    private let clock: ClockFn
    private let queue: DispatchSerialQueue            // the actor's executor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()               // iOS 17 / macOS 14 API
    }

    public init(transport: any Transport,
                slots: Int = FreakProtocol.slots,
                config: SessionConfig = .init(),
                clock: @escaping ClockFn = FreakClock.monotonic,
                sleep: @escaping SleepFn = FreakClock.threadSleep) {
        self.slots = slots
        self.clock = clock
        self.queue = DispatchSerialQueue(
            label: "com.ericbrookfield.freakcore.device", qos: .userInitiated)
        self.session = FreakSession(transport: transport, config: config,
                                    clock: clock, sleep: sleep)
    }

    /// Closes the transport via the session. No implicit close in deinit —
    /// owners call close() explicitly.
    public func close() {
        session.close()
    }

    // ------------------------------------------------------------- reads

    public func name(slot: Int) throws -> String {
        try session.readName(slot: slot).name
    }

    public func read(slot: Int) throws -> Preset {
        let info = try session.readName(slot: slot)
        let blob = try session.readBlob(slot: slot)
        return try Preset(name: info.name, blob: blob, meta: info.meta)
    }

    /// Read names (and, by default, blobs + hashes) for the requested slots.
    /// Cancellation throws .cancelled; no partial snapshot is returned.
    public func snapshot(readBlobs: Bool = true, keepBlobs: Bool = false,
                         slots requestedSlots: [Int]? = nil,
                         progress: ProgressFn? = nil,
                         cancel: CancelToken? = nil) throws -> DeviceSnapshot {
        let slotList = requestedSlots.map { $0.sorted() } ?? Array(0..<slots)
        let total = slotList.count
        var records: [SlotRecord] = []
        var nameMs: [Double] = []
        var dumpMs: [Double] = []
        var durations: [Double] = []
        let tStart = clock()
        for (done, slot) in slotList.enumerated() {
            if let cancel, cancel.isCancelled {
                throw FreakError.cancelled(done: done, total: total)
            }
            let tSlot = clock()
            var nm: String? = nil
            var meta: Data? = nil
            do {
                let t0 = clock()
                let info = try session.readName(slot: slot)
                nameMs.append((clock() - t0) * 1000)
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
            if readBlobs {
                let t0 = clock()
                let blob = try session.readBlob(slot: slot)
                dumpMs.append((clock() - t0) * 1000)
                sha = FreakProtocol.digest(blob)
                if keepBlobs {
                    kept = blob
                }
            }
            records.append(SlotRecord(slot: slot, name: nm, sha256: sha,
                                      meta: meta, blob: kept))
            durations.append(clock() - tSlot)
            if let progress {
                let elapsed = clock() - tStart
                let med = durations.sorted()[durations.count / 2]
                let eta: Double? = durations.isEmpty
                    ? nil : med * Double(total - done - 1)
                progress(ProgressEvent(done: done + 1, total: total, slot: slot,
                                       name: nm ?? "", elapsedSeconds: elapsed,
                                       etaSeconds: eta))
            }
        }
        let elapsed = clock() - tStart
        let timing = TimingReport(
            totalSeconds: roundTo(elapsed, places: 3),
            perSlotSeconds: roundTo(elapsed / Double(max(total, 1)), places: 4),
            nameMsMedian: median(nameMs),
            dumpMsMedian: median(dumpMs))
        return DeviceSnapshot(takenAt: isoNow(), records: records, timing: timing)
    }

    // -------------------------------------------- writes (verified by default)

    public func write(slot: Int, preset: Preset, verify: Bool = true,
                      cancel: CancelToken? = nil) throws -> WriteReport {
        let t0 = clock()
        let info = try session.writePreset(slot: slot, preset, cancel: cancel)
        var verified: Bool? = nil
        if verify {
            if info.name != preset.name {
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: preset.sha256, actualSha256: nil,
                    expectedName: preset.name, actualName: info.name,
                    firstDifference: nil, expectedLen: preset.blob.count,
                    actualLen: 0))
            }
            let blob = try session.readBlob(slot: slot)
            let actual = FreakProtocol.digest(blob)
            if actual != preset.sha256 {
                let expected = [UInt8](preset.blob)
                let got = [UInt8](blob)
                let n = min(expected.count, got.count)
                let first = (0..<n).first { expected[$0] != got[$0] } ?? n
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: preset.sha256, actualSha256: actual,
                    expectedName: preset.name, actualName: info.name,
                    firstDifference: first, expectedLen: expected.count,
                    actualLen: got.count))
            }
            verified = true
        }
        return WriteReport(slot: slot, sha256: preset.sha256, name: preset.name,
                           verified: verified, durationSeconds: clock() - t0)
    }

    public func rename(slot: Int, name: String, verify: Bool = true) throws -> WriteReport {
        try FreakProtocol.validateName(name)
        let t0 = clock()
        let current = try session.readName(slot: slot)          // current meta
        let info = try session.writeName(slot: slot, name: name, meta: current.meta)
        var verified: Bool? = nil
        if verify {
            if info.name != name {
                throw FreakError.verifyMismatch(VerifyMismatch(
                    slot: slot, expectedSha256: "", actualSha256: nil,
                    expectedName: name, actualName: info.name,
                    firstDifference: nil, expectedLen: 0, actualLen: 0))
            }
            verified = true
        }
        return WriteReport(slot: slot, sha256: "", name: name,
                           verified: verified, durationSeconds: clock() - t0)
    }

    // ------------------------------------------------------ backup / restore

    /// Read every requested slot to the phase-0 on-disk format, persisting
    /// as it goes (each slot written before the next is read, so a cancelled
    /// pass leaves valid partial state). Reads only; never writes to the
    /// device.
    public func backup(to dest: URL, slots requestedSlots: [Int]? = nil,
                       resume: Bool = false,
                       progress: ProgressFn? = nil,
                       cancel: CancelToken? = nil) throws -> BackupSet {
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
            index = ["created": isoNow(), "slots": slots,
                     "presets": [String: Any](), "timing": [String: Any]()]
        }
        var presets = (index["presets"] as? [String: Any]) ?? [:]

        let slotList = requestedSlots.map { $0.sorted() } ?? Array(0..<slots)
        let total = slotList.count
        var nameMs: [Double] = []
        var dumpMs: [Double] = []
        var durations: [Double] = []
        let tStart = clock()
        for (done, slot) in slotList.enumerated() {
            if let cancel, cancel.isCancelled {
                throw FreakError.cancelled(done: done, total: total)
            }
            let binPath = presetsDir.appendingPathComponent(String(format: "%03d.bin", slot))
            if resume && fm.fileExists(atPath: binPath.path) && presets[String(slot)] != nil {
                continue
            }
            let tSlot = clock()
            var t0 = clock()
            let info = try session.readName(slot: slot)
            nameMs.append((clock() - t0) * 1000)
            t0 = clock()
            let blob = try session.readBlob(slot: slot)
            dumpMs.append((clock() - t0) * 1000)
            try blob.write(to: binPath)
            presets[String(slot)] = ["slot": slot, "name": info.name,
                                     "bytes": blob.count,
                                     "sha256": FreakProtocol.digest(blob),
                                     "meta_hex": info.meta.hexString]
            index["presets"] = presets
            try atomicWriteText(jsonText(index), to: indexPath)
            durations.append(clock() - tSlot)
            if let progress {
                let elapsed = clock() - tStart
                let med = durations.sorted()[durations.count / 2]
                progress(ProgressEvent(done: done + 1, total: total, slot: slot,
                                       name: info.name, elapsedSeconds: elapsed,
                                       etaSeconds: med * Double(total - done - 1)))
            }
        }
        let elapsed = clock() - tStart
        let readCount = durations.count
        index["timing"] = [
            "total_seconds": roundTo(elapsed, places: 3),
            "per_slot_seconds": roundTo(elapsed / Double(max(readCount, 1)), places: 4),
            "name_ms_median": median(nameMs).map { $0 as Any } ?? NSNull(),
            "dump_ms_median": median(dumpMs).map { $0 as Any } ?? NSNull(),
        ] as [String: Any]
        try atomicWriteText(jsonText(index), to: indexPath)
        return try BackupSet.load(from: dest)
    }

    /// Write presets from a BackupSet back to the device. Stops at the first
    /// thrown error (a failing write path must not keep writing); reports
    /// for completed slots travel in .restoreStopped(completed:underlying:).
    public func restore(from source: BackupSet, slots requestedSlots: [Int]? = nil,
                        verify: Bool = true,
                        progress: ProgressFn? = nil,
                        cancel: CancelToken? = nil) throws -> [WriteReport] {
        let slotList = requestedSlots.map { $0.sorted() } ?? source.coveredSlots()
        let total = slotList.count
        var reports: [WriteReport] = []
        var durations: [Double] = []
        let tStart = clock()
        for (done, slot) in slotList.enumerated() {
            let rep: WriteReport
            do {
                if let cancel, cancel.isCancelled {
                    throw FreakError.cancelled(done: done, total: total)
                }
                let preset = try source.preset(slot: slot)
                let t0 = clock()
                rep = try write(slot: slot, preset: preset, verify: verify,
                                cancel: cancel)
                durations.append(clock() - t0)
            } catch let e as FreakError {
                throw FreakError.restoreStopped(completed: reports, underlying: e)
            }
            reports.append(rep)
            if let progress {
                let elapsed = clock() - tStart
                let med = durations.sorted()[durations.count / 2]
                progress(ProgressEvent(done: done + 1, total: total, slot: slot,
                                       name: rep.name, elapsedSeconds: elapsed,
                                       etaSeconds: med * Double(total - done - 1)))
            }
        }
        return reports
    }
}
