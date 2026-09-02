All context is read — core-api.md, write-protocol.md, and all nine Python reference modules plus both transports. Here is the complete specification.

---

# Swift Architecture Specification — MicroFreak Librarian iPad Port

**Version 1.0 — 2026-09-01.** Implements `docs/core-api.md` (v0.1.0); wire ground truth remains `docs/write-protocol.md`. The Python package `microfreak` is the reference implementation; this port is a behavioral transliteration, not a redesign. Every deviation from the Python is listed in §10 — anything not listed there is a bug.

---

## 1. Ground rules

- **Three deliverables under `/Users/ericbrookfield/Development/mfcap/ios/`:** `FreakCore` (SwiftPM package, platform-agnostic core), `FreakMIDI` (SwiftPM package, CoreMIDI adapter), `App` (XcodeGen SwiftUI iPad app, product name "MicroFreak Librarian").
- **FreakCore imports only `Foundation` and `CryptoKit`** (SHA-256). No CoreMIDI, UIKit, SwiftUI, Combine, or third-party dependencies. `swift test` runs on macOS 14+.
- **Swift 6 language mode, strict concurrency, everywhere** (`swiftLanguageModes: [.v6]` in both manifests; `SWIFT_VERSION 6.0` in the app).
- Byte width conventions: wire bytes and single-byte fields are `UInt8`; slots, counts, and indexes are `Int`; byte buffers (frames, blobs, meta) are `Data`; timeouts and durations are `TimeInterval` (Double, seconds).
- Protocol quirks that are law (restated so no implementer needs the Python open): reply-lag defense via embedded bank/pos matching in one chokepoint; device 0x18 acks after EVERY write frame (long 0x52, write-open, go, each chunk); chunk seqs `(i+1) % 128` after the seq-0 go frame; outbound long-0x52 `payload[9] = 0x06`; addresses only in 0x19/0x52 frames; 4672-byte blobs = 146×32 chunks; **no checksum exists, nothing computes one, ever**; writes verified by default; expendability = sha duplicated ≥ 3 or blank successfully-read name, never the string "Init".

---

## 2. Repository layout

```
ios/
  FreakCore/
    Package.swift
    Sources/FreakCore/
      FreakProtocol.swift        # constants + pure codec (protocol.py)
      Model.swift                # Preset, SlotRecord, DeviceSnapshot, TimingReport,
                                 # WriteReport, ProgressEvent, CancelToken, NameInfo, Frame
      Errors.swift               # FreakError + payload structs/enums (errors.py)
      Transport.swift            # the Transport protocol (transport.py)
      Session.swift              # FreakSession (session.py)
      Device.swift               # MicroFreakDevice actor (device.py)
      Backup.swift               # BackupSet + atomic write (backup.py)
      Library.swift              # Library, LibraryEntry (library.py)
      Sync.swift                 # diff, SyncDiff, SlotDiff, SlotStatus (sync.py)
      Analysis.swift             # shaCensus, findExpendable, pickScratchSlot (analysis.py)
      SimulatedMicroFreak.swift  # transports/simulated.py — SHIPS IN THE LIBRARY TARGET
                                 # (demo mode links it; it is not test-only)
      Support.swift              # FreakClock, medians, ISO timestamps, hex helpers,
                                 # withCancellation
    Tests/FreakCoreTests/
      VectorTests.swift          # golden-vector runner (§8)
      ProtocolTests.swift  SessionTests.swift  WriteSequenceTests.swift
      DeviceTests.swift  BackupRestoreTests.swift  LibraryTests.swift
      SyncTests.swift  AnalysisTests.swift  SimulatedFidelityTests.swift
      ConcurrencyTests.swift
      Fixtures/vectors/*.json    # golden vectors, §8
  FreakMIDI/
    Package.swift
    Sources/FreakMIDI/
      CoreMIDITransport.swift    # Transport over CoreMIDI
      SysEx7.swift               # UMP SysEx7 encode/decode + inbound assembler (pure)
      MIDIEndpoints.swift        # discovery: listEndpoints, findMicroFreak
      FreakMIDIClient.swift      # process-wide MIDIClientRef + notify fan-out
      MIDISetupMonitor.swift     # AsyncStream of setup-changed events
      OpenDevice.swift           # openMicroFreak() — the open_device() equivalent
    Tests/FreakMIDITests/
      SysEx7Tests.swift          # pure codec + reassembly tears; no hardware
  App/
    project.yml                  # XcodeGen (§7.3)
    Sources/ ...                 # §7.1
    Tests/ ...
```

**FreakCore/Package.swift** (exact):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreakCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FreakCore", targets: ["FreakCore"])],
    targets: [
        .target(name: "FreakCore"),
        .testTarget(
            name: "FreakCoreTests",
            dependencies: ["FreakCore"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6])
```

**FreakMIDI/Package.swift**: identical shape; platforms `[.iOS(.v17), .macOS(.v14)]` (macOS lets the SysEx7 tests run in CI), one dependency `.package(path: "../FreakCore")`, target dependency `"FreakCore"`.

---

## 3. FreakCore — module-by-module

### 3.1 `FreakProtocol.swift` — constants and pure codec

A case-less enum namespace (Python keyword `protocol` is a Swift keyword too; `FreakProtocol` is the namespace everywhere).

```swift
public enum FreakProtocol {
    // constants — values identical to protocol.py
    public static let prefix = Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01])
    public static let cmdOpen: UInt8 = 0x19
    public static let cmdNext: UInt8 = 0x18
    public static let cmdChunkMore: UInt8 = 0x16
    public static let cmdChunkLast: UInt8 = 0x17
    public static let cmdGo: UInt8 = 0x15
    public static let cmdName: UInt8 = 0x52
    public static let slots = 512
    public static let slotsPerBank = 128
    public static let highBankBoundary = 384
    public static let writePayload9: UInt8 = 0x06
    public static let replyMetaFlag: UInt8 = 0x10
    public static let blobSize = 4672
    public static let chunkSize = 32
    public static let chunkCount = 146
    public static let namePayloadLen = 35
    public static let nameOffset = 12
    public static let nameLen = 23
    public static let metaLen = 9
    public static let duplicateThreshold = 3
    public static let noChecksum = true      // documented fact; nothing computes one, ever

    // addressing
    public static func addr(_ slot: Int) throws -> (bank: UInt8, pos: UInt8)   // FreakError.slotOutOfRange
    public static func slot(bank: Int, pos: Int) throws -> Int                 // inverse; same error

    // frame envelope: F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7
    public static func frame(seq: UInt8, length: UInt8, cmd: UInt8,
                             data: Data = Data()) -> Data     // masks every body byte & 0x7F

    // request builders — seq always explicit; this namespace counts nothing
    public static func readNameRequest(seq: UInt8, slot: Int) throws -> Data     // len 0x03, [bank,pos,0x00]
    public static func openDumpRequest(seq: UInt8, slot: Int) throws -> Data     // len 0x01, [bank,pos,0x01]
    public static func pullNextRequest(seq: UInt8) -> Data                       // len 0x01, [0x00]
    public static func nameWriteFrame(seq: UInt8, slot: Int,
                                      name: String, meta: Data) throws -> Data   // len 0x23; see below
    public static func openWriteFrame(seq: UInt8, slot: Int) throws -> Data      // len 0x03, [bank,pos,0x01]
    public static func goFrame() -> Data                                         // seq 0, len 0, empty
    public static func chunkFrames(blob: Data) throws -> [Data]                  // 145×0x16 + 1×0x17

    // parsers / helpers
    public static func parse(_ raw: Data) -> Frame?              // nil for non-MicroFreak traffic
    public static func decodeNameReply(_ frame: Frame) throws -> NameInfo
    public static func assembleBlob(_ chunks: [Frame]) throws -> Data   // FreakError.blobSize if != 4672
    public static func digest(_ blob: Data) -> String            // CryptoKit SHA-256, lowercase hex
    @discardableResult
    public static func validateName(_ name: String) throws -> String
}

