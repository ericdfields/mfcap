// CoreMIDITransport.swift — the ONE platform-specific file in FreakCore,
// entirely inside #if canImport(CoreMIDI). It compiles on macOS too
// (CoreMIDI exists there); the guard exists for future non-Apple hosts, and
// tests never instantiate it — SysEx7 and the endpoint-matching helper carry
// the headless-testable logic.
//
// Lifecycle: one MIDIClientRef per transport instance, created in the
// opener, disposed in close(). CoreMIDI is driven through the UMP APIs
// (MIDIInputPortCreateWithProtocol / MIDISendEventList) with MIDI protocol
// 1.0; SysEx rides in 64-bit SysEx7 packets (SysEx7.swift). The receive
// block runs on a CoreMIDI-owned thread; it feeds each SysEx7 packet to the
// per-source assembler and pushes completed F0..F7 messages into the Inbox.
// The transport never parses MicroFreak semantics — that is the session's
// job. Unplug behavior, v1: an unplugged device surfaces as send failures
// and receive timeouts; the app's connect screen re-runs discovery.

#if canImport(CoreMIDI)
import CoreMIDI
import Foundation
import os

public struct MIDIEndpointInfo: Sendable, Equatable {
    public let name: String              // display name (kMIDIPropertyDisplayName)
    public let uniqueID: Int32           // kMIDIPropertyUniqueID — stable reconnect key

    public init(name: String, uniqueID: Int32) {
        self.name = name
        self.uniqueID = uniqueID
    }
}

/// Single-consumer awaitable inbox bridging CoreMIDI's push callback into
/// the poll-model FreakTransport. ALL mutable state — the FIFO, the single
/// parked continuation, and the per-source SysEx7 assembler — lives behind
/// one OSAllocatedUnfairLock, so the class is honestly Sendable.
final class MIDIInbox: Sendable {
    private struct State: Sendable {
        var queue: [Data] = []
        var parked: CheckedContinuation<Data?, Never>? = nil
        var generation = 0                // pairs a parked receiver with its timeout
        var closed = false
        var assembler = SysEx7.Assembler()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Feed one 64-bit SysEx7 packet from the receive block; a completed
    /// message wakes a parked receiver or joins the FIFO.
    func consume(word0: UInt32, word1: UInt32) {
        let handoff: (CheckedContinuation<Data?, Never>, Data)? = lock.withLock { state in
            guard !state.closed else { return nil }
            guard let message = state.assembler.consume(word0: word0, word1: word1) else {
                return nil
            }
            if let parked = state.parked {
                state.parked = nil
                state.generation += 1
                return (parked, message)
            }
            state.queue.append(message)
            return nil
        }
        if let (continuation, message) = handoff {
            continuation.resume(returning: message)
        }
    }

    /// Buffered -> return immediately; timeout <= 0 -> nil immediately;
    /// otherwise park until a message, the timeout, or close() — whichever
    /// side resumes first wins under the lock, the loser is a no-op.
    func pop(timeout: TimeInterval) async -> Data? {
        enum FastPath {
            case message(Data)
            case empty
            case park
        }
        let fast: FastPath = lock.withLock { state in
            if state.closed {
                return .empty
            }
            if !state.queue.isEmpty {
                return .message(state.queue.removeFirst())
            }
            return timeout <= 0 ? .empty : .park
        }
        switch fast {
        case .message(let m):
            return m
        case .empty:
            return nil
        case .park:
            return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                enum ParkOutcome: Sendable {
                    case deliver(Data?)
                    case parked(Int)
                }
                let outcome: ParkOutcome = lock.withLock { state in
                    if state.closed {
                        return .deliver(nil)
                    }
                    if !state.queue.isEmpty {
                        return .deliver(state.queue.removeFirst())
                    }
                    state.generation += 1
                    state.parked = cont
                    return .parked(state.generation)
                }
                switch outcome {
                case .deliver(let message):
                    cont.resume(returning: message)
                case .parked(let generation):
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(timeout))
                        self?.fireTimeout(generation: generation)
                    }
                }
            }
        }
    }

    private func fireTimeout(generation: Int) {
        let resume: CheckedContinuation<Data?, Never>? = lock.withLock { state in
            guard state.generation == generation, let parked = state.parked else {
                return nil
            }
            state.parked = nil
            state.generation += 1
            return parked
        }
        resume?.resume(returning: nil)
    }

    /// Resumes any parked receiver with nil and rejects further pushes.
    func close() {
        let resume: CheckedContinuation<Data?, Never>? = lock.withLock { state in
            state.closed = true
            state.queue = []
            let parked = state.parked
            state.parked = nil
            state.generation += 1
            return parked
        }
        resume?.resume(returning: nil)
    }
}

