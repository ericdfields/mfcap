// TransportTests.swift — the push-to-poll FIFO and CoreMIDITransport's
// logic over a faked backend seam. No MIDIClientCreate, no ports, no
// hardware anywhere in this file: the MIDIWireBackend fake stands in for
// every CoreMIDI call.

import Foundation
import FreakCore
import Testing
@testable import FreakMIDI

// ------------------------------------------------------------ fake backend

/// Fake MIDIWireBackend: records sent words, lets tests inject inbound
/// words as if CoreMIDI's receive block had fired.
private final class FakeWireBackend: MIDIWireBackend, @unchecked Sendable {
    // @unchecked Sendable: all state guarded by `lock`.
    private let lock = NSLock()
    private var sentBatches: [[UInt32]] = []
    private var handler: (@Sendable ([UInt32]) -> Void)?
    private var startError: FreakError?
    private var closeCallCount = 0

    var sent: [[UInt32]] {
        lock.lock(); defer { lock.unlock() }
        return sentBatches
    }

    var closeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return closeCallCount
    }

    func failNextStart(with error: FreakError) {
        lock.lock(); startError = error; lock.unlock()
    }

    /// Deliver inbound UMP words as the receive block would.
    func inject(words: [UInt32]) {
        lock.lock(); let h = handler; lock.unlock()
        h?(words)
    }

    // MIDIWireBackend
    func start(receiving handler: @escaping @Sendable ([UInt32]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if let error = startError { throw error }
        self.handler = handler
    }

    func send(words: [UInt32]) throws {
        lock.lock(); defer { lock.unlock() }
        sentBatches.append(words)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeCallCount += 1
        handler = nil
    }
}

private func makeTransport(
    _ backend: FakeWireBackend = FakeWireBackend()) throws -> (CoreMIDITransport, FakeWireBackend) {
    let transport = try CoreMIDITransport(
        backend: backend,
        source: MIDIEndpointInfo(id: 1, name: "Fake MicroFreak", isOffline: false),
        destination: MIDIEndpointInfo(id: 2, name: "Fake MicroFreak", isOffline: false))
    return (transport, backend)
}

// ------------------------------------------------------------------- FIFO

@Suite("SysExFIFO push-to-poll")
struct SysExFIFOTests {

    @Test func zeroOrNegativeTimeoutReturnsImmediatelyWhenEmpty() {
        let fifo = SysExFIFO()
        let t0 = Date()
        #expect(fifo.pop(timeout: 0) == nil)
        #expect(fifo.pop(timeout: -1) == nil)
        #expect(Date().timeIntervalSince(t0) < 0.5)    // did not block
    }

    @Test func zeroTimeoutReturnsQueuedMessage() {
        let fifo = SysExFIFO()
        fifo.push(Data([1]))
        #expect(fifo.pop(timeout: 0) == Data([1]))
    }

    @Test func arrivalOrderPreserved() {
        let fifo = SysExFIFO()
        for i: UInt8 in 0..<5 { fifo.push(Data([i])) }
        for i: UInt8 in 0..<5 { #expect(fifo.pop(timeout: 0) == Data([i])) }
        #expect(fifo.pop(timeout: 0) == nil)
    }

    @Test func popTimesOutAfterRoughlyTheTimeout() {
        let fifo = SysExFIFO()
        let t0 = Date()
        #expect(fifo.pop(timeout: 0.15) == nil)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed >= 0.14, "returned too early: \(elapsed)s")
        #expect(elapsed < 2.0, "blocked far past the deadline: \(elapsed)s")
    }

    @Test func blockedPopWakesOnPush() {
        let fifo = SysExFIFO()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            fifo.push(Data([0x42]))
        }
        let t0 = Date()
        #expect(fifo.pop(timeout: 5.0) == Data([0x42]))
        #expect(Date().timeIntervalSince(t0) < 4.0, "should not have waited out the timeout")
    }

    @Test func closeWakesBlockedPopWithNil() {
        let fifo = SysExFIFO()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            fifo.close()
        }
        let t0 = Date()
        #expect(fifo.pop(timeout: 5.0) == nil)
        #expect(Date().timeIntervalSince(t0) < 4.0, "close should wake the waiter")
    }

    @Test func closedFIFOPopsNilAndDropsPushes() {
        let fifo = SysExFIFO()
        fifo.push(Data([1]))
        fifo.close()
        #expect(fifo.pop(timeout: 0) == nil)
        fifo.push(Data([2]))
        #expect(fifo.pop(timeout: 0) == nil)
    }
}

