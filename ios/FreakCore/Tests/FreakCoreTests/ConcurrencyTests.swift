// ConcurrencyTests.swift — the FIFO transaction gate's serialization
// guarantee (chunk streams never interleave), and the ProgressReporter
// stream contract.

import Foundation
import Testing
@testable import FreakCore

@Suite("Concurrency")
struct ConcurrencyTests {

    /// Two concurrent write calls on ONE session serialize through the FIFO
    /// gate: the wire shows two contiguous 146-chunk runs, never interleaved
    /// (chunks are unaddressed and unmatchable by design; interleaving would
    /// corrupt both slots), and the sim observes zero faults.
    @Test func concurrentWritesNeverInterleaveChunkStreams() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = MicroFreakDevice(transport: sim, clock: TestClock())
        let presetA = try Preset(name: "Writer A", blob: blob7(11), meta: testMeta)
        let presetB = try Preset(name: "Writer B", blob: blob7(22), meta: testMeta)
        async let a = device.write(slot: 100, preset: presetA)
        async let b = device.write(slot: 300, preset: presetB)
        let (reportA, reportB) = try await (a, b)
        #expect(reportA.verified == true && reportB.verified == true)
        let faults = await sim.faults()
        #expect(faults.isEmpty, "\(faults)")
        #expect(try await sim.peek(slot: 100).blob == presetA.blob)
        #expect(try await sim.peek(slot: 300).blob == presetB.blob)
        // the outbound chunk frames form exactly two contiguous 146-runs
        var runs: [Int] = []
        var current = 0
        for entry in await sim.wireLog() where entry.direction == .out {
            if Wire.parse(entry.raw)!.isChunk {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 {
            runs.append(current)
        }
        #expect(runs == [146, 146], "chunk streams interleaved: \(runs)")
    }

    /// Concurrent reads on one session are also serialized and all correct.
    @Test func concurrentReadsSerialize() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = MicroFreakDevice(transport: sim, clock: TestClock())
        let names = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for slot in 0..<24 {
                group.addTask { (slot, try await device.name(slot: slot)) }
            }
            var out: [Int: String] = [:]
            for try await (slot, name) in group {
                out[slot] = name
            }
            return out
        }
        for slot in 0..<24 {
            #expect(names[slot] == String(format: "Patch %03d", slot))
        }
        #expect(await sim.faults().isEmpty)
    }

    /// The §6 usage pattern is live: progress events arrive over the
    /// AsyncStream while the operation runs, and the stream always
    /// terminates (finish() in a defer), so a UI `for await` loop ends.
    @Test func progressStreamDeliversAndTerminates() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let (reporter, collector) = collectingReporter()
        var opts = SnapshotOptions()
        opts.readBlobs = false
        opts.slots = Array(0..<5)
        let snapshotTask = Task {
            try await device.snapshot(options: opts, progress: reporter)
        }
        let events = await collector.value      // ends because the op finishes
        _ = try await snapshotTask.value
        #expect(events.map(\.done) == [1, 2, 3, 4, 5])
    }

    /// The stream terminates on the error path too.
    @Test func progressStreamTerminatesOnFailure() async throws {
        let device = makeDevice(DeadTransport())
        let (reporter, collector) = collectingReporter()
        var opts = BackupOptions()
        opts.slots = [0]
        let work = tempDir("progress-error")
        defer { try? FileManager.default.removeItem(at: work) }
        await #expect(throws: FreakError.self) {
            try await device.backup(to: work.appendingPathComponent("b"),
                                    options: opts, progress: reporter)
        }
        let events = await collector.value      // finish() ran in the defer
        #expect(events.isEmpty)
    }
}
