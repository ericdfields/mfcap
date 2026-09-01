// SimulatedMicroFreak.swift — an in-memory device faithful to
// docs/write-protocol.md (transports/simulated.py). Ships in the library
// target: demo mode links it; it is not test-only.
//
// Implements Transport synchronously: send() runs the device state machine
// inline and appends replies to an internal outbox; receive(timeout:) pops
// the outbox FIFO, returning nil immediately when empty (no real sleeping —
// offline tests are instant).
//
// Fidelity (asserted by SimulatedFidelityTests):
//
// 1. Name reads reply with the full 35-byte long-0x52 payload: bank, pos,
//    0x00, 5 opaque bytes, pos-again, the 0/1 slot-384 flag, category,
//    attribute (printable values like 0x32/0x33 included, so header-leak
//    regressions are caught), then the NUL-padded 23-byte name. The reply
//    echoes its request's seq, as every captured reply does.
// 2. replyLag == true (the default, so every offline test exercises the
//    defense): the reply to name-read N is held and emitted only when
//    name-read N+1 arrives; the first name read yields nothing. The held
//    reply's content is rendered from device state at emission time — the
//    behavior of a device that is slow to answer, not one that answers
//    wrong. NOTE: this is deliberately HARSHER than hardware. On the real
//    device a lone name read is answered; replies lag only under rapid
//    back-to-back reads (write-protocol.md). Holding unconditionally
//    guarantees the Session's retry defense engages in every offline run,
//    at the cost of one nameTimeout on a first read — do not tune real-time
//    lag behavior against this model.
// 3. Dump reads: open [bank,pos,0x01], then 145 x 0x16 + 1 x 0x17 (32 bytes
//    each), pull-paced by 0x18; each emitted chunk echoes its pull's seq,
//    as captured.
// 4. Writes: the long 0x52 alone updates name+meta with no blob change (a
//    rename is only this frame, per MCC); the short 0x52 [bank,pos,0x01]
//    opens; 0x15 arms; 0x17 commits. Matching the captures, the device acks
//    the long 0x52, the short 0x52 open, the 0x15 go AND every chunk, each
//    with a 0x18 whose len byte is 0x00, payload empty, seq echoing the
//    acked frame's seq. Inbound long-0x52 writes are validated against the
//    captured outbound convention (payload[8]=pos, payload[9]=0x06,
//    payload[3] without the reply-only 0x10 bit); deviations append to
//    `faults`. A committed total != 4672 bytes, or chunks without an open,
//    leaves the slot untouched and appends to `faults` — so a broken writer
//    fails verification instead of passing. No checksum anywhere.
// 5. failChunkAt == N: the write chunk with 0-based cumulative index N
//    (counted across the sim's lifetime) and every later one receive no
//    0x18 ack — drives .chunkNotAcked and torn-write tests.
//
// wireLog direction convention is the host's (mfcap house style):
// (.out, raw) = host -> device, (.in, raw) = device -> host.

import CryptoKit
import Foundation

public struct WireEntry: Sendable, Equatable {
    public enum Direction: String, Sendable {
        case out
        case `in`
    }
    public let direction: Direction
    public let raw: Data

    public init(direction: Direction, raw: Data) {
        self.direction = direction
        self.raw = raw
    }
}

// @unchecked Sendable: sanctioned by §4 for Transport implementations —
// one internal NSLock guards ALL mutable state; every public method takes it.
public final class SimulatedMicroFreak: Transport, @unchecked Sendable {
    private struct SlotState {
        var name: String
        var meta: Data      // metaLen bytes = long-0x52 payload[3..11], reply form
        var blob: Data
    }

    private struct PendingWrite {
        var slot: Int
        var armed: Bool
        var buf: Data
    }

    public let slots: Int
    public let replyLag: Bool
    public let failChunkAt: Int?

    private let lock = NSLock()
    private var state: [Int: SlotState] = [:]
    private var outbox: [Data] = []
    // reply-lag holding cell: (slot, request seq) of the unanswered read
    private var held: (slot: Int, seq: UInt8)? = nil
    private var dump: (slot: Int, nextChunkIndex: Int)? = nil
    private var pendingWrite: PendingWrite? = nil
    private var chunkCounter = 0                       // cumulative, for failChunkAt
    private var faultsList: [String] = []
    private var wireLogList: [WireEntry] = []

