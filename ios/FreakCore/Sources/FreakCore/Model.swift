// Model.swift — value types mirroring the Python frozen dataclasses, plus
// the progress/cancellation idioms of the port:
//
// - Cancellation is Task cancellation. There is no CancelToken. Long
//   operations poll Task.isCancelled between slots and before each write
//   chunk and throw FreakError.operationCancelled(done:total:).
// - Progress is an AsyncStream delivered through ProgressReporter.

import Foundation

/// Decoded long-0x52 payload.
public struct NameInfo: Sendable, Equatable {
    public let slot: Int          // from payload[0..1] — the reply-lag matching key
    public let name: String
    public let meta: Data         // 9 bytes = payload[3..11], verbatim reply form

    public init(slot: Int, name: String, meta: Data) {
        self.slot = slot
        self.name = name
        self.meta = meta
    }
}

/// One preset: name + 4672-byte blob + the 9 opaque meta bytes.
///
/// meta has no default — every Preset traces to a real read (device, backup,
/// or library). It is round-tripped verbatim except the direction-dependent
/// header bytes Wire.nameWriteFrame recomputes (payload[3] reply flag
/// cleared, payload[8]=pos, payload[9]=0x06 on writes).
///
/// Blob and meta must be 7-bit clean: SysEx payload bytes have bit 7 clear,
/// and the wire encoder masks with & 0x7F — so a byte > 0x7F would be
/// silently rewritten in transit. Rejecting it here keeps a foreign or
/// corrupted .bin from producing a "successful" unverified write of
/// different content.
public struct Preset: Sendable, Equatable {
    public let name: String
    public let blob: Data          // exactly 4672 bytes, 7-bit clean
    public let meta: Data          // exactly 9 bytes, 7-bit clean, reply-form as read
    public let sha256: String      // computed once at init from blob

    /// Validates all three fields. Throws .invalidName / .blobSize /
    /// .protocolViolation.
    public init(name: String, blob: Data, meta: Data) throws {
        try Wire.validateName(name)
        guard blob.count == Wire.blobSize else {
            throw FreakError.blobSize(expected: Wire.blobSize, actual: blob.count)
        }
        guard meta.count == Wire.metaLength else {
            throw FreakError.protocolViolation(
                detail: "meta must be \(Wire.metaLength) bytes, got \(meta.count)")
        }
        let blobBytes = [UInt8](blob)
        if let bad = blobBytes.firstIndex(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: String(
                format: "blob byte %d is 0x%02X: SysEx content must be 7-bit clean "
                    + "(it would be masked in transit)",
                bad, blobBytes[bad]))
        }
        if meta.contains(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: "meta contains non-7-bit bytes")
        }
        self.name = name
        self.blob = blob
        self.meta = meta
        self.sha256 = Wire.digest(blob)
    }

    /// Copy with a new (validated) name. Same blob, same meta, same sha256.
    public func renamed(_ name: String) throws -> Preset {
        try Preset(name: name, blob: blob, meta: meta)
    }
}

public struct SlotRecord: Sendable, Equatable {
    public let slot: Int
    public let name: String?       // nil = the name read FAILED (not blank)
    public let sha256: String?     // nil = blob not read (names-only snapshot)
    public let meta: Data?         // nil only when the name read failed
    public let blob: Data?         // nil unless the snapshot kept blobs

    public init(slot: Int, name: String?, sha256: String?, meta: Data?, blob: Data?) {
        self.slot = slot
        self.name = name
        self.sha256 = sha256
        self.meta = meta
        self.blob = blob
    }
}

public struct TimingReport: Sendable, Equatable {
    public let totalSeconds: Double
    public let perSlotSeconds: Double
    public let nameMsMedian: Double?
    public let dumpMsMedian: Double?

    public init(totalSeconds: Double, perSlotSeconds: Double,
                nameMsMedian: Double?, dumpMsMedian: Double?) {
        self.totalSeconds = totalSeconds
        self.perSlotSeconds = perSlotSeconds
        self.nameMsMedian = nameMsMedian
        self.dumpMsMedian = dumpMsMedian
    }
}

public struct DeviceSnapshot: Sendable, Equatable {
    public let takenAt: String                 // "yyyy-MM-dd'T'HH:mm:ss", local time
    public let records: [SlotRecord]           // ascending slot order, requested slots only
    public let timing: TimingReport

    public init(takenAt: String, records: [SlotRecord], timing: TimingReport) {
        self.takenAt = takenAt
        self.records = records
        self.timing = timing
    }

    public func record(slot: Int) -> SlotRecord? {
        records.first { $0.slot == slot }
    }

    /// True when every record carries a sha256.
    public var hasHashes: Bool {
        records.allSatisfy { $0.sha256 != nil }
    }
}

public struct WriteReport: Sendable, Equatable {
    public let slot: Int
    public let sha256: String        // of the blob sent; "" for a rename (no blob traffic)
    public let name: String
    public let verified: Bool?       // true = read back & matched; nil = verify skipped;
                                     // false NEVER occurs — a mismatch throws instead
    public let durationSeconds: Double

    public init(slot: Int, sha256: String, name: String, verified: Bool?,
                durationSeconds: Double) {
        self.slot = slot
        self.sha256 = sha256
        self.name = name
        self.verified = verified
        self.durationSeconds = durationSeconds
    }
}

public struct ProgressEvent: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let slot: Int
    public let name: String
    public let elapsedSeconds: Double
    public let etaSeconds: Double?   // median-based, same math as mfcap midi.backup

    public init(done: Int, total: Int, slot: Int, name: String,
                elapsedSeconds: Double, etaSeconds: Double?) {
        self.done = done
        self.total = total
        self.slot = slot
        self.name = name
        self.elapsedSeconds = elapsedSeconds
        self.etaSeconds = etaSeconds
    }
}

/// Create one, hand it to a long operation, iterate `events` from the UI.
/// Single-consumer. The operation calls finish() on every exit path (defer),
/// so a UI `for await` loop always terminates.
public final class ProgressReporter: Sendable {
    public let events: AsyncStream<ProgressEvent>
    private let continuation: AsyncStream<ProgressEvent>.Continuation

    /// bufferingNewest(1): the UI only ever wants the latest state; a slow
    /// consumer never backs up a 211-second backup.
    public convenience init() {
        self.init(bufferingPolicy: .bufferingNewest(1))
    }

    /// Test hook: an unbounded reporter observes every event.
    init(bufferingPolicy: AsyncStream<ProgressEvent>.Continuation.BufferingPolicy) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ProgressEvent.self, bufferingPolicy: bufferingPolicy)
        self.events = stream
        self.continuation = continuation
    }

    /// Called by FreakCore operations.
    public func report(_ event: ProgressEvent) {
        continuation.yield(event)
    }

    public func finish() {
        continuation.finish()
    }
}