public struct Frame: Sendable, Equatable {
    public let raw: Data
    public let seq: UInt8
    public let length: UInt8
    public let cmd: UInt8
    public let data: Data
    public var isChunk: Bool      // cmd ∈ {0x16, 0x17}   — replaces is_chunk(f)
    public var isLastChunk: Bool  // cmd == 0x17          — replaces is_last_chunk(f)
    public var isAck: Bool        // cmd == 0x18          — replaces is_ack(f)
}

public struct NameInfo: Sendable, Equatable {
    public let slot: Int          // from payload[0..1] — the reply-lag matching key
    public let name: String
    public let meta: Data         // 9 bytes = payload[3..11], verbatim
}
```

Behavioral requirements, verbatim from `protocol.py` (all asserted by golden vectors, §8):

- `nameWriteFrame` is **the single composer of address-derived header bytes**. Outbound payload: `[0]=bank, [1]=pos, [2]=0x00, [3]=meta[0] & ~0x10, [4..7]=meta[1..4] verbatim, [8]=pos (recomputed; meta[5] ignored), [9]=0x06 constant (meta[6] ignored), [10]=meta[7], [11]=meta[8], [12..34]=name ASCII NUL-padded to 23`. Throws `.invalidName` (bad name), `.protocolViolation` (meta not 9 bytes, or meta byte > 0x7F).
- `chunkFrames`: throws `.blobSize` on length ≠ 4672 and `.protocolViolation` naming the first byte index if any blob byte > 0x7F (frame() masks to 7 bits — letting it through would silently alter wire content). Chunk `i` carries seq `(i+1) % 128`, wrapping **through 0**; this stream is separate from the session's addressed counter.
- The `<len>` literals: name read 0x03, dump open 0x01 (the phase-0 value proven by full 512-slot backups), pull-next 0x01, chunks 0x20, long 0x52 0x23, short 0x52 0x03, go 0x00.
- `parse`: nil if length < 10, first byte ≠ 0xF0, last ≠ 0xF7, or the first 6 bytes ≠ `prefix` (full 6-byte match, including the trailing 0x01).
- `decodeNameReply`: throws `.protocolViolation` unless cmd == 0x52 and payload is exactly 35 bytes; slot from `slot(bank:pos:)` (out-of-range embedded address → throws, caller treats as malformed). Name decode: `payload[12...]` split at first NUL, filtered to `0x20..<0x7F`, then whitespace-trimmed — exactly `_decode_name`.
- `validateName`: ≤ 23 chars, every scalar in `0x20..<0x7F`, and `name == name.trimmed` (leading/trailing whitespace can never round-trip because replies decode stripped). Throws `.invalidName(detail:)` with messages mirroring the Python.
- **Address invariant (structural):** no chunk builder or parser accepts or returns a slot. Keep it inexpressible.

### 3.2 `Model.swift` — value types

All `struct`, all `Sendable`, all `Equatable`, stored via `let` (frozen-dataclass equivalence).

```swift
public struct Preset: Sendable, Equatable, Hashable {
    public let name: String
    public let blob: Data          // exactly 4672 bytes, 7-bit clean
    public let meta: Data          // exactly 9 bytes, 7-bit clean; NO default — every
                                   // Preset traces to a real read (device, backup, library)
    public init(name: String, blob: Data, meta: Data) throws
    // validation order mirrors model.py: validateName, blob size (.blobSize),
    // meta length (.protocolViolation), blob 7-bit (.protocolViolation naming
    // the first bad index), meta 7-bit (.protocolViolation)
    public var sha256: String      // FreakProtocol.digest(blob), computed
    public func renamed(_ name: String) throws -> Preset
}

public struct SlotRecord: Sendable, Equatable {
    public let slot: Int
    public let name: String?       // nil = name read FAILED
    public let sha256: String?     // nil = blob not read (names-only snapshot)
    public let meta: Data?         // nil only when the name read failed
    public let blob: Data?         // nil unless the snapshot kept blobs
    public init(slot: Int, name: String?, sha256: String?, meta: Data?, blob: Data?)
}

public struct TimingReport: Sendable, Equatable {
    public let totalSeconds: Double
    public let perSlotSeconds: Double
    public let nameMsMedian: Double?
    public let dumpMsMedian: Double?
}

public struct DeviceSnapshot: Sendable, Equatable {
    public let takenAt: String                 // ISO 8601 local, "yyyy-MM-dd'T'HH:mm:ss"
    public let records: [SlotRecord]           // ascending slot order, requested slots only
    public let timing: TimingReport
    public func record(slot: Int) -> SlotRecord?
    public var hasHashes: Bool                 // all records carry sha256
}

public struct WriteReport: Sendable, Equatable {
    public let slot: Int
    public let sha256: String                  // "" for a rename — no blob traffic
    public let name: String
    public let verified: Bool?                 // true = read back & matched; nil = skipped;
                                               // false NEVER occurs — a mismatch throws
    public let durationSeconds: Double
}

public struct ProgressEvent: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let slot: Int
    public let name: String
    public let elapsedSeconds: Double
    public let etaSeconds: Double?             // median-based, phase-0 math
}

public typealias ProgressFn = @Sendable (ProgressEvent) -> Void

public final class CancelToken: @unchecked Sendable {   // NSLock-guarded Bool
    public init()
    public func cancel()                       // callable from any isolation
    public var isCancelled: Bool { get }
}
```

`Support.swift` adds the structured-concurrency bridge (additive; the token remains the core primitive):

```swift
public func withCancellation<T: Sendable>(
    _ body: @Sendable (CancelToken) async throws -> T) async throws -> T
// wraps body in withTaskCancellationHandler; the handler calls token.cancel(),
// so `Task.cancel()` on the enclosing task cancels the device operation cooperatively
```

plus internal helpers: `FreakClock.monotonic: ClockFn` (`DispatchTime.now().uptimeNanoseconds / 1e9`), `FreakClock.threadSleep: SleepFn` (`Thread.sleep(forTimeInterval:)`), `isoNow()`, `median(_:)` (Python parity: `sorted[count/2]`, rounded to 1 decimal), `roundTo(_:places:)`, `Data(hex:)` / `Data.hexString`.

```swift
public typealias ClockFn = @Sendable () -> Double     // monotonic seconds
public typealias SleepFn = @Sendable (Double) -> Void
```

### 3.3 `Errors.swift`

One enum replaces the Python class hierarchy; grouping predicates preserve the hierarchy's catch ergonomics. All payloads Sendable. `CustomStringConvertible` messages mirror the Python strings.

```swift
public enum TimeoutStage: String, Sendable { case nameRead = "name_read", dump,
                                             nameWriteAck = "name_write_ack" }
public enum WriteStage: String, Sendable { case nameWrite = "name_write", open, go,
                                           chunk, finalRead = "final_read" }

public struct VerifyMismatch: Sendable, Equatable {
    public let slot: Int
    public let expectedSha256: String          // "" for a rename verify
    public let actualSha256: String?
    public let expectedName: String
    public let actualName: String?
    public let firstDifference: Int?
    public let expectedLen: Int
    public let actualLen: Int
}

public enum FreakError: Error, Sendable, CustomStringConvertible {
    // ProtocolError family
    case protocolViolation(detail: String)
    case slotOutOfRange(slot: Int)
    case blobSize(expected: Int, actual: Int)
    case invalidName(detail: String)
    // TransportError family — adapters wrap EVERY backend failure here,
    // with the backend's own description flattened into `detail`
    case transport(detail: String)
    case transportUnavailable(detail: String)          // parity case; see §10
    case deviceNotFound(inputs: [String], outputs: [String])
    // transaction
    case deviceTimeout(stage: TimeoutStage, slot: Int?)
    case replyMismatch(requestedSlot: Int, repliedSlot: Int?, attempts: Int)
    // WriteError family
    case chunkNotAcked(slot: Int, chunkIndex: Int)
    case writeAborted(stage: WriteStage, slot: Int, chunksSent: Int, underlying: String?)
    case verifyMismatch(VerifyMismatch)
    // cancellation
    case cancelled(done: Int, total: Int)
    // restore's ".completed" attachment (Python sets e.completed dynamically):
    indirect case restoreStopped(completed: [WriteReport], underlying: FreakError)
    // stored data
    case integrity(path: String, detail: String)
    // LibraryError family
    case entryNotFound(entryID: String)
    case libraryCorrupt(path: String, detail: String)
    case libraryExists(path: String)                   // Python FileExistsError
    case libraryNotFound(path: String)                 // Python FileNotFoundError
    // precondition failures (Python ValueError)
    case snapshotMissingHashes                         // diff on hash-less snapshot
    case snapshotMissingBlobs                          // importSnapshot without kept blobs

