// TestSupport.swift — shared helpers for the FreakCore test suite: hex
// codecs, a 7-bit blob generator, and the scripted FreakTransport doubles
// the session/device tests drive. Every double is an actor — no locks, no
// @unchecked Sendable anywhere in the test tree.

import Foundation
import os
import Testing
@testable import FreakCore

typealias Frame = Wire.Frame

// ------------------------------------------------------------- hex helpers

/// Parse space-separated uppercase hex ("F0 00 20 6B ...") — the golden
/// vectors' byte encoding.
func hexBytes(_ spaced: String) -> Data {
    Data(spaced.split(separator: " ").map { UInt8($0, radix: 16)! })
}

func spacedHex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// ---------------------------------------------------------------- builders

func makeSession(_ transport: any FreakTransport,
                 config: SessionConfig = .init()) -> FreakSession {
    FreakSession(transport: transport, config: config, clock: TestClock())
}

func makeDevice(_ transport: any FreakTransport,
                slotCount: Int = Wire.slots) -> MicroFreakDevice {
    MicroFreakDevice(transport: transport, slotCount: slotCount, clock: TestClock())
}

// -------------------------------------------------------------- test data

/// Deterministic 7-bit-clean 4672-byte blob (the Python suite's blob7 LCG).
func blob7(_ seed: Int) -> Data {
    var out = [UInt8]()
    var x = (seed % 126) + 1
    while out.count < Wire.blobSize {
        x = (x * 75 + 74) % 127
        out.append(UInt8(x))
    }
    return Data(out.prefix(Wire.blobSize))
}

let testMeta = Data([0x18, 0x00, 0x00, 0x00, 0x00, 0x7F, 0x01, 0x00, 0x33])

// -------------------------------------------------------------- transports

/// Never answers anything.
actor DeadTransport: FreakTransport {
    func send(_ message: Data) async throws {}
    func receive(timeout: TimeInterval) async throws -> Data? { nil }
    func close() async {}
}

/// Always replies to a name read with a reply for one fixed other slot — a
/// lag that never resolves.
actor WrongSlotTransport: FreakTransport {
    private let wrong: Int
    private var outbox: [Data] = []
    private var sendCount = 0

    init(wrongSlot: Int) {
        self.wrong = wrongSlot
    }

    var sends: Int { sendCount }

    func send(_ message: Data) async throws {
        guard let f = Wire.parse(message),
              f.cmd == Wire.cmdOpen, f.data.count == 3, f.data.last == 0 else { return }
        sendCount += 1
        let (bank, pos) = try Wire.addr(wrong)
        let meta = Data([0, 0, 0, 0, 0, pos, wrong < 384 ? 0 : 1, 0, 0x33])
        let payload = Data([bank, pos, 0]) + meta + Data("Wrong".utf8) + Data(count: 18)
        outbox.append(Wire.frame(seq: 0, length: 0x23, cmd: Wire.cmdName, data: payload))
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        outbox.isEmpty ? nil : outbox.removeFirst()
    }

    func close() async {}
}

/// Answers a name read with a malformed 0x52 (embedded bank 5 = slot 640,
/// outside the device) immediately followed by the genuine reply.
actor BadAddressThenGoodTransport: FreakTransport {
    private let goodSlot: Int
    private var outbox: [Data] = []

    init(goodSlot: Int) {
        self.goodSlot = goodSlot
    }

    func send(_ message: Data) async throws {
        guard let f = Wire.parse(message),
              f.cmd == Wire.cmdOpen, f.data.count == 3, f.data.last == 0 else { return }
        let bogus = Data([5, 0, 0]) + Data(count: 9) + Data("Bogus".utf8) + Data(count: 18)
        outbox.append(Wire.frame(seq: f.seq, length: 0x23, cmd: Wire.cmdName, data: bogus))
        let (bank, pos) = try Wire.addr(goodSlot)
        let meta = Data([0, 0, 0, 0, 0, pos, goodSlot < 384 ? 0 : 1, 0, 0x33])
        let payload = Data([bank, pos, 0]) + meta + Data("Good".utf8) + Data(count: 19)
        outbox.append(Wire.frame(seq: f.seq, length: 0x23, cmd: Wire.cmdName, data: payload))
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        outbox.isEmpty ? nil : outbox.removeFirst()
    }

    func close() async {}
}