    public init(slots: Int = FreakProtocol.slots,
                replyLag: Bool = true,                 // default ON — every offline
                failChunkAt: Int? = nil) {             // test exercises the defense
        self.slots = slots
        self.replyLag = replyLag
        self.failChunkAt = failChunkAt
        for s in 0..<slots {
            state[s] = SlotState(
                name: "Init",
                meta: Self.positionalMeta(slot: s, opaque5: Data(count: 5),
                                          category: 0x00, attribute: 0x33),
                blob: Data(count: FreakProtocol.blobSize))
        }
    }

    /// The reference device's shape: named pseudo-presets in the low slots
    /// plus initCopies identical "Init" blobs, correct meta including the
    /// payload[9] flip at 384 — so expendability tests are real.
    public static func factoryFresh(initCopies: Int = 269, seed: Int = 0,
                                    slots: Int = FreakProtocol.slots,
                                    replyLag: Bool = true,
                                    failChunkAt: Int? = nil) -> SimulatedMicroFreak {
        let sim = SimulatedMicroFreak(slots: slots, replyLag: replyLag,
                                      failChunkAt: failChunkAt)
        precondition(0 <= initCopies && initCopies <= sim.slots,
                     "initCopies \(initCopies) > slots \(sim.slots)")
        let named = sim.slots - initCopies
        let initBlob = synthBlob(seed: seed, label: "init")
        sim.lock.lock()
        defer { sim.lock.unlock() }
        for slot in 0..<sim.slots {
            let name: String
            let blob: Data
            let opaque: Data
            let category: UInt8
            let attribute: UInt8
            if slot < named {
                name = String(format: "Patch %03d", slot)
                blob = synthBlob(seed: seed, label: "slot\(slot)")
                opaque = Data([UInt8((slot * 3) % 0x20), 0x00, 0x00, 0x00, 0x00])
                category = UInt8(slot % 0x0C)
                attribute = slot % 2 == 0 ? 0x32 : 0x33
            } else {
                name = "Init"
                blob = initBlob
                opaque = Data([0x08, 0x00, 0x00, 0x00, 0x00])
                category = 0x00
                attribute = 0x33
            }
            sim.state[slot] = SlotState(
                name: name,
                meta: positionalMeta(slot: slot, opaque5: opaque,
                                     category: category, attribute: attribute),
                blob: blob)
        }
        return sim
    }

    /// Deterministic synthetic 4672-byte, 7-bit-clean content. No real
    /// Arturia blob is bundled.
    ///
    /// Deviation #11 (binding override to spec §3.11): cross-language sim
    /// blob PARITY with Python's _synth_blob is DROPPED as a requirement —
    /// no sim_factory.json vector exists. factoryFresh must reproduce the
    /// documented SHAPE deterministically (269 identical Init blobs + named
    /// low slots, seeded blob synth, positionally correct meta: reply
    /// meta[0] carries 0x10 exactly when slot >= 128, the payload[9]-
    /// equivalent flag flips at slot 384, printable attribute bytes
    /// 0x32/0x33), but its blob bytes need not match Python's.
    static func synthBlob(seed: Int, label: String) -> Data {
        var out = Data()
        var counter = 0
        while out.count < FreakProtocol.blobSize {
            let digest = SHA256.hash(data: Data("\(seed):\(label):\(counter)".utf8))
            out.append(contentsOf: digest.map { $0 & 0x7F })
            counter += 1
        }
        return Data(out.prefix(FreakProtocol.blobSize))
    }

    // ------------------------------------------------------ test back doors

