// FreakMIDIClient.swift — the one process-wide MIDIClientRef.
//
// Created lazily by shared() via MIDIClientCreateWithBlock; its notify block
// fans out to registered observers (MIDISetupMonitor instances). Creation
// failure throws FreakError.transport carrying the OSStatus. The client is
// never disposed — it persists for the process (CoreMIDITransport.close
// disposes only its ports).

import CoreMIDI
import FreakCore
import Foundation

public final class FreakMIDIClient: @unchecked Sendable {
    // @unchecked Sendable: all mutable state (client ref, created flag,
    // observer table) is guarded by `lock`; fan-out runs on a snapshot
    // taken under the lock.
    private static let instance = FreakMIDIClient()

    private let lock = NSLock()
    private var client: MIDIClientRef = 0
    private var created = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    private init() {}

    /// The process-wide client, creating the underlying MIDIClientRef on
    /// first call. Throws .transport with the OSStatus if CoreMIDI refuses.
    public static func shared() throws -> FreakMIDIClient {
        try instance.ensureCreated()
        return instance
    }

    /// The underlying CoreMIDI client ref (ports are created against it).
    func ref() throws -> MIDIClientRef {
        try ensureCreated()
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    /// Register a setup-change observer; the returned token unregisters it.
    /// Observers fire on a CoreMIDI-owned thread — they must be cheap and
    /// thread-safe (MIDISetupMonitor just yields into an AsyncStream).
    @discardableResult
    func addSetupObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func removeSetupObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    private func ensureCreated() throws {
        lock.lock()
        defer { lock.unlock() }
        if created { return }
        var ref: MIDIClientRef = 0
        // The notify block runs later, on a CoreMIDI thread — never
        // synchronously inside this call, so holding `lock` here is safe.
        let status = MIDIClientCreateWithBlock("mfcap" as CFString, &ref) { notification in
            FreakMIDIClient.instance.fanOut(notification.pointee.messageID)
        }
        guard status == noErr else {
            throw FreakError.transport(
                detail: "MIDIClientCreateWithBlock failed (OSStatus \(status))")
        }
        client = ref
        created = true
    }

    /// Added/removed/setup notifications coalesce into one observer ping;
    /// everything else (IO errors, property changes, …) is ignored here.
    private func fanOut(_ messageID: MIDINotificationMessageID) {
        switch messageID {
        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
            lock.lock()
            let snapshot = Array(observers.values)
            lock.unlock()
            for observer in snapshot { observer() }
        default:
            break
        }
    }
}