    // hierarchy predicates (Python isinstance equivalents)
    public var isProtocolError: Bool   // protocolViolation, slotOutOfRange, blobSize, invalidName
    public var isTransportError: Bool  // transport, transportUnavailable, deviceNotFound
    public var isWriteError: Bool      // chunkNotAcked, writeAborted, verifyMismatch
    public var isLibraryError: Bool    // entryNotFound, libraryCorrupt, libraryExists, libraryNotFound
}
```

Mapping table (implementers: check this off):

| Python | Swift |
|---|---|
| `MicroFreakError` | `FreakError` (any case) |
| `ProtocolError` | `.protocolViolation` / `isProtocolError` |
| `SlotOutOfRangeError(.slot)` | `.slotOutOfRange(slot:)` |
| `BlobSizeError(.expected,.actual)` | `.blobSize(expected:actual:)` |
| `InvalidNameError` | `.invalidName(detail:)` |
| `TransportError` (chained) | `.transport(detail:)` — chain flattened into detail |
| `TransportUnavailableError` | `.transportUnavailable(detail:)` |
| `DeviceNotFoundError(.inputs,.outputs)` | `.deviceNotFound(inputs:outputs:)` |
| `DeviceTimeoutError(.stage,.slot)` | `.deviceTimeout(stage:slot:)` |
| `ReplyMismatchError` | `.replyMismatch(requestedSlot:repliedSlot:attempts:)` |
| `ChunkNotAckedError(.slot,.chunk_index)` | `.chunkNotAcked(slot:chunkIndex:)` |
| `WriteAbortedError(.stage,.slot,.chunks_sent)` | `.writeAborted(stage:slot:chunksSent:underlying:)` |
| `VerifyMismatchError(8 fields)` | `.verifyMismatch(VerifyMismatch)` |
| `OperationCancelledError(.done,.total)` | `.cancelled(done:total:)` |
| `…` + `.completed` on restore | `.restoreStopped(completed:underlying:)` |
| `IntegrityError(.path,.detail)` | `.integrity(path:detail:)` |
| `EntryNotFoundError(.entry_id)` | `.entryNotFound(entryID:)` |
| `LibraryCorruptError(.path,.detail)` | `.libraryCorrupt(path:detail:)` |
| `FileExistsError` / `FileNotFoundError` (Library) | `.libraryExists(path:)` / `.libraryNotFound(path:)` |
| `ValueError` (sync / import preconditions) | `.snapshotMissingHashes` / `.snapshotMissingBlobs` |

### 3.4 `Transport.swift` — the seam

```swift
public protocol Transport: AnyObject, Sendable {
    /// Send one complete SysEx message F0..F7, atomically.
    func send(_ message: Data) throws
    /// Next complete inbound SysEx message, or nil on timeout.
    /// timeout <= 0 means "return immediately if nothing is queued".
    /// Blocks the calling thread up to `timeout` — callers run on the
    /// device actor's dedicated dispatch queue, never the cooperative pool.
    func receive(timeout: TimeInterval) throws -> Data?
    /// Release the backend; further calls may throw FreakError.transport.
    func close()
}
```

Contract (identical to the Python seam): poll model, deliberately — the core spawns no threads; push-style backends buffer into an internal locked queue inside the adapter. Arrival order preserved; buffer, never drop. The transport's only jobs are byte movement and message-boundary reassembly (complete F0..F7 before delivery). No parsing, filtering, matching, retries, or threading above the seam. Discovery is a per-backend factory concern, not part of the protocol. Adapters catch every backend error and throw `.transport`/`.deviceNotFound` with the backend description in `detail`. Implementations are internally synchronized and declared `@unchecked Sendable` with a one-line justification comment at the declaration.

### 3.5 `Session.swift` — `FreakSession`

```swift
public struct SessionConfig: Sendable {
    public var nameTimeout: TimeInterval = 1.0
    public var dumpTimeout: TimeInterval = 1.5
    public var ackTimeout: TimeInterval = 1.0
    public var nameRetries: Int = 3
    public init() {}
}

