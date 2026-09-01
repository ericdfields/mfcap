# MicroFreak SysEx write protocol — decoded and gate-verified

Captured 2026-09-01 from MIDI Control Center via the MIDI Monitor spy route,
against firmware 5.x hardware. Everything below is **verified by the gate**:
a captured burst replayed to a different slot read back byte-identical, and a
fully synthesized burst (new content, new name) did too.

## Frame envelope (unchanged from the read protocol)

    F0 00 20 6B 07 01 <seq> <len> <cmd> [payload...] F7

`<len>` is the payload length for chunk frames (0x20 = 32 bytes) and name
frames (0x23 = 35, 0x03 = 3). The old `LEN_IS_UNVERIFIED` doubt is resolved
for these frame types.

## The write sequence

| # | dir | cmd | payload | meaning |
|---|-----|-----|---------|---------|
| 1 | →   | 0x19 | `bank, pos, 0x00` | name read (MCC refreshes its list) |
| 2 | →   | 0x52 | `bank, pos, 0x00, hdr[9], name[23]` | write name + metadata |
| 3 | →   | 0x52 | `bank, pos, 0x01` | **open blob write to (bank, pos)** |
| 4 | →   | 0x15 | none (seq 0, len 0) | go |
| 5 | →   | 0x16 | 32 content bytes | chunk; device acks each with ← 0x18 |
| … |     |      | ×145 | |
| 6 | →   | 0x17 | 32 content bytes | last chunk |
| 7 | →   | 0x19 | `bank, pos, 0x00` | name read back |

- The device acks every chunk with `0x18` ("next"), mirroring the read
  protocol with the roles reversed.
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
(and its mirror, the 0x52 name-read reply):

    payload[0]  bank
    payload[1]  pos
    payload[2]  0x00
    payload[3..7]  unknown (varies; flags/bookkeeping)
    payload[8]  pos again
    payload[9]  unknown (0 below slot 384, 1 above)
    payload[10] category/attribute
    payload[11] attribute (often printable — 0x32/0x33 — which is what used
                to leak into decoded names)
    payload[12..34]  name, ASCII, NUL-padded, 23 bytes

A rename in MCC sends **only** frame 2 (and a refresh read) — no blob
rewrite. Dragging an "init" preset in MCC likewise sends only a name frame.

## Quirks that will bite a librarian

- **Reply lag:** under rapid back-to-back name reads the device's replies lag
  one request behind. Always match the reply's embedded `bank, pos` to the
  request (see `Reader.name`).
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