    public func load(slot: Int, preset: Preset) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkSlot(slot)      // .slotOutOfRange (Python raised IndexError; §10 deviation 8)
        let m = [UInt8](preset.meta)
        state[slot] = SlotState(
            name: preset.name,
            meta: Self.positionalMeta(slot: slot, opaque5: Data(m[0..<5]),
                                      category: m[7], attribute: m[8]),
            blob: preset.blob)
    }

    public func peek(slot: Int) throws -> Preset {
        lock.lock()
        defer { lock.unlock() }
        try checkSlot(slot)
        let st = state[slot]!
        return try Preset(name: st.name, blob: st.blob, meta: st.meta)
    }

    /// Snapshot copy under the lock.
    public var faults: [String] {
        lock.lock()
        defer { lock.unlock() }
        return faultsList
    }

    /// Snapshot copy under the lock.
    public var wireLog: [WireEntry] {
        lock.lock()
        defer { lock.unlock() }
        return wireLogList
    }

    // ------------------------------------------------------------ Transport

    /// Runs the device state machine inline.
    public func send(_ message: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let raw = message
        wireLogList.append(WireEntry(direction: .out, raw: raw))
        guard let f = FreakProtocol.parse(raw) else {
            faultsList.append("unparseable frame: \(raw.prefix(12).hexString)...")
            return
        }
        switch f.cmd {
        case FreakProtocol.cmdOpen:
            onOpen(f)
        case FreakProtocol.cmdNext:
            onPull(f)
        case FreakProtocol.cmdName:
            onName(f)
        case FreakProtocol.cmdGo:
            onGo(f)
        case FreakProtocol.cmdChunkMore, FreakProtocol.cmdChunkLast:
            onChunk(f)
        default:
            faultsList.append(String(format: "unknown command 0x%02X", f.cmd))
        }
    }

    /// FIFO outbox pop; nil immediately when empty — no sleeping.
    public func receive(timeout: TimeInterval) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !outbox.isEmpty else {
            return nil
        }
        return outbox.removeFirst()
    }

    public func close() {}

    // -------------------------------------------------------- state machine
    // (all called with the lock held)

    private func onOpen(_ f: Frame) {
        let d = [UInt8](f.data)
        guard d.count == 3 else {
            faultsList.append("0x19 with \(d.count)-byte payload")
            return
        }
        guard let slot = slotFrom(bank: d[0], pos: d[1]) else {
            return
        }
        let trailer = d[2]
        if trailer == 0x00 {                        // name read
            if replyLag {
                let pending = held
                held = (slot, f.seq)
                if let pending {
                    emitNameReply(slot: pending.slot, seq: pending.seq)
                }
            } else {
                emitNameReply(slot: slot, seq: f.seq)
            }
        } else if trailer == 0x01 {                 // dump open
            dump = (slot, 0)
        } else {
            faultsList.append(String(format: "0x19 with trailer 0x%02X", trailer))
        }
    }

    private func onPull(_ f: Frame) {
        guard let (slot, i) = dump else {
            faultsList.append("0x18 pull without a dump open")
            return
        }
        let blob = [UInt8](state[slot]!.blob)
        let piece = Data(blob[(i * FreakProtocol.chunkSize)..<((i + 1) * FreakProtocol.chunkSize)])
        let cmd = i == FreakProtocol.chunkCount - 1
            ? FreakProtocol.cmdChunkLast : FreakProtocol.cmdChunkMore
        emit(FreakProtocol.frame(seq: f.seq, length: 0x20, cmd: cmd, data: piece))
        // chunk echoes the pull's seq
        if i == FreakProtocol.chunkCount - 1 {
            dump = nil
        } else {
            dump = (slot, i + 1)
        }
    }

    private func onName(_ f: Frame) {
        let d = [UInt8](f.data)
        if d.count == FreakProtocol.namePayloadLen {       // long form: name + meta
            guard let slot = slotFrom(bank: d[0], pos: d[1]) else {
                return
            }
            if d[2] != 0x00 {
                faultsList.append(String(format: "long 0x52 payload[2]=0x%02X", d[2]))
            }
            let pos = UInt8(slot % FreakProtocol.slotsPerBank)
            if d[8] != pos {
                faultsList.append(String(
                    format: "long 0x52 payload[8]=0x%02X, expected pos 0x%02X (slot %d)",
                    d[8], pos, slot))
            }
            if d[9] != FreakProtocol.writePayload9 {
                // every captured outbound write carries 0x06 here; the 0/1
                // slot-384 flag belongs to REPLIES only
                faultsList.append(String(
                    format: "long 0x52 payload[9]=%d, expected 0x%02X on a write (slot %d)",
                    d[9], FreakProtocol.writePayload9, slot))
            }
            if d[3] & FreakProtocol.replyMetaFlag != 0 {
                faultsList.append(String(
                    format: "long 0x52 payload[3]=0x%02X carries the reply-only 0x10 bit (slot %d)",
                    d[3], slot))
            }
            var st = state[slot]!
            st.name = FreakProtocol.decodeName(d)
            // store reply-form meta so subsequent name reads mirror hardware
            st.meta = Self.positionalMeta(slot: slot, opaque5: Data(d[3..<8]),
                                          category: d[10], attribute: d[11])
            state[slot] = st
            ack(f)                // captured: the long 0x52 is acked with 0x18
        } else if d.count == 3 && d[2] == 0x01 {           // short form: open write
            guard let slot = slotFrom(bank: d[0], pos: d[1]) else {
                return
            }
            if pendingWrite != nil {
                faultsList.append("write opened while a write was pending")
            }
            pendingWrite = PendingWrite(slot: slot, armed: false, buf: Data())
            ack(f)                // captured: the open is acked with 0x18
        } else {
            faultsList.append("0x52 with \(d.count)-byte payload: \(f.data.hexString)")
        }
    }

    private func onGo(_ f: Frame) {
        guard pendingWrite != nil, pendingWrite!.armed == false else {
            faultsList.append("0x15 go without a fresh write open")
            return
        }
        pendingWrite!.armed = true
        ack(f)                    // captured: go is acked with 0x18
    }

    private func onChunk(_ f: Frame) {
        let idx = chunkCounter
        chunkCounter += 1
        guard pendingWrite != nil, pendingWrite!.armed else {
            faultsList.append("chunk without an open+armed write")
            return                                  // slot untouched, no ack
        }
        if f.data.count != FreakProtocol.chunkSize {
            faultsList.append("chunk with \(f.data.count) bytes")
        }
        pendingWrite!.buf.append(f.data)
        let acked = !(failChunkAt != nil && idx >= failChunkAt!)
        if acked {
            ack(f)
        }
        if f.cmd == FreakProtocol.cmdChunkLast {    // commit
            let w = pendingWrite!
            pendingWrite = nil
            let total = w.buf.count
            if total == FreakProtocol.blobSize {
                state[w.slot]!.blob = w.buf
            } else {
                faultsList.append(
                    "write to slot \(w.slot) committed \(total) bytes, "
                    + "expected \(FreakProtocol.blobSize); slot untouched")
            }
        }
    }

    // -------------------------------------------------------------- helpers

    private func slotFrom(bank: UInt8, pos: UInt8) -> Int? {
        let slot = Int(bank) * FreakProtocol.slotsPerBank + Int(pos)
        guard 0 <= slot && slot < slots && Int(pos) < FreakProtocol.slotsPerBank else {
            faultsList.append("address (bank \(bank), pos \(pos)) out of range")
            return nil
        }
        return slot
    }

    private func checkSlot(_ slot: Int) throws {
        guard 0 <= slot && slot < slots else {
            throw FreakError.slotOutOfRange(slot: slot)
        }
    }

    /// Device-shape 0x18 ack: len byte 0x00, empty payload, seq echoing the
    /// acked frame's seq — the shape of every captured inbound ack.
    private func ack(_ f: Frame) {
        emit(FreakProtocol.frame(seq: f.seq, length: 0x00, cmd: FreakProtocol.cmdNext))
    }

    /// metaLen bytes in REPLY form, positionally correct for slot:
    /// meta[5]=pos, meta[6]=the 0/1 slot-384 flag, and meta[0] carries the
    /// reply-only 0x10 bit exactly when slot >= 128 (all hardware reply
    /// fixtures: slots 0/8/40 clear, 200/511 set).
    private static func positionalMeta(slot: Int, opaque5: Data,
                                       category: UInt8, attribute: UInt8) -> Data {
        let pos = UInt8(slot % FreakProtocol.slotsPerBank)
        let high: UInt8 = slot < FreakProtocol.highBankBoundary ? 0 : 1
        var m = [UInt8](opaque5.prefix(5))
        m += [UInt8](repeating: 0x00, count: 5 - m.count)
        m[0] &= ~FreakProtocol.replyMetaFlag
        if slot >= FreakProtocol.slotsPerBank {
            m[0] |= FreakProtocol.replyMetaFlag
        }
        return Data(m) + Data([pos, high, category & 0x7F, attribute & 0x7F])
    }

    /// Render the long-0x52 reply from CURRENT device state (a lagged device
    /// is slow, not wrong) and append it to the outbox. The reply echoes its
    /// own request's seq, as every captured reply does — under lag that is
    /// the seq of the read it answers, not of the read that released it.
    private func emitNameReply(slot: Int, seq: UInt8) {
        let st = state[slot]!
        let bank = UInt8(slot / FreakProtocol.slotsPerBank)
        let pos = UInt8(slot % FreakProtocol.slotsPerBank)
        var field = [UInt8](st.name.utf8.map { $0 <= 0x7F ? $0 : UInt8(ascii: "?") }
            .prefix(FreakProtocol.nameLen))
        field += [UInt8](repeating: 0x00, count: FreakProtocol.nameLen - field.count)
        let payload = Data([bank, pos, 0x00]) + st.meta + Data(field)
        assert(payload.count == FreakProtocol.namePayloadLen)
        emit(FreakProtocol.frame(seq: seq, length: 0x23, cmd: FreakProtocol.cmdName,
                                 data: payload))
    }

    private func emit(_ raw: Data) {
        wireLogList.append(WireEntry(direction: .in, raw: raw))
        outbox.append(raw)
    }
}
