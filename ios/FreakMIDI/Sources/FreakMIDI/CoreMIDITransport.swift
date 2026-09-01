// CoreMIDITransport.swift — FreakCore's Transport seam over modern CoreMIDI.
//
// Modern UMP API only, both directions (nothing deprecated on iOS 17):
// input via MIDIInputPortCreateWithProtocol(…, ._1_0, …) connected to the
// one selected source (no promiscuous listening); output via
// MIDIOutputPortCreate + MIDISendEventList with SysEx7 UMP packets
// (timestamp 0 = now). The largest MicroFreak frame is 45 bytes (long 0x52),
// so an outbound message always fits one MIDIEventList.
//
// Push-to-poll: CoreMIDI's receive block (a CoreMIDI-owned high-priority
// thread) feeds completed messages into an NSCondition-guarded FIFO;
// receive(timeout:) wait(until:)-loops until a message or the deadline —
// the documented "locked array + semaphore" adapter shape. Order preserved;
// unbounded buffer; never drops. Blocking is fine here by design: callers
// run on the MicroFreakDevice actor's dedicated dispatch queue, never the
// cooperative pool.
//
// Non-SysEx MIDI is dropped at this adapter (§10 deviation 7): rtmidi
// forwarded complete channel messages, which FreakProtocol.parse then
// discarded — observable behavior is identical.
//
// Testability: every CoreMIDI call sits behind the internal MIDIWireBackend
// seam. The transport's logic — encode-on-send, assemble-on-receive, FIFO
// timeout behavior, close semantics — is exercised in unit tests against a
// fake backend, with no MIDI client, port, or hardware involved.

import CoreMIDI
import FreakCore
import Foundation

// MARK: - The internal seam over CoreMIDI

/// Everything CoreMIDITransport asks of CoreMIDI, reduced to word movement.
/// The real implementation is CoreMIDIWireBackend; tests substitute a fake.
protocol MIDIWireBackend: AnyObject, Sendable {
    /// Open the ports and begin delivering inbound UMP words to `handler`
    /// (called on the backend's thread, one MIDIEventPacket's words per call).
    func start(receiving handler: @escaping @Sendable (_ words: [UInt32]) -> Void) throws
    /// Send one encoded SysEx message's UMP words, atomically.
    func send(words: [UInt32]) throws
    /// Disconnect and dispose the ports. Idempotent; never throws.
    func close()
}

// MARK: - Push-to-poll FIFO

/// NSCondition-guarded FIFO of complete SysEx messages: the push side is
/// CoreMIDI's receive thread, the pop side the device actor's queue.
/// push never blocks; pop blocks up to `timeout` (<= 0: return immediately
/// if nothing is queued). close() wakes every waiter; a closed queue pops
/// nil forever.
final class SysExFIFO: @unchecked Sendable {
    // @unchecked Sendable: every member is guarded by `condition`.
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var closed = false

    func push(_ message: Data) {
        condition.lock()
        if !closed {
            queue.append(message)
            condition.signal()
        }
        condition.unlock()
    }

