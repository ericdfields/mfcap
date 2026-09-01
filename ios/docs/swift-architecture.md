# FreakCore / FreakLibrarian — Swift architecture specification

**Version 1.0 — 2026-09-01.** This document is the implementation contract for the iPad port of the
`microfreak` core. Two engineers implement against it **in parallel**: one builds the `FreakCore`
package (§3–§13), one builds the SwiftUI app against the seam in §14. Neither waits on the other;
every public declaration below is final. The golden-vector schema (§2) comes first so the vectors
engineer can start generating immediately.

Normative sources, in order of authority:

1. `/Users/ericbrookfield/Development/mfcap/docs/write-protocol.md` — wire ground truth (hardware-verified).
2. `/Users/ericbrookfield/Development/mfcap/docs/core-api.md` — the core API contract (its "Porting the core" section is the checklist).
3. `/Users/ericbrookfield/Development/mfcap/microfreak/` — the Python reference implementation. Port **semantics**, not idioms (§15 lists what not to port).

Where this document and those sources could ever disagree, write-protocol.md wins on wire bytes and
core-api.md wins on API semantics. Everything else — Swift naming, concurrency shape, file layout —
is decided here and only here.

---

## 1. Ground rules and toolchain

- Toolchain: Swift 6.4 / Xcode 27 on this Mac. `xcodegen` at `/opt/homebrew/bin/xcodegen`.
- Deployment: iPadOS 17.0+. `FreakCore` also builds for macOS 14+ so `swift test` runs headless on this Mac.
- **Swift 6 language mode with strict concurrency, everywhere, compiling clean.** No `@unchecked Sendable`
  anywhere in `FreakCore` except the two places §12 explicitly authorizes (and those carry the exact
  invariant comment given there).
- `FreakCore` imports only `Foundation` and `CryptoKit` (SHA-256). No CoreMIDI, UIKit, SwiftUI,
  Combine, or third-party dependencies — with the single exception of `CoreMIDITransport.swift`,
  which is `#if canImport(CoreMIDI)`-guarded (§12).
- Tests never open real MIDI ports or endpoints. `CoreMIDITransport` is exercised only through its
  pure, unguarded helpers (`SysEx7`, endpoint-name matching); everything else runs against
  `SimulatedMicroFreak`.
- Type conventions: wire bytes and single-byte fields are `UInt8`; slots, counts, indexes are `Int`;
  byte buffers (frames, blobs, meta) are `Data`; durations/timeouts are `TimeInterval` (seconds);
  hashes are lowercase 64-char hex `String`.
- Directory ownership: everything in this spec lives under `/Users/ericbrookfield/Development/mfcap/ios/`.
  An earlier scaffold exists at `ios/App/` and `ios/FreakMIDI/`; **this spec supersedes it**. The
  normative layout is §3 — the FreakCore engineer owns `ios/FreakCore/` (replacing its current
  contents), the app engineer owns `ios/FreakLibrarian/`. The legacy `ios/App/` and `ios/FreakMIDI/`
  trees are dead once both deliverables build; do not extend them.

### Protocol law (restated so no one re-derives it)

These are invariants, verified against hardware; violating any of them is a bug regardless of what
any Swift idiom would prefer:

- Frame envelope `F0 00 20 6B 07 01 <seq> <len> <cmd> [payload…] F7`. All payload bytes 7-bit.
- Reply-lag defense: a long-0x52 reply is matched to its request **only** by the embedded
  bank/pos (payload[0..1]) — never by arrival order or seq — in exactly one chokepoint (§8).
- The device acks **every** write frame with a 0x18 (long 0x52, short 0x52 open, 0x15 go, and every
  chunk). Device ack shape: len `0x00`, empty payload, seq echoing the acked frame. (The host's
  pull-next 0x18 during reads is different: len `0x01`, payload `[0x00]`.)
- Write chunk seqs: the go frame carries seq 0 and chunk *i* carries `(i + 1) % 128` — wrapping
  **through 0**. The session's addressed-request counter is a separate stream: 1..127, wrapping,
  never emitting 0.
- Outbound long-0x52 header: `payload[3] = meta[0] & ~0x10` (reply-only bit cleared),
  `payload[8] = pos` (recomputed), `payload[9] = 0x06` (constant on writes; replies carry the
  slot-384 0/1 flag there instead). `meta[1..4]`, `meta[7]`, `meta[8]` round-trip verbatim.
- Slot addresses appear **only** in 0x19 and 0x52 frames, always payload[0..1]. Chunk frames carry
  no address and no chunk API accepts or returns a slot — structurally, so pattern-matching an
  address inside a chunk is not expressible.
- Blobs are exactly 4672 bytes = 146 chunks × 32 bytes, no exceptions.
- Names: ≤ 23 printable-ASCII characters (`0x20..0x7E`), NUL-padded on the wire, no
  leading/trailing whitespace (cannot round-trip — replies decode stripped).
- **No checksum exists anywhere in the protocol. Nothing computes one, ever.**
- Every device write is read back and hash-verified by default; opt-out is explicit and per-call.
  A verify result is "verified" or a thrown error — never a silently-false flag.
- Expendability is a content judgement: sha256 duplicated ≥ 3 times among the considered records,
  or a *successfully-read* blank/whitespace name. Never a `name == "Init"` string match. Unknown is
  never expendable (`sha256 == nil` and `name == nil` each disqualify their own rule only).
- Restore stops at the first failure while reporting what completed.
- Timeout defaults proven on hardware: name 1.0 s, dump 1.5 s, ack 1.0 s, 3 name attempts.

---

## 2. Golden-vector fixtures — schema and test loading

The parity oracle. A vectors engineer generates these JSON files from the Python core (suggested
generator location: `mfcap/tools/gen_swift_vectors.py`, invoked from the repo root; the generator
runs the *Python* codec/session/sim and serializes what it saw). The Swift tests **must consume
these fixtures and compare byte-for-byte — they must not re-derive expected bytes by hand.**
A missing or unparseable fixture file is a test **failure**, never a skip.

### 2.1 Location

```
ios/FreakCore/Tests/FreakCoreTests/Fixtures/vectors/
  frames.json          kind = "frame_build"
  chunks.json          kind = "chunk_frames"
  name_replies.json    kind = "name_reply_decode"
  names.json           kind = "name_validation"
  write_burst.json     kind = "write_burst"
  read_dump.json       kind = "read_dump"
  reply_lag.json       kind = "reply_lag"
  expendable.json      kind = "expendable"
  sync_diff.json       kind = "sync_diff"
```

### 2.2 Conventions

- Encoding: UTF-8 JSON. Key order irrelevant. No comments.
- **Wire-byte strings** (any field named `hex` or ending `_hex` except sha fields): uppercase
  two-digit hex, single-space separated — `"F0 00 20 6B 07 01 …"`. Empty byte string = `""`.
- **Hashes** (`sha256`, `expected_sha256`): lowercase 64-char contiguous hex.
- Every file is one JSON object (the *envelope*); every case has a unique `id` string used in test
  failure messages.

### 2.3 Envelope (all files)

```json
{
  "schema": 1,
  "kind": "<one of the nine kinds>",
  "generated_by": "tools/gen_swift_vectors.py @ <python package version or git rev>",
  "description": "<free text>",
  "sim": { "factory_fresh": true, "init_copies": 269, "seed": 0, "reply_lag": false },
  "cases": [ … ]
}
```

`sim` is present **only** for the transcript kinds (`write_burst`, `read_dump`, `reply_lag`) and
describes the exact `SimulatedMicroFreak` construction the transcript was recorded against
(`reply_lag` files set `"reply_lag": true`). The Swift test constructs its own sim identically —
which is why §11 pins the factory-state and synthetic-blob algorithms bit-exactly.

### 2.4 Case shapes, per kind

**`frame_build`** — pure codec builders, one frame each.

```json
{ "id": "name_write_509", "builder": "name_write_frame",
  "inputs": { "seq": 5, "slot": 509, "name": "Akiko San", "meta_hex": "18 00 00 00 00 7D 01 00 33" },
  "expected_hex": "F0 00 20 6B 07 01 05 23 52 …" }
```

- `builder` ∈ `"read_name_req" | "open_dump_req" | "pull_next_req" | "name_write_frame" | "open_write_frame" | "go_frame"`.
- `inputs` carries only the fields that builder takes: `seq` (int, omitted for `go_frame`), `slot`
  (int), `name` (string), `meta_hex` (9 bytes, **reply-form as read from a device** — the builder
  must clear/recompute the direction-dependent bytes itself).
- Error cases replace `expected_hex` with `"expected_error"` ∈
  `"slot_out_of_range" | "invalid_name" | "protocol"`.
