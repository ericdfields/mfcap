// Transport.swift — the injected seam: byte movement and message-boundary
// reassembly, nothing more (transport.py).
//
// Poll model, deliberately: the core stays single-threaded and thread-free;
// push-style backends (CoreMIDI receive blocks, rtmidi callbacks) buffer
// into an internal locked queue inside the adapter. Discovery is a
// per-backend factory concern, not part of the interface.
//
// Contract:
// - send() transmits one complete SysEx message F0..F7, atomically.
// - receive() returns the next complete inbound SysEx message, or nil on
//   timeout. Arrival order is preserved; the transport buffers and never
//   drops. The transport's only jobs are byte movement and message-boundary
//   reassembly — no parsing, filtering, matching, retries, or threading
//   above the seam.
// - close() releases the backend; further calls may throw FreakError.transport.
//
// Adapters catch every backend error and throw .transport / .deviceNotFound
// with the backend description in `detail`. Implementations are internally
// synchronized and declared `@unchecked Sendable` with a one-line
// justification comment at the declaration.

import Foundation

public protocol Transport: AnyObject, Sendable {
    /// Send one complete SysEx message F0..F7, atomically.
    func send(_ message: Data) throws
    /// Next complete inbound SysEx message, or nil on timeout.
    /// timeout <= 0 means "return immediately if nothing is queued".
    /// Blocks the calling thread up to `timeout` — callers run on the
    /// device actor's dedicated dispatch queue, never the cooperative pool.
    func receive(timeout: TimeInterval) throws -> Data?
    /// Release the backend; further calls may throw FreakError.transport.
    func close()
}
