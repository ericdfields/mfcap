// Audition.swift — play through a queue of presets on the real synth, one
// tap each (port of audition.py).
//
// The MicroFreak plays whatever preset is selected on its panel, so to hear
// a library preset it has to be ON the device. This session borrows one
// expendable slot as the audition slot:
//
//     start()    read + keep the slot's original preset
//     next()     verified-write the next queued preset there, then Bank
//                Select + Program Change so the synth loads it (~0.5 s)
//     verdict()  file the judgement on the library entry
//     stop()     restore the slot's original, verified — the device is left
//                as it was found, always, even after a failure mid-queue
//
// Nothing is auditioned "in place": the user's own slots are never touched.
// The device confirms neither Program Change nor panel state over MIDI, so
// a selection that "doesn't take" (Program Change Receive off) is a UI
// concern — the flow itself cannot detect it.

import Foundation

public actor AuditionSession {
    public let device: any FreakDeviceProtocol
    public let library: Library
    public let slot: Int
    public private(set) var queue: [LibraryEntry]
    public private(set) var original: Preset?
    public private(set) var index = -1
    public private(set) var started = false
    public private(set) var restored = false
    public private(set) var history: [(entryID: String, verdict: Verdict)] = []

    public init(device: any FreakDeviceProtocol, library: Library,
                queue: [LibraryEntry], slot: Int) {
        self.device = device
        self.library = library
        self.queue = queue
        self.slot = slot
    }

    /// The natural audition queue: everything not yet judged.
    public static func unrated(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter { $0.verdict == .unrated }
    }

    public var current: LibraryEntry? {
        (0..<queue.count).contains(index) ? queue[index] : nil
    }

    public var remaining: Int { max(0, queue.count - (index + 1)) }

    /// Save what is in the audition slot now. Idempotent.
    @discardableResult
    public func start() async throws -> Preset {
        if let original { return original }
        let p = try await device.read(slot: slot)
        original = p
        started = true
        return p
    }

    /// Put the next queued preset on the synth. nil when the queue is
    /// exhausted (the device holds the last auditioned preset until stop()).
    public func next() async throws -> LibraryEntry? {
        if !started { try await start() }
        guard index + 1 < queue.count else { return nil }
        index += 1
        let entry = queue[index]
        let preset = try await library.get(id: entry.id)
        _ = try await device.write(slot: slot, preset: preset)   // verified
        try await device.select(slot: slot)
        return entry
    }

    /// File a verdict for the current (or given) preset.
    @discardableResult
    public func verdict(_ verdict: Verdict, for entry: LibraryEntry? = nil) async throws -> LibraryEntry {
        guard let target = entry ?? current else {
            throw FreakError.protocolViolation(detail: "nothing is being auditioned")
        }
        let updated = try await library.setVerdict(id: target.id, to: verdict)
        history.append((target.id, verdict))
        return updated
    }

    /// Restore the audition slot's original preset (verified). Safe to call
    /// more than once.
    @discardableResult
    public func stop() async throws -> Preset? {
        if started, !restored, let original {
            _ = try await device.write(slot: slot, preset: original)
            restored = true
        }
        return original
    }
}
