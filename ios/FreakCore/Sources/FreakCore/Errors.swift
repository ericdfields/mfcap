// Errors.swift — one frozen enum mirroring microfreak.errors. The Python
// class hierarchy's grouping is expressed as a computed `group` so callers
// can still catch coarsely.
//
// Nothing else escapes FreakCore's public API: adapters catch every backend
// and Foundation error and rethrow .transport / .integrity / .libraryCorrupt
// as appropriate. CancellationError from structured concurrency is always
// translated to .operationCancelled before crossing a public boundary.

import Foundation

public enum TimeoutStage: String, Sendable {
    case nameRead = "name_read"
    case dump
    case nameWriteAck = "name_write_ack"
}

public enum WriteStage: String, Sendable {
    case nameWrite = "name_write"
    case open
    case go
    case chunk
    case finalRead = "final_read"
}

public struct VerifyMismatch: Sendable, Equatable {
    public let slot: Int
    public let expectedSha256: String     // "" for a rename
    public let actualSha256: String?      // nil when the name already mismatched (no blob read)
    public let expectedName: String
    public let actualName: String?
    public let firstDifference: Int?      // first differing blob byte index, nil for name-only
    public let expectedLength: Int
    public let actualLength: Int

    public init(slot: Int, expectedSha256: String, actualSha256: String?,
                expectedName: String, actualName: String?,
                firstDifference: Int?, expectedLength: Int, actualLength: Int) {
        self.slot = slot
        self.expectedSha256 = expectedSha256
        self.actualSha256 = actualSha256
        self.expectedName = expectedName
        self.actualName = actualName
        self.firstDifference = firstDifference
        self.expectedLength = expectedLength
        self.actualLength = actualLength
    }
}

public enum FreakError: Error, Equatable, Sendable {

    // -- protocol (Python ProtocolError subtree)
    case slotOutOfRange(slot: Int)
    case blobSize(expected: Int, actual: Int)
    case invalidName(reason: String)
    case protocolViolation(detail: String)          // Python's bare ProtocolError

    // -- transport
    /// Backend failure. `detail` embeds the underlying error's description
    /// (Swift can't carry an Equatable existential; adapters format the
    /// cause into the string).
    case transport(detail: String)
    case transportUnavailable(detail: String)       // backend cannot be used at all
    case deviceNotFound(inputs: [String], outputs: [String])

    // -- transaction
    case deviceTimeout(stage: TimeoutStage, slot: Int?)
    case replyMismatch(requestedSlot: Int, repliedSlot: Int?, attempts: Int)

    // -- writes (Python WriteError subtree)
    case chunkNotAcked(slot: Int, chunkIndex: Int)
    case writeAborted(stage: WriteStage, slot: Int, chunksSent: Int)
    case verifyMismatch(VerifyMismatch)

    // -- cancellation
    case operationCancelled(done: Int, total: Int)

    // -- stored data
    case integrity(path: String, detail: String)
    case entryNotFound(entryID: String)
    case libraryCorrupt(path: String, detail: String)
    case libraryExists(path: String)                // Python: FileExistsError from Library.create
    case libraryNotFound(path: String)              // Python: FileNotFoundError from Library.open

    // -- API misuse (Python raised ValueError)
    case snapshotMissingHashes                      // diff over a hash-less snapshot
    case snapshotMissingBlobs                       // importSnapshot without kept blobs

    // -- composite (Python attached .completed to the exception)
    indirect case restoreFailed(underlying: FreakError, completed: [WriteReport])
}

public extension FreakError {
    enum Group: Sendable {
        case protocolError
        case transport
        case transaction
        case write
        case cancellation
        case storage
        case library
        case usage
        case composite
    }

    var group: Group {
        switch self {
        case .slotOutOfRange, .blobSize, .invalidName, .protocolViolation:
            return .protocolError
        case .transport, .transportUnavailable, .deviceNotFound:
            return .transport
        case .deviceTimeout, .replyMismatch:
            return .transaction
        case .chunkNotAcked, .writeAborted, .verifyMismatch:
            return .write
        case .operationCancelled:
            return .cancellation
        case .integrity:
            return .storage
        case .entryNotFound, .libraryCorrupt, .libraryExists, .libraryNotFound:
            return .library
        case .snapshotMissingHashes, .snapshotMissingBlobs:
            return .usage
        case .restoreFailed:
            return .composite
        }
    }
}

extension FreakError: LocalizedError {
    /// Mirrors the Python messages' information content (exact wording free).
    public var errorDescription: String? {
        switch self {
        case .slotOutOfRange(let slot):
            return "slot \(slot) out of range"
        case .blobSize(let expected, let actual):
            return "blob is \(actual) bytes, expected \(expected)"
        case .invalidName(let reason):
            return "invalid name: \(reason)"
        case .protocolViolation(let detail):
            return detail
        case .transport(let detail):
            return "transport failure: \(detail)"
        case .transportUnavailable(let detail):
            return "transport unavailable: \(detail)"
        case .deviceNotFound(let inputs, let outputs):
            return "No MicroFreak MIDI endpoint found.\n"
                + "  inputs seen:  \(inputs)\n"
                + "  outputs seen: \(outputs)"
        case .deviceTimeout(let stage, let slot):
            let suffix = slot.map { " (slot \($0))" } ?? ""
            return "device timeout during \(stage.rawValue)\(suffix)"
        case .replyMismatch(let requested, let replied, let attempts):
            let who = replied.map(String.init) ?? "another slot"
            return "asked for slot \(requested), device kept answering for "
                + "slot \(who) after \(attempts) attempts"
        case .chunkNotAcked(let slot, let chunkIndex):
            return "no 0x18 ack for chunk \(chunkIndex) writing slot \(slot)"
        case .writeAborted(let stage, let slot, let chunksSent):
            return "write to slot \(slot) aborted at stage '\(stage.rawValue)' "
                + "(\(chunksSent) chunks sent)"
        case .verifyMismatch(let m):
            var detail: [String] = []
            if let actualName = m.actualName, actualName != m.expectedName {
                detail.append("name '\(actualName)' != '\(m.expectedName)'")
            }
            if let actualSha = m.actualSha256, actualSha != m.expectedSha256 {
                detail.append("sha \(actualSha.prefix(12)) != \(m.expectedSha256.prefix(12))")
            }
            let joined = detail.isEmpty ? "mismatch" : detail.joined(separator: "; ")
            return "verify failed for slot \(m.slot): \(joined)"
        case .operationCancelled(let done, let total):
            return "operation cancelled after \(done)/\(total)"
        case .integrity(let path, let detail):
            return "\(path): \(detail)"
        case .entryNotFound(let entryID):
            return "no library entry \(entryID)"
        case .libraryCorrupt(let path, let detail):
            return "\(path): \(detail)"
        case .libraryExists(let path):
            return "\(path): a library already exists here — use Library.open; "
                + "create(at:) will not overwrite an index"
        case .libraryNotFound(let path):
            return "\(path): no library here — create one"
        case .snapshotMissingHashes:
            return "diff requires a snapshot with blob hashes"
        case .snapshotMissingBlobs:
            return "importSnapshot requires a snapshot with blobs "
                + "(snapshot with readBlobs and keepBlobs)"
        case .restoreFailed(let underlying, let completed):
            return "restore stopped after \(completed.count) slots: "
                + (underlying.errorDescription ?? String(describing: underlying))
        }
    }
}