    func pop(timeout: TimeInterval) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if closed { return nil }
        if !queue.isEmpty { return queue.removeFirst() }
        if timeout <= 0 { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while queue.isEmpty && !closed {
            if !condition.wait(until: deadline) { return nil }   // deadline passed
        }
        if closed || queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    func close() {
        condition.lock()
        closed = true
        queue.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Inbound assembly (shared with the receive thread)

/// Owns the SysEx7 assembler and the FIFO; captured by the backend's receive
/// handler so the handler never references the transport (no retain cycle
/// through the port's block).
final class InboundAssembly: @unchecked Sendable {
    // @unchecked Sendable: `assembler` is only touched under `lock`; the
    // FIFO is internally synchronized.
    private let lock = NSLock()
    private var assembler = SysEx7Assembler()
    let fifo = SysExFIFO()

    func consume(words: [UInt32]) {
        lock.lock()
        let messages = assembler.consume(words: words)
        lock.unlock()
        for message in messages {
            fifo.push(message)
        }
    }
}

// MARK: - The transport

public final class CoreMIDITransport: Transport, @unchecked Sendable {
    // @unchecked Sendable: `closed` is guarded by `stateLock`; all inbound
    // state lives in the internally synchronized InboundAssembly/FIFO.
    public let source: MIDIEndpointInfo
    public let destination: MIDIEndpointInfo

    private let backend: any MIDIWireBackend
    private let inbound = InboundAssembly()
    private let stateLock = NSLock()
    private var closed = false

    /// Discovery + open: findMicroFreak over the current endpoint lists;
    /// no match throws .deviceNotFound listing every seen display name
    /// (offline and excluded ones included, so the message shows the whole
    /// picture).
    public static func open(hints: [String] = defaultHints,
                            exclude: String = "mfcap") throws -> CoreMIDITransport {
        let sources = enumerateSources()
        let destinations = enumerateDestinations()
        guard let match = matchMicroFreak(sources: sources.map(\.info),
                                          destinations: destinations.map(\.info),
                                          hints: hints, exclude: exclude),
              let src = sources.first(where: { $0.info.id == match.source.id }),
              let dst = destinations.first(where: { $0.info.id == match.destination.id })
        else {
            throw FreakError.deviceNotFound(inputs: sources.map(\.info.name),
                                            outputs: destinations.map(\.info.name))
        }
        return try open(source: src, destination: dst)
    }

    /// Explicit picker (the open_ports equivalent): .deviceNotFound if either
    /// id no longer resolves via MIDIObjectFindByUniqueID.
    public static func open(sourceID: MIDIUniqueID,
                            destinationID: MIDIUniqueID) throws -> CoreMIDITransport {
        guard let srcRef = resolveEndpoint(id: sourceID, expecting: .source),
              let dstRef = resolveEndpoint(id: destinationID, expecting: .destination)
        else {
            throw FreakError.deviceNotFound(
                inputs: enumerateSources().map(\.info.name),
                outputs: enumerateDestinations().map(\.info.name))
        }
        return try open(source: EndpointHandle(info: endpointInfo(srcRef), ref: srcRef),
                        destination: EndpointHandle(info: endpointInfo(dstRef), ref: dstRef))
    }

    private static func open(source: EndpointHandle,
                             destination: EndpointHandle) throws -> CoreMIDITransport {
        let client = try FreakMIDIClient.shared().ref()
        let backend = CoreMIDIWireBackend(client: client,
                                          sourceRef: source.ref,
                                          destinationRef: destination.ref)
        return try CoreMIDITransport(backend: backend,
                                     source: source.info,
                                     destination: destination.info)
    }

    /// Internal so tests can drive the transport over a fake backend.
    init(backend: any MIDIWireBackend,
         source: MIDIEndpointInfo,
         destination: MIDIEndpointInfo) throws {
        self.backend = backend
        self.source = source
        self.destination = destination
        let inbound = self.inbound
        try backend.start(receiving: { words in
            inbound.consume(words: words)
        })
    }

    // ------------------------------------------------------------ Transport

    public func send(_ message: Data) throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed else {
            throw FreakError.transport(detail: "transport closed")
        }
        try backend.send(words: SysEx7.encode(message))
    }

    public func receive(timeout: TimeInterval) throws -> Data? {
        inbound.fifo.pop(timeout: timeout)
    }

    /// Disconnect the source, dispose both ports (the process-wide client
    /// persists), then wake any blocked receive so it returns nil.
    /// Subsequent send throws .transport("transport closed"). Idempotent.
    public func close() {
        stateLock.lock()
        let alreadyClosed = closed
        closed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }
        backend.close()
        inbound.fifo.close()
    }
}

// MARK: - The real CoreMIDI backend

final class CoreMIDIWireBackend: MIDIWireBackend, @unchecked Sendable {
    // @unchecked Sendable: the port refs and closed flag are guarded by
    // `lock`; everything else is immutable.
    private let client: MIDIClientRef
    private let sourceRef: MIDIEndpointRef
    private let destinationRef: MIDIEndpointRef
    private let lock = NSLock()
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var closed = false

