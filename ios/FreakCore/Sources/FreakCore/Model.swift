// Model.swift — value types (model.py). All structs, all Sendable, all
// Equatable, stored via `let` (frozen-dataclass equivalence).
//
// Long operations poll a CancelToken between slots and between write chunks
// and throw FreakError.cancelled(done:total:). Worst-case cancel latency is
// one dump/ack timeout.

import Foundation

/// One parsed MicroFreak SysEx frame.
public struct Frame: Sendable, Equatable {
    public let raw: Data
    public let seq: UInt8
    public let length: UInt8
    public let cmd: UInt8
    public let data: Data

    public init(raw: Data, seq: UInt8, length: UInt8, cmd: UInt8, data: Data) {
        self.raw = raw
        self.seq = seq
        self.length = length
        self.cmd = cmd
        self.data = data
    }

    public var isChunk: Bool {      // replaces is_chunk(f)
        cmd == FreakProtocol.cmdChunkMore || cmd == FreakProtocol.cmdChunkLast
    }
    public var isLastChunk: Bool {  // replaces is_last_chunk(f)
        cmd == FreakProtocol.cmdChunkLast
    }
    public var isAck: Bool {        // replaces is_ack(f)
        cmd == FreakProtocol.cmdNext
    }
}

/// Decoded long-0x52 payload.
public struct NameInfo: Sendable, Equatable {
    public let slot: Int          // from payload[0..1] — the reply-lag matching key
    public let name: String
    public let meta: Data         // 9 bytes = payload[3..11], verbatim

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
/// header bytes nameWriteFrame recomputes (payload[3] reply flag cleared,
/// payload[8]=pos, payload[9]=0x06 on writes).
///
/// Blob and meta must be 7-bit clean: SysEx payload bytes have bit 7 clear,
/// and the wire encoder masks with & 0x7F — so a byte > 0x7F would be
/// silently rewritten in transit. Rejecting it here keeps a foreign or
/// corrupted .bin from producing a "successful" unverified write of
/// different content.
public struct Preset: Sendable, Equatable, Hashable {
    public let name: String
    public let blob: Data          // exactly 4672 bytes, 7-bit clean
    public let meta: Data          // exactly 9 bytes, 7-bit clean

    public init(name: String, blob: Data, meta: Data) throws {
        // validation order mirrors model.py
        try FreakProtocol.validateName(name)
        guard blob.count == FreakProtocol.blobSize else {
            throw FreakError.blobSize(expected: FreakProtocol.blobSize,
                                      actual: blob.count)
        }
        guard meta.count == FreakProtocol.metaLen else {
            throw FreakError.protocolViolation(
                detail: "meta must be \(FreakProtocol.metaLen) bytes, got \(meta.count)")
        }
        let b = [UInt8](blob)
        if let bad = b.firstIndex(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: String(
                format: "blob byte %d is 0x%02X: SysEx content must be "
                    + "7-bit clean (it would be masked in transit)",
                bad, b[bad]))
        }
        if meta.contains(where: { $0 > 0x7F }) {
            throw FreakError.protocolViolation(detail: "meta contains non-7-bit bytes")
        }
        self.name = name
        self.blob = blob
        self.meta = meta
    }

    public var sha256: String { FreakProtocol.digest(blob) }

    public func renamed(_ name: String) throws -> Preset {
        try Preset(name: name, blob: blob, meta: meta)
    }
}

public struct SlotRecord: Sendable, Equatable {
    public let slot: Int
    public let name: String?       // nil = name read FAILED
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
    public let takenAt: String                 // ISO 8601 local, "yyyy-MM-dd'T'HH:mm:ss"
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

    public var hasHashes: Bool {
        records.allSatisfy { $0.sha256 != nil }
    }
}

public struct WriteReport: Sendable, Equatable {
    public let slot: Int
    public let sha256: String                  // "" for a rename — no blob traffic
    public let name: String
    public let verified: Bool?                 // true = read back & matched; nil = skipped;
                                               // false NEVER occurs — a mismatch throws
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
    public let etaSeconds: Double?             // median-based, phase-0 math

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

public typealias ProgressFn = @Sendable (ProgressEvent) -> Void

/// Cooperative cancellation. One NSLock-guarded Bool — callable from any
/// isolation.
// @unchecked Sendable: sanctioned by §4 — the NSLock provides the
// synchronization the compiler cannot see.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
