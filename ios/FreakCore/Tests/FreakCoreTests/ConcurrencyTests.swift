// ConcurrencyTests.swift — the actor's serialization guarantee (chunk
// streams never interleave) and the withCancellation structured-concurrency
// bridge.

import Foundation
import Testing
@testable import FreakCore

@Suite("Concurrency")
struct ConcurrencyTests {

    /// Two concurrent write calls on the actor serialize: the wire shows two
    /// contiguous 146-chunk runs, never interleaved (chunks are unaddressed
    /// and unmatchable by design; interleaving would corrupt both slots).
    @Test func concurrentWritesNeverInterleaveChunkStreams() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = MicroFreakDevice(transport: sim)
        let presetA = try Preset(name: "Writer A", blob: blob7(11), meta: testMeta)
        let presetB = try Preset(name: "Writer B", blob: blob7(22), meta: testMeta)
        async let a = device.write(slot: 100, preset: presetA)
        async let b = device.write(slot: 300, preset: presetB)
        let (reportA, reportB) = try await (a, b)
        #expect(reportA.verified == true && reportB.verified == true)
        #expect(sim.faults.isEmpty, "\(sim.faults)")
        #expect(try sim.peek(slot: 100).blob == presetA.blob)
        #expect(try sim.peek(slot: 300).blob == presetB.blob)
        // the outbound chunk frames form exactly two contiguous 146-runs
        var runs: [Int] = []
        var current = 0
        for entry in sim.wireLog where entry.direction == .out {
            if FreakProtocol.parse(entry.raw)!.isChunk {
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

    /// Concurrent reads on the actor are also serialized and all correct.
    @Test func concurrentReadsSerialize() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = MicroFreakDevice(transport: sim)
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
        #expect(sim.faults.isEmpty)
    }

    // -------------------------------------------------- withCancellation

    /// Task.cancel() on the enclosing task reaches the CancelToken.
    @Test func taskCancellationReachesTheToken() async throws {
        let task = Task {
            try await withCancellation { token -> Bool in
                while !token.isCancelled {
                    await Task.yield()
                }
                return true
            }
        }
        task.cancel()
        #expect(try await task.value, "the cancellation handler must fire the token")
    }

    /// The token handed out by withCancellation plumbs into device
    /// operations: cancelling it mid-snapshot throws .cancelled.
    @Test func withCancellationDrivesDeviceCancel() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let e = await expectFreakErrorAsync {
            try await withCancellation { token in
                try await device.snapshot(
                    readBlobs: false, slots: Array(0..<10),
                    progress: { event in
                        if event.done == 3 {
                            token.cancel()
                        }
                    },
                    cancel: token)
            }
        }
        #expect(e == .cancelled(done: 3, total: 10))
    }

    /// Progress events bridge to an AsyncStream across the actor boundary
    /// (the app's ProgressBridge pattern, §3.6).
    @Test func progressBridgesToAsyncStream() async throws {
        let sim = SimulatedMicroFreak.factoryFresh(replyLag: false)
        let device = makeDevice(sim)
        let (stream, continuation) = AsyncStream.makeStream(of: ProgressEvent.self)
        let snapshotTask = Task {
            defer { continuation.finish() }
            return try await device.snapshot(readBlobs: false,
                                             slots: Array(0..<5),
                                             progress: { continuation.yield($0) })
        }
        var dones: [Int] = []
        for await event in stream {
            dones.append(event.done)
        }
        _ = try await snapshotTask.value
        #expect(dones == [1, 2, 3, 4, 5])
    }
}
