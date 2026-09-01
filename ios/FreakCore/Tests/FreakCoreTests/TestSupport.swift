// TestSupport.swift — shared helpers for the FreakCore test suite:
// hex codecs, the deterministic virtual clock, a 7-bit blob generator, and
// the scripted Transport doubles the session/device tests drive.

import Foundation
import Testing
@testable import FreakCore

// ------------------------------------------------------------- hex helpers

/// Parse space-separated uppercase hex ("F0 00 20 6B ...") — the golden
/// vectors' byte encoding.
func hexBytes(_ spaced: String) -> Data {
    Data(spaced.split(separator: " ").map { UInt8($0, radix: 16)! })
}

func spacedHex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// ---------------------------------------------------------- virtual clock

/// Deterministic monotonic clock; sleep() advances it by max(dt, 1e-4) —
/// the same FakeClock the Python suite and tools/gen_vectors.py use, so
/// silent timeout windows cost nothing real.
// @unchecked Sendable: NSLock-guarded state — the same pattern the §4 table
// sanctions for CancelToken (test-only double).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0.0

    var clock: ClockFn {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return now
        }
    }

    var sleep: SleepFn {
        { [self] dt in
            lock.lock()
            now += max(dt, 1e-4)
            lock.unlock()
        }
    }
}

func makeSession(_ transport: any Transport,
                 config: SessionConfig = .init()) -> FreakSession {
    let tc = TestClock()
    return FreakSession(transport: transport, config: config,
                        clock: tc.clock, sleep: tc.sleep)
}

func makeDevice(_ transport: any Transport,
                slots: Int = FreakProtocol.slots) -> MicroFreakDevice {
    let tc = TestClock()
    return MicroFreakDevice(transport: transport, slots: slots,
                            clock: tc.clock, sleep: tc.sleep)
}

// -------------------------------------------------------------- test data

/// Deterministic 7-bit-clean 4672-byte blob (the Python suite's blob7 LCG).
func blob7(_ seed: Int) -> Data {
    var out = [UInt8]()
    var x = (seed % 126) + 1
    while out.count < FreakProtocol.blobSize {
        x = (x * 75 + 74) % 127
        out.append(UInt8(x))
    }
    return Data(out.prefix(FreakProtocol.blobSize))
}

let testMeta = Data([0x18, 0x00, 0x00, 0x00, 0x00, 0x7F, 0x01, 0x00, 0x33])

// -------------------------------------------------------------- transports
// All doubles are Transport implementations, whose @unchecked Sendable is
// sanctioned by §4; each is internally NSLock-synchronized.

/// Never answers anything.
final class DeadTransport: Transport, @unchecked Sendable {
    func send(_ message: Data) throws {}
    func receive(timeout: TimeInterval) throws -> Data? { nil }
    func close() {}
}

/// Always replies to a name read with a reply for one fixed other slot — a
/// lag that never resolves.
final class WrongSlotTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let wrong: Int
    private var outbox: [Data] = []
    private var sendCount = 0

    init(wrongSlot: Int) {
        self.wrong = wrongSlot
    }

    var sends: Int {
        lock.lock()
        defer { lock.unlock() }
        return sendCount
    }

    func send(_ message: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let f = FreakProtocol.parse(message),
              f.cmd == FreakProtocol.cmdOpen, f.data.count == 3,
              f.data.last == 0 else { return }
        sendCount += 1
        let (bank, pos) = try FreakProtocol.addr(wrong)
        let meta = Data([0, 0, 0, 0, 0, pos, wrong < 384 ? 0 : 1, 0, 0x33])
        let payload = Data([bank, pos, 0]) + meta + Data("Wrong".utf8)
            + Data(count: 18)
        outbox.append(FreakProtocol.frame(seq: 0, length: 0x23,
                                          cmd: FreakProtocol.cmdName, data: payload))
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return outbox.isEmpty ? nil : outbox.removeFirst()
    }

    func close() {}
}

