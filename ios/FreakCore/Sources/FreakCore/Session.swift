// Session.swift — FreakSession: seq counter, one transaction at a time, the
// reply-lag chokepoint (port of session.py).
//
// - The addressed-request seq counter is owned here; it increments 1..127
//   and wraps, never emitting 0, matching mfcap.midi.Reader. The write burst
//   has a separate seq stream, verbatim from the captures: goFrame() carries
//   seq 0 and the chunks continue from it, (i + 1) % 128 — wrapping THROUGH
//   0 (Wire.chunkFrames owns that stream).
// - FreakSession is an actor. Actor isolation gives data-race freedom, but
//   actor REENTRANCY would let a second caller interleave at any `await`
//   inside a write burst — exactly the catastrophe the Python lock prevents
//   (chunk streams are unaddressed and unmatchable by design). So every
//   public method runs its body inside a non-reentrant FIFO gate: "one
//   transaction at a time" is enforced by construction.
// - transactAddressed() is the ONLY function in the package that inspects a
//   0x52 reply — readName, writeName's read-back, and writePreset's frames
//   1 and 7 all pass through it, so the reply-lag bug cannot be reintroduced
//   without deleting this function.

import Foundation

public struct SessionConfig: Sendable {
    public var nameTimeout: TimeInterval = 1.0
    public var dumpTimeout: TimeInterval = 1.5
    public var ackTimeout: TimeInterval = 1.0
    public var nameRetries: Int = 3
    public var pollInterval: TimeInterval = 0.002   // sleep between empty receive polls

    public init() {}
}

