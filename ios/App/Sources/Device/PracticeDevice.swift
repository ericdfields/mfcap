// PracticeDevice.swift — Practice Mode as a first-class device (UX §11,
// architecture spec §14.1).
//
// This file is the ONE place in the app that knows the practice device is
// FreakCore's SimulatedMicroFreak; everything downstream holds
// `any FreakDeviceProtocol` and cannot tell hardware from simulation.
//
// Profiles (UX §11): Factory Fresh (the reference device's shape — real-
// looking named presets plus 269 identical Init blobs, so emptiness
// judgments, census counts and the sync diff behave exactly like Eric's
// synth), Lived In, Full (zero expendables — exercises the no-scratch-slot
// path), and Flaky (a torn write injected partway through the second blob
// write, so every §14 error surface is reachable without hardware).
//
// Honest pacing: the simulator answers instantly by design (offline tests
// are instant; the session's clock handles pacing), so PacedTransport wraps
// it and sleeps a uniform per-delivered-message delay tuned to hardware
// shape — a blob read is ~147 inbound messages ≈ 400 ms, a full backup
// ≈ 3.5 minutes — so progress bars, ETAs, cancel and resume are experienced
// truthfully. The delay is per MESSAGE, deliberately content-blind: the app
// layer never inspects frame bytes (architecture spec §14). Reply-lag stays
// ON in every profile — practice mode exercises the same defenses as
// hardware.

import Foundation
import FreakCore

enum PracticeProfile: String, CaseIterable, Identifiable, Sendable, Codable {
    case factoryFresh
    case livedIn
    case full
    case flaky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .factoryFresh: return "Factory Fresh"
        case .livedIn: return "Lived In"
        case .full: return "Full"
        case .flaky: return "Flaky"
        }
    }

    var blurb: String {
        switch self {
        case .factoryFresh:
            return "243 named presets + 269 identical Init slots — the "
                + "reference device's shape, so emptiness judgments are real."
        case .livedIn:
            return "Scattered user presets, few expendable slots."
        case .full:
            return "Zero expendable slots — exercises the no-scratch-slot path."
        case .flaky:
            return "A torn write is injected partway through the second blob "
                + "write — every error surface is reachable without hardware."
        }
    }

    var identity: DeviceIdentity { .practice(profile: rawValue) }

    /// The simulated transport for this profile. replyLag stays at its
    /// default `true` in every profile (UX §11 rule).
    fileprivate func makeSimulator() -> SimulatedMicroFreak {
        switch self {
        case .factoryFresh:
            return SimulatedMicroFreak.factoryFresh()
        case .livedIn:
            return SimulatedMicroFreak.factoryFresh(initCopies: 40, seed: 7)
        case .full:
            return SimulatedMicroFreak.factoryFresh(initCopies: 0, seed: 3)
        case .flaky:
            // Cumulative chunk index 200 ⇒ the first full write (chunks
            // 0–145) succeeds; the second write loses its acks at its chunk
            // 54 → .chunkNotAcked → the torn-slot flow (UX §14). The lost
            // acks also exercise the timeout surfaces.
            return SimulatedMicroFreak.factoryFresh(failChunkAt: 200)
        }
    }
}

enum PracticeDevice {
    /// Build the practice device. `paced: false` is for previews/tests only —
    /// the shipped entry points always pace honestly (UX §11).
    @MainActor
    static func make(profile: PracticeProfile, paced: Bool = true,
                     fast: Bool = false) -> (device: any FreakDeviceProtocol,
                                             pacer: PacedTransport?) {
        let simulator = profile.makeSimulator()
        if paced {
            let pacer = PacedTransport(wrapping: simulator, fast: fast)
            return (MicroFreakDevice(transport: pacer), pacer)
        }
        return (MicroFreakDevice(transport: simulator), nil)
    }
}

/// Wraps the instant simulator in honest wire timing. Content-blind: it
/// delays each delivered message uniformly and never looks at the bytes.
public actor PacedTransport: FreakTransport {
    /// ~147 inbound messages per blob read ⇒ 400 ms/blob; a name reply is a
    /// couple of messages ⇒ names pass ≈ 2 s for 512 slots; a full backup
    /// ≈ 3.5 minutes — hardware-shaped throughout.
    private static let perMessageDelay: TimeInterval = 0.4 / 147.0
    private static let fastFactor = 20.0

    private let inner: SimulatedMicroFreak
    private var fast: Bool

    init(wrapping inner: SimulatedMicroFreak, fast: Bool) {
        self.inner = inner
        self.fast = fast
    }

    /// The "Fast practice timing (20×)" toggle, flippable live (UX §11).
    public func setFast(_ value: Bool) { fast = value }

    public func send(_ message: Data) async throws {
        try await inner.send(message)
    }

    public func receive(timeout: TimeInterval) async throws -> Data? {
        guard let message = try await inner.receive(timeout: timeout) else {
            return nil
        }
        let delay = Self.perMessageDelay / (fast ? Self.fastFactor : 1.0)
        // A cancelled task should not lose a delivered message — skip the
        // pacing sleep and hand it over; the session's own cancellation
        // polls decide what happens next.
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return message
    }

    public func close() async {
        await inner.close()
    }
}