public final class CoreMIDITransport: FreakTransport, Sendable {
    public static let defaultHints = ["microfreak"]      // case-insensitive substring match

    // All CoreMIDI refs are assigned once during open and stored as lets —
    // that plus the lock-guarded inbox is what makes the class honestly
    // Sendable.
    private let client: MIDIClientRef
    private let inputPort: MIDIPortRef
    private let outputPort: MIDIPortRef
    private let source: MIDIEndpointRef
    private let destination: MIDIEndpointRef
    private let inbox: MIDIInbox
    private let closed = OSAllocatedUnfairLock(initialState: false)

    // ---------------------------------------------------------- discovery

    /// Enumerate current sources and destinations. Never throws; safe on any
    /// thread.
    public static func endpoints() -> (sources: [MIDIEndpointInfo],
                                       destinations: [MIDIEndpointInfo]) {
        var sources: [MIDIEndpointInfo] = []
        for i in 0..<MIDIGetNumberOfSources() {
            if let info = describe(MIDIGetSource(i)) {
                sources.append(info)
            }
        }
        var destinations: [MIDIEndpointInfo] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            if let info = describe(MIDIGetDestination(i)) {
                destinations.append(info)
            }
        }
        return (sources, destinations)
    }

    private static func describe(_ endpoint: MIDIEndpointRef) -> MIDIEndpointInfo? {
        guard endpoint != 0 else { return nil }
        var unmanagedName: Unmanaged<CFString>?
        var name = ""
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName,
                                       &unmanagedName) == noErr,
           let cf = unmanagedName?.takeRetainedValue() {
            name = cf as String
        }
        var uniqueID: Int32 = 0
        _ = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
        return MIDIEndpointInfo(name: name, uniqueID: uniqueID)
    }

    /// Endpoint-name matching, factored for headless testability: the first
    /// entry whose name contains any hint (case-insensitive) and does not
    /// contain `exclude` (skips mfcap's own virtual proxy ports).
    static func match(_ candidates: [MIDIEndpointInfo], hints: [String],
                      exclude: String) -> MIDIEndpointInfo? {
        candidates.first { info in
            let lower = info.name.lowercased()
            if !exclude.isEmpty && lower.contains(exclude.lowercased()) {
                return false
            }
            return hints.contains { lower.contains($0.lowercased()) }
        }
    }

    /// Discover-and-open: first source AND destination whose display name
    /// matches. No match -> .deviceNotFound(inputs:outputs:) listing every
    /// endpoint seen. Backend failure -> .transport.
    public static func open(hints: [String] = defaultHints,
                            exclude: String = "mfcap") throws -> CoreMIDITransport {
        let (sources, destinations) = endpoints()
        guard let source = match(sources, hints: hints, exclude: exclude),
              let destination = match(destinations, hints: hints, exclude: exclude) else {
            throw FreakError.deviceNotFound(inputs: sources.map(\.name),
                                            outputs: destinations.map(\.name))
        }
        return try open(source: source, destination: destination)
    }

    /// Explicit picker by endpoint identity (from endpoints()).
    public static func open(source: MIDIEndpointInfo,
                            destination: MIDIEndpointInfo) throws -> CoreMIDITransport {
        func find(count: Int, get: (Int) -> MIDIEndpointRef,
                  id: Int32) -> MIDIEndpointRef? {
            for i in 0..<count {
                let ref = get(i)
                var uniqueID: Int32 = 0
                if MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID,
                                                &uniqueID) == noErr,
                   uniqueID == id {
                    return ref
                }
            }
            return nil
        }
        guard let sourceRef = find(count: MIDIGetNumberOfSources(),
                                   get: MIDIGetSource, id: source.uniqueID),
              let destinationRef = find(count: MIDIGetNumberOfDestinations(),
                                        get: MIDIGetDestination,
                                        id: destination.uniqueID) else {
            let (sources, destinations) = endpoints()
            throw FreakError.deviceNotFound(inputs: sources.map(\.name),
                                            outputs: destinations.map(\.name))
        }
        return try CoreMIDITransport(sourceRef: sourceRef,
                                     destinationRef: destinationRef)
    }

    // ------------------------------------------------------------ lifecycle

    private init(sourceRef: MIDIEndpointRef, destinationRef: MIDIEndpointRef) throws {
        let inbox = MIDIInbox()
        var client = MIDIClientRef()
        var status = MIDIClientCreateWithBlock("FreakCore" as CFString, &client) { _ in }
        guard status == noErr else {
            throw FreakError.transport(detail: "MIDIClientCreateWithBlock: \(status)")
        }
        var inputPort = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(
            client, "FreakCore.in" as CFString, ._1_0, &inputPort) { eventListPtr, _ in
            // CoreMIDI-owned thread: walk the packets word by word, feed
            // 64-bit SysEx7 packets to the assembler inside the inbox.
            // Non-SysEx7 UMP traffic is ignored.
            for packetPtr in eventListPtr.unsafeSequence() {
                let wordCount = Int(packetPtr.pointee.wordCount)
                let words: [UInt32] = withUnsafeBytes(of: packetPtr.pointee.words) { raw in
                    Array(raw.bindMemory(to: UInt32.self).prefix(wordCount))
                }
                var i = 0
                while i < words.count {
                    let word0 = words[i]
                    let mt = (word0 >> 28) & 0xF
                    if mt == SysEx7.messageType, i + 1 < words.count {
                        inbox.consume(word0: word0, word1: words[i + 1])
                    }
                    i += CoreMIDITransport.umpWordCount(messageType: mt)
                }
            }
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            throw FreakError.transport(detail: "MIDIInputPortCreateWithProtocol: \(status)")
        }
        var outputPort = MIDIPortRef()
        status = MIDIOutputPortCreate(client, "FreakCore.out" as CFString, &outputPort)
        guard status == noErr else {
            MIDIPortDispose(inputPort)
            MIDIClientDispose(client)
            throw FreakError.transport(detail: "MIDIOutputPortCreate: \(status)")
        }
        status = MIDIPortConnectSource(inputPort, sourceRef, nil)
        guard status == noErr else {
            MIDIPortDispose(outputPort)
            MIDIPortDispose(inputPort)
            MIDIClientDispose(client)
            throw FreakError.transport(detail: "MIDIPortConnectSource: \(status)")
        }
        self.client = client
        self.inputPort = inputPort
        self.outputPort = outputPort
        self.source = sourceRef
        self.destination = destinationRef
        self.inbox = inbox
    }

    /// UMP message sizes in 32-bit words, per message type (M2-104-UM).
    static func umpWordCount(messageType: UInt32) -> Int {
        switch messageType {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        case 0x5, 0xD, 0xE, 0xF: return 4
        default: return 1
        }
    }

    // --------------------------------------------------------- FreakTransport

    public func send(_ message: Data) async throws {
        guard !closed.withLock({ $0 }) else {
            throw FreakError.transport(detail: "transport is closed")
        }
        let words = try SysEx7.encode(message)
        // Messages here are <= 45 bytes — one event list always suffices —
        // but iterate defensively in case a longer message ever appears.
        var offset = 0
        while offset < words.count {
            let batch = Array(words[offset..<min(offset + 32, words.count)])
            offset += batch.count
            var eventList = MIDIEventList()
            let packet = MIDIEventListInit(&eventList, ._1_0)
            // MIDIEventListAdd cannot overflow here: each batch is capped at
            // 32 words, well inside one MIDIEventList.
            _ = batch.withUnsafeBufferPointer { buf in
                MIDIEventListAdd(&eventList,
                                 MemoryLayout<MIDIEventList>.size,
                                 packet, 0, buf.count, buf.baseAddress!)
            }
            let status = MIDISendEventList(outputPort, destination, &eventList)
            guard status == noErr else {
                throw FreakError.transport(detail: "MIDISendEventList: \(status)")
            }
        }
    }

    /// One channel message as a single 32-bit MIDI 1.0 Channel Voice UMP.
    public func sendShort(_ message: Data) async throws {
        guard !closed.withLock({ $0 }) else {
            throw FreakError.transport(detail: "transport is closed")
        }
        guard let word = MIDIShort.umpWord(message) else {
            throw FreakError.transport(detail: "not a channel message: \(message.hexString)")
        }
        var words = [word]
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        _ = words.withUnsafeMutableBufferPointer { buf in
            MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                             packet, 0, buf.count, buf.baseAddress!)
        }
        let status = MIDISendEventList(outputPort, destination, &eventList)
        guard status == noErr else {
            throw FreakError.transport(detail: "MIDISendEventList: \(status)")
        }
    }

    public func receive(timeout: TimeInterval) async throws -> Data? {
        guard !closed.withLock({ $0 }) else {
            throw FreakError.transport(detail: "transport is closed")
        }
        return await inbox.pop(timeout: timeout)
    }

    public func close() async {
        let wasClosed = closed.withLock { flag -> Bool in
            let old = flag
            flag = true
            return old
        }
        guard !wasClosed else { return }
        inbox.close()
        MIDIPortDisconnectSource(inputPort, source)
        MIDIPortDispose(inputPort)
        MIDIPortDispose(outputPort)
        MIDIClientDispose(client)
    }
}
#endif