public final class FreakSession {          // deliberately NOT Sendable — see below
    public init(transport: any Transport,
                config: SessionConfig = .init(),
                clock: @escaping ClockFn = FreakClock.monotonic,
                sleep: @escaping SleepFn = FreakClock.threadSleep)
    public func readName(slot: Int) throws -> NameInfo
    public func readBlob(slot: Int) throws -> Data
    public func writePreset(slot: Int, _ preset: Preset,
                            cancel: CancelToken? = nil) throws -> NameInfo
    public func writeName(slot: Int, name: String, meta: Data) throws -> NameInfo
    public func close()
    static let pollSleep: TimeInterval = 0.002   // _POLL_SLEEP
}
```

Invariants (the core's spine — transliterate `session.py` line for line):

- **Serialization by confinement, not lock.** Python's `threading.Lock` is replaced by Swift 6 type-level confinement: `FreakSession` is non-Sendable and lives inside the `MicroFreakDevice` actor, so the compiler makes concurrent entry impossible. One `FreakSession` per transport.
- **Addressed seq counter** owned here: `seq = seq % 127 + 1` → 1..127, wrapping, never 0. Seq 0 appears only in the go frame; the chunk stream `(i+1) % 128` is owned by `chunkFrames`.
- **`transactAddressed(request:slot:)` (private) is the ONLY function in the port allowed to inspect a 0x52 reply.** `readName`, `writeName`'s read-back, and `writePreset` frames 1 and 7 all pass through it. Procedure, exactly: drain stale inbound; up to `nameRetries` attempts of {send the *same* request bytes; wait up to `nameTimeout` scanning frames — non-0x52 or wrong-length ignored, malformed (decode throws) ignored; embedded slot == requested → return; different slot → record as stale, break to immediate resend; silence → resend}. After retries: any reply seen → `.replyMismatch(requestedSlot:repliedSlot:attempts: nameRetries)`; total silence → `.deviceTimeout(stage: .nameRead, slot:)`.
- **`writePreset`** — the gate-verified 7-frame sequence: `chunkFrames` first (validates blob up front); frame 1 name-read via chokepoint, result discarded (MCC fidelity); frame 2 long 0x52 then **await ack**; frame 3 short 0x52 open, await ack; frame 4 go, await ack; frames 5–6 the 146 chunks — poll `cancel` before each chunk (`.cancelled(done: i, total: 146)`; a mid-write cancel tears the slot, recovery is "write again"), send, await per-chunk ack within `ackTimeout` or `.chunkNotAcked(slot:chunkIndex: i)`. The three control-frame acks are consumed before the chunk loop so ack N is chunk N's ack — lockstep flow control. Frame 7 read-back via chokepoint; its failures wrap as `.writeAborted(stage: .finalRead, …)`. Transport/protocol errors at any stage wrap as `.writeAborted(stage:slot:chunksSent:underlying:)`; `chunkNotAcked`/`cancelled`/`writeAborted` pass through unwrapped. Returns frame 7's `NameInfo` — comparison is the caller's job.
- **`writeName`** — rename, exactly what MCC sends: long 0x52, await ack (missing → `.deviceTimeout(stage: .nameWriteAck, slot:)`), then refresh read via the chokepoint. No blob traffic.
- **`readBlob`** — drain; send dump-open; strict lockstep: first sweep already-delivered chunks with `receive(timeout: 0)` (bounded by `chunkCount` so a runaway device streaming 0x16 forever raises `.protocolViolation("… chunks without a 0x17 terminator")`), then pull-next / await one chunk within `dumpTimeout` (`.deviceTimeout(stage: .dump, slot:)`), non-chunk frames during a dump discarded as stale, until 0x17; `assembleBlob` enforces 4672.
- `nextFrame(timeout:)` loops on `receive(remaining)`, sleeping `pollSleep` between empty polls, parsing with `FreakProtocol.parse` and skipping nil — identical to `_next_frame`. Clock and sleep injectable; **no static mutable state anywhere in the package.**

### 3.6 `Device.swift` — the `MicroFreakDevice` actor

The concurrency keystone. Python's blocking-synchronous core is preserved verbatim *inside* an actor whose executor is a dedicated dispatch queue, so blocking waits never touch the cooperative thread pool.

```swift
public actor MicroFreakDevice {
    public nonisolated let slots: Int

    private let session: FreakSession                 // non-Sendable, actor-confined
    private let queue: DispatchSerialQueue            // the actor's executor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()               // iOS 17 / macOS 14 API
    }

    public init(transport: any Transport,
                slots: Int = FreakProtocol.slots,
                config: SessionConfig = .init(),
                clock: @escaping ClockFn = FreakClock.monotonic,
                sleep: @escaping SleepFn = FreakClock.threadSleep)
    // queue = DispatchSerialQueue(label: "com.ericbrookfield.freakcore.device",
    //                             qos: .userInitiated)

    // reads
    public func name(slot: Int) throws -> String
    public func read(slot: Int) throws -> Preset
    public func snapshot(readBlobs: Bool = true, keepBlobs: Bool = false,
                         slots: [Int]? = nil,
                         progress: ProgressFn? = nil,
                         cancel: CancelToken? = nil) throws -> DeviceSnapshot
    // writes (verified by default)
    public func write(slot: Int, preset: Preset, verify: Bool = true,
                      cancel: CancelToken? = nil) throws -> WriteReport
    public func rename(slot: Int, name: String, verify: Bool = true) throws -> WriteReport
    // backup / restore
    public func backup(to dest: URL, slots: [Int]? = nil, resume: Bool = false,
                       progress: ProgressFn? = nil,
                       cancel: CancelToken? = nil) throws -> BackupSet
    public func restore(from source: BackupSet, slots: [Int]? = nil,
                        verify: Bool = true,
                        progress: ProgressFn? = nil,
                        cancel: CancelToken? = nil) throws -> [WriteReport]
    public func close()
}
```

Why this shape (implementers do not revisit): actor isolation replaces the Python lock — "one transaction at a time" is compiler-enforced because every entry point is actor-isolated and chunk-stream interleaving is unexpressible from outside; the `DispatchSerialQueue` executor means the blocking `receive(timeout:)`/`Thread.sleep` calls stall only that queue's thread (Dispatch overcommits; a 211-second backup never starves Swift concurrency); every method is synchronous *inside* (a transliteration of `device.py`) and `async throws` at every call site by actor semantics.

Behavior, verbatim from `device.py`:

- `snapshot`: sorted requested slots (default `0..<slots`); per slot: cancel check first (`.cancelled(done:total:)`, no partial snapshot); name read with `.deviceTimeout`/`.replyMismatch` swallowed → `name: nil, meta: nil` on the record; blob read only when `readBlobs` (sha computed; bytes kept only when `keepBlobs`); progress after each slot with median ETA (`sorted(durations)[n/2] * remaining`); TimingReport rounded (3/4/1 decimals) exactly as Python.
- `write`: `session.writePreset`, then if `verify`: name mismatch → `.verifyMismatch` (actualSha nil, firstDifference nil, actualLen 0); else read blob back, sha compare, mismatch → `.verifyMismatch` with `firstDifference` = first differing byte index (or min-length if one is a prefix); `verified = true`. `verify: false` → `verified = nil`. **`verified == false` is unrepresentable in outcomes — a mismatch always throws.**
- `rename`: `validateName` first; read current meta via `readName`; `writeName`; verify name equality (sha `""`, `expectedLen`/`actualLen` 0).
- `backup(to:)`: phase-0 on-disk format (§3.7), per-slot persistence — blob file + atomically rewritten `index.json` before the next slot is read, so interruption leaves valid partial state; `resume: true` skips slots whose `.bin` exists *and* have an index entry; merges into an existing index if present; timing written at the end; returns `BackupSet.load(dest)`. **Reads only; never writes to the device.**
- `restore(from:)`: sorted requested slots (default `source.coveredSlots()`); per slot cancel-check → `source.preset(slot:)` → `write`; **any thrown FreakError (including `.cancelled`) is wrapped as `.restoreStopped(completed: reports, underlying: error)` — a failing write path must not keep writing**; progress per completed slot.
- `close()` closes the transport via the session. No implicit close in `deinit` — owners call `close()` explicitly.

Progress and cancellation across isolation: `ProgressEvent` is Sendable and `ProgressFn` is `@Sendable`, invoked synchronously on the device queue between slots — never mid-frame. UI consumption pattern (the app's `ProgressBridge`, §7.1): `AsyncStream.makeStream(of: ProgressEvent.self)`, pass `{ continuation.yield($0) }` as `progress`, `for await` on the MainActor. `CancelToken` is Sendable; call `cancel()` from any isolation; polled between slots and between chunks; worst-case latency one dump/ack timeout.

`open_device()` equivalent lives in FreakMIDI (§5); FreakCore has no device factory.

### 3.7 `Backup.swift` — `BackupSet`

Immutable after load ⇒ a Sendable struct (it crosses the actor boundary in `backup`/`restore`).

```swift
public struct BackupSet: Sendable {
    public struct Entry: Sendable, Equatable {
        public let slot: Int
        public let name: String?
        public let bytes: Int?
        public let sha256: String?
        public let metaHex: String?      // 18 hex chars; nil on pre-meta phase-0 indexes
    }
    public let path: URL
    public let createdAt: String
    public let timing: TimingReport

    public static func load(from path: URL) throws -> BackupSet
    public func covers(slot: Int) -> Bool            // entry exists AND has sha256
    public func coveredSlots() -> [Int]              // sorted
    public func preset(slot: Int) throws -> Preset   // .slotOutOfRange if not covered;
                                                     // .integrity("no meta recorded; re-backup
                                                     // to restore this slot") if metaHex nil
    public func records() -> [SlotRecord]            // name+sha+meta per entry, blob nil
}

func atomicWriteText(_ text: String, to url: URL) throws   // internal:
// Data.write(to: url, options: .atomic) — temp file + rename, same guarantee as
// Python's mkstemp + os.replace; readers never see a torn file
```

`load` parses `index.json` (unparseable → `.libraryCorrupt`; missing/non-dict `presets` → `.libraryCorrupt`) and **re-hashes every blob file** against its recorded sha, ascending slot order — first bad slot named in `.integrity` (missing file or sha mismatch). Timing fields default 0.0 / nil as in Python. On-disk schema, byte-role-compatible with phase-0 `mfcap backup` (existing backups open unchanged):

```
<dest>/index.json    {"created": ISO8601, "slots": N,
                      "presets": {"<slot>": {"slot","name","bytes","sha256","meta_hex"}},
                      "timing": {"total_seconds","per_slot_seconds",
                                 "name_ms_median","dump_ms_median"}}
<dest>/presets/NNN.bin   4672 bytes, zero-padded 3-digit slot
```

JSON writing: `JSONSerialization` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` — schema-identical to the Python (same keys, `null` for absent medians), byte order of keys may differ; both implementations read either. Creation goes through `MicroFreakDevice.backup` only — no `BackupSet.create`.

### 3.8 `Library.swift`

