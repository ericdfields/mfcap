// Session.swift — FreakSession: seq counter, one transaction at a time, the
// reply-lag chokepoint (session.py).
//
// - The addressed-request seq counter is owned here; it increments 1..127
//   and wraps, never emitting 0, matching mfcap.midi.Reader. The write burst
//   has a separate seq stream, verbatim from the captures: goFrame() carries
//   seq 0 and the chunks continue from it, (i + 1) % 128 — wrapping THROUGH
//   0 (chunkFrames owns that stream).
// - Serialization by confinement, not lock: Python's threading.Lock is
//   replaced by Swift 6 type-level confinement — FreakSession is non-Sendable
//   and lives inside the MicroFreakDevice actor, so the compiler makes
//   concurrent entry impossible. One FreakSession per transport.
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
    public init() {}
}

/// One serialized request/reply conversation with the device.
/// Deliberately NOT Sendable — confined inside MicroFreakDevice.
public final class FreakSession {
    static let pollSleep: TimeInterval = 0.002   // _POLL_SLEEP

    let transport: any Transport
    let config: SessionConfig
    let clock: ClockFn
    let sleep: SleepFn
    private var seq = 0

    public init(transport: any Transport,
                config: SessionConfig = .init(),
                clock: @escaping ClockFn = FreakClock.monotonic,
                sleep: @escaping SleepFn = FreakClock.threadSleep) {
        self.transport = transport
        self.config = config
        self.clock = clock
        self.sleep = sleep
    }

    // ------------------------------------------------------------- public

    public func readName(slot: Int) throws -> NameInfo {
        try transactAddressed(
            request: FreakProtocol.readNameRequest(seq: nextSeq(), slot: slot),
            slot: slot)
    }

    /// Open a dump, then pull chunks in strict lockstep — one outstanding
    /// request — until the device says "last".
    public func readBlob(slot: Int) throws -> Data {
        try drain()
        try transport.send(FreakProtocol.openDumpRequest(seq: nextSeq(), slot: slot))
        var chunks: [Frame] = []
        while true {
            // collect anything already delivered before pulling again; the
            // count bound keeps a runaway device (streaming 0x16 forever with
            // no terminator) from spinning this loop unboundedly
            var gotLast = false
            while chunks.count < FreakProtocol.chunkCount {
                guard let raw = try transport.receive(timeout: 0.0) else { break }
                guard let f = FreakProtocol.parse(raw), f.isChunk else { continue }
                chunks.append(f)
                if f.isLastChunk {
                    gotLast = true
                    break
                }
            }
            if gotLast {
                return try FreakProtocol.assembleBlob(chunks)
            }
            if chunks.count >= FreakProtocol.chunkCount {
                throw FreakError.protocolViolation(
                    detail: "slot \(slot): \(chunks.count) chunks without a 0x17 terminator")
            }
            try transport.send(FreakProtocol.pullNextRequest(seq: nextSeq()))
            let f = try awaitChunk(slot: slot)
            chunks.append(f)
            if f.isLastChunk {
                return try FreakProtocol.assembleBlob(chunks)
            }
        }
    }

    /// The gate-verified 7-frame write sequence, verbatim from
    /// docs/write-protocol.md. No checksum is computed at any point; none
    /// exists. The returned NameInfo is frame 7's read-back — comparison is
    /// the caller's job (the frame itself is protocol fidelity and always
    /// sent).
    public func writePreset(slot: Int, _ preset: Preset,
                            cancel: CancelToken? = nil) throws -> NameInfo {
        let frames = try FreakProtocol.chunkFrames(blob: preset.blob)   // validates up front
        // 1. name read (fidelity to MCC; result discarded)
        _ = try transactAddressed(
            request: FreakProtocol.readNameRequest(seq: nextSeq(), slot: slot),
            slot: slot)
        var chunksSent = 0
        var stage = WriteStage.nameWrite
        do {
            // 2. name + meta — the device acks it with 0x18 (captured: every
            //    outbound 0x52 and 0x15 is acked, not just chunks)
            try send(FreakProtocol.nameWriteFrame(seq: nextSeq(), slot: slot,
                                                  name: preset.name, meta: preset.meta),
                     stage: .nameWrite, slot: slot, chunksSent: chunksSent)
            try requireAck(stage: .nameWrite, slot: slot, chunksSent: chunksSent)
            // 3. open blob write — acked with 0x18
            stage = .open
            try send(FreakProtocol.openWriteFrame(seq: nextSeq(), slot: slot),
                     stage: .open, slot: slot, chunksSent: chunksSent)
            try requireAck(stage: .open, slot: slot, chunksSent: chunksSent)
            // 4. go — acked with 0x18
            stage = .go
            try send(FreakProtocol.goFrame(), stage: .go, slot: slot, chunksSent: chunksSent)
            try requireAck(stage: .go, slot: slot, chunksSent: chunksSent)
            // 5-6. 146 chunks, each acked by the device with 0x18.
            // The three control-frame acks above are consumed before the
            // chunk loop, so ack N here really is the ack for chunk N —
            // flow control stays in lockstep with the device.
            stage = .chunk
            for (i, ch) in frames.enumerated() {
                if let cancel, cancel.isCancelled {
                    // Cancelling mid-write tears the slot; the fields say
                    // how far it got — recovery is "write again".
                    throw FreakError.cancelled(done: i, total: frames.count)
                }
                try send(ch, stage: .chunk, slot: slot, chunksSent: chunksSent)
                chunksSent += 1
                if !(try awaitAck()) {
                    throw FreakError.chunkNotAcked(slot: slot, chunkIndex: i)
                }
            }
        } catch let e as FreakError {
            switch e {
            case .chunkNotAcked, .cancelled, .writeAborted:
                throw e
            default:
                if e.isTransportError || e.isProtocolError {
                    throw FreakError.writeAborted(stage: stage, slot: slot,
                                                  chunksSent: chunksSent,
                                                  underlying: e.description)
                }
                throw e
            }
        }
        // 7. name read back
        do {
            return try transactAddressed(
                request: FreakProtocol.readNameRequest(seq: nextSeq(), slot: slot),
                slot: slot)
        } catch let e as FreakError {
            switch e {
            case .deviceTimeout, .replyMismatch:
                throw FreakError.writeAborted(stage: .finalRead, slot: slot,
                                              chunksSent: chunksSent,
                                              underlying: e.description)
            default:
                if e.isTransportError {
                    throw FreakError.writeAborted(stage: .finalRead, slot: slot,
                                                  chunksSent: chunksSent,
                                                  underlying: e.description)
                }
                throw e
            }
        }
    }