public actor FreakSession {
    private let transport: any FreakTransport
    private let config: SessionConfig
    private let clock: any FreakClock

    /// Addressed-request seq counter: `seq = seq % 127 + 1` -> 1..127,
    /// wrapping, NEVER 0. (0 appears on the wire only in the go frame; the
    /// chunk stream is Wire.chunkFrames'.)
    private var seq = 0

    // Non-reentrant FIFO gate.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any FreakTransport,
                config: SessionConfig = SessionConfig(),
                clock: any FreakClock = SystemClock()) {
        self.transport = transport
        self.config = config
        self.clock = clock
    }

    // ------------------------------------------------------------- public

    public func readName(slot: Int) async throws -> NameInfo {
        try await withTransaction {
            try await self.transactAddressed(
                request: Wire.readNameRequest(seq: self.nextSeq(), slot: slot),
                slot: slot)
        }
    }

    public func readBlob(slot: Int) async throws -> Data {
        try await withTransaction {
            try await self.readBlobInTransaction(slot: slot)
        }
    }

    /// The gate-verified 7-frame write sequence, verbatim from
    /// docs/write-protocol.md. No checksum is computed at any point; none
    /// exists. Returns frame 7's read-back NameInfo — comparison is the
    /// caller's job (the frame itself is protocol fidelity and always sent).
    /// Polls Task.isCancelled before each chunk; throws
    /// .operationCancelled(done: chunkIndex, total: 146) — tearing the slot.
    public func writePreset(slot: Int, preset: Preset) async throws -> NameInfo {
        // Built first: validates size / 7-bit cleanliness up front, outside
        // the gate.
        let frames = try Wire.chunkFrames(blob: preset.blob)
        return try await withTransaction {
            try await self.writePresetInTransaction(slot: slot, preset: preset,
                                                    frames: frames)
        }
    }

    /// Rename-in-place, exactly what MCC sends: the long 0x52 (awaiting the
    /// device's 0x18 ack; absence -> .deviceTimeout(stage: .nameWriteAck))
    /// plus a refresh read. No blob traffic.
    public func writeName(slot: Int, name: String, meta: Data) async throws -> NameInfo {
        try await withTransaction {
            try await self.transport.send(Wire.nameWriteFrame(
                seq: self.nextSeq(), slot: slot, name: name, meta: meta))
            guard try await self.awaitAck() else {
                throw FreakError.deviceTimeout(stage: .nameWriteAck, slot: slot)
            }
            return try await self.transactAddressed(
                request: Wire.readNameRequest(seq: self.nextSeq(), slot: slot),
                slot: slot)
        }
    }

    public func close() async {
        await transport.close()
    }

    // -------------------------------------------------- the transaction gate

    /// Non-reentrant FIFO gate: acquire() suspends while busy (FIFO resume
    /// order); release() resumes the head waiter. Cancellation while queued:
    /// the waiter still acquires, then the op's first Task.isCancelled poll
    /// exits it promptly.
    private func withTransaction<T: Sendable>(
        _ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // Resumed by release() with busy left true for us.
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // ------------------------------------------------------------ machinery

    private func nextSeq() -> UInt8 {
        seq = seq % 127 + 1     // 1..127, never 0
        return UInt8(seq)
    }

    private func drain() async throws {
        while try await transport.receive(timeout: 0) != nil {}
    }

    /// Next parseable MicroFreak frame within `within` seconds, else nil.
    /// An empty poll sleeps `pollInterval` on the injected clock (the sim
    /// returns nil immediately — this is what keeps the poll from spinning
    /// hot). A sleep interrupted by task cancellation returns early; callers
    /// re-check deadlines and the cancellation poll points exit promptly.
    private func nextFrame(within: TimeInterval) async throws -> Wire.Frame? {
        let deadline = clock.now + within
        while true {
            let remaining = deadline - clock.now
            if remaining <= 0 {
                return nil
            }
            guard let raw = try await transport.receive(timeout: remaining) else {
                try? await clock.sleep(for: config.pollInterval)
                continue
            }
            if let f = Wire.parse(raw) {
                return f
            }
        }
    }

    /// THE reply-lag chokepoint — the only code in the package that inspects
    /// a 0x52 reply. Send an addressed request; accept only a long-0x52
    /// reply whose embedded bank/pos names the requested slot.
    ///
    /// A mismatched reply is discarded as stale and the request resent,
    /// nameRetries attempts total; then .replyMismatch. Total silence throws
    /// .deviceTimeout(stage: .nameRead, slot:).
    ///
    /// Known limitation (verbatim from the Python): when two consecutive
    /// reads target the SAME slot (writePreset frames 1 and 7; a rename's
    /// read-back), a lagged reply to the first is indistinguishable from the
    /// answer to the second — the embedded address matches either way.
    /// Blob-hash verification covers writes; renames retain the window. No
    /// protocol-level fix exists — replies carry no request id. Do not
    /// "improve" this.
    private func transactAddressed(request: Data, slot: Int) async throws -> NameInfo {
        try await drain()
        var sawReply = false
        var repliedSlot: Int? = nil
        for _ in 0..<config.nameRetries {
            try await transport.send(request)
            let deadline = clock.now + config.nameTimeout
            scan: while true {
                let remaining = deadline - clock.now
                if remaining <= 0 {
                    break scan                  // silent attempt; resend
                }
                guard let f = try await nextFrame(within: remaining) else {
                    break scan                  // silent attempt; resend
                }
                if f.cmd != Wire.cmdName || f.data.count != Wire.namePayloadLength {
                    continue scan               // unrelated traffic; ignore
                }
                let info: NameInfo
                do {
                    info = try Wire.decodeNameReply(f)
                } catch let e as FreakError where e.group == .protocolError {
                    continue scan               // malformed (e.g. out-of-range
                                                // embedded address); ignore
                }
                sawReply = true
                if info.slot == slot {
                    return info
                }
                repliedSlot = info.slot         // stale (lagged) reply
                break scan                      // discard and resend at once
            }
        }
        if sawReply {
            throw FreakError.replyMismatch(requestedSlot: slot,
                                           repliedSlot: repliedSlot,
                                           attempts: config.nameRetries)
        }
        throw FreakError.deviceTimeout(stage: .nameRead, slot: slot)
    }

    /// Dump state machine: open, then pull chunks in strict lockstep — one
    /// outstanding request — until the device says "last".
    private func readBlobInTransaction(slot: Int) async throws -> Data {
        try await drain()
        try await transport.send(Wire.openDumpRequest(seq: nextSeq(), slot: slot))
        var chunks: [Wire.Frame] = []
        while true {
            // Sweep anything already delivered before pulling again; the
            // count bound keeps a runaway device (streaming 0x16 forever with
            // no terminator) from spinning this loop unboundedly.
            var gotLast = false
            while chunks.count < Wire.chunkCount {
                guard let raw = try await transport.receive(timeout: 0) else { break }
                guard let f = Wire.parse(raw), f.isChunk else { continue }
                chunks.append(f)
                if f.isLastChunk {
                    gotLast = true
                    break
                }
            }
            if gotLast {
                return try Wire.assembleBlob(chunks)
            }
            if chunks.count >= Wire.chunkCount {
                throw FreakError.protocolViolation(
                    detail: "slot \(slot): \(chunks.count) chunks without a 0x17 terminator")
            }
            try await transport.send(Wire.pullNextRequest(seq: nextSeq()))
            let f = try await awaitChunk(slot: slot)
            chunks.append(f)
            if f.isLastChunk {
                return try Wire.assembleBlob(chunks)
            }
        }
    }

    /// The 7-frame sequence with ack accounting (inside the gate).
    private func writePresetInTransaction(slot: Int, preset: Preset,
                                          frames: [Data]) async throws -> NameInfo {
        // 1. name read (fidelity to MCC; result discarded). Its own errors
        //    propagate unwrapped.
        _ = try await transactAddressed(
            request: Wire.readNameRequest(seq: nextSeq(), slot: slot), slot: slot)
        var chunksSent = 0
        var stage = WriteStage.nameWrite
        do {
            // 2. name + meta — the device acks it with 0x18 (captured: every
            //    outbound 0x52 and 0x15 is acked, not just chunks)
            try await transport.send(Wire.nameWriteFrame(
                seq: nextSeq(), slot: slot, name: preset.name, meta: preset.meta))
            try await requireAck(stage: .nameWrite, slot: slot, chunksSent: chunksSent)
            // 3. open blob write — acked with 0x18
            stage = .open
            try await transport.send(Wire.openWriteFrame(seq: nextSeq(), slot: slot))
            try await requireAck(stage: .open, slot: slot, chunksSent: chunksSent)
            // 4. go — acked with 0x18
            stage = .go
            try await transport.send(Wire.goFrame())
            try await requireAck(stage: .go, slot: slot, chunksSent: chunksSent)
            // 5-6. 146 chunks, each acked by the device with 0x18. The three
            // control-frame acks above are consumed before the chunk loop, so
            // ack N here really is the ack for chunk N — flow control stays
            // in lockstep with the device (the device acks EVERY write frame;
            // a writer pairing acks with chunks only would run three ahead).
            stage = .chunk
            for (i, ch) in frames.enumerated() {
                if Task.isCancelled {
                    // Cancelling mid-write tears the slot; the fields say how
                    // far it got — recovery is "write again".
                    throw FreakError.operationCancelled(done: i, total: frames.count)
                }
                try await transport.send(ch)
                chunksSent += 1
                if !(try await awaitAck()) {
                    throw FreakError.chunkNotAcked(slot: slot, chunkIndex: i)
                }
            }
        } catch let e as FreakError {
            switch e {
            case .chunkNotAcked, .operationCancelled, .writeAborted:
                throw e
            default:
                if e.group == .transport || e.group == .protocolError {
                    throw FreakError.writeAborted(stage: stage, slot: slot,
                                                  chunksSent: chunksSent)
                }
                throw e
            }
        }
        // 7. name read back
        do {
            return try await transactAddressed(
                request: Wire.readNameRequest(seq: nextSeq(), slot: slot), slot: slot)
        } catch let e as FreakError {
            switch e.group {
            case .transaction, .transport:
                throw FreakError.writeAborted(stage: .finalRead, slot: slot,
                                              chunksSent: chunksSent)
            default:
                throw e
            }
        }
    }

    /// Await the device's 0x18 ack for a write control frame (long 0x52,
    /// short 0x52 open, go); absence aborts the write at that stage.
    private func requireAck(stage: WriteStage, slot: Int, chunksSent: Int) async throws {
        if !(try await awaitAck()) {
            throw FreakError.writeAborted(stage: stage, slot: slot,
                                          chunksSent: chunksSent)
        }
    }

    private func awaitChunk(slot: Int) async throws -> Wire.Frame {
        let deadline = clock.now + config.dumpTimeout
        while true {
            let remaining = deadline - clock.now
            if remaining <= 0 {
                throw FreakError.deviceTimeout(stage: .dump, slot: slot)
            }
            guard let f = try await nextFrame(within: remaining) else {
                throw FreakError.deviceTimeout(stage: .dump, slot: slot)
            }
            if f.isChunk {
                return f
            }
            // anything else during a dump is stale; discard
        }
    }

    /// Device 0x18 within ackTimeout; false on timeout.
    private func awaitAck() async throws -> Bool {
        let deadline = clock.now + config.ackTimeout
        while true {
            let remaining = deadline - clock.now
            if remaining <= 0 {
                return false
            }
            guard let f = try await nextFrame(within: remaining) else {
                return false
            }
            if f.isAck {
                return true
            }
            // anything else during a write is stale; discard
        }
    }
}