```swift
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let id: String              // uuid4 hex (lowercase, no dashes), minted at add()
    public let name: String
    public let sha256: String
    public let metaHex: String         // 18 hex chars, round-trips Preset.meta
    public let slot: Int?              // a DELIBERATE user pin; never set by bank import
    public let addedAt: String         // ISO 8601
    public let tags: [String]
}

public final class Library {           // deliberately NOT Sendable — single-writer,
                                       // owned by one isolation domain (the app uses MainActor);
                                       // never crosses into MicroFreakDevice
    public let root: URL
    public static func create(at root: URL) throws -> Library   // .libraryExists if index.json present
    public static func open(at root: URL) throws -> Library     // .libraryNotFound / .libraryCorrupt
    // reads
    public func entries() -> [LibraryEntry]
    public func entry(id: String) throws -> LibraryEntry        // .entryNotFound
    public func get(id: String) throws -> Preset                // re-hashes blob vs filename;
                                                                // .integrity("blob file missing" /
                                                                // "sha256 mismatch (bit rot?)")
    public func findBySha(_ sha256: String) -> [LibraryEntry]
    public func hasBlob(_ sha256: String) -> Bool
    public func slotMap() -> [Int: LibraryEntry]   // the user's real pins; NOT a sync baseline
    // writes (every mutation ends in an atomic index save)
    @discardableResult
    public func add(_ preset: Preset, slot: Int? = nil, tags: [String] = []) throws -> LibraryEntry
    @discardableResult
    public func renameEntry(id: String, name: String) throws -> LibraryEntry
    public func remove(id: String) throws        // blob file deleted only when unreferenced
    public func assignSlot(id: String, slot: Int?) throws
    @discardableResult
    public func storePreset(_ preset: Preset) throws -> PresetRef  // blob-only; no catalog entry
    public func clearCollectionSlotClaims() throws -> Int   // one-time, loss-free repair
    // import
    @discardableResult
    public func importSnapshot(_ snapshot: DeviceSnapshot,
                               skipExpendable: Bool = true,
                               threshold: Int = FreakProtocol.duplicateThreshold)
                               throws -> [LibraryEntry]
}
```

Semantics verbatim from `library.py`: on-disk `index.json {"schema": 1, "entries": [...]}` + `blobs/<sha256>.bin` (content-addressed; 269 Inits cost one file); `add` writes the blob iff absent and always creates a new entry (two entries may share a sha); assigning a slot clears any other entry's claim (the `dedupe:` merge path included). `slot` is a DELIBERATE user pin — set by `assignSlot` and by device-capture adds, NEVER by `collectionFromBank` / `mergeBundle`, whose arrangement lives in the `PresetCollection`; `clearCollectionSlotClaims()` is the one-time repair for libraries built before that rule, clearing a claim only when an **`.importedBank`** collection already records the same `(sha256, name)` at that slot (loss-free, idempotent) — a `.deviceSnapshot` collection records the same triples `importSnapshot` legitimately pinned, so a device capture is left alone. `storePreset(_:)` stores a preset's blob content-addressed and returns its `PresetRef` without creating a catalog entry — the only correct way to mint a ref for bytes a caller is writing straight into a collection's `slots` (a ref to bytes the store never received cannot be resolved, and `planApply` folds that slot to SKIP forever). `importSnapshot` requires kept blobs (`.snapshotMissingBlobs` otherwise), skips expendable slots when asked, skips `meta == nil` records (failed name read — cannot round-trip), skips existing `(sha256, name)` pairs, assigns each imported entry its source slot, returns entries actually added. Atomic index writes; single-writer assumption; no cross-process locking. Entry JSON keys exactly `id, name, sha256, meta_hex, slot (explicit null), added_at, tags, category, favorite, verdict` — both writers always emit all ten (readers default the last three, so an older index still loads; an index missing one was NOT written by either core).

### 3.9 `Sync.swift`

```swift
public enum SlotStatus: String, Sendable, CaseIterable {
    case inSync = "in_sync", unlisted = "unlisted", baselineOnly = "missing",
         differs = "changed", empty = "empty"
}
public struct SlotDiff: Sendable {
    public let slot: Int
    public let status: SlotStatus
    public let device: SlotRecord?        // the snapshot record for this slot
    public let baseline: PresetRef?       // what the chosen collection places here
    public let nameDiffers: Bool          // shas equal, names differ
}
public struct SyncDiff: Sendable {
    public let slots: [SlotDiff]          // one per snapshot record, ascending
    public let unreadBaselineSlots: [Int] // baseline slots the snapshot missed
    public func byStatus(_ status: SlotStatus) -> [SlotDiff]
}
public func computeDiff(snapshot: DeviceSnapshot, baseline: [Int: PresetRef],
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff
public func computeDiff(snapshot: DeviceSnapshot, collection: PresetCollection,
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff
```

The **baseline is a collection**, never the library: the library is a flat catalog of unique patches with no slot opinion, so diffing against it merged every imported bank into one incoherent mash.

Pure and deterministic; throws `.snapshotMissingHashes` if any considered record lacks a sha (refusing beats guessing). Status table exactly as `sync.py`: no b & expendable → `.empty`; no b & not → `.unlisted`; b & shas equal → `.inSync`; b & expendable → `.baselineOnly`; else `.differs`. A slot the baseline is silent about can only be `.unlisted` or `.empty` — never `missing`. The core never auto-writes from a diff — executing it is the caller composing `write`/`add` calls per row, or `planApply` for the whole arrangement.

**One decision table.** `planApply` (§3.11) is computed on `computeDiff`: `.inSync && !nameDiffers` → SKIP; `.inSync` (name only) / `.differs` / `.baselineOnly` → WRITE; `.unlisted` / `.empty` → the unlisted policy. Expendability splits only the diff's label (`changed` vs `missing`), never the action, so the Sync screen and Apply can never disagree.

### 3.10 `Analysis.swift`

```swift
public enum Analysis {
    public static func shaCensus(_ records: [SlotRecord]) -> [String: Int]
    public static func findExpendable(_ records: [SlotRecord],
                                      threshold: Int = FreakProtocol.duplicateThreshold) -> Set<Int>
    public static func pickScratchSlot(_ records: [SlotRecord],
                                       preferFrom: Int = 500,
                                       exclude: Set<Int> = []) -> Int?
}
```

Rules verbatim: expendable = successfully-read blank/whitespace-only name, OR sha occurring ≥ threshold times (3, not 2). **Never** a `name == "Init"` string match. Unknown is never expendable: `sha256 == nil` and `name == nil` each disqualify their rule. `pickScratchSlot`: highest expendable ≥ `preferFrom` not excluded, else highest expendable overall, else nil — phase-0 semantics exactly, asserted by vectors.

### 3.11 `SimulatedMicroFreak.swift` — the demo/offline device

Ships in the **library target** (demo mode links it). Faithful transliteration of `transports/simulated.py`, including its docstring-numbered fidelity points 1–5.

```swift
public struct WireEntry: Sendable, Equatable {
    public enum Direction: String, Sendable { case out, `in` }   // host convention:
    public let direction: Direction                              // out = host→device
    public let raw: Data
}

public final class SimulatedMicroFreak: Transport, @unchecked Sendable {
    // one internal NSLock guards ALL state; every public method takes it
    public init(slots: Int = FreakProtocol.slots,
                replyLag: Bool = true,                 // default ON — every offline
                failChunkAt: Int? = nil)               // test exercises the defense
    public static func factoryFresh(initCopies: Int = 269, seed: Int = 0,
                                    slots: Int = FreakProtocol.slots,
                                    replyLag: Bool = true,
                                    failChunkAt: Int? = nil) -> SimulatedMicroFreak
    // test back doors
    public func load(slot: Int, preset: Preset) throws     // .slotOutOfRange (was IndexError)
    public func peek(slot: Int) throws -> Preset
    public var faults: [String] { get }                    // snapshot copies under the lock
    public var wireLog: [WireEntry] { get }
    // Transport
    public func send(_ message: Data) throws               // runs the device state machine inline
    public func receive(timeout: TimeInterval) throws -> Data?  // FIFO outbox pop; nil
                                                           // immediately when empty — no sleeping
    public func close()
}
```

Required behaviors (each is a `SimulatedFidelityTests` case):