/// Answers a name read with a malformed 0x52 (embedded bank 5 = slot 640,
/// outside the device) immediately followed by the genuine reply.
final class BadAddressThenGoodTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let goodSlot: Int
    private var outbox: [Data] = []

    init(goodSlot: Int) {
        self.goodSlot = goodSlot
    }

    func send(_ message: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let f = FreakProtocol.parse(message),
              f.cmd == FreakProtocol.cmdOpen, f.data.count == 3,
              f.data.last == 0 else { return }
        let bogus = Data([5, 0, 0]) + Data(count: 9) + Data("Bogus".utf8)
            + Data(count: 18)
        outbox.append(FreakProtocol.frame(seq: f.seq, length: 0x23,
                                          cmd: FreakProtocol.cmdName, data: bogus))
        let (bank, pos) = try FreakProtocol.addr(goodSlot)
        let meta = Data([0, 0, 0, 0, 0, pos, goodSlot < 384 ? 0 : 1, 0, 0x33])
        let payload = Data([bank, pos, 0]) + meta + Data("Good".utf8)
            + Data(count: 19)
        outbox.append(FreakProtocol.frame(seq: f.seq, length: 0x23,
                                          cmd: FreakProtocol.cmdName, data: payload))
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return outbox.isEmpty ? nil : outbox.removeFirst()
    }

    func close() {}
}

/// A device gone wrong: after the dump open it streams 0x16 chunks forever
/// and never sends the 0x17 last-chunk marker — the case the >= chunkCount
/// guard in FreakSession.readBlob exists for.
final class RunawayDumpTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func send(_ message: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let f = FreakProtocol.parse(message),
           f.cmd == FreakProtocol.cmdOpen, f.data.count == 3, f.data.last == 1 {
            opened = true
        }
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard opened else { return nil }
        return FreakProtocol.frame(seq: 0, length: 0x20,
                                   cmd: FreakProtocol.cmdChunkMore,
                                   data: Data(repeating: 0x55, count: 32))
    }

    func close() {}
}

/// Passes through to the inner transport until `judge(frame)` says fail,
/// then throws .transport from send().
final class FailingSendTransport: Transport, @unchecked Sendable {
    private let inner: any Transport
    private let judge: @Sendable (Frame) -> Bool

    init(_ inner: any Transport, judge: @escaping @Sendable (Frame) -> Bool) {
        self.inner = inner
        self.judge = judge
    }

    func send(_ message: Data) throws {
        if let f = FreakProtocol.parse(message), judge(f) {
            throw FreakError.transport(detail: "wire pulled")
        }
        try inner.send(message)
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        try inner.receive(timeout: timeout)
    }

    func close() {
        inner.close()
    }
}

/// Delivers everything except device 0x18 acks once armed.
final class AckDroppingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any Transport
    private var dropping = false

    init(_ inner: any Transport) {
        self.inner = inner
    }

    var dropAcks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return dropping }
        set { lock.lock(); dropping = newValue; lock.unlock() }
    }

    func send(_ message: Data) throws {
        try inner.send(message)
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        while true {
            guard let raw = try inner.receive(timeout: timeout) else { return nil }
            if dropAcks, let f = FreakProtocol.parse(raw), f.isAck {
                continue
            }
            return raw
        }
    }

    func close() {
        inner.close()
    }
}

/// After the last chunk goes out, suppress long-0x52 name replies so the
/// final read-back times out.
final class ReplyDroppingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any Transport
    private var afterLastChunk = false

    init(_ inner: any Transport) {
        self.inner = inner
    }

    func send(_ message: Data) throws {
        let f = FreakProtocol.parse(message)
        try inner.send(message)
        if let f, f.cmd == FreakProtocol.cmdChunkLast {
            lock.lock()
            afterLastChunk = true
            lock.unlock()
        }
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        while true {
            guard let raw = try inner.receive(timeout: timeout) else { return nil }
            lock.lock()
            let dropping = afterLastChunk
            lock.unlock()
            if dropping, let f = FreakProtocol.parse(raw),
               f.cmd == FreakProtocol.cmdName {
                continue
            }
            return raw
        }
    }

    func close() {
        inner.close()
    }
}

