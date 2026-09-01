# mfcap — MicroFreak phase 0 harness

Everything needed to decode the MicroFreak's SysEx **write** protocol and prove
it, on the way to the iPad librarian. Reads are already understood; writes are
the gate. This toolkit backs the device up, watches MIDI Control Center write a
preset, works out how, and then proves it by writing one itself and reading it
back.

Runs on the Mac. Python 3.9+, one dependency.

---

## The friction budget

The design rule everywhere in here: **try it automatically, ask a person only
when that has actually failed, and then ask for exactly one thing.** This is
the complete list of moments a human is needed, in order.

| # | What | Who | How long | Avoidable? |
|---|------|-----|----------|-----------|
| 1 | Plug the MicroFreak into the Mac by USB, power it on | you | 30 s | no — it's physical |
| 2 | Install MIDI Control Center, if it isn't already | you | 5 min | no (Arturia has no CLI installer) |
| 3 | Tick your terminal in System Settings → Privacy & Security → Accessibility | you | 1 click | yes, but skipping it costs ~20 manual drags |
| 4 | Calibration: hover over 7 controls in MCC, press return each time | you | 90 s | yes, same trade as #3 |
| 5 | Pick the `MicroFreak` virtual port in MCC, if it doesn't adopt it on its own | you | 1 dropdown | often not needed at all |
| 6 | The rename capture — type one different letter in MCC and save | you | 15 s | no, there's no drag to replay |
| 7 | *Fallback route only:* admin password for MIDI Monitor's spy driver | you | 1 password | only if #5 fails outright |

Everything else — installing `python-rtmidi` and `cliclick`, launching MCC,
backing up all 512 slots, running the five captures, splitting them, diffing
them, hunting the checksum, writing the rewrite map, running the gate — happens
without anyone in the chair.

**When a person *is* needed**, the script says so three ways at once: a red
banner in the terminal, a macOS notification, and it speaks the instruction
aloud, because you're standing at the synth and not looking at the screen. Then
it watches the MIDI wire and advances by itself the moment you're done. You
never walk back to press return.

**When nobody is there** (`--unattended`, or no TTY), it does not hang. It
writes `NEEDS_HUMAN.md`, prints a `::needs-human:: {...}` marker line an
orchestrating agent can surface verbatim, and exits **75**. Re-running skips
everything already completed.

---

## Install

```bash
python3 -m mfcap doctor          # installs what it can, lists what it can't
```

`doctor` self-heals: it pip-installs `python-rtmidi` and brew-installs
`cliclick` on its own. It only reports back the things that genuinely need
hands — a USB cable, an app installer, a permission toggle. Exit 75 means
"there's a list for you"; exit 0 means go.

---

## The run

```bash
python3 -m mfcap backup                        # 1. safety rail — all 512 slots to disk
python3 -m mfcap calibrate                     # 2. the 90-second hover pass (once, ever)
python3 -m mfcap capture                       # 3. the five captures
python3 -m mfcap analyze --slot-a 509 --slot-b 510
python3 -m mfcap verify --source-slot 509 --scratch-slot 511 \
        --rewrites ~/mfcap-work/rewrites.json  # 4. the gate
```

### 1. `backup` — do this first, always

Fully autonomous, uses only the documented read protocol. Dumps every slot to
`~/mfcap-work/backup/presets/NNN.bin` with a SHA-256 index, and **measures
throughput** — which answers the open question from the plan: how long does a
512-slot pass actually take, and can a sync realistically do one?

Nothing in this toolkit writes to the device until this has succeeded. If fewer
than 90% of slots dump, it fails loudly rather than pretending it backed you
up: that usually means the `<len>` byte assumption in `sysex.py` is wrong, and
that's a finding, not an error.

### 2. `calibrate` — pointing, once

You hover over seven controls in MCC and press return. No clicking, no typing
coordinates. Positions are stored **relative to MCC's window**, so moving or
reopening the window doesn't invalidate them.