    init(client: MIDIClientRef, sourceRef: MIDIEndpointRef,
         destinationRef: MIDIEndpointRef) {
        self.client = client
        self.sourceRef = sourceRef
        self.destinationRef = destinationRef
    }

    func start(receiving handler: @escaping @Sendable (_ words: [UInt32]) -> Void) throws {
        var inPort: MIDIPortRef = 0
        var status = MIDIInputPortCreateWithProtocol(
            client, "mfcap-in" as CFString, ._1_0, &inPort) { eventList, _ in
                handler(Self.words(from: eventList))
            }
        guard status == noErr else {
            throw FreakError.transport(
                detail: "MIDIInputPortCreateWithProtocol failed (OSStatus \(status))")
        }
        status = MIDIPortConnectSource(inPort, sourceRef, nil)
        guard status == noErr else {
            MIDIPortDispose(inPort)
            throw FreakError.transport(
                detail: "MIDIPortConnectSource failed (OSStatus \(status))")
        }
        var outPort: MIDIPortRef = 0
        status = MIDIOutputPortCreate(client, "mfcap-out" as CFString, &outPort)
        guard status == noErr else {
            MIDIPortDisconnectSource(inPort, sourceRef)
            MIDIPortDispose(inPort)
            throw FreakError.transport(
                detail: "MIDIOutputPortCreate failed (OSStatus \(status))")
        }
        lock.lock()
        inputPort = inPort
        outputPort = outPort
        lock.unlock()
    }

    /// Flatten one MIDIEventList into its UMP words, packet by packet.
    static func words(from eventList: UnsafePointer<MIDIEventList>) -> [UInt32] {
        var words: [UInt32] = []
        for packet in eventList.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let u32 = raw.bindMemory(to: UInt32.self)
                for i in 0 ..< Swift.min(count, u32.count) {
                    words.append(u32[i])
                }
            }
        }
        return words
    }

    func send(words: [UInt32]) throws {
        lock.lock()
        let port = outputPort
        let isClosed = closed
        lock.unlock()
        guard !isClosed, port != 0 else {
            throw FreakError.transport(detail: "transport closed")
        }
        // A stack MIDIEventList holds one packet of up to 64 words; the
        // largest MicroFreak frame (45 bytes -> 16 words) always fits one.
        // The loop is defensive for oversized messages: 64 is a multiple of
        // a SysEx7 message's 2 words, so packets never split a UMP message.
        var remaining = words[...]
        repeat {
            let batch = Array(remaining.prefix(64))
            remaining = remaining.dropFirst(batch.count)
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            let added: UnsafeMutablePointer<MIDIEventPacket>? =
                batch.withUnsafeBufferPointer { buffer in
                    MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size,
                                     packet, 0, buffer.count, buffer.baseAddress!)
                }
            guard added != nil else {
                throw FreakError.transport(detail: "MIDIEventListAdd failed: list full")
            }
            let status = MIDISendEventList(port, destinationRef, &list)
            guard status == noErr else {
                throw FreakError.transport(
                    detail: "MIDISendEventList failed (OSStatus \(status))")
            }
        } while !remaining.isEmpty
    }

    func close() {
        lock.lock()
        let inPort = inputPort
        let outPort = outputPort
        let alreadyClosed = closed
        closed = true
        inputPort = 0
        outputPort = 0
        lock.unlock()
        guard !alreadyClosed else { return }
        if inPort != 0 {
            MIDIPortDisconnectSource(inPort, sourceRef)
            MIDIPortDispose(inPort)
        }
        if outPort != 0 {
            MIDIPortDispose(outPort)
        }
    }
}