1. Name replies are full 35-byte long-0x52 payloads in **reply form**: positional meta (`meta[5]=pos`, `meta[6]` = 0/1 slot-384 flag, `meta[0]` carries 0x10 exactly when slot ≥ 128), printable attribute bytes (0x32/0x33) so header-leak regressions are caught; reply echoes its request's seq.
2. `replyLag` (default true): reply to name-read N held and emitted when name-read N+1 arrives; held reply rendered from device state **at emission time** (slow, not wrong). Deliberately harsher than hardware — do not tune real-time lag behavior against the sim. (UI note: the first name read of a demo session costs one `nameTimeout` ≈ 1 s before the retry releases it; subsequent reads are fast.)
3. Dumps: open `[bank,pos,0x01]`, then 145×0x16 + 1×0x17 (32 bytes each), pull-paced; each chunk echoes its pull's seq.
4. Writes: long 0x52 alone updates name+meta (a rename is only this frame); short 0x52 opens; 0x15 arms; 0x17 commits. Device acks long 0x52, open, go, AND every chunk — each a 0x18 with len 0x00, empty payload, seq echoing the acked frame. Inbound long-0x52 validated against the outbound convention (`payload[8]==pos`, `payload[9]==0x06`, `payload[3]` without 0x10); deviations → `faults`. Committed total ≠ 4672, or chunks without open+armed → slot untouched + fault (a broken writer fails verification instead of passing). No checksum anywhere.
5. `failChunkAt: N`: the write chunk with 0-based **cumulative** index N (counted across the sim's lifetime — fresh sim per torn-write scenario) and all later ones get no ack.

`synthBlob(seed:label:)` must match the Python byte-for-byte (cross-checked by the `sim_factory` vector): concatenated `SHA-256(UTF-8 "\(seed):\(label):\(counter)")` digests with each byte `& 0x7F`, counter 0,1,2,…, truncated to 4672. `factoryFresh` reproduces the reference device: slots `0..<(slots-initCopies)` named `"Patch %03d"` with per-slot blobs, opaque `[(slot*3) % 0x20, 0,0,0,0]`, category `slot % 0x0C`, attribute 0x32/0x33 alternating; the rest identical "Init" blobs with opaque `[0x08,0,0,0,0]`, category 0, attribute 0x33 — meta positionally correct including the payload[9] flip at 384.

### 3.12 Python → Swift symbol map (completeness check)

| Python | Swift |
|---|---|
| `open_device()` | `FreakMIDI.openMicroFreak()` (§5) |
| `MicroFreak` | `actor MicroFreakDevice` |
| `MicroFreak.session` | not exposed (§10) |
| `Session` | `final class FreakSession` |
| `Transport` (Protocol) | `protocol Transport` |
| `Preset` / `.sha256` / `.renamed` | `struct Preset` / `var sha256` / `func renamed(_:)` |
| `SlotRecord`, `DeviceSnapshot`, `TimingReport`, `WriteReport`, `ProgressEvent`, `ProgressFn`, `CancelToken`, `NameInfo`, `Frame` | same names, §3.2/§3.1 |
| `BackupSet` | `struct BackupSet` |
| `Library`, `LibraryEntry` | `final class Library`, `struct LibraryEntry` |
| `diff` / `diff_baseline`, `SyncDiff`, `SlotDiff`, `SlotStatus` | `computeDiff(snapshot:baseline:)` / `(snapshot:collection:)`, same value types, §3.9 |
| `analysis.sha_census/find_expendable/pick_scratch_slot` | `Analysis.shaCensus/findExpendable/pickScratchSlot` |
| `protocol.*` constants & functions | `FreakProtocol.*` (§3.1; `is_chunk/is_last_chunk/is_ack` → `Frame.isChunk/.isLastChunk/.isAck`) |
| exceptions | `FreakError` (§3.3) |
| `transports.simulated.SimulatedMicroFreak` | `SimulatedMicroFreak` (FreakCore) |
| `transports.rtmidi.available` | not ported — CoreMIDI is always present on iOS/macOS |
| `transports.rtmidi.list_ports` | `FreakMIDI.listEndpoints()` |
| `transports.rtmidi.find_microfreak` | `FreakMIDI.findMicroFreak(hints:exclude:)` |
| `RtMidiTransport.open` / `.open_ports` | `CoreMIDITransport.open(hints:exclude:)` / `.open(sourceID:destinationID:)` |

---

## 4. Concurrency model — one-page summary

| Layer | Isolation | Sendable? |
|---|---|---|
| `FreakProtocol`, `Analysis`, `diff` | pure functions | n/a (all inputs/outputs Sendable except `Library` param) |
| Value types (Preset … Frame, BackupSet, LibraryEntry, SyncDiff) | none needed | `Sendable` structs, `let` fields |
| `CancelToken` | any | `@unchecked Sendable` (NSLock) |
| `Transport` impls | internally synchronized | `@unchecked Sendable` required by the protocol |
| `FreakSession` | confined inside the device actor | **not** Sendable (compiler-enforced single transaction; replaces `threading.Lock`) |
| `MicroFreakDevice` | `actor`, custom executor = dedicated `DispatchSerialQueue` | actor |
| `Library` | caller-owned (app: `@MainActor`) | **not** Sendable (single-writer, as documented in Python) |
| `SimulatedMicroFreak` | internally locked | `@unchecked Sendable` |

Rules: blocking waits (`receive(timeout:)`, `Thread.sleep`) happen only on the device actor's dispatch queue — never the cooperative pool, never the main thread. Progress callbacks are `@Sendable`, fire on the device queue, and the app bridges them to the MainActor via `AsyncStream`. Cancellation is the `CancelToken`, bridged from structured concurrency by `withCancellation`. Two concurrent `write` calls on the actor serialize automatically; `ConcurrencyTests` asserts the sim's `wireLog` shows no interleaved chunk streams.

---

## 5. FreakMIDI — CoreMIDI onto the Transport seam

### 5.1 `CoreMIDITransport`

```swift
public struct MIDIEndpointInfo: Sendable, Hashable {
    public let id: MIDIUniqueID          // kMIDIPropertyUniqueID — stable reconnect key
    public let name: String              // kMIDIPropertyDisplayName
    public let isOffline: Bool           // kMIDIPropertyOffline
}

public let defaultHints = ["microfreak", "micro freak", "arturia microfreak"]

public func listEndpoints() throws -> (sources: [MIDIEndpointInfo],
                                       destinations: [MIDIEndpointInfo])
public func findMicroFreak(hints: [String] = defaultHints, exclude: String = "mfcap")
    throws -> (source: MIDIEndpointInfo, destination: MIDIEndpointInfo)?
    // case-insensitive substring match on displayName, skipping names containing `exclude`

public final class CoreMIDITransport: Transport, @unchecked Sendable {
    public static func open(hints: [String] = defaultHints,
                            exclude: String = "mfcap") throws -> CoreMIDITransport
        // discovery + open; throws .deviceNotFound(inputs:outputs:) listing every
        // display name seen when no match
    public static func open(sourceID: MIDIUniqueID,
                            destinationID: MIDIUniqueID) throws -> CoreMIDITransport
        // explicit picker (the open_ports equivalent); .deviceNotFound if either id
        // no longer resolves via MIDIObjectFindByUniqueID
    public let source: MIDIEndpointInfo
    public let destination: MIDIEndpointInfo
    public func send(_ message: Data) throws
    public func receive(timeout: TimeInterval) throws -> Data?
    public func close()
}

public func openMicroFreak(hints: [String] = defaultHints, exclude: String = "mfcap")
    throws -> MicroFreakDevice        // MicroFreakDevice(transport: try CoreMIDITransport.open(...))
```

Implementation mandates (no alternatives):

- **Client:** one process-wide `MIDIClientRef` created lazily by `FreakMIDIClient.shared()` via `MIDIClientCreateWithBlock`; its notify block fans out to registered `MIDISetupMonitor`s. Creation failure → `.transport(detail:)` carrying the OSStatus.
- **Modern UMP API, both directions** (nothing deprecated on iOS 17): input port via `MIDIInputPortCreateWithProtocol(client, "mfcap-in", ._1_0, &port, receiveBlock)`; source connected with `MIDIPortConnectSource` (only the selected source — no promiscuous listening). Output via `MIDIOutputPortCreate`; sends via `MIDISendEventList` with a `MIDIEventList` built from SysEx7 UMP packets (timestamp 0 = now). Largest frame is 45 bytes ⇒ always fits one event list. Every OSStatus ≠ noErr → `.transport`.
- **SysEx7 codec (`SysEx7.swift`, pure, unit-tested):** UMP 64-bit Data messages, message-type nibble 0x3, group 0. Word0 = `[0x3][group][status][byteCount][b1][b2]`, word1 = `[b3][b4][b5][b6]`; status 0x0 complete / 0x1 start / 0x2 continue / 0x3 end; byteCount 0–6. `encode(_ message: Data) -> [UInt32]` strips the F0/F7 framing (UMP carries only interior bytes) and splits 6 bytes per packet. `SysEx7Assembler.consume(word0:word1:) -> Data?` re-wraps completed streams as `F0…F7` (the Transport contract delivers complete SysEx). Tear rules mirror the rtmidi adapter: a `start`/`complete` while a partial is pending drops the torn partial; `continue`/`end` with no pending partial is dropped; non-type-3 UMP messages are ignored (see §10).
- **Push-to-poll:** the receive block (a CoreMIDI-owned high-priority thread) feeds completed messages into an `NSCondition`-guarded FIFO `[Data]`; `receive(timeout:)` does `condition.wait(until:)` loops until a message or deadline — the documented "locked array + semaphore" adapter shape. Order preserved; unbounded buffer; never drops.
- `close()`: `MIDIPortDisconnectSource`, dispose both ports (client persists for the process), then signal the condition so a blocked `receive` returns nil; subsequent `send` throws `.transport("transport closed")`.

### 5.2 Connection lifecycle on iPadOS

```swift
public final class MIDISetupMonitor: @unchecked Sendable {
    public enum Event: Sendable { case setupChanged }   // added/removed/setup notifications coalesce
    public init() throws
    public var events: AsyncStream<Event> { get }
    public func stop()
}
```

Policy (owned by the app layer, §7.1, but normative here):

- **Discovery & reconnect:** on launch and on every `.setupChanged`, run `findMicroFreak`; track the hardware by `MIDIUniqueID`. Device vanished with a transport open → the app closes the device, shows "disconnected", and offers demo mode.
- **Backgrounding:** no `UIBackgroundModes` are declared (no audio background entitlement). On `didEnterBackgroundNotification` the app wraps any in-flight operation in a `UIApplication.beginBackgroundTask`; the expiration handler calls the operation's `CancelToken.cancel()`. Read passes (snapshot/backup) resume later via `backup(resume: true)`; a cancelled write may tear its slot — the app records the slot dirty and offers "write again" on foreground (the documented recovery). Single verified writes (~0.5 s) always finish inside the grace window.
- **Foregrounding:** on `willEnterForegroundNotification`, re-resolve both endpoint ids (setup notifications may have been dropped during suspension); unresolvable → disconnected state. CoreMIDI port refs survive suspension; no re-open is needed when the ids still resolve.

---

## 6. Demo mode

Hardware and demo are the same type behind the same seam — `MicroFreakDevice` over a `Transport`:

```swift
// hardware
let device = try FreakMIDI.openMicroFreak()
// demo — identical API, no hardware, instant
let device = MicroFreakDevice(transport: SimulatedMicroFreak.factoryFresh())
```

Rules: demo always uses `factoryFresh()` **with `replyLag` left at its default `true`** so the shipping reply-lag defense is exercised on every demo interaction; `initCopies: 269, seed: 0` (the reference device's shape — expendability, scratch-slot, and diff flows are real). Everything downstream of the device — `Library`, `BackupSet`, `diff`, all screens — is byte-identical between modes; nothing outside `AppModel.connect…` may mention `SimulatedMicroFreak`. Demo entry points: automatic offer when discovery finds no MicroFreak, a Settings toggle, and launch argument `-MFDemoMode YES` (UI tests). Demo-made backups are written under `Backups/demo-<timestamp>` to keep them distinguishable; the library is shared between modes (it is device-independent by design).

---

## 7. The app — "MicroFreak Librarian"

### 7.1 Module layout (`ios/App/Sources/`)

```
App/
  MicroFreakLibrarianApp.swift   # @main SwiftUI App; injects AppModel
  AppModel.swift                 # @MainActor @Observable. Owns: connection state
                                 # (.disconnected / .demo(MicroFreakDevice) /
                                 #  .hardware(MicroFreakDevice, source:, destination:)),
                                 # the Library (open-or-create at Documents/Library),
                                 # the MIDISetupMonitor task, background-task policy (§5.2)
Device/
  DeviceOperations.swift         # thin async facades: refreshNames (names-only snapshot),
                                 # fullScan (keepBlobs snapshot), writePreset, renameSlot,
                                 # runBackup, runRestore — each owns one CancelToken and
                                 # publishes OperationState { idle, running(ProgressEvent),
                                 # done, failed(FreakError) }
  ProgressBridge.swift           # AsyncStream<ProgressEvent> bridge (§3.6 pattern)
Screens/
  SlotGridView.swift             # 512-slot browser (names-only refresh is interactive: ~1 ms/slot)
  PresetDetailView.swift         # read/write/rename one slot; verified-write results
  LibraryView.swift              # entries, tags, rename, assign slot, remove
  SyncView.swift                 # device vs. ONE chosen baseline collection; diff table by SlotStatus
                                 # (each an explicit write/add composed by the user)
  BackupsView.swift              # run/resume backup (progress + median ETA), restore
  SettingsView.swift             # port picker (listEndpoints), demo toggle, timeouts display
Support/
  Paths.swift                    # Documents/Library, Documents/Backups/<stamp>, demo- prefix
  Formatters.swift               # durations, ETA, sha prefixes
```

Storage: library at `Documents/Library/`, backups at `Documents/Backups/<yyyy-MM-dd-HHmmss>/`; `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` expose both in the Files app (backups are plain phase-0 folders — portable to the Mac/Python tooling unchanged). UI throughput expectations are law: names-only refresh interactive; any blob pass is a progress-bar operation (~400 ms/slot, ~3.5 min full).

### 7.2 Isolation wiring

`AppModel` and all views are `@MainActor`. Device calls are `try await device.…` (actor hop). `Library` is MainActor-owned; `diff` runs on the MainActor (pure, fast); `importSnapshot` runs on the MainActor after the snapshot returns (~1 MB of writes, fine). Long device operations run in a `Task` owned by `DeviceOperations`, using `withCancellation` so a SwiftUI cancel button (or the background-expiration handler) is one `token.cancel()`.

### 7.3 `ios/App/project.yml` (XcodeGen, exact)

```yaml
name: MicroFreakLibrarian
options:
  bundleIdPrefix: com.ericbrookfield
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
packages:
  FreakCore:
    path: ../FreakCore
  FreakMIDI:
    path: ../FreakMIDI
targets:
  MicroFreakLibrarian:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - package: FreakCore
      - package: FreakMIDI
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ericbrookfield.microfreak-librarian
        PRODUCT_NAME: MicroFreak Librarian
        TARGETED_DEVICE_FAMILY: "2"        # iPad only
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: 0.1.0
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: MicroFreak Librarian
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        ITSAppUsesNonExemptEncryption: false
  MicroFreakLibrarianTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: MicroFreakLibrarian
schemes:
  MicroFreakLibrarian:
    build:
      targets: { MicroFreakLibrarian: all }
    run:
      config: Debug
    test:
      config: Debug
      targets: [MicroFreakLibrarianTests]
```

No background modes, no entitlements file, no capabilities: CoreMIDI over USB needs none. Generate with `xcodegen generate` in `ios/App/`.

---

## 8. Golden-vector JSON format

Location: `ios/FreakCore/Tests/FreakCoreTests/Fixtures/vectors/*.json`. Generated by the Python reference (a future `bin/gen_vectors.py` driving `microfreak` itself, so vectors *are* the reference's behavior); Swift only consumes them. Conventions: **all byte fields are lowercase hex strings, no separators or prefixes**; all keys snake_case; optional-absent is JSON `null`; every case carries a unique `id` used in failure messages. Common envelope for every file:

```json
{
  "schema": "mfcap-vectors/1",
  "kind": "<one of the kinds below>",
  "source": "microfreak==0.1.0",
  "cases": [ ... ]
}
```

The Swift runner (`VectorTests`) enumerates every `*.json` in the directory, dispatches on `kind`, and **fails on an unknown kind** — a new vector file can never be silently skipped. Error expectations use these tokens, mapped 1:1 to `FreakError` cases: `slot_out_of_range`, `blob_size`, `invalid_name`, `protocol`.

1. **`frame_builders.json`** — kind `frame_builders`. Case: `{"id", "builder": "read_name_req"|"open_dump_req"|"pull_next_req"|"open_write_frame"|"go_frame", "seq": int|null, "slot": int|null, "expect_hex": str}` or `{"…", "expect_error": token}`. Required coverage: each builder at slots 0, 127, 128, 383, 384, 511; seq 0, 1, 127; errors at slot −1 and 512.
2. **`name_write_frames.json`** — kind `name_write_frame`. Case: `{"id", "seq", "slot", "name", "meta_hex", "expect_hex" | "expect_error"}`. Required: reply-form meta with the 0x10 bit set (must come out cleared); slot ≥ 384 with `meta[6] = 1` (payload[9] still 0x06); `meta[5]` ≠ pos (payload[8] recomputed); 23-char name; empty name; error cases: 24-char name, non-ASCII, leading/trailing space, 8-byte meta, meta byte 0x80.
3. **`chunk_frames.json`** — kind `chunk_frames`. Case: `{"id", "blob_hex" (9344 chars), "expect_frames_hex": [146 strings]}` or `{"id", "blob_hex", "expect_error": "blob_size"|"protocol"}`. Required: one full synthetic blob asserting the complete seq stream 1..127, 0, 1..18 and the 0x16/0x17 split; a 4671-byte blob; a blob with one 0x80 byte.
4. **`parse_decode.json`** — kind `parse_decode`. Case: `{"id", "raw_hex", "expect": {"seq", "length", "cmd", "data_hex"} | null, "expect_name_info": {"slot", "name", "meta_hex"} | {"error": "protocol"} | null (absent when not a long-0x52 case)}`. Required: hardware-shape name replies for slots 0, 8, 40, 200, 511 (the fixture slots — printable attribute bytes exercising header-leak filtering); a device ack (len 0, empty payload); a chunk; non-Arturia SysEx → `expect: null`; truncated frame → null; long-0x52 with out-of-range embedded address → `expect_name_info.error`.
5. **`name_validation.json`** — kind `name_validation`. Case: `{"id", "name", "ok": bool}`. Required: "", 23 chars, 24 chars, tab, non-ASCII (é), interior spaces ok, leading space, trailing space.
6. **`write_burst.json`** — kind `write_burst`. The end-to-end host frame stream for one verified-write sequence, captured from a **fresh** reference `Session` (seq counter starting at 0 → first emitted 1) over a **non-lagged** sim that acks everything. Case: `{"id", "slot", "name", "meta_hex", "blob_hex", "expect_frames_hex": [151 strings]}` — frame 1 (0x19 seq 1), frame 2 (long 0x52 seq 2), frame 3 (short 0x52 seq 3), frame 4 (go seq 0), 146 chunks (seq 1..127, 0, 1..18), frame 7 (0x19 seq 4). Required: one case below slot 384 and one at ≥ 384. Swift asserts by driving `FreakSession.writePreset` over a scripted always-ack transport and comparing its outbound log.
7. **`sim_factory.json`** — kind `sim_factory`. Pins cross-language sim fidelity: `{"seed": 0, "init_copies": 269, "slots": 512, "expect": {"init_blob_sha256": str, "init_count": 269, "records": [{"slot", "name", "sha256", "meta_hex"}, …]}}` with records for slots 0, 1, 127, 128, 242, 243, 383, 384, 511 (bank, 0x10-bit, and payload[9]-flip boundaries).
8. **`analysis.json`** — kind `analysis`. Case: `{"id", "records": [{"slot", "name": str|null, "sha256": str|null}], "threshold": int, "expect_expendable": [int], "scratch": {"prefer_from": int, "exclude": [int], "expect": int|null} | null}`. Required: blank-name rule, whitespace-only name, threshold boundary (2 copies vs 3), `name: null` never expendable, `sha: null` never expendable, "Init"-named unique blob NOT expendable, scratch preference ≥ 500 and fallback.
9. **`sync_diff.json`** — kind `sync_diff`. The baseline is a **collection's slot map**, never the library: the flat catalog carries no slot opinion, so diffing against it merged every imported bank into one incoherent mash. Case: `{"name", "records": [{"slot", "name", "sha256"}], "baseline": [{"slot", "sha256", "name", "meta_hex"}], "threshold": int|null, "expected": [{"slot", "status": "in_sync"|"unlisted"|"missing"|"changed"|"empty", "status_name", "name_differs": bool}], "unread_baseline_slots": [int], "note"}` — at least one case producing all five statuses, plus the error case (`"records_missing_hash": true` → `"expected_error": "snapshot_missing_hashes"`). There is no `"added"` status: a slot the baseline is silent about is `unlisted` (or `empty` when expendable), never `missing`. Generated by `tools/gen_vectors.py` (`gen_sync_diff`); mirrored in `swift-architecture.md` §"sync_diff.json".

---

## 9. Test plan (FreakCoreTests)

Beyond `VectorTests`: **SessionTests** — the Python proof ported: 512 rapid `readName`s against the lagged `factoryFresh` sim (virtual clock: injected clock advanced by the injected sleep), every slot labeled correctly; ReplyMismatch after 3 attempts against a stuck-stale script; timeout paths. **WriteSequenceTests** — 7-frame order and ack accounting via `wireLog`; rename = long-0x52 + refresh only. **DeviceTests** — verify-mismatch via sim back-door `load` between write and read-back; `verified == nil` on opt-out. **TornWriteTests** — `failChunkAt` → `.chunkNotAcked`, slot untouched, sim `faults` populated. **BackupRestoreTests** — temp-dir round trip, resume-skips, restore stop-at-first-failure with `.restoreStopped.completed`. **SimulatedFidelityTests** — §3.11 points 1–5. **ConcurrencyTests** — concurrent actor calls never interleave chunk streams. FreakMIDITests: SysEx7 encode/decode round trips, split/torn reassembly — pure, CI-safe, no hardware. First-hardware-session confirmations (ack pacing at our timing; sub-384 long-0x52 header) are already recorded as confirmed in write-protocol.md's provenance note — no additional gating in the port.

## 10. Complete list of deliberate deviations from the Python

1. `threading.Lock` in `Session` → actor confinement of non-Sendable `FreakSession` (compiler-enforced, stronger).
2. `MicroFreak.session` accessor not exposed (non-Sendable can't cross the actor boundary; nothing in the app needs raw session access).
3. Restore's dynamic `.completed` attribute → explicit `.restoreStopped(completed:underlying:)` wrapper case.
4. Exception chaining (`raise … from e`) → `underlying`/`detail` strings inside cases.
5. `SlotDiff.device` non-optional (the reference always populates it).
6. `SessionConfig` exposed on `MicroFreakDevice.init` (additive; defaults identical to Python).
7. `CoreMIDITransport` drops non-SysEx MIDI messages at the adapter (rtmidi forwards complete channel messages, which `parse` then discards — observable behavior identical).
8. Sim's `load`/`peek` throw `.slotOutOfRange` instead of Python's `IndexError`.
9. `withCancellation` bridge added (additive convenience; `CancelToken` remains the primitive).
10. JSON output key order/indentation not byte-identical to CPython's (schema- and value-identical; both sides parse either).

---

**Summary.** The port is two Swift 6 packages plus an XcodeGen app: FreakCore transliterates the Python core one file per module — a pure `FreakProtocol` codec, Sendable value structs, one `FreakError` enum, and a non-Sendable `FreakSession` whose single `transactAddressed` chokepoint owns the reply-lag defense — with `SimulatedMicroFreak` shipping in the library target so demo mode is the same `MicroFreakDevice` API over a different `Transport`. Concurrency is settled by making `MicroFreakDevice` an actor running on a dedicated `DispatchSerialQueue` executor, so the deliberately blocking poll-model transport and injectable clock/sleep survive unchanged while `@Sendable` progress callbacks bridge to the MainActor via `AsyncStream` and `CancelToken` bridges structured cancellation. FreakMIDI maps the seam onto modern CoreMIDI (UMP SysEx7 encode/reassembly, `MIDIUniqueID`-based discovery and reconnect, cancel-on-background-expiration lifecycle), and cross-implementation fidelity is pinned by nine Python-generated golden-vector JSON files — including a full 151-frame write burst and a factory-sim shape vector — under `Tests/FreakCoreTests/Fixtures/vectors/`.