// VerdictAuditionTests.swift — the Verdict attribute (round-trip, back-compat,
// dedupe merge), select() reaching the simulated panel, and an AuditionSession
// run: borrowed slot, verified write + Program Change per preset, verdicts
// filed, original restored on stop. Mirrors tests/test_verdict_audition.py.

import Foundation
import Testing
@testable import FreakCore

@Suite("Verdict + audition")
struct VerdictAuditionTests {

    @Test func verdictRoundTripAndBackCompat() async throws {
        #expect(Verdict.fromSlug("try_later") == .tryLater)
        #expect(Verdict.fromSlug("bogus") == .unrated)
        let root = tempDir("verdict"); defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        let e = try await lib.add(try Preset(name: "A", blob: blob7(1), meta: testMeta))
        #expect(e.verdict == .unrated)
        _ = try await lib.setVerdict(id: e.id, to: .tryLater)
        #expect(try await Library.open(at: root).entry(id: e.id).verdict == .tryLater)
        // an index written before verdict existed loads as .unrated
        let indexURL = root.appendingPathComponent("index.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
        var entries = obj["entries"] as! [[String: Any]]
        entries[0]["verdict"] = nil
        obj["entries"] = entries
        try JSONSerialization.data(withJSONObject: obj).write(to: indexURL)
        #expect(try await Library.open(at: root).entry(id: e.id).verdict == .unrated)
        // dedupe keeps a filed verdict over .unrated
        let a = try await lib.add(try Preset(name: "X", blob: blob7(2), meta: testMeta))
        _ = try await lib.setVerdict(id: a.id, to: .keep)
        _ = try await lib.add(try Preset(name: "X", blob: blob7(2), meta: testMeta))
        _ = try await lib.dedupe()
        #expect(await lib.entries().first { $0.name == "X" }?.verdict == .keep)
    }

    @Test func selectReachesSimulatedPanel() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let device = makeDevice(sim)
        try await device.select(slot: 300)                     // bank 2, program 44
        #expect(await sim.selectedSlot == 300)
        let msgs = MIDIShort.selectPresetMessages(slot: 300)
        #expect(msgs.last == Data([0xC0, 44]) && msgs.first == Data([0xB0, 0, 2]))
        #expect(MIDIShort.umpWord(Data([0xC0, 44])) == 0x20C0_2C00)
        #expect(await sim.faults().isEmpty)
        await #expect(throws: FreakError.slotOutOfRange(slot: 512)) {
            try await device.select(slot: 512)
        }
    }

    @Test func auditionBorrowsSlotFilesVerdictsAndRestores() async throws {
        let sim = SimulatedMicroFreak.factoryFresh()
        let device = makeDevice(sim)
        let root = tempDir("audition"); defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library.create(at: root)
        var entries: [LibraryEntry] = []
        for i in 0..<3 {
            entries.append(try await lib.add(
                try Preset(name: "P\(i)", blob: blob7(10 + i), meta: testMeta)))
        }
        let slot = 509
        let before = try await sim.peek(slot: slot)
        let session = AuditionSession(device: device, library: lib,
                                      queue: AuditionSession.unrated(await lib.entries()),
                                      slot: slot)
        _ = try await session.start()
        #expect(await session.original == before)
        #expect(await session.remaining == 3)
        let first = try await session.next()
        #expect(first?.id == entries[0].id)
        let onDevice = try await sim.peek(slot: slot).blob
        let expected = try await lib.get(id: entries[0].id).blob
        #expect(onDevice == expected)                            // verified-written
        #expect(await sim.selectedSlot == slot)
        _ = try await session.verdict(.keep)
        let second = try await session.next()
        _ = try await session.verdict(.never, for: second)
        _ = try await session.next()
        #expect(await session.remaining == 0)
        #expect(try await session.next() == nil)
        _ = try await session.stop()
        #expect(try await sim.peek(slot: slot) == before, "original must be restored")
        _ = try await session.stop()                           // idempotent
        #expect(try await lib.entry(id: entries[0].id).verdict == .keep)
        #expect(try await lib.entry(id: entries[1].id).verdict == .never)
        #expect(try await lib.entry(id: entries[2].id).verdict == .unrated)
        #expect(await session.history.map(\.verdict) == [.keep, .never])
        #expect(await sim.faults().isEmpty)
    }
}
