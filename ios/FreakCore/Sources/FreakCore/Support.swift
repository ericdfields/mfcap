// Support.swift — injectable clock/sleep, the structured-concurrency
// cancellation bridge, and small internal helpers.

import Foundation

public typealias ClockFn = @Sendable () -> Double     // monotonic seconds
public typealias SleepFn = @Sendable (Double) -> Void

public enum FreakClock {
    /// Monotonic seconds (DispatchTime uptime).
    public static let monotonic: ClockFn = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    /// Blocking sleep on the calling thread — only ever runs on the device
    /// actor's dedicated dispatch queue, never the cooperative pool.
    public static let threadSleep: SleepFn = { interval in
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Structured-concurrency bridge (additive; the token remains the core
/// primitive): wraps `body` in withTaskCancellationHandler; the handler
/// calls token.cancel(), so `Task.cancel()` on the enclosing task cancels
/// the device operation cooperatively.
public func withCancellation<T: Sendable>(
    _ body: @Sendable (CancelToken) async throws -> T) async throws -> T {
    let token = CancelToken()
    return try await withTaskCancellationHandler {
        try await body(token)
    } onCancel: {
        token.cancel()
    }
}

// ------------------------------------------------------- internal helpers

/// ISO 8601 local, "yyyy-MM-dd'T'HH:mm:ss" — matches Python's
/// time.strftime("%Y-%m-%dT%H:%M:%S").
func isoNow() -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fmt.string(from: Date())
}

/// Median as mfcap.midi.backup computes it: sorted()[count / 2], rounded to
/// 1 decimal. nil for an empty list.
func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    return roundTo(xs.sorted()[xs.count / 2], places: 1)
}

func roundTo(_ x: Double, places: Int) -> Double {
    let f = pow(10.0, Double(places))
    return (x * f).rounded() / f
}

extension Data {
    /// Contiguous hex (no separators), any case; nil on malformed input.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.nibble(chars[i]), let lo = Data.nibble(chars[i + 1]) else {
                return nil
            }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30           // 0-9
        case 0x61...0x66: return c - 0x61 + 10      // a-f
        case 0x41...0x46: return c - 0x41 + 10      // A-F
        default: return nil
        }
    }

    /// Lowercase contiguous hex — matches Python bytes.hex().
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