/// A device gone wrong: after the dump open it streams 0x16 chunks forever
/// and never sends the 0x17 last-chunk marker — the case the >= chunkCount
/// guard in FreakSession's dump loop exists for.
actor RunawayDumpTransport: FreakTransport {
    private var opened = false

    func send(_ message: Data) async throws {
        if let f = Wire.parse(message),
           f.cmd == Wire.cmdOpen, f.data.count == 3, f.data.last == 1 {
            opened = true
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        guard opened else { return nil }
        return Wire.frame(seq: 0, length: 0x20, cmd: Wire.cmdChunkMore,
                          data: Data(repeating: 0x55, count: 32))
    }

    func close() async {}
}

/// Passes through to the inner transport until `judge(frame)` says fail,
/// then throws .transport from send().
actor FailingSendTransport: FreakTransport {
    private let inner: any FreakTransport
    private let judge: @Sendable (Frame) -> Bool

    init(_ inner: any FreakTransport, judge: @escaping @Sendable (Frame) -> Bool) {
        self.inner = inner
        self.judge = judge
    }

    func send(_ message: Data) async throws {
        if let f = Wire.parse(message), judge(f) {
            throw FreakError.transport(detail: "wire pulled")
        }
        try await inner.send(message)
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        try await inner.receive(timeout: timeout)
    }

    func close() async {
        await inner.close()
    }
}

/// Passes through, and cancels the CURRENT task right after forwarding a
/// frame the judge matches — a deterministic way to cancel a long operation
/// mid-flight (the operation's next Task.isCancelled poll throws
/// .operationCancelled).
actor SelfCancellingTransport: FreakTransport {
    private let inner: any FreakTransport
    private let judge: @Sendable (Frame) -> Bool

    init(_ inner: any FreakTransport, judge: @escaping @Sendable (Frame) -> Bool) {
        self.inner = inner
        self.judge = judge
    }

    func send(_ message: Data) async throws {
        try await inner.send(message)
        if let f = Wire.parse(message), judge(f) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        try await inner.receive(timeout: timeout)
    }

    func close() async {
        await inner.close()
    }
}

/// Delivers everything except device 0x18 acks once armed.
actor AckDroppingTransport: FreakTransport {
    private let inner: any FreakTransport
    private var dropping = false

    init(_ inner: any FreakTransport) {
        self.inner = inner
    }

    func dropAcks(_ enabled: Bool) {
        dropping = enabled
    }

    func send(_ message: Data) async throws {
        try await inner.send(message)
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        while true {
            guard let raw = try await inner.receive(timeout: timeout) else { return nil }
            if dropping, let f = Wire.parse(raw), f.isAck {
                continue
            }
            return raw
        }
    }

    func close() async {
        await inner.close()
    }
}

/// After the last chunk goes out, suppress long-0x52 name replies so the
/// final read-back times out.
actor ReplyDroppingTransport: FreakTransport {
    private let inner: any FreakTransport
    private var afterLastChunk = false

    init(_ inner: any FreakTransport) {
        self.inner = inner
    }

    func send(_ message: Data) async throws {
        let f = Wire.parse(message)
        try await inner.send(message)
        if let f, f.cmd == Wire.cmdChunkLast {
            afterLastChunk = true
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        while true {
            guard let raw = try await inner.receive(timeout: timeout) else { return nil }
            if afterLastChunk, let f = Wire.parse(raw), f.cmd == Wire.cmdName {
                continue
            }
            return raw
        }
    }

    func close() async {
        await inner.close()
    }
}

/// Passes everything through, but flips one bit of one write chunk in
/// transit — a wire that lies.
actor ChunkCorruptingTransport: FreakTransport {
    private let inner: any FreakTransport
    private let chunkIndex: Int
    private let byteOffset: Int
    private var seen = 0

    init(_ inner: any FreakTransport, chunkIndex: Int, byteOffset: Int) {
        self.inner = inner
        self.chunkIndex = chunkIndex
        self.byteOffset = byteOffset
    }

    func send(_ message: Data) async throws {
        var raw = message
        if let f = Wire.parse(raw), f.isChunk {
            let hit = seen == chunkIndex
            seen += 1
            if hit {
                var body = [UInt8](raw)
                body[9 + byteOffset] ^= 0x01   // stays 7-bit clean
                raw = Data(body)
            }
        }
        try await inner.send(raw)
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        try await inner.receive(timeout: timeout)
    }

    func close() async {
        await inner.close()
    }
}

/// Replays the device side of a golden-vector transcript: every outbound
/// frame must byte-match the next expected "out" entry (mismatch throws and
/// is remembered), after which any following "in" entries are queued for
/// receive(). Fully consuming the transcript proves the port emitted
/// exactly the reference conversation.
actor TranscriptTransport: FreakTransport {
    struct Entry: Sendable {
        let dir: String
        let frame: Data
    }

    private let entries: [Entry]
    private var pos = 0
    private var inbox: [Data] = []
    private var firstMismatch: String?

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    var mismatch: String? { firstMismatch }

    var fullyConsumed: Bool { pos == entries.count && inbox.isEmpty }

    func send(_ message: Data) async throws {
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

    func receive(timeout: TimeInterval) async throws -> Data? {
        inbox.isEmpty ? nil : inbox.removeFirst()
    }

    func close() async {}

    private func fail(_ message: String) throws {
        if firstMismatch == nil {
            firstMismatch = message
        }
        throw FreakError.transport(detail: message)
    }
}

/// Parse a vector transcript into Sendable entries and wrap them in a
/// TranscriptTransport (the parse happens in the caller's region, so the
/// non-Sendable JSON dictionaries never cross into the actor).
func transcriptTransport(_ transcript: [[String: Any]]) -> TranscriptTransport {
    TranscriptTransport(transcript.map {
        TranscriptTransport.Entry(dir: $0["dir"] as! String,
                                  frame: hexBytes($0["frame"] as! String))
    })
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

// ------------------------------------------------------------- progress

/// An unbounded ProgressReporter plus a collector task, so tests can assert
/// every event (the public reporter's bufferingNewest(1) is a UI policy).
/// (Qualified: Foundation on this SDK also declares a ProgressReporter.)
func collectingReporter() -> (FreakCore.ProgressReporter, Task<[ProgressEvent], Never>) {
    let reporter = FreakCore.ProgressReporter(bufferingPolicy: .unbounded)
    let collector = Task {
        var events: [ProgressEvent] = []
        for await event in reporter.events {
            events.append(event)
        }
        return events
    }
    return (reporter, collector)
}

// --------------------------------------------------------------- misc

/// Drain a SimulatedMicroFreak's outbox (the Python tests' recv_all).
func recvAll(_ sim: SimulatedMicroFreak) async throws -> [Data] {
    var out: [Data] = []
    while let raw = try await sim.receive(timeout: 0.0) {
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