- Required coverage (generator's checklist): every builder; slots 0, 127, 128, 383, 384, 509, 511
  for addressed builders; a `name_write_frame` whose input meta carries the 0x10 reply bit and the
  reply-side payload[9] values 0 and 1 (proving both are rewritten); max-length and empty names;
  error cases for slot −1/512, 24-char name, non-ASCII name, 8-bit meta.

**`chunk_frames`** — the 146-frame burst, seq wrap included.

```json
{ "id": "burst_seed_2026", "blob_hex": "3C 20 03 … (4672 bytes)",
  "expected_hex_frames": [ "F0 … chunk 0, seq 01 …", "… ×146 total, last is 0x17 …" ] }
```

Error cases: `{ "id", "blob_hex", "expected_error": "blob_size" | "protocol" }` (wrong length; a
byte > 0x7F). At least one success case must have a blob long enough that the seq stream wraps
through 0 (any full blob does: seqs run 1..127, 0, 1..18).

**`name_reply_decode`** — `parse` + `decodeNameReply` on captured-shape raw frames.

```json
{ "id": "reply_slot_200", "raw_hex": "F0 00 20 6B 07 01 …",
  "expected": { "slot": 200, "name": "Bass Prophet", "meta_hex": "18 00 00 00 00 48 00 05 32" } }
```

- `expected: null` (and no `expected_error`) means `parse` returns nil — non-MicroFreak traffic
  (wrong prefix, truncated, no F7).
- `"expected_error": "protocol"` means `parse` succeeds but `decodeNameReply` throws (wrong cmd,
  wrong payload length, out-of-range embedded address).
- Must include: replies for slots below/above 128 (0x10 bit set/clear in meta), below/at/above 384
  (payload[9] 0/1), a name field with printable garbage after the first NUL (header-leak
  regression), a whitespace-padded name (decodes stripped), an all-NUL name (decodes `""`).

**`name_validation`** — `validateName` verdicts: `{ "id", "name": "…", "valid": true|false }`.
Cover: 23 chars (valid), 24 (invalid), `""` (valid), leading/trailing space (invalid), tab/newline
(invalid), non-ASCII (invalid), full printable range (valid).

**`write_burst`** — session-level parity: the complete wire transcript of one
`writePreset` against the §2.3 sim. The Swift test builds the identical sim, preloads nothing, runs
a **fresh** `FreakSession` (seq counter starts at 0 → first emitted seq is 1) executing
`writePreset(slot:preset:)`, captures the sim's `wireLog`, and compares every frame in order.

```json
{ "id": "write_slot_509",
  "slot": 509, "name": "Golden 509",
  "meta_hex": "<9 bytes, reply-form>", "blob_hex": "<4672 bytes>",
  "transcript": [ { "dir": "out", "hex": "F0 …" }, { "dir": "in", "hex": "F0 …" }, … ] }
```

`dir` is the host's convention: `"out"` = host→device, `"in"` = device→host. The transcript
contains: read-name + reply, long 0x52 + ack, short 0x52 open + ack, go (seq 0) + ack,
146 chunks each + ack (149 control+chunk acks total), read-back + reply. One case must target a
slot ≥ 384 with input meta carrying the 0x10 bit and reply-form payload[9] = 1; one must target a
slot < 128.

**`read_dump`** — transcript of one `readBlob(slot:)` against the §2.3 sim, plus the hash the
assembled blob must have:

```json
{ "id": "dump_slot_3", "slot": 3, "expected_sha256": "…64 hex…",
  "transcript": [ { "dir": "out", "hex": "…open…" }, { "dir": "in", "hex": "…chunk…" }, … ] }
```

**`reply_lag`** — the lag defense, end to end. Sim built with `"reply_lag": true`. A fresh session
reads `slots` in order via `readName`; every read must succeed with the expected name (retries
absorb the lag), and the full wire transcript must match:

```json
{ "id": "lag_walk", "slots": [0, 1, 2, 3, 500],
  "expected_names": ["Patch 000", "Patch 001", "Patch 002", "Patch 003", "Init"],
  "transcript": [ … ] }
```

One case must be the 512-slot proof: `"slots": [0 … 511]`, every name correct (transcript may be
omitted for this case — field `"transcript": null` — the assertion is the names).

**`expendable`** — analysis parity over synthetic records:

```json
{ "id": "census_basics", "threshold": 3,
  "records": [ { "slot": 0, "name": "A", "sha256": "…" },
               { "slot": 1, "name": null, "sha256": "…" },
               { "slot": 2, "name": "  ", "sha256": null } ],
  "expected_expendable": [5, 6, 7],
  "scratch": { "prefer_from": 500, "exclude": [510], "expected": 509 } }
```

`name: null` = name read failed; `sha256: null` = blob unread; `scratch.expected: null` = no pick.
Must cover: duplicated ≥ threshold, duplicated exactly threshold−1 (not expendable), blank-name
rule, failed-name-read + mass-duplicated blob (still expendable via content), `"Init"` name with a
*unique* blob (NOT expendable), scratch preference above/below `prefer_from`, exclusion.

**`sync_diff`** — pure diff parity:

```json
{ "id": "five_states", "threshold": 3,
  "records": [ { "slot": 0, "name": "A", "sha256": "…" }, … ],
  "library": [ { "slot": 0, "name": "A", "sha256": "…" }, … ],
  "expected": [ { "slot": 0, "status": "in_sync" }, { "slot": 1, "status": "added" },
                { "slot": 2, "status": "missing" }, { "slot": 3, "status": "changed" },
                { "slot": 4, "status": "empty" } ] }
```

`status` strings are the Python `SlotStatus` values: `"in_sync" | "added" | "missing" | "changed" | "empty"`.
Must cover all five states plus the error case `{ "id", "records_missing_hash": true, … }` variant:
a case whose records include a `sha256: null` and whose only expectation is
`"expected_error": "snapshot_missing_hashes"`.

### 2.5 Loading in Swift tests

The test target declares `resources: [.copy("Fixtures")]` (§3), so files land in
`Bundle.module` preserving the directory. One helper, used by every vector test:

```swift
// Tests/FreakCoreTests/Vectors.swift
enum Vectors {
    struct Envelope<Case: Decodable>: Decodable {
        let schema: Int          // must be 1; anything else -> XCTFail
        let kind: String
        let sim: SimSpec?
        let cases: [Case]
    }
    struct SimSpec: Decodable {
        let factoryFresh: Bool   // "factory_fresh"
        let initCopies: Int      // "init_copies"
        let seed: Int
        let replyLag: Bool       // "reply_lag"
    }
    /// Loads Fixtures/vectors/<name>.json from Bundle.module. Throws (fails the test) if
    /// missing, unparseable, schema != 1, or kind mismatch.
    static func load<Case: Decodable>(_ name: String, kind: String) throws -> Envelope<Case>
    /// "F0 00 20" -> Data([0xF0, 0x00, 0x20]); "" -> empty Data. Throws on malformed hex.
    static func data(fromHex hex: String) throws -> Data
    static func hex(from data: Data) -> String   // canonical uppercase space-separated
}
```

Decoding uses `JSONDecoder` with `keyDecodingStrategy = .convertFromSnakeCase` **off** — define
explicit `CodingKeys` matching the snake_case field names above, so a schema drift is a compile-time
or decode-time failure, never a silent nil.

---

## 3. Module layout

### 3.1 `FreakCore` — Swift package

```
ios/FreakCore/
  Package.swift
  Sources/FreakCore/
    Wire.swift                  # constants + pure codec           (port of protocol.py)
    Model.swift                 # Preset, SlotRecord, DeviceSnapshot, TimingReport,
                                #   WriteReport, ProgressEvent, NameInfo, ProgressReporter
    Errors.swift                # FreakError                       (port of errors.py)
    FreakTransport.swift        # the transport seam               (port of transport.py)
    FreakClock.swift            # FreakClock protocol + SystemClock
    Session.swift               # FreakSession actor               (port of session.py)
    Device.swift                # FreakDeviceProtocol + MicroFreakDevice (port of device.py)
    Backup.swift                # BackupSet + AtomicFile           (port of backup.py)
    Library.swift               # Library actor, LibraryEntry      (port of library.py)
    Sync.swift                  # computeDiff, SyncDiff, SlotDiff, SlotStatus (port of sync.py)
    Analysis.swift              # Analysis enum                    (port of analysis.py)
    SimulatedMicroFreak.swift   # the offline device — SHIPS IN THE LIBRARY TARGET
                                #   (practice mode links it; it is not test-only)
    SysEx7.swift                # pure UMP SysEx7 encode/reassemble — NO CoreMIDI import,
                                #   fully testable headless
    CoreMIDITransport.swift     # the ONE platform-specific file, entirely inside
                                #   #if canImport(CoreMIDI) ... #endif
  Tests/FreakCoreTests/
    Vectors.swift  VectorTests.swift
    WireTests.swift  SessionTests.swift  WriteSequenceTests.swift
    DeviceTests.swift  BackupRestoreTests.swift  LibraryTests.swift
    SyncTests.swift  AnalysisTests.swift  SimulatedFidelityTests.swift
    SysEx7Tests.swift  ConcurrencyTests.swift  TestClock.swift
    Fixtures/vectors/*.json     # §2
```

`Package.swift`, exactly:

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

`CoreMIDITransport.swift` compiles on macOS too (CoreMIDI exists there) — that is fine; the guard
exists for future non-Apple hosts, and tests simply never instantiate it.

### 3.2 `FreakLibrarian` — the app

```
ios/FreakLibrarian/
  project.yml                   # xcodegen; the app engineer owns everything below Sources/
  Sources/
    FreakLibrarianApp.swift
    ...                         # app-internal structure is the app engineer's to design,
                                # against the seam in §14 only
```

`project.yml` pinned essentials (the app engineer may add settings, never change these):

```yaml
name: FreakLibrarian
options:
  bundleIdPrefix: com.ericbrookfield
  deploymentTarget:
    iOS: "17.0"
packages:
  FreakCore:
    path: ../FreakCore
targets:
  FreakLibrarian:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - package: FreakCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ericbrookfield.freaklibrarian
        INFOPLIST_KEY_CFBundleDisplayName: "Freak Librarian"
        TARGETED_DEVICE_FAMILY: "2"          # iPad only
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
```

USB-C MIDI needs no Info.plist permission keys. Bluetooth MIDI is out of scope for v1.

---

## 4. Wire — constants and the pure codec (`Wire.swift`)

A caseless enum namespace. Pure and stateless; **no I/O anywhere**; seq is always an explicit
parameter — this module counts nothing.

```swift
public enum Wire {

    // MARK: constants (values identical to protocol.py)
    public static let prefix = Data([0xF0, 0x00, 0x20, 0x6B, 0x07, 0x01])
    public static let cmdOpen: UInt8      = 0x19   // name read (trailer 0x00) / dump open (0x01)
    public static let cmdNext: UInt8      = 0x18   // pull next (reads); device per-frame ack (writes)
    public static let cmdChunkMore: UInt8 = 0x16
    public static let cmdChunkLast: UInt8 = 0x17
    public static let cmdGo: UInt8        = 0x15   // seq 0, len 0, empty payload
    public static let cmdName: UInt8      = 0x52   // long: name+meta (35B); short [bank,pos,0x01]: open write

    public static let slots = 512
    public static let slotsPerBank = 128
    public static let highBankBoundary = 384       // REPLY payload[9]: 0 below, 1 at/above
    public static let writePayload9: UInt8 = 0x06  // payload[9] in every captured outbound long 0x52
    public static let replyMetaFlag: UInt8 = 0x10  // payload[3] bit, device replies only (slots >= 128)
    public static let blobSize = 4672              // 146 x 32
    public static let chunkSize = 32
    public static let chunkCount = 146
    public static let namePayloadLength = 35       // 12-byte header + 23-byte name
    public static let nameOffset = 12
    public static let nameLength = 23
    public static let metaLength = 9               // long-0x52 payload[3..11]
    public static let duplicateThreshold = 3       // content-based expendability (3, not 2)
    // NO_CHECKSUM: no checksum exists; nothing in this module computes one, ever.

    public struct Frame: Sendable, Equatable {
        public let raw: Data
        public let seq: UInt8
        public let length: UInt8
        public let cmd: UInt8
        public let data: Data                      // payload bytes (between cmd and F7)
    }

    // MARK: addressing
    /// slot (0-based) -> (bank, pos). Throws .slotOutOfRange outside 0..<512.
    public static func addr(_ slot: Int) throws -> (bank: UInt8, pos: UInt8)
    /// Inverse of addr. Throws .slotOutOfRange when the pair names no valid slot.
    public static func slot(bank: UInt8, pos: UInt8) throws -> Int

    // MARK: frame assembly
    /// One complete SysEx message F0..F7. Every body byte is masked & 0x7F.
    public static func frame(seq: UInt8, length: UInt8, cmd: UInt8,
                             data: some Sequence<UInt8>) -> Data

    // MARK: request builders (seq explicit, always)
    public static func readNameRequest(seq: UInt8, slot: Int) throws -> Data   // len 0x03, [bank,pos,0x00]
    public static func openDumpRequest(seq: UInt8, slot: Int) throws -> Data   // len 0x01, [bank,pos,0x01]
    public static func pullNextRequest(seq: UInt8) -> Data                     // len 0x01, [0x00]
    /// THE single composer of address-derived header bytes. Outbound payload:
    ///   [0]=bank [1]=pos [2]=0x00
    ///   [3]=meta[0] & ~replyMetaFlag   [4..7]=meta[1..4] verbatim
    ///   [8]=pos (recomputed; meta[5] ignored)
    ///   [9]=writePayload9 (constant 0x06; meta[6] ignored)
    ///   [10]=meta[7] [11]=meta[8]      [12..34]=name, ASCII, NUL-padded to 23
    /// Throws .invalidName, .slotOutOfRange, .protocolViolation (meta not 9 bytes / not 7-bit).
    public static func nameWriteFrame(seq: UInt8, slot: Int, name: String, meta: Data) throws -> Data
    public static func openWriteFrame(seq: UInt8, slot: Int) throws -> Data    // len 0x03, [bank,pos,0x01]
    public static func goFrame() -> Data                                       // seq 0, len 0, empty
    /// 145 x 0x16 + 1 x 0x17, 32 content bytes each, chunk i carrying seq (i+1) % 128 —
    /// wrapping THROUGH 0 (this function owns the write-burst seq stream). No address parameter,
    /// by design. Throws .blobSize on length != 4672; .protocolViolation on any byte > 0x7F
    /// (masking would silently alter content on the wire — reject instead).
    public static func chunkFrames(blob: Data) throws -> [Data]

    // MARK: parsers / helpers
    /// nil for non-MicroFreak traffic (short, wrong prefix, no F0/F7). Never throws.
    public static func parse(_ raw: Data) -> Frame?
    /// Decode a long-0x52 payload (reply or outbound). Throws .protocolViolation on wrong
    /// cmd/length or an out-of-range embedded address.
    public static func decodeNameReply(_ frame: Frame) throws -> NameInfo
    public static func isChunk(_ f: Frame) -> Bool          // 0x16 or 0x17
    public static func isLastChunk(_ f: Frame) -> Bool      // 0x17
    public static func isAck(_ f: Frame) -> Bool            // 0x18
    /// Concatenate chunk payloads; throws .blobSize unless the total is exactly 4672.
    public static func assembleBlob(_ chunks: [Frame]) throws -> Data
    /// Lowercase hex SHA-256 (CryptoKit).
    public static func digest(_ blob: Data) -> String
    /// <= 23 printable-ASCII chars, no leading/trailing whitespace (replies decode stripped,
    /// so such a name can never round-trip). Throws .invalidName. Returns nothing.
    public static func validateName(_ name: String) throws
}
```

Name decoding (inside `decodeNameReply`, private helper `decodeNameField(_ payload: Data) -> String`):
take `payload[12...]`, cut at the first NUL, keep only bytes `0x20...0x7E`, then trim leading and
trailing whitespace. This matches the Python `_decode_name` exactly and is asserted by the
`name_reply_decode` vectors.

`NameInfo` lives in `Model.swift`:

```swift
public struct NameInfo: Sendable, Equatable {
    public let slot: Int          // from payload[0..1] — the reply-lag matching key
    public let name: String
    public let meta: Data         // 9 bytes = payload[3..11], verbatim reply form
    public init(slot: Int, name: String, meta: Data)
}
```

---

## 5. Errors (`Errors.swift`)

One frozen enum mirroring `microfreak.errors`. Grouping (the Python class hierarchy) is expressed
as a computed `group` so callers can still catch coarsely.

```swift
public enum FreakError: Error, Equatable, Sendable {

    // -- protocol (Python ProtocolError subtree)
    case slotOutOfRange(slot: Int)
    case blobSize(expected: Int, actual: Int)
    case invalidName(reason: String)
    case protocolViolation(detail: String)          // Python's bare ProtocolError

    // -- transport
    /// Backend failure. `detail` embeds the underlying error's description (Swift can't
    /// carry an Equatable existential; adapters format the cause into the string).
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

public enum TimeoutStage: String, Sendable { case nameRead = "name_read", dump,
                                             nameWriteAck = "name_write_ack" }
public enum WriteStage: String, Sendable { case nameWrite = "name_write", open, go, chunk,
                                           finalRead = "final_read" }

public struct VerifyMismatch: Sendable, Equatable {
    public let slot: Int
    public let expectedSha256: String     // "" for a rename
    public let actualSha256: String?      // nil when the name already mismatched (no blob read)
    public let expectedName: String
    public let actualName: String?
    public let firstDifference: Int?      // first differing blob byte index, nil for name-only
    public let expectedLength: Int
    public let actualLength: Int
    public init(...)                      // memberwise
}

public extension FreakError {
    enum Group: Sendable { case protocolError, transport, transaction, write,
                           cancellation, storage, library, usage, composite }
    var group: Group { get }              // exhaustive switch over self
}

extension FreakError: LocalizedError {
    /// errorDescription mirrors the Python messages' information content (exact wording free).
    public var errorDescription: String? { get }
}
```

Rules:

- Nothing else escapes `FreakCore`'s public API: adapters catch every backend/`Foundation` error
  and rethrow `.transport(detail:)` / `.integrity` / `.libraryCorrupt` as appropriate. The one
  deliberate exception: `CancellationError` from structured concurrency is always translated to
  `.operationCancelled` before crossing a public boundary (§7, §9).
- `restoreFailed` wraps **any** `FreakError` thrown mid-restore, carrying the reports for slots
  already completed (the Python `.completed` attachment).

---

## 6. Models (`Model.swift`)

All `Sendable` value types mirroring the frozen dataclasses.

```swift
public struct Preset: Sendable, Equatable {
    public let name: String
    public let blob: Data          // exactly 4672 bytes, 7-bit clean
    public let meta: Data          // exactly 9 bytes, 7-bit clean, reply-form as read
    public let sha256: String      // computed once at init from blob

    /// Validates all three fields (name via Wire.validateName; blob 4672 bytes and 7-bit
    /// clean; meta 9 bytes and 7-bit clean — a byte > 0x7F would be silently masked on the
    /// wire, so it is rejected here). Throws .invalidName / .blobSize / .protocolViolation.
    public init(name: String, blob: Data, meta: Data) throws
    /// Copy with a new (validated) name. Same blob, same meta, same sha256.
    public func renamed(_ name: String) throws -> Preset
}

public struct SlotRecord: Sendable, Equatable {
    public let slot: Int
    public let name: String?       // nil = the name read FAILED (not blank)
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
    public init(...)
}

public struct DeviceSnapshot: Sendable, Equatable {
    public let takenAt: String                 // "yyyy-MM-dd'T'HH:mm:ss", local time
    public let records: [SlotRecord]           // ascending slot order, requested slots only
    public let timing: TimingReport
    public init(takenAt: String, records: [SlotRecord], timing: TimingReport)
    public func record(slot: Int) -> SlotRecord?
    public var hasHashes: Bool                 // every record carries a sha256
}

public struct WriteReport: Sendable, Equatable {
    public let slot: Int
    public let sha256: String        // of the blob sent; "" for a rename (no blob traffic)
    public let name: String
    public let verified: Bool?       // true = read back & matched; nil = verify skipped;
                                     // false NEVER occurs — a mismatch throws instead
    public let durationSeconds: Double
    public init(...)
}

public struct ProgressEvent: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let slot: Int
    public let name: String
    public let elapsedSeconds: Double
    public let etaSeconds: Double?   // median-based (§9 pins the math)
    public init(...)
}
```

### Progress and cancellation idioms

- **Cancellation is `Task` cancellation.** There is no `CancelToken` in the port. Long operations
  poll `Task.isCancelled` between slots and before each write chunk and throw
  `FreakError.operationCancelled(done:total:)`. Worst-case cancel latency is one dump/ack timeout,
  same as Python. Cancelling mid-write tears the slot; recovery is "write again".
- **Progress is an `AsyncStream`** delivered through one small type:

```swift
/// Create one, hand it to a long operation, iterate `events` from the UI.
/// Single-consumer. The operation calls finish() on every exit path (defer), so a UI
/// `for await` loop always terminates.
public final class ProgressReporter: Sendable {
    public let events: AsyncStream<ProgressEvent>
    /// bufferingNewest(1): the UI only ever wants the latest state; a slow consumer
    /// never backs up a 211-second backup.
    public init()
    public func report(_ event: ProgressEvent)   // called by FreakCore operations
    public func finish()
}
```

(Implementation: `AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))`, continuation
stored in a `let`. `AsyncStream.Continuation` is `Sendable`, so the class is cleanly `Sendable`
with only `let` storage.)

Usage pattern the app follows (normative example):

```swift
let progress = ProgressReporter()
let task = Task { try await device.backup(to: url, options: .init(), progress: progress) }
for await ev in progress.events { self.progressState = ev }   // ends when the op finishes
let backupSet = try await task.value
// Cancel button: task.cancel()  ->  op throws .operationCancelled(done:total:)
```

---

## 7. The transport seam (`FreakTransport.swift`, `FreakClock.swift`)

### 7.1 Decision: **async poll**

```swift
/// The only platform-specific seam. Byte movement and SysEx message-boundary reassembly,
/// nothing more: no parsing, filtering, matching, retries, or buffering policy above it.
/// Arrival order preserved; the transport buffers and never drops.
public protocol FreakTransport: Sendable {
    /// Transmit one complete SysEx message F0..F7, atomically. Throws .transport on
    /// backend failure (chained into `detail`).
    func send(_ message: Data) async throws
    /// Next complete inbound SysEx message (F0..F7, reassembled), or nil on timeout.
    /// timeout <= 0 means non-blocking: return a buffered message or nil immediately.
    /// Throws .transport on backend failure. Single-consumer: exactly one caller
    /// (the session) polls this; behavior with concurrent receivers is unspecified.
    func receive(timeout: TimeInterval) async throws -> Data?
    /// Release the backend. Idempotent. Subsequent send/receive throw .transport.
    func close() async
}
```

Justification (the two sentences): the Python core's three state machines are single-consumer
*pull* loops, and keeping `receive(timeout:)` ports them — and `SimulatedMicroFreak`'s inline
synchronous semantics — verbatim, with one outstanding request by construction. The methods are
`async` (rather than blocking) because CoreMIDI's push callback then only has to bridge into an
awaitable inbox and, under Swift 6 strict concurrency, blocking a cooperative-pool thread for up to
a 1.5 s timeout is not acceptable.

Discovery is a per-backend factory concern (static methods on the concrete transports), not part
of the protocol.

### 7.2 Clock injection

The session's timeout state machines must be testable without real time:

```swift
public protocol FreakClock: Sendable {
    /// Monotonic seconds. Only differences are meaningful.
    var now: TimeInterval { get }
    /// Suspend ~seconds. Must NOT swallow cancellation: on task cancellation it may
    /// either throw CancellationError or return early — callers re-check deadlines.
    func sleep(for seconds: TimeInterval) async throws
}

/// ContinuousClock-backed default.
public struct SystemClock: FreakClock {
    public init()
}
```

Tests use `TestClock` (test target only): `now` returns a stored value; `sleep` advances it by the
requested amount and returns immediately — so a full lagged-read retry cycle costs zero wall time.

---

## 8. FreakSession (`Session.swift`) — the reply-lag chokepoint

### 8.1 Decision: **actor, with an explicit FIFO transaction gate**

`FreakSession` is an `actor`. Actor isolation gives data-race freedom under Swift 6 with no
`@unchecked` anything — but actor **reentrancy** would let a second caller interleave at any
`await` inside a write burst, which is exactly the catastrophe the Python lock prevents (chunk
streams are unaddressed and unmatchable). So every public method runs its body inside a
non-reentrant FIFO gate; "one transaction at a time" is enforced by construction, and
`ConcurrencyTests` proves it (two concurrent `writePreset`s against the sim → zero sim `faults`,
transcripts strictly sequential).

```swift
public struct SessionConfig: Sendable {
    public var nameTimeout: TimeInterval = 1.0
    public var dumpTimeout: TimeInterval = 1.5
    public var ackTimeout: TimeInterval = 1.0
    public var nameRetries: Int = 3
    public var pollInterval: TimeInterval = 0.002   // sleep between empty receive polls
    public init()
}

public actor FreakSession {
    public init(transport: any FreakTransport,
                config: SessionConfig = SessionConfig(),
                clock: any FreakClock = SystemClock())

    // The four public operations. Each acquires the transaction gate for its whole body.
    public func readName(slot: Int) async throws -> NameInfo
    public func readBlob(slot: Int) async throws -> Data
    /// The gate-verified 7-frame write sequence, verbatim from write-protocol.md.
    /// Returns frame 7's read-back NameInfo — comparison is the caller's job (the frame
    /// itself is protocol fidelity and always sent). Polls Task.isCancelled before each
    /// chunk; throws .operationCancelled(done: chunkIndex, total: 146) — tearing the slot.
    public func writePreset(slot: Int, preset: Preset) async throws -> NameInfo
    /// Rename-in-place, exactly what MCC sends: long 0x52 (awaiting the device's 0x18 ack;
    /// absence -> .deviceTimeout(stage: .nameWriteAck, slot:)) + a refresh read. No blob traffic.
    public func writeName(slot: Int, name: String, meta: Data) async throws -> NameInfo
    public func close() async

    // -- private, but their semantics are normative --

    /// Addressed-request seq counter: `seq = seq % 127 + 1` -> 1..127, wrapping, NEVER 0.
    /// (0 appears on the wire only in the go frame; the chunk stream is Wire.chunkFrames'.)
    private var seq: UInt8

    /// Non-reentrant FIFO gate: `busy: Bool` + `waiters: [CheckedContinuation<Void, Never>]`.
    /// acquire() suspends while busy (FIFO resume order); release() resumes the head waiter.
    /// Cancellation while queued: the waiter still acquires, then the op's first
    /// Task.checkCancellation / isCancelled poll exits it promptly.
    private func withTransaction<T: Sendable>(_ body: () async throws -> T) async throws -> T

    /// THE reply-lag chokepoint — the only code in the package that inspects a 0x52 reply.
    private func transactAddressed(request: Data, slot: Int) async throws -> NameInfo

    private func drain() async throws              // while receive(timeout: 0) != nil {}
    private func nextFrame(within: TimeInterval) async throws -> Wire.Frame?
    private func awaitAck() async throws -> Bool   // device 0x18 within ackTimeout
}
```

### 8.2 `transactAddressed` — normative algorithm

The only function allowed to decode a long-0x52 reply. Every 0x52 inspection in the package —
`readName`, `writeName`'s read-back, `writePreset`'s frames 1 and 7 — routes through it, so the
reply-lag bug cannot be reintroduced without deleting it.

1. `drain()` all stale inbound frames.
2. For attempt in `1...config.nameRetries`:
   a. `send(request)`. Set `deadline = clock.now + nameTimeout`.
   b. Loop: `nextFrame(within: remaining)`. On nil / deadline passed → silent attempt; go to next
      attempt (resend).
   c. Ignore any frame that is not a long 0x52 (`cmd != 0x52 || data.count != 35`) — unrelated
      traffic; keep waiting.
   d. `decodeNameReply` — on `.protocolViolation` (e.g. out-of-range embedded address) ignore and
      keep waiting.
   e. Reply's embedded slot == requested slot → **return** it.
   f. Otherwise it is stale (lagged): record `repliedSlot`, note `sawReply = true`, break the
      inner loop and resend immediately (counts as one attempt).
3. Attempts exhausted: `sawReply` → throw
   `.replyMismatch(requestedSlot:repliedSlot:attempts: nameRetries)`; total silence → throw
   `.deviceTimeout(stage: .nameRead, slot:)`.

`nextFrame(within:)` loops until the deadline: `receive(timeout: remaining)`; a nil before the
deadline sleeps `clock.sleep(for: pollInterval)` and retries (the sim returns nil immediately —
this is what keeps the poll from spinning hot); a raw message that fails `Wire.parse` is skipped.

Known, documented limitation (verbatim from the Python): when two consecutive reads target the
SAME slot (write's frames 1 and 7; a rename's read-back), a lagged reply to the first is
indistinguishable from the answer to the second. Blob-hash verification covers writes; renames
retain the window. No protocol-level fix exists — replies carry no request id. Do not "improve"
this.

### 8.3 `readBlob` — dump state machine

Strict lockstep, one outstanding request:

1. `drain()`. Send `openDumpRequest(seq: next, slot:)`.
2. Loop:
   a. First sweep anything already delivered without blocking (`receive(timeout: 0)`), appending
      chunk frames (ignore non-chunks), stopping at a 0x17 or at 146 collected.
   b. A 0x17 seen → `assembleBlob` (throws `.blobSize` unless exactly 4672) and return.
   c. 146 chunks with no 0x17 → throw `.protocolViolation("… chunks without a 0x17 terminator")`.
   d. Send `pullNextRequest(seq: next)`. Await the next chunk within `dumpTimeout`, discarding
      every non-chunk frame as stale; timeout → `.deviceTimeout(stage: .dump, slot:)`. Append; a
      0x17 → assemble and return.

### 8.4 `writePreset` — the 7-frame sequence with ack accounting

`Wire.chunkFrames(blob:)` is built **first** (validates size/7-bit up front, outside the gate).
Then, inside the transaction:

| # | action | on failure |
|---|--------|-----------|
| 1 | `transactAddressed(readNameRequest)` — result discarded (fidelity to MCC) | its own errors propagate unwrapped |
| 2 | send `nameWriteFrame`; `awaitAck()` | no ack → `.writeAborted(.nameWrite, slot, chunksSent)` |
| 3 | send `openWriteFrame`; `awaitAck()` | → `.writeAborted(.open, …)` |
| 4 | send `goFrame()` (seq 0); `awaitAck()` | → `.writeAborted(.go, …)` |
| 5–6 | for each of the 146 chunks: poll `Task.isCancelled` → `.operationCancelled(done: i, total: 146)`; send; `chunksSent += 1`; `awaitAck()` or `.chunkNotAcked(slot, chunkIndex: i)` | |
| 7 | `transactAddressed(readNameRequest)`; return its NameInfo | timeout/mismatch/transport → `.writeAborted(.finalRead, slot, chunksSent)` |

Error wrapping mirrors the Python exactly: `.chunkNotAcked`, `.operationCancelled`, and
`.writeAborted` pass through untouched; a `.transport` or protocol-group error inside stages 2–6 is
wrapped as `.writeAborted(stage:slot:chunksSent:)`. The three control-frame acks (2–4) are consumed
*before* the chunk loop, so ack *N* in the loop really is the ack for chunk *N* — flow control
stays in lockstep (a writer pairing acks with chunks only would run three ahead; the device acks
every write frame).

`awaitAck()` waits up to `ackTimeout` for any frame with `cmd == 0x18`, discarding everything else
as stale; returns false on timeout.

---

## 9. FreakDeviceProtocol and MicroFreakDevice (`Device.swift`)

### 9.1 The app-facing seam

The app holds `any FreakDeviceProtocol` and never learns whether it is hardware or the simulator.

```swift
public struct SnapshotOptions: Sendable {
    public var readBlobs: Bool = true     // false = fast names-only pass (sha256 nil)
    public var keepBlobs: Bool = false    // true required for Library.importSnapshot
    public var slots: [Int]? = nil        // nil = all; sorted ascending before use
    public init()
}

public struct BackupOptions: Sendable {
    public var slots: [Int]? = nil
    public var resume: Bool = false       // skip slots already on disk with an index entry
    public init()
}

public protocol FreakDeviceProtocol: Sendable {
    var slotCount: Int { get }

    // reads
    func name(slot: Int) async throws -> String                       // ~1 ms on hardware
    func read(slot: Int) async throws -> Preset                       // ~400 ms on hardware
    func snapshot(options: SnapshotOptions,
                  progress: ProgressReporter?) async throws -> DeviceSnapshot

    // writes (verified by default via the extension overloads)
    func write(slot: Int, preset: Preset, verify: Bool) async throws -> WriteReport
    func rename(slot: Int, name: String, verify: Bool) async throws -> WriteReport

    // backup / restore
    func backup(to dest: URL, options: BackupOptions,
                progress: ProgressReporter?) async throws -> BackupSet
    func restore(from source: BackupSet, slots: [Int]?, verify: Bool,
                 progress: ProgressReporter?) async throws -> [WriteReport]

    func close() async
}

/// Default-argument overloads (protocols cannot declare defaults).
public extension FreakDeviceProtocol {
    func snapshot() async throws -> DeviceSnapshot                    // options: .init(), progress: nil
    func snapshot(options: SnapshotOptions) async throws -> DeviceSnapshot
    func write(slot: Int, preset: Preset) async throws -> WriteReport // verify: true
    func rename(slot: Int, name: String) async throws -> WriteReport  // verify: true
    func backup(to dest: URL) async throws -> BackupSet
    func restore(from source: BackupSet) async throws -> [WriteReport] // all covered, verify: true
}
```

### 9.2 The implementation

```swift
public final class MicroFreakDevice: FreakDeviceProtocol, Sendable {
    public let slotCount: Int
    public let session: FreakSession          // escape hatch, mirrors Python .session
    public init(transport: any FreakTransport,
                slotCount: Int = Wire.slots,
                config: SessionConfig = SessionConfig(),
                clock: any FreakClock = SystemClock())
}
```

All stored properties are `let`s of `Sendable` types → clean `Sendable` conformance; per-operation
mutable state (timings, records) is method-local.

Normative behaviors (each mirrors device.py exactly):

- **`read`**: `readName` then `readBlob`; `Preset(name: info.name, blob: blob, meta: info.meta)`.
- **`snapshot`**: iterate the sorted requested slots. Per slot: poll `Task.isCancelled` →
  `.operationCancelled(done:total:)` (no partial snapshot is ever returned). Name read failures
  of kind `.deviceTimeout` / `.replyMismatch` are swallowed → record gets `name: nil, meta: nil`
  (everything else propagates). If `readBlobs`: `readBlob` (errors propagate), `sha256 = digest`,
  keep bytes only when `keepBlobs`. Timing: name and dump durations in ms; per-slot durations for
  the ETA. Progress event after each slot: `done = index + 1`, `name = record.name ?? ""`,
  `etaSeconds = median(durations) * (total − done)`. `median(xs)` is the Python `_median` order
  statistic: `sorted(xs)[xs.count / 2]` (upper median, unrounded here). Final `TimingReport`:
  `totalSeconds` rounded to 3 decimals, `perSlotSeconds = elapsed / max(total, 1)` rounded to 4,
  `nameMsMedian` / `dumpMsMedian` = median rounded to 1 decimal, nil when no samples.
  `takenAt` = local time `"yyyy-MM-dd'T'HH:mm:ss"` (formatter: `en_US_POSIX`, current time zone).
- **`write`**: `session.writePreset`. If `verify` (default true via overload): read-back name must
  equal `preset.name` else throw `.verifyMismatch(VerifyMismatch(slot:, expectedSha256: preset.sha256,
  actualSha256: nil, expectedName:, actualName: info.name, firstDifference: nil,
  expectedLength: 4672, actualLength: 0))`; then `readBlob`, digest-compare — mismatch computes
  `firstDifference` (first differing index, else `min(count, count)`) and throws with both lengths.
  Success → `verified: true`. `verify: false` → `verified: nil`. Never `false`.
- **`rename`**: `Wire.validateName` first; `readName` for current meta; `session.writeName`;
  verify compares read-back name only (throws `.verifyMismatch` with `expectedSha256: ""`,
  lengths 0/0). Report has `sha256: ""`.
- **`backup`**: creates `dest/presets/`; loads an existing `index.json` if present (adding missing
  `presets`/`timing` keys) else starts
  `{"created": now, "slots": slotCount, "presets": {}, "timing": {}}`. Per slot (sorted): cancel
  poll; skip when `options.resume` && `presets/NNN.bin` exists && index has the `"N"` key; read
  name (**not** swallowed here — a backup wants to know), read blob, write `NNN.bin`
  (zero-padded 3 digits), set index entry `{"slot": n, "name": …, "bytes": 4672, "sha256": …,
  "meta_hex": …}`, atomically rewrite `index.json` — **each slot is on disk before the next is
  read**, so interruption leaves valid partial state. After the loop: write the `timing` object
  (`per_slot_seconds` divides by the number of slots actually read this pass) and return
  `BackupSet.load(dest)`. Reads only; never writes to the device.
- **`restore`**: `slots ?? source.coveredSlots()`, sorted. Per slot: cancel poll; `source.preset`;
  `write`. **Any** `FreakError` (the cancellation included) is rethrown as
  `.restoreFailed(underlying:, completed: reports)` — a failing write path must not keep writing.
  Progress after each success.
- All long ops call `progress?.report(…)` per slot and `progress?.finish()` in a `defer`.

---

## 10. Backup and Library on disk (`Backup.swift`, `Library.swift`)

**Interop is a hard requirement**: a library or backup written on the iPad opens unchanged in the
Python core and vice versa. "Identical format" means identical file layout, file names, JSON keys,
value types, and value encodings — not byte-identical JSON (key order and whitespace are free;
both sides' parsers ignore them). Pinned encodings:

- JSON files are UTF-8. Swift writes with `JSONSerialization` options
  `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`. All strings in these schemas are ASCII
  by construction (names are validated printable-ASCII), so Python's `ensure_ascii` never matters.
- `meta_hex`: 18 lowercase hex chars (9 bytes). `sha256`: 64 lowercase hex chars.
- Entry `id`: **uuid4 hex, lowercase, 32 chars, NO hyphens** — `UUID().uuidString` must be
  lowercased with hyphens removed before writing. (Python `uuid.uuid4().hex`.)
- Timestamps (`created`, `added_at`): `"yyyy-MM-dd'T'HH:mm:ss"`, local time, no fraction, no zone.
- `slot: null` is written explicitly for an unassigned entry (readers also accept an absent key).
- Numbers: integers where Python writes ints; timing floats may serialize with any precision —
  readers accept int or float.
- Atomic writes: temp file in the same directory + atomic rename
  (`FileManager.replaceItemAt` or `rename(2)` semantics) — readers never see a torn index. Helper:

```swift
enum AtomicFile {   // internal
    /// Write text via temp file + atomic replace. Throws .integrity on failure.
    static func write(_ data: Data, to url: URL) throws
}
```

### 10.1 Backup format (phase-0, byte-compatible with `mfcap backup`)

```
<dest>/
  index.json      {"created": "2026-09-01T12:00:00", "slots": 512,
                   "presets": {"<slot as decimal string>": {"slot": int, "name": str,
                               "bytes": int, "sha256": str, "meta_hex": str}},
                   "timing": {"total_seconds": num, "per_slot_seconds": num,
                              "name_ms_median": num|null, "dump_ms_median": num|null}}
  presets/NNN.bin 4672-byte raw blob, zero-padded 3-digit slot number ("042.bin")
```

`meta_hex` is additive over phase-0: an old index without it still loads — its records carry
`meta: nil` and stay usable for diff/analysis — but `preset(slot:)` on such a slot throws
`.integrity(path:, detail: "no meta recorded; re-backup to restore this slot")`.

```swift
public struct BackupSet: Sendable {
    public let path: URL
    public let createdAt: String
    public let timing: TimingReport

    /// Load and verify: re-hashes EVERY blob file against its recorded sha256.
    /// First bad slot -> .integrity naming it; missing blob file -> .integrity;
    /// unparseable index / missing "presets" table -> .libraryCorrupt.
    /// Synchronous file IO; callers off the main thread wrap it in a Task.
    public static func load(_ path: URL) throws -> BackupSet

    public func covers(_ slot: Int) -> Bool          // entry exists AND has a sha256
    public func coveredSlots() -> [Int]              // ascending
    /// Reads NNN.bin lazily. .slotOutOfRange when not covered; .integrity when meta_hex
    /// is absent (see above). name nil in the index -> "".
    public func preset(_ slot: Int) throws -> Preset
    /// name + sha + meta per indexed slot; blob always nil (lazy).
    public func records() -> [SlotRecord]
}
```

Creation goes through `MicroFreakDevice.backup` only — there is no `BackupSet.create`. One
mutation path.

### 10.2 Library format

```
<root>/
  index.json          {"schema": 1, "entries": [{"id": str, "name": str, "sha256": str,
                       "meta_hex": str, "slot": int|null, "added_at": str, "tags": [str]}]}
  blobs/<sha256>.bin  content-addressed 4672-byte blobs (269 factory Inits cost one file)
```

```swift
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let id: String            // uuid4 hex; minted at add(); survives renames
    public let name: String
    public let sha256: String
    public let metaHex: String       // 18 hex chars, round-trips Preset.meta
    public let slot: Int?            // desired device slot; at most one entry per slot
    public let addedAt: String
    public let tags: [String]
}

public actor Library {
    public nonisolated let root: URL

    /// Create a NEW library. Throws .libraryExists if root already holds an index.json
    /// (creating over an existing library would orphan its blobs).
    public static func create(at root: URL) throws -> Library
    /// Open an existing one. Missing index.json -> .libraryNotFound (open-or-create idiom:
    /// catch it and call create). Unreadable/malformed/unsupported-schema -> .libraryCorrupt.
    public static func open(at root: URL) throws -> Library

    // reads
    public func entries() -> [LibraryEntry]
    public func entry(id: String) throws -> LibraryEntry          // .entryNotFound
    /// Re-hashes the blob file against its filename on EVERY get; .integrity on rot
    /// or a missing blob file.
    public func get(id: String) throws -> Preset
    public func findBySha(_ sha256: String) -> [LibraryEntry]
    public func hasBlob(_ sha256: String) -> Bool
    public func slotMap() -> [Int: LibraryEntry]

    // writes (index rewritten atomically after each)
    /// Blob file written iff absent; ALWAYS a new entry (two entries may share one blob
    /// sha under different names). Assigning a slot clears any other entry's claim first.
    public func add(_ preset: Preset, slot: Int? = nil,
                    tags: [String] = []) throws -> LibraryEntry   // .slotOutOfRange
    public func renameEntry(id: String, to name: String) throws -> LibraryEntry  // validates name
    /// Deletes the entry; the blob file is deleted only when no remaining entry references it.
    public func remove(id: String) throws
    public func assignSlot(id: String, slot: Int?) throws
    /// Bulk-import. Requires kept blobs (else .snapshotMissingBlobs). Skips: expendable
    /// slots (when skipExpendable), records with meta == nil (name read failed — cannot
    /// round-trip), and records whose (sha256, name) pair already exists (name nil -> "").
    /// Each imported entry is assigned its source slot. Returns entries actually added.
    public func importSnapshot(_ snapshot: DeviceSnapshot,
                               skipExpendable: Bool = true,
                               threshold: Int = Wire.duplicateThreshold) throws -> [LibraryEntry]
}
```

Single-writer assumption; no cross-process locking — same as Python. On iPad the library root is
`Documents/Library/`, backups are `Documents/Backups/<yyyy-MM-dd-HHmmss>/` (visible in the Files
app via the app's Info.plist `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` — the app
engineer sets both to YES so Eric can move libraries between iPad and Mac).

---

## 11. Sync diff and analysis (`Sync.swift`, `Analysis.swift`)

```swift
public enum SlotStatus: String, Sendable, CaseIterable {
    case inSync = "in_sync"       // assigned entry's sha == device sha
    case deviceOnly = "added"     // non-expendable on device, no assigned entry
    case libraryOnly = "missing"  // entry assigned, device slot expendable
    case differs = "changed"      // both real, shas differ
    case empty = "empty"          // device slot expendable, nothing assigned
}

public struct SlotDiff: Sendable, Equatable {
    public let slot: Int
    public let status: SlotStatus
    public let device: SlotRecord?
    public let library: LibraryEntry?
}

public struct SyncDiff: Sendable, Equatable {
    public let slots: [SlotDiff]                    // one per snapshot record, ascending
    public func byStatus(_ status: SlotStatus) -> [SlotDiff]
}

/// Pure and deterministic; computes and never writes. Every considered record must carry
/// a sha256 — else .snapshotMissingHashes (refusing beats guessing). Per record, with
/// ex = slot in findExpendable(records, threshold:) and lib = slotMap[slot]:
/// no lib && ex -> .empty; no lib -> .deviceOnly; sha == lib.sha256 -> .inSync;
/// ex -> .libraryOnly; else -> .differs.
public func computeDiff(snapshot: DeviceSnapshot,
                        slotMap: [Int: LibraryEntry],
                        threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff

public extension Library {
    /// Convenience: computeDiff(snapshot:, slotMap: slotMap(), threshold:).
    func diff(against snapshot: DeviceSnapshot,
              threshold: Int = Wire.duplicateThreshold) throws -> SyncDiff
}
```

The core never auto-writes from a diff; executing one is the app composing `write`/`add` calls.

```swift
public enum Analysis {
    /// How many slots hold each blob hash; records without a hash are skipped.
    public static func shaCensus(_ records: [SlotRecord]) -> [String: Int]
    /// Expendable = successfully-read blank/whitespace name, OR sha256 occurring
    /// >= threshold times among `records`. NEVER a name == "Init" match. Unknown never
    /// qualifies: sha nil disqualifies the duplicate rule; name nil disqualifies the
    /// blank rule (the rules stay independent — a name-read-failed slot with a
    /// mass-duplicated blob is still expendable).
    public static func findExpendable(_ records: [SlotRecord],
                                      threshold: Int = Wire.duplicateThreshold) -> Set<Int>
    /// Highest expendable slot >= preferFrom, else highest expendable overall, else nil
    /// (the caller asks the human). Exactly the proven phase-0 semantics.
    public static func pickScratchSlot(_ records: [SlotRecord],
                                       preferFrom: Int = 500,
                                       exclude: Set<Int> = []) -> Int?
}
```

## 11b. SimulatedMicroFreak (`SimulatedMicroFreak.swift`)

An **actor** implementing `FreakTransport`, in the **library** target — practice mode links it.
Faithful port of `transports/simulated.py`; its wire behavior is asserted both by
`SimulatedFidelityTests` and, transitively, by every transcript vector (§2).

```swift
public struct WireLogEntry: Sendable, Equatable {
    public enum Direction: String, Sendable { case out, `in` }   // host convention:
    public let direction: Direction                              // out = host->device
    public let raw: Data
}

public actor SimulatedMicroFreak: FreakTransport {
    public init(slots: Int = Wire.slots, replyLag: Bool = true, failChunkAt: Int? = nil)

    /// The reference device's shape: (slots - initCopies) named pseudo-presets in the low
    /// slots, then initCopies identical "Init" blobs; meta positionally correct including
    /// the payload[9] flip at slot 384 and the 0x10 reply bit at slot >= 128.
    public static func factoryFresh(initCopies: Int = 269, seed: Int = 0,
                                    slots: Int = Wire.slots, replyLag: Bool = true,
                                    failChunkAt: Int? = nil) -> SimulatedMicroFreak

    // test/practice back doors
    public func load(slot: Int, preset: Preset)      // preconditionFailure on bad slot
    public func peek(slot: Int) throws -> Preset
    public func faults() -> [String]                 // protocol violations observed
    public func wireLog() -> [WireLogEntry]

    // FreakTransport: send() runs the device state machine inline; receive() pops the
    // FIFO outbox, returning nil IMMEDIATELY when empty regardless of timeout (no real
    // waiting — offline tests are instant; the session's clock handles pacing).
    public func send(_ message: Data) async throws
    public func receive(timeout: TimeInterval) async throws -> Data?
    public func close() async
}
```

Normative behaviors (each mirrors simulated.py; fault *strings* need not match Python verbatim,
fault *conditions* must):

- **Name read (0x19 trailer 0x00):** with `replyLag` (the default — every offline test exercises
  the defense) the reply to read N is held and emitted only when read N+1 arrives; the first read
  yields nothing. The held reply is **rendered from device state at emission time** (a lagged
  device is slow, not wrong) and echoes *its own request's* seq. Deliberately harsher than
  hardware — never tune real-time behavior against it. Without lag, reply immediately.
- **Reply payload:** `[bank, pos, 0x00] + meta(9, reply form) + name NUL-padded to 23`.
- **Dump (0x19 trailer 0x01, then 0x18 pulls):** each pull emits the next 32-byte chunk (0x16, or
  0x17 for chunk 145) echoing the pull's seq. A pull without an open dump → fault.
- **Long 0x52 in:** updates name+meta unconditionally (a rename is only this frame), stores meta
  re-derived in reply form via `positionalMeta`, acks with a device-shape 0x18. Validations → the
  outbound-write convention: `payload[2] == 0x00`, `payload[8] == pos`, `payload[9] == 0x06`,
  `payload[3] & 0x10 == 0`; each deviation appends a fault (state still updates).
- **Short 0x52 `[bank,pos,0x01]`:** opens a write (fault if one is pending), acks.
- **0x15 go:** arms an open, un-armed write, acks; otherwise fault, no ack.
- **Chunks:** each increments a **cumulative lifetime** chunk counter (for `failChunkAt`). A chunk
  without an open+armed write → fault, no ack, slot untouched. Otherwise append payload to the
  buffer; ack unless `failChunkAt != nil && counter-index >= failChunkAt` (that chunk and every
  later one get no ack — drives `.chunkNotAcked` and torn-write tests; use a fresh sim per torn
  scenario). A 0x17 commits: exactly 4672 buffered bytes → slot blob replaced; anything else →
  fault, **slot untouched** (a broken writer fails verification instead of passing).
- **Device ack shape:** `Wire.frame(seq: ackedFrame.seq, length: 0x00, cmd: 0x18, data: [])`.
- **Unparseable/unknown frames** → fault.

Bit-exact algorithms (required for transcript-vector parity):

```
synthBlob(seed, label): out = []; counter = 0
  while out.count < 4672:
    h = SHA256("\(seed):\(label):\(counter)".utf8)          // 32 bytes
    out += h.map { $0 & 0x7F }; counter += 1
  return out.prefix(4672)

positionalMeta(slot, opaque5, category, attribute):
  m = opaque5 padded/truncated to 5 bytes
  m[0] &= ~0x10;  if slot >= 128 { m[0] |= 0x10 }
  return m + [pos, (slot < 384 ? 0 : 1), category & 0x7F, attribute & 0x7F]

factoryFresh(initCopies, seed): named = slots - initCopies; initBlob = synthBlob(seed, "init")
  slot < named:  name "Patch %03d" % slot, blob synthBlob(seed, "slot\(slot)"),
                 opaque5 [(slot*3) % 0x20, 0,0,0,0], category slot % 0x0C,
                 attribute (slot even ? 0x32 : 0x33)
  slot >= named: name "Init", blob initBlob, opaque5 [0x08,0,0,0,0],
                 category 0x00, attribute 0x33
  every slot's meta via positionalMeta

load(slot, preset): stored meta = positionalMeta(slot, meta[0..<5], meta[7], meta[8])
```

---

## 12. CoreMIDITransport (`SysEx7.swift` + `CoreMIDITransport.swift`)

### 12.1 Pure layer — `SysEx7.swift` (no CoreMIDI import; fully unit-tested headless)

CoreMIDI on iOS 17 is used through the UMP APIs (`MIDIInputPortCreateWithProtocol`,
`MIDISendEventList`) with MIDI protocol 1.0. In UMP, SysEx travels as 64-bit **SysEx7** packets
(message type 0x3): status nibble `0 = complete, 1 = start, 2 = continue, 3 = end`, a byte-count
nibble (0–6), and up to six 7-bit data bytes per packet. The F0/F7 framing bytes are **not**
carried in UMP data — the adapter strips them on send and restores them on receive.

```swift
public enum SysEx7 {
    /// One complete SysEx message (F0..F7) -> UMP words, group 0. Payload (the bytes
    /// between F0 and F7) is split into 6-byte groups: a single group emits status
    /// "complete"; otherwise "start", then "continue"*, then "end". Each SysEx7 packet
    /// is two UInt32 words (big-endian field order per the UMP spec).
    /// Throws .protocolViolation when `message` lacks F0/F7 framing or any inner byte > 0x7F.
    public static func encode(_ message: Data) throws -> [UInt32]

    /// Streaming reassembler — a value-type state machine, one instance per source.
    public struct Assembler: Sendable {
        public init()
        /// Feed one 64-bit SysEx7 packet. Returns a complete F0..F7 message when this
        /// packet finishes one, else nil. Never throws: malformed input drops state.
        public mutating func consume(word0: UInt32, word1: UInt32) -> Data?
        public mutating func reset()
    }
}
```

Assembler state machine (normative):

| state | event (status nibble) | action → next state |
|---|---|---|
| idle | complete (0) | emit `F0 + bytes + F7` → idle |
| idle | start (1) | buffer = bytes → assembling |
| idle | continue (2) / end (3) | drop (orphan fragment) → idle |
| assembling | start (1) | discard old buffer, buffer = bytes → assembling |
| assembling | continue (2) | append → assembling |
| assembling | end (3) | append, emit `F0 + buffer + F7` → idle |
| assembling | complete (0) | discard old buffer, emit this one → idle |
| any | mt != 0x3 | ignore packet, state unchanged |
| assembling | buffer > 8 KiB | drop buffer → idle (runaway guard; largest real frame is 45 bytes) |

Byte-count nibble governs how many of the six data bytes are read; out-of-range counts (7+) drop
the packet.

### 12.2 Platform layer — `CoreMIDITransport.swift`, entirely inside `#if canImport(CoreMIDI)`

```swift
#if canImport(CoreMIDI)
import CoreMIDI

public struct MIDIEndpointInfo: Sendable, Equatable {
    public let name: String              // display name (kMIDIPropertyDisplayName)
    public let uniqueID: Int32           // kMIDIPropertyUniqueID — stable reconnect key
}

public final class CoreMIDITransport: FreakTransport, Sendable {
    public static let defaultHints = ["microfreak"]      // case-insensitive substring match

    /// Enumerate current sources and destinations. Never throws; safe on any thread.
    public static func endpoints() -> (sources: [MIDIEndpointInfo],
                                       destinations: [MIDIEndpointInfo])

    /// Discover-and-open: first source AND destination whose display name contains any
    /// hint (case-insensitive) and does not contain `exclude` (skips mfcap's own virtual
    /// proxy ports). No match -> .deviceNotFound(inputs:outputs:) listing every endpoint
    /// seen. Backend failure -> .transport.
    public static func open(hints: [String] = defaultHints,
                            exclude: String = "mfcap") throws -> CoreMIDITransport

    /// Explicit picker by endpoint identity (from endpoints()).
    public static func open(source: MIDIEndpointInfo,
                            destination: MIDIEndpointInfo) throws -> CoreMIDITransport

    public func send(_ message: Data) async throws
    public func receive(timeout: TimeInterval) async throws -> Data?
    public func close() async
}
#endif
```

Lifecycle and internals (normative):

- **One `MIDIClientRef` per transport instance**, created in the opener via
  `MIDIClientCreateWithBlock`, disposed in `close()` (which also unconnects and disposes the
  ports). All CoreMIDI refs are assigned once during open and stored as `let`s — that plus the
  lock-guarded inbox is what makes the class honestly `Sendable`.
- **Input**: `MIDIInputPortCreateWithProtocol(client, "FreakCore.in", ._1_0, receiveBlock)`,
  connected to the chosen source. The receive block runs on a CoreMIDI-owned thread; it walks the
  `MIDIEventList` packets word-by-word, feeds each 64-bit SysEx7 packet to the per-source
  `SysEx7.Assembler`, and pushes each completed `F0..F7` message into the **Inbox**. Non-SysEx7
  UMP traffic is ignored.
- **Inbox** (internal final class): an `OSAllocatedUnfairLock`-guarded state struct holding a
  FIFO `[Data]` plus at most one parked `CheckedContinuation<Data?, Never>` (single consumer).
  `push`: if a receiver is parked, resume it with the message, else append. `pop(timeout:)`:
  buffered → return immediately; `timeout <= 0` → return nil immediately; otherwise park a
  continuation and start a timeout `Task` (using `ContinuousClock`) that resumes it with nil if
  nothing arrives first — whichever side resumes first wins under the lock, the loser is a no-op.
  `close()` resumes any parked receiver with nil and rejects further pushes. If holding the
  assembler inside the receive block closure requires a mutable capture, wrap assembler + queue in
  the same lock; the only permitted `@unchecked Sendable` in the package is this Inbox **iff**
  `OSAllocatedUnfairLock` generics prove insufficient, and it must carry the comment
  `// invariant: all mutable state accessed only under `lock``.
- **Send**: `SysEx7.encode(message)` → one `MIDIEventList` (build with `MIDIEventListAdd`,
  protocol `._1_0`) → `MIDISendEventList(outPort, destination, &list)`. Any OSStatus != noErr →
  `.transport(detail: "MIDISendEventList: \(status)")`. Messages here are ≤ 45 bytes — one event
  list always suffices (spec the builder to iterate for safety anyway).
- **Errors**: every OSStatus failure and every unexpected condition becomes `.transport(detail:)`
  with the failing call named. The transport never parses MicroFreak semantics — that is the
  session's job.
- **Unplug behavior**: v1 keeps it simple — an unplugged device surfaces as send failures and
  receive timeouts; the app's connect screen re-runs discovery. No `MIDISetupNotification`
  handling in the transport (the app may add its own `MIDIClientCreateWithBlock` observer later
  without touching this seam).
- **Tests never construct this type.** `SysEx7Tests` covers encode/reassembly exhaustively
  (fragmentation at every boundary 1..6, orphan continue/end, interleaved start, runaway guard,
  round-trip of every §4 builder's output).

---

## 13. FreakCore test plan (headless, `swift test` on macOS)

| suite | proves |
|---|---|
| `VectorTests` | every §2 fixture kind, loaded via `Vectors.load`, byte-identical results. **No expected bytes are hand-written in Swift tests, anywhere.** |
| `WireTests` | codec edge behavior not expressible as vectors: parse of foreign traffic, 7-bit rejection, addr/slot inverses across the range |
| `SessionTests` | reply-lag defense (mismatch → resend; retries exhausted → `.replyMismatch`; silence → `.deviceTimeout`), seq counter 1..127 never 0, drain-before-transact, dump lockstep + stale-frame discard, runaway-chunk guard — all with `TestClock`, zero wall time |
| `WriteSequenceTests` | full 7-frame order + ack accounting against the sim; torn write via `failChunkAt` (→ `.chunkNotAcked`, sim slot untouched, next verified write succeeds); cancellation mid-burst (→ `.operationCancelled`, then rewrite recovers) |
| `DeviceTests` | write-verify (success, name-mismatch, blob-mismatch with `firstDifference`), rename (name-frame-only: sim wire log contains no chunks), snapshot swallowing only name-read failures, snapshot cancellation returns nothing partial |
| `BackupRestoreTests` | backup on-disk bytes (index keys, NNN.bin, meta_hex), per-slot persistence (cancel mid-pass leaves loadable partial state), resume skips, `BackupSet.load` re-hash + first-bad-slot naming, old-index-without-meta_hex behavior, restore stop-on-first-failure with `.restoreFailed.completed` |
| `LibraryTests` | create/open/exists/corrupt, add dedupes blobs but not entries, slot-claim clearing, remove refcounting, get() re-hash, importSnapshot skip rules; interop assertions: id is 32-char hyphenless lowercase hex, timestamps match the pinned format, `slot: null` written |
| `SyncTests`, `AnalysisTests` | the five states, `.snapshotMissingHashes`, expendable rules incl. never-"Init"-by-name, scratch-slot preference |
| `SimulatedFidelityTests` | ack shapes, lag holding-cell semantics (held reply renders current state; seq echoes its own request), factory meta positional correctness (0x10 at ≥128, payload[9] flip at 384), fault conditions |
| `ConcurrencyTests` | two concurrent `writePreset`/`readBlob` tasks on one session → zero sim faults, transcripts strictly sequential (the FIFO gate holds) |
| `SysEx7Tests` | §12.1 table exhaustively |

The 512-slot lagged-read proof (every slot labeled correctly) runs as a `reply_lag` vector case.
Nothing in the test tree opens a MIDI port, sleeps real time (beyond incidental scheduler hops),
or touches the network.

---

## 14. The app's core-facing seam (contract for the FreakLibrarian engineer)

The app depends on the `FreakCore` product and exactly these public names — everything it needs to
build against **before FreakCore is implemented** (stub conformances of `FreakDeviceProtocol` are
cheap):

- `FreakDeviceProtocol` (+ its option structs and default-argument overloads) — held as
  `any FreakDeviceProtocol`. The app never imports `FreakSession`, `Wire`, or any frame type;
  UI code never reaches into frames.
- Models: `Preset`, `SlotRecord`, `DeviceSnapshot`, `TimingReport`, `WriteReport`,
  `ProgressEvent`, `NameInfo`, `LibraryEntry`, `SlotDiff`, `SlotStatus`, `SyncDiff`.
- `ProgressReporter` + `Task` cancellation (§6 pattern is normative).
- `FreakError` for user-facing error mapping (switch on `group` for coarse handling).
- `Library` (actor), `BackupSet`, `computeDiff`/`Library.diff`, `Analysis`.
- Device acquisition:

```swift
public enum FreakDeviceFactory {
    /// Practice mode: MicroFreakDevice over SimulatedMicroFreak.factoryFresh(...).
    /// Instant, offline, 269 duplicated Init slots among named pseudo-presets — the
    /// full UI (browse, backup, sync, expendability badges) works on the couch.
    public static func practice(initCopies: Int = 269, seed: Int = 0) -> any FreakDeviceProtocol

    #if canImport(CoreMIDI)
    /// Hardware: MicroFreakDevice over CoreMIDITransport.open(hints:exclude:).
    /// Throws .deviceNotFound / .transport — the connect screen shows the endpoint
    /// lists carried in .deviceNotFound and offers practice mode as the fallback.
    public static func hardware(hints: [String] = CoreMIDITransport.defaultHints)
        throws -> any FreakDeviceProtocol
    #endif
}
```

App-side obligations (normative, UI design otherwise free):

1. **Practice mode is a first-class mode**, selectable at launch and whenever hardware is absent;
   every screen works against it. The status bar always shows which device kind is connected.
2. **Long ops** (backup ≈ 211 s, snapshot-with-blobs, restore, full-device import) run in a
   `Task`, render `ProgressEvent` (count, slot, name, elapsed, ETA), and offer Cancel →
   `task.cancel()`. `.operationCancelled` after a backup is not an error state — the partial
   backup is valid and resumable (`BackupOptions.resume`).
3. **Names-only refresh** (`SnapshotOptions(readBlobs: false)`) is the interactive path for the
   slot browser; a full hash pass is always an explicit, progress-barred user action.
4. Slot browser marks expendable slots via `Analysis.findExpendable` over the latest hashed
   snapshot, and "safe target" suggestions use `Analysis.pickScratchSlot`.
5. Writes/renames go through the default **verified** overloads; `.verifyMismatch` is surfaced
   loudly, never retried silently.
6. The sync screen renders `SyncDiff` rows grouped by `SlotStatus` and composes explicit
   per-row `write`/`add` actions — the app never auto-writes a diff either.
7. File locations: `Documents/Library/`, `Documents/Backups/<yyyy-MM-dd-HHmmss>/`;
   `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` = YES.
8. Serialize device operations in the app layer too (one op in flight per device; the session
   gate makes overlap safe, but the UI should not queue a backup behind a browse invisibly).

---

## 15. What NOT to port

Transliterating any of these is noise or a bug:

- **`threading.Lock` / `queue.Queue` / `threading.Event`** — replaced by the actor + FIFO gate
  (§8), the transport Inbox (§12), and `Task` cancellation. No GCD queues, no semaphores waiting
  on cooperative threads.
- **`CancelToken` / `ProgressFn` callbacks** — replaced by `Task` cancellation and
  `ProgressReporter` (§6). Do not add a token type "for familiarity".
- **`microfreak.transports.rtmidi` — the entire module**: rtmidi discovery strings, port-name
  parsing, `available()`, virtual-port handling, the callback→queue shim. Only the *concepts*
  survive (hint matching, `exclude: "mfcap"`, `.deviceNotFound` listing endpoints) in §12.
- **`open_device()` module-level convenience and lazy imports** — Swift has
  `FreakDeviceFactory`; there is no lazy-import problem to solve.
- **Python context-manager protocol** (`__enter__`/`__exit__`) — `close()` is explicit; the app
  owns device lifetime.
- **`time.monotonic` / `time.sleep` defaults and the 2 ms busy-poll as a *blocking* sleep** —
  clock/sleep injection survives as `FreakClock`, but sleeping is `async`.
- **Python-exception leakage**: `ValueError`, `FileNotFoundError`, `FileExistsError`,
  `IndexError` have mapped `FreakError` cases (§5) — do not throw `NSError`s or `fatalError` for
  API-misuse paths that Python raised on.
- **`dataclasses.replace`, `__post_init__` idioms** — validation lives in throwing initializers.
- **String-keyed index dicts as an in-memory model** — internal storage is typed; only the JSON
  boundary (§10) speaks the Python schema.
- **`wire_log`/`faults` string formats** — conditions are normative, wording is not.
- **`BackupSet` mutation via device code paths** — creation still goes only through
  `MicroFreakDevice.backup`; do not add `BackupSet.create`.
- **Reply-lag "improvements"** — do not add request-id heuristics, seq-based matching, or
  same-slot disambiguation; the documented rename window stays (§8.2).

---

## 16. Open assumptions (inherited, for the record)

Both of core-api.md's open write-direction assumptions were confirmed on hardware 2026-09-01
(write-protocol.md, Provenance) with one residue: every captured MCC write targeted slots ≥ 384;
the from-scratch core write below the boundary was confirmed via `Session.write_preset`. The Swift
port encodes the same behavior and inherits the same evidence — no new hardware assumptions are
introduced by this spec. First hardware session with the iPad should still start with reads and a
scratch-slot verified write (`Analysis.pickScratchSlot`) before any restore.
