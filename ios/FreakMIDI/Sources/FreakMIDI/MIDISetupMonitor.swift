// MIDISetupMonitor.swift — AsyncStream of CoreMIDI setup-changed events.
//
// Connection lifecycle on iPadOS (§5.2, normative — the app layer owns the
// policy, restated here for the implementer):
//
// - Discovery & reconnect: on launch and on every .setupChanged, run
//   findMicroFreak(); track the hardware by MIDIUniqueID. If the device
//   vanished while a transport is open, the app closes the device, shows
//   "disconnected", and offers demo mode.
// - Backgrounding: no UIBackgroundModes are declared. On
//   didEnterBackgroundNotification the app wraps any in-flight operation in
//   a UIApplication.beginBackgroundTask whose expiration handler calls the
//   operation's CancelToken.cancel(). Read passes (snapshot/backup) resume
//   later via backup(resume: true); a cancelled write may tear its slot —
//   the app records the slot dirty and offers "write again" on foreground
//   (the documented recovery). Single verified writes (~0.5 s) always
//   finish inside the grace window.
// - Foregrounding: on willEnterForegroundNotification, re-resolve both
//   endpoint ids (setup notifications may have been dropped during
//   suspension); unresolvable -> disconnected state. CoreMIDI port refs
//   survive suspension; no re-open is needed while the ids still resolve.

import Foundation

public final class MIDISetupMonitor: @unchecked Sendable {
    // @unchecked Sendable: `token` is guarded by `lock`; the AsyncStream
    // continuation is itself thread-safe.
    public enum Event: Sendable {
        /// CoreMIDI's object-added / object-removed / setup-changed
        /// notifications, coalesced: pending events collapse to one
        /// (bufferingNewest(1)) — consumers re-run discovery either way.
        case setupChanged
    }

    /// One .setupChanged per CoreMIDI setup change while the monitor runs;
    /// finishes when stop() is called.
    public let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var token: UUID?

    /// Registers with the process-wide FreakMIDIClient (creating it on
    /// first use — throws .transport if CoreMIDI refuses).
    public init() throws {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self, bufferingPolicy: .bufferingNewest(1))
        self.events = stream
        self.continuation = continuation
        let client = try FreakMIDIClient.shared()
        self.token = client.addSetupObserver { [continuation] in
            continuation.yield(.setupChanged)
        }
    }

    /// Unregister and finish the stream. Idempotent.
    public func stop() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        guard let current else { return }
        // shared() cannot fail here: a token exists only if the client was
        // created in init.
        (try? FreakMIDIClient.shared())?.removeSetupObserver(current)
        continuation.finish()
    }

    deinit {
        stop()
    }
}
