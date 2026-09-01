// FreakClock.swift — injectable monotonic clock + sleep, so the session's
// timeout state machines are testable without real time.

import Foundation

public protocol FreakClock: Sendable {
    /// Monotonic seconds. Only differences are meaningful.
    var now: TimeInterval { get }

    /// Suspend ~seconds. Must NOT swallow cancellation: on task cancellation
    /// it may either throw CancellationError or return early — callers
    /// re-check deadlines.
    func sleep(for seconds: TimeInterval) async throws
}

/// ContinuousClock-backed default.
public struct SystemClock: FreakClock {
    private static let epoch = ContinuousClock.now

    public init() {}

    public var now: TimeInterval {
        let elapsed = Self.epoch.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