// -------------------------------------------------- transport over the seam

@Suite("CoreMIDITransport over a fake backend")
struct CoreMIDITransportSeamTests {

    @Test func sendEncodesToUMPWords() throws {
        let (transport, backend) = try makeTransport()
        let frame = FreakProtocol.pullNextRequest(seq: 5)
        try transport.send(frame)
        #expect(backend.sent == [SysEx7.encode(frame)])
    }

    @Test func inboundWordsAssembleIntoCompleteSysEx() throws {
        let (transport, backend) = try makeTransport()
        let reply = try FreakProtocol.readNameRequest(seq: 9, slot: 200)
        backend.inject(words: SysEx7.encode(reply))
        #expect(try transport.receive(timeout: 1.0) == reply)
        #expect(try transport.receive(timeout: 0) == nil)
    }

    @Test func multiPacketMessageSplitAcrossInjectionsAssembles() throws {
        let (transport, backend) = try makeTransport()
        let frame = try FreakProtocol.nameWriteFrame(
            seq: 2, slot: 40, name: "Bass Station",
            meta: Data([8, 0, 0, 0, 0, 40, 0, 3, 0x32]))
        let words = SysEx7.encode(frame)                      // 16 words
        backend.inject(words: Array(words[0..<6]))            // 3 packets
        #expect(try transport.receive(timeout: 0) == nil)     // not complete yet
        backend.inject(words: Array(words[6...]))
        #expect(try transport.receive(timeout: 1.0) == frame)
    }

    @Test func tornInboundStreamDropsPartialKeepsNext() throws {
        let (transport, backend) = try makeTransport()
        let torn = try FreakProtocol.openDumpRequest(seq: 1, slot: 0)
        let good = FreakProtocol.pullNextRequest(seq: 2)
        backend.inject(words: Array(SysEx7.encode(torn)[0..<2]))   // start, never ended
        backend.inject(words: SysEx7.encode(good))                 // tears the partial
        #expect(try transport.receive(timeout: 1.0) == good)
        #expect(try transport.receive(timeout: 0) == nil)
    }

    @Test func nonSysExUMPTrafficIsDroppedAtTheAdapter() throws {
        let (transport, backend) = try makeTransport()
        backend.inject(words: [0x2090_3C40])                  // MIDI 1.0 note-on
        backend.inject(words: [0x10F8_0000])                  // system real-time
        #expect(try transport.receive(timeout: 0) == nil)
    }

    @Test func messagesArriveInOrderAcrossInjections() throws {
        let (transport, backend) = try makeTransport()
        let frames = try (0..<4).map { try FreakProtocol.readNameRequest(seq: UInt8($0 + 1), slot: $0) }
        for frame in frames { backend.inject(words: SysEx7.encode(frame)) }
        for frame in frames { #expect(try transport.receive(timeout: 1.0) == frame) }
    }

    @Test func closeSemantics() throws {
        let (transport, backend) = try makeTransport()
        transport.close()
        // blocked/subsequent receive returns nil
        #expect(try transport.receive(timeout: 0.1) == nil)
        // subsequent send throws .transport("transport closed")
        do {
            try transport.send(FreakProtocol.goFrame())
            Issue.record("send after close should throw")
        } catch let error as FreakError {
            #expect(error == .transport(detail: "transport closed"))
        }
        // close is idempotent and reached the backend exactly once
        transport.close()
        #expect(backend.closeCount == 1)
    }

    @Test func closeWakesAReceiveBlockedOnTheDeadline() throws {
        let (transport, _) = try makeTransport()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            transport.close()
        }
        let t0 = Date()
        #expect(try transport.receive(timeout: 5.0) == nil)
        #expect(Date().timeIntervalSince(t0) < 4.0)
    }

    @Test func backendStartFailurePropagatesFromInit() {
        let backend = FakeWireBackend()
        backend.failNextStart(with: .transport(detail: "MIDIInputPortCreateWithProtocol failed (OSStatus -50)"))
        do {
            _ = try makeTransport(backend)
            Issue.record("init should rethrow the backend failure")
        } catch let error as FreakError {
            #expect(error.isTransportError)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func endpointInfosAreExposed() throws {
        let (transport, _) = try makeTransport()
        #expect(transport.source.id == 1)
        #expect(transport.destination.id == 2)
    }
}
