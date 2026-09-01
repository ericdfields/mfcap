# mfcap — MicroFreak phase 0 capture harness (runbook)

Toolkit delivered 1 Sep 2026 as `mfcap.tar.gz`. Runs on the Mac. Python 3.9+, one dep (`python-rtmidi`).
Companion to `claude/microfreak-librarian-plan.md`.

## Purpose
Decode the MicroFreak SysEx **write** protocol (the phase 0 gate) by watching MIDI Control Center do it, then prove it by writing a preset and reading it back byte-identical.

## Command sequence
```
python3 -m mfcap doctor                        # self-heals deps, lists only true human blockers
python3 -m mfcap backup                        # all 512 slots to disk + throughput measurement
python3 -m mfcap calibrate                     # 90-second hover pass over MCC controls (once ever)
python3 -m mfcap capture                       # the five captures
python3 -m mfcap analyze --slot-a 509 --slot-b 510
python3 -m mfcap verify --source-slot 509 --scratch-slot 511 --rewrites ~/mfcap-work/rewrites.json
```
Work dir defaults to `~/mfcap-work`. All steps resumable — completed steps are skipped on re-run.

## Human touchpoints (the complete list)
1. Plug MicroFreak into Mac by USB, power on — physical, 30s
2. Install MIDI Control Center if absent — 5 min
3. Tick terminal in System Settings > Privacy & Security > Accessibility — 1 click, optional (skipping costs ~20 manual drags)
4. Calibration hover pass over 7 MCC controls — 90s, optional, same trade as #3
5. Pick the `MicroFreak` virtual port in MCC if it doesn't adopt it automatically — 1 dropdown, often unnecessary
6. The rename capture (c5) — type one letter, save — 15s, unavoidable (no drag to replay)
7. Fallback route only: admin password for MIDI Monitor spy driver

Everything else is autonomous: dep installs, launching MCC, the 512-slot backup, the five captures, splitting, diffing, checksum hunt, rewrite map, gate.

## Human-in-the-loop contract
- Escalation is threefold and simultaneous: red terminal banner + macOS notification + spoken instruction (`say`), because the person is at the synth, not the screen.
- Steps auto-advance by watching MIDI traffic go quiet — nobody returns to the keyboard to press return.
- Unattended (`--unattended` or no TTY): never hangs. Writes `NEEDS_HUMAN.md`, prints a machine-readable `::needs-human:: {json}` marker line, exits **75**.
- `Step(name, instruction, auto, done_when, why, device_action)` in `operator.py` is the abstraction: `auto` runs first and silently; a human is asked only after it fails.

## Capture route
Primary: CoreMIDI virtual-port MITM (`proxy.py`). No admin, no driver, no GUI scripting.
`MCC -> virtual destination -> mfcap -> hardware`, replies back the same way, everything logged to JSONL with timestamps and direction.
`Proxy.probe()` decides in 25s whether MCC adopted the virtual port. If not, the script itself falls back to Snoize MIDI Monitor's spy driver; `mmlog.py` parses its saved logs into the same JSONL (`mfcap import-mm <log>`).

## The five cases
| case | action | isolates |
|---|---|---|
| c1 | preset A -> slot 509 | baseline complete write |
| c2 | same preset -> slot 510 | address field |
| c3 | different preset -> slot 509 | payload boundary |
| c4 | init/empty preset -> slot 509 | padding/defaults |
| c5 | rename in place | is the name written separately |

Scratch slots auto-chosen as highest-numbered **empty** slots from the backup; stops and asks if the device is full.

## The gate — key shortcut
We do not need to *understand* the write protocol to prove we can use it. `verify.py` replays MCC's own captured burst with the address bytes rewritten to a scratch slot, reads that slot back, compares SHA-256 to what MCC originally wrote. Passing confirms the write path **and** the address field simultaneously, before decoding any parameter.
No automatic restore using an unproven write path; scratch slot original saved to `gate/scratch_original.bin`.

## Module map
`operator.py` (Step/escalation/resume) · `sysex.py` (frames, documented protocol only) · `midi.py` (CoreMIDI, Reader, backup+timing) · `proxy.py` (MITM + probe) · `mccauto.py` (calibration, verified coordinate replay via cliclick, window-relative coords) · `captures.py` (cases as Steps, capture splitting) · `analyze.py` (burst split, diffs, checksum hunt, emits `rewrites.json`) · `verify.py` (retargeted replay + gate + `pick_scratch_slot`) · `mmlog.py` (MIDI Monitor parser) · `cli.py`

## Tests
`python3 tests/test_gate.py` runs offline against a simulated MicroFreak. Proves the gate reaches a correct verdict AND that a wrong rewrite map fails it rather than quietly passing. Both pass as delivered.

## Flagged assumptions
- `<len>` byte semantics unverified (name reads use 0x03, dump opens 0x01; neither equals payload length). Marked `LEN_IS_UNVERIFIED`. If `backup` returns mostly empty slots, this is the cause.
- Parameter sign carried outside the three value bytes; `decode_param` takes it as an argument rather than inferring from bit 14.
- Firmware assumed 5.x / 512 slots (`--slots` overrides).
- The write protocol in `tests/test_gate.py` is **invented** (open/chunk/commit + sum checksum) purely to exercise the harness. It is not a claim about Arturia's format.

## Verified before delivery
Analyzer run against a synthetic write protocol correctly located the address field in both open and commit frames, identified the payload boundary, and identified the checksum. Gate tests pass in both directions.