/// Passes everything through, but flips one bit of one write chunk in
/// transit — a wire that lies.
final class ChunkCorruptingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any Transport
    private let chunkIndex: Int
    private let byteOffset: Int
    private var seen = 0

    init(_ inner: any Transport, chunkIndex: Int, byteOffset: Int) {
        self.inner = inner
        self.chunkIndex = chunkIndex
        self.byteOffset = byteOffset
    }

    func send(_ message: Data) throws {
        var raw = message
        if let f = FreakProtocol.parse(raw), f.isChunk {
            lock.lock()
            let hit = seen == chunkIndex
            seen += 1
            lock.unlock()
            if hit {
                var body = [UInt8](raw)
                body[9 + byteOffset] ^= 0x01   // stays 7-bit clean
                raw = Data(body)
            }
        }
        try inner.send(raw)
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        try inner.receive(timeout: timeout)
    }

    func close() {
        inner.close()
    }
}

/// Replays the device side of a golden-vector transcript: every outbound
/// frame must byte-match the next expected "out" entry (mismatch throws and
/// is remembered), after which any following "in" entries are queued for
/// receive(). Fully consuming the transcript proves the port emitted
/// exactly the reference conversation.
final class TranscriptTransport: Transport, @unchecked Sendable {
    struct Entry {
        let dir: String
        let frame: Data
    }

    private let lock = NSLock()
    private var entries: [Entry]
    private var pos = 0
    private var inbox: [Data] = []
    private var firstMismatch: String?

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    convenience init(transcript: [[String: Any]]) {
        self.init(transcript.map {
            Entry(dir: $0["dir"] as! String, frame: hexBytes($0["frame"] as! String))
        })
    }

    var mismatch: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstMismatch
    }

    var fullyConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pos == entries.count && inbox.isEmpty
    }

    func send(_ message: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard pos < entries.count else {
            return try fail("unexpected extra frame past transcript end: "
                + spacedHex(message))
        }
        let e = entries[pos]
        guard e.dir == "out" else {
            return try fail("host sent while transcript expected inbound "
                + "traffic at entry \(pos): " + spacedHex(message))
        }
        guard e.frame == message else {
            return try fail("frame mismatch at transcript entry \(pos):\n"
                + "  expected \(spacedHex(e.frame))\n"
                + "  got      \(spacedHex(message))")
        }
        pos += 1
        while pos < entries.count && entries[pos].dir == "in" {
            inbox.append(entries[pos].frame)
            pos += 1
        }
    }

    func receive(timeout: TimeInterval) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    func close() {}

    private func fail(_ message: String) throws {
        if firstMismatch == nil {
            firstMismatch = message
        }
        throw FreakError.transport(detail: message)
    }
}

// ------------------------------------------------------------ error helpers

/// Runs body and returns the FreakError it throws; records an issue when
/// nothing (or a foreign error) is thrown.
@discardableResult
func expectFreakError(_ comment: String = "expected a FreakError",
                      _ body: () throws -> Any?) -> FreakError? {
    do {
        _ = try body()
    } catch let e as FreakError {
        return e
    } catch {
        Issue.record("\(comment): got foreign error \(error)")
        return nil
    }
    Issue.record("\(comment): nothing was thrown")
    return nil
}

@discardableResult
func expectFreakErrorAsync(_ comment: String = "expected a FreakError",
                           _ body: () async throws -> Any?) async -> FreakError? {
    do {
        _ = try await body()
    } catch let e as FreakError {
        return e
    } catch {
        Issue.record("\(comment): got foreign error \(error)")
        return nil
    }
    Issue.record("\(comment): nothing was thrown")
    return nil
}

// --------------------------------------------------------------- LockedBox

/// Tiny thread-safe container for test bookkeeping crossing @Sendable
/// closures (progress callbacks fired on the device queue).
// @unchecked Sendable: NSLock-guarded state — the same pattern the §4 table
// sanctions for CancelToken (test-only double).
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}

/// Drain a SimulatedMicroFreak's outbox (the Python tests' recv_all).
func recvAll(_ sim: SimulatedMicroFreak) throws -> [Data] {
    var out: [Data] = []
    while let raw = try sim.receive(timeout: 0.0) {
        out.append(raw)
    }
    return out
}

/// Fresh per-test scratch directory; caller removes it in a defer.
func tempDir(_ prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("freakcore-tests")
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
