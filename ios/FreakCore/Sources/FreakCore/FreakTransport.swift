// FreakTransport.swift — the transport seam (port of transport.py).
//
// Decision: async poll. The Python core's three state machines are
// single-consumer *pull* loops, and keeping receive(timeout:) ports them —
// and SimulatedMicroFreak's inline synchronous semantics — verbatim, with
// one outstanding request by construction. The methods are async (rather
// than blocking) because CoreMIDI's push callback then only has to bridge
// into an awaitable inbox and, under Swift 6 strict concurrency, blocking a
// cooperative-pool thread for up to a 1.5 s timeout is not acceptable.
//
// Discovery is a per-backend factory concern (static methods on the concrete
// transports), not part of the protocol.

import Foundation

/// The only platform-specific seam. Byte movement and SysEx message-boundary
/// reassembly, nothing more: no parsing, filtering, matching, retries, or
/// buffering policy above it. Arrival order preserved; the transport buffers
/// and never drops.
public protocol FreakTransport: Sendable {
    /// Transmit one complete SysEx message F0..F7, atomically. Throws
    /// .transport on backend failure (chained into `detail`).
    func send(_ message: Data) async throws

    /// Next complete inbound SysEx message (F0..F7, reassembled), or nil on
    /// timeout. timeout <= 0 means non-blocking: return a buffered message
    /// or nil immediately. Throws .transport on backend failure.
    /// Single-consumer: exactly one caller (the session) polls this;
    /// behavior with concurrent receivers is unspecified.
    func receive(timeout: TimeInterval) async throws -> Data?

    /// Release the backend. Idempotent. Subsequent send/receive throw
    /// .transport.
    func close() async
}