    /// Rename-in-place, exactly what MCC sends: the long 0x52 frame (acked
    /// by the device with 0x18, per the c4 capture) plus a refresh read. No
    /// blob traffic.
    public func writeName(slot: Int, name: String, meta: Data) throws -> NameInfo {
        try transport.send(FreakProtocol.nameWriteFrame(seq: nextSeq(), slot: slot,
                                                        name: name, meta: meta))
        guard try awaitAck() else {
            throw FreakError.deviceTimeout(stage: .nameWriteAck, slot: slot)
        }
        return try transactAddressed(
            request: FreakProtocol.readNameRequest(seq: nextSeq(), slot: slot),
            slot: slot)
    }

    public func close() {
        transport.close()
    }

    // ------------------------------------------------------------ private

    private func nextSeq() -> UInt8 {
        seq = seq % 127 + 1     // 1..127, never 0
        return UInt8(seq)
    }

    private func send(_ message: Data, stage: WriteStage, slot: Int,
                      chunksSent: Int) throws {
        do {
            try transport.send(message)
        } catch let e as FreakError where e.isTransportError {
            throw FreakError.writeAborted(stage: stage, slot: slot,
                                          chunksSent: chunksSent,
                                          underlying: e.description)
        }
    }

    /// Await the device's 0x18 ack for a write control frame (long 0x52,
    /// short 0x52 open, go); absence aborts the write at that stage.
    private func requireAck(stage: WriteStage, slot: Int, chunksSent: Int) throws {
        if !(try awaitAck()) {
            throw FreakError.writeAborted(stage: stage, slot: slot,
                                          chunksSent: chunksSent, underlying: nil)
        }
    }

    private func drain() throws {
        while try transport.receive(timeout: 0.0) != nil {}
    }

    /// Next parseable MicroFreak frame within timeout, else nil.
    private func nextFrame(timeout: TimeInterval) throws -> Frame? {
        let deadline = clock() + timeout
        while true {
            let remaining = deadline - clock()
            if remaining <= 0 {
                return nil
            }
            guard let raw = try transport.receive(timeout: remaining) else {
                sleep(Self.pollSleep)
                continue
            }
            if let f = FreakProtocol.parse(raw) {
                return f
            }
        }
    }

    /// Send an addressed request; accept only a long-0x52 reply whose
    /// embedded bank/pos names the requested slot — the reply-lag defense.
    ///
    /// A mismatched reply is discarded as stale and the request retried,
    /// nameRetries times total; then .replyMismatch. Total silence throws
    /// .deviceTimeout(stage: .nameRead, slot:).
    ///
    /// Known limitation: when two consecutive reads target the SAME slot
    /// (writePreset frames 1 and 7; a rename's read-back), a lagged reply
    /// to the first is indistinguishable from the answer to the second —
    /// the embedded address matches either way. Blob-hash verification
    /// covers write(); for a rename this could in principle compare against
    /// a stale pre-rename name (whether a lagged hardware reply carries
    /// request-time or emission-time content is unobserved). No
    /// protocol-level fix exists: replies carry no request id.
    private func transactAddressed(request: Data, slot: Int) throws -> NameInfo {
        try drain()
        var sawReply = false
        var repliedSlot: Int? = nil
        for _ in 0..<config.nameRetries {
            try transport.send(request)
            let deadline = clock() + config.nameTimeout
            scan: while true {
                let remaining = deadline - clock()
                if remaining <= 0 {
                    break scan                  // silent attempt; resend
                }
                guard let f = try nextFrame(timeout: remaining) else {
                    break scan                  // silent attempt; resend
                }
                if f.cmd != FreakProtocol.cmdName
                    || f.data.count != FreakProtocol.namePayloadLen {
                    continue scan               // unrelated traffic; ignore
                }
                let info: NameInfo
                do {
                    info = try FreakProtocol.decodeNameReply(f)
                } catch let e as FreakError where e.isProtocolError {
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

    private func awaitChunk(slot: Int) throws -> Frame {
        let deadline = clock() + config.dumpTimeout
        while true {
            let remaining = deadline - clock()
            if remaining <= 0 {
                throw FreakError.deviceTimeout(stage: .dump, slot: slot)
            }
            guard let f = try nextFrame(timeout: remaining) else {
                throw FreakError.deviceTimeout(stage: .dump, slot: slot)
            }
            if f.isChunk {
                return f
            }
            // anything else during a dump is stale; discard
        }
    }

    private func awaitAck() throws -> Bool {
        let deadline = clock() + config.ackTimeout
        while true {
            let remaining = deadline - clock()
            if remaining <= 0 {
                return false
            }
            guard let f = try nextFrame(timeout: remaining) else {
                return false
            }
            if f.isAck {
                return true
            }
            // anything else during a write is stale; discard
        }
    }
}
