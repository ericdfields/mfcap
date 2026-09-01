# MicroFreak SysEx write protocol — decoded and gate-verified

Captured 2026-09-01 from MIDI Control Center via the MIDI Monitor spy route,
against firmware 5.x hardware. Everything below is **verified by the gate**:
a captured burst replayed to a different slot read back byte-identical, and a
fully synthesized burst (new content, new name) did too.

## Frame envelope (unchanged from the read protocol)

    F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7

`<len>` is the payload length for chunk frames (0x20 = 32 bytes) and name
frames (0x23 = 35, 0x03 = 3). The old `LEN_IS_UNVERIFIED` doubt is resolved
for these frame types. Dump opens are the one place two values are both
proven: MCC sends len 0x03 (= payload length, per the c2 capture) while the
phase-0/core code sends the archived-notes value 0x01, accepted by hardware
across full 512-slot backups.

## The write sequence

| # | dir | cmd | payload | meaning |
|---|-----|-----|---------|---------|
| 1 | →   | 0x19 | `bank, pos, 0x00` | name read (MCC refreshes its list) |
| 2 | →   | 0x52 | `bank, pos, 0x00, hdr[9], name[23]` | write name + metadata; device acks ← 0x18 |
| 3 | →   | 0x52 | `bank, pos, 0x01` | **open blob write to (bank, pos)**; device acks ← 0x18 |
| 4 | →   | 0x15 | none (seq 0, len 0) | go; device acks ← 0x18 |
| 5 | →   | 0x16 | 32 content bytes | chunk; device acks each with ← 0x18 |
| … |     |      | ×145 | |
| 6 | →   | 0x17 | 32 content bytes | last chunk |
| 7 | →   | 0x19 | `bank, pos, 0x00` | name read back |

- The device acks **every write frame** with `0x18` — the long 0x52, the
  short 0x52 open, the 0x15 go, and every chunk (c3: 149 inbound 0x18s for
  146 chunks; c2: 150 for 146 + two name frames). A writer that pairs acks
  with chunks only will run three acks ahead of the device.
- The device's ack shape is `len 0x00`, **empty payload**, seq echoing the
  acked frame's seq. (The HOST's pull-next 0x18 during reads is different:
  len 0x01, payload `[0x00]`.)
- Chunk seq bytes increment: the go frame carries seq 0 and the chunks
  continue 1, 2, .., 127 then wrap **through 0** (mod 128) — c2/c3 both show
  1..127, 0, 1..18 across the 146 chunks.
- 146 chunks × 32 bytes = **4672 bytes**, exactly the size of a preset dump.
  The blob you write is the blob you read.
- **No checksum.** Chunks carry raw content only; the device accepts a
  synthesized burst with no trailing integrity byte.

## Addressing

The slot address (`bank = slot // 128`, `pos = slot % 128`) appears **only**
in 0x19 and 0x52 frames, always as the first two payload bytes. Chunks carry
no address — a chunk payload can coincidentally begin `03 7F`, so never
pattern-match addresses inside chunks.

## Names and metadata

Names never travel in the blob; they ride exclusively in the long 0x52 frame
(and its near-mirror, the 0x52 name-read reply). Two header bytes are
**direction-dependent** — the outbound write and the reply are NOT
byte-identical:

    payload[0]  bank
    payload[1]  pos
    payload[2]  0x00
    payload[3]  flags: 0x08 observed on factory Init entries. Bit 0x10
                appears ONLY in device replies (and only for slots >= 128:
                fixtures 0/8/40 clear, 200/511 set); every captured outbound
                write (c2/c3/c4, 4 frames) has it clear. Writers must clear
                it when round-tripping reply meta.
    payload[4..7]  unknown (varies; flags/bookkeeping; round-trips verbatim)
    payload[8]  pos again
    payload[9]  direction-dependent: REPLIES carry 0 below slot 384, 1 at or
                above; every captured OUTBOUND write carries 0x06, including
                writes to slots 510/511 where a reply would say 1.
    payload[10] category/attribute
    payload[11] attribute (often printable — 0x32/0x33 — which is what used
                to leak into decoded names)
    payload[12..34]  name, ASCII, NUL-padded, 23 bytes

A rename in MCC sends **only** frame 2 (and a refresh read) — no blob
rewrite. Dragging an "init" preset in MCC likewise sends only a name frame.

## Quirks that will bite a librarian

- **Reply lag:** under rapid back-to-back name reads the device's replies lag
  one request behind. Always match the reply's embedded `bank, pos` to the
  request (see `Reader.name`). Blind spot: when two consecutive reads target
  the SAME slot (a write's read-back, a rename's refresh), embedded-address
  matching cannot tell a lagged reply from the real answer; whether a lagged
  hardware reply carries request-time or emission-time content is unobserved.
  Blob-hash verification covers writes; renames retain this window.
- **"Empty" slots don't exist:** unused slots are factory Init presets with
  the name "Init" and identical blobs (269 of 512 on the reference device).
  Emptiness is a content judgement (mass-duplicated sha), not a name one.
- **Throughput:** full 512-slot read ≈ 211 s (dump ≈ 400 ms/slot, name read
  ≈ 1 ms). A full-device sync is a ~3.5 minute operation.

## Architecture note

The protocol core (`sysex.py`, `midi.py`, `writer.py`, `verify.py`) must stay
**framework- and host-agnostic**: plain Python over `python-rtmidi`, which
runs on CoreMIDI (macOS/iPadOS via bridging) and ALSA (Linux/Raspberry Pi)
alike. The iPad librarian is one frontend; a Pi-powered hardware device with
a touchscreen is an equally supported future host. UI code must never reach
into frames directly — it talks to the core's slot/preset API.

## Provenance

- `~/mfcap-work/cases/c*.jsonl` — the captured bursts (c1 is tail-only;
  MIDI Monitor's 1000-event buffer clipped its start)
- `~/mfcap-work/gate/` — expected/readback blobs and verdicts
- Gate replay: c3's burst (preset "Akiko San" → slot 511) retargeted to
  slot 509, read back sha-identical
- Synthesized write: factory-Init blob + name "Init" via `mfcap restore
  --slot 509`, read back identical to the pre-gate backup hash
- Core hardware confirmation (2026-09-01, first `microfreak` package
  session): a from-scratch write built by `Session.write_preset` —
  incrementing chunk seqs, control-frame 0x18 ack accounting, and the
  write-direction header bytes (payload[3] flag cleared, payload[9]=0x06) —
  was accepted by hardware and read back hash-identical, ~0.5 s per verified
  write. The doc's two open write-direction assumptions are confirmed.