Skip it if you'd rather — captures then ask you to do five drags by hand, and
still detect their own completion from the wire.

### 3. `capture` — the five cases

Starts the proxy, gets MCC talking through it, then runs:

| case | action | isolates |
|------|--------|----------|
| c1 | preset A → slot 509 | a complete write, baseline |
| c2 | the **same** preset → slot 510 | the address field |
| c3 | a **different** preset → slot 509 | the payload boundary |
| c4 | an init/empty preset → slot 509 | padding and defaults |
| c5 | rename in place | whether the name is written separately |

Scratch slots are chosen automatically as the highest-numbered **empty** slots
from your backup. If the device is genuinely full, it stops and asks rather
than picking something of yours.

### 4. `analyze` → `verify` — the gate

`analyze` writes `findings.md` (address field, payload boundary, checksum hunt)
and — so nobody transcribes hex by hand — `rewrites.json`, which feeds straight
into `verify`.

`verify` is the shortcut that makes phase 0 cheap: **we don't need to understand
the write protocol to prove we can use it.** It replays MCC's own captured burst
with the address bytes rewritten to a scratch slot, reads that slot back, and
compares SHA-256 against what MCC originally wrote. Pass means the write path is
real *and* the address field is confirmed, both at once, before a single
parameter has been decoded.

It refuses to auto-restore anything using an unproven write path. The scratch
slot's original contents are saved to `gate/scratch_original.bin` either way.

---

## How the capture actually works

Primary route is a man-in-the-middle, needing no admin password, no kernel
driver and no GUI scripting:

```
MCC  ->  [virtual destination]  ->  mfcap  ->  real MicroFreak
MCC  <-  [virtual source]       <-  mfcap  <-  real MicroFreak
```

`mfcap` publishes a CoreMIDI virtual endpoint pair named `MicroFreak`. If MCC
picks it, every byte is ours, in order, timestamped, both directions.

Some hosts filter on USB transport and won't talk to a virtual port. `probe()`
finds that out in 25 seconds and falls back to Snoize **MIDI Monitor**'s spy
driver — the script makes that call, not you. `mmlog.py` parses MIDI Monitor's
saved logs into the same JSONL the rest of the toolkit eats:

```bash
python3 -m mfcap import-mm ~/Desktop/capture.txt
```

---

## Layout

```
mfcap/
  operator.py   human-in-the-loop: Step, escalation, auto-advance, resume
  sysex.py      frame construction and decoding (documented protocol only)
  midi.py       CoreMIDI I/O, the Reader, full-device backup + timing
  proxy.py      virtual-port MITM and its self-probe
  mccauto.py    calibration and verified coordinate replay
  captures.py   the five cases, as Steps
  analyze.py    burst splitting, diffs, checksum hunt, rewrite map
  verify.py     retargeted replay and the write/read-back gate
  mmlog.py      MIDI Monitor fallback parser
  cli.py        commands
tests/
  test_gate.py  replay + gate against a simulated MicroFreak
```

`python3 tests/test_gate.py` runs offline against a fake device — it proves the
gate reaches a correct verdict **and** that a wrong rewrite map fails it rather
than quietly passing.

---

## What is assumed, and where that's marked

Everything in `sysex.py` comes from `francoisgeorgy/microfreak-reverse`, which
was archived in April 2024. Two things there are documented but not
independently confirmed:

- **The `<len>` byte.** Name reads use `0x03`, dump opens use `0x01`; neither
  equals the payload length. Reproduced literally and flagged
  `LEN_IS_UNVERIFIED`. If `backup` returns mostly empty slots, this is why.
- **Parameter sign.** The published formula carries sign outside the three
  value bytes, so `decode_param` takes it as an argument rather than guessing
  from bit 14.

Firmware is assumed to be 5.x with 512 slots. Pass `--slots` if not.

The write protocol in `tests/test_gate.py` is **invented** — a plausible
open/chunk/commit with a sum checksum. It exists to test the harness, not to
describe Arturia's format. Nothing claims to know the real one until the gate
goes green.
