// TestClock.swift — the deterministic virtual clock: `now` returns a stored
// value; sleep(for:) advances it by max(dt, 1e-4) and returns immediately —
// the same FakeClock the Python suite and tools/gen_vectors.py use, so a
// full lagged-read retry cycle costs zero wall time.

import Foundation
import os
@testable import FreakCore

final class TestClock: FreakClock {
    private let state = OSAllocatedUnfairLock(initialState: 0.0)

    var now: TimeInterval {
        state.withLock { $0 }
    }

    func sleep(for seconds: TimeInterval) async throws {
        state.withLock { $0 += max(seconds, 1e-4) }
    }
}
