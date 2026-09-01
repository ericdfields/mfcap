"""mfcap command line.

    mfcap doctor      what's missing, all of it, in one list
    mfcap ports       what CoreMIDI can see
    mfcap backup      full 512-slot dump - do this before anything else
    mfcap calibrate   one hover pass over MCC's controls
    mfcap capture     run the five captures
    mfcap analyze     propose a write-frame spec from the captures
    mfcap verify      the gate: write, read back, compare hashes
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import analyze as an
from . import mccauto, midi, mmlog, sysex as sx, verify as vf
from .captures import build_cases, run_cases, split_capture
from .operator import EXIT_NEEDS_HUMAN, Operator, Step
from .proxy import Proxy

DEFAULT_WORK = Path.home() / "mfcap-work"


# --------------------------------------------------------------------------
# doctor - batch every human requirement into one list, once
# --------------------------------------------------------------------------

def _try(cmd: list, timeout: float = 300.0) -> bool:
    """Run a fix-it command ourselves rather than asking a person to."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def cmd_doctor(args) -> int:
    op = Operator(args.work, voice=False, notify=False)
    op.banner("mfcap doctor",
              "Fixing what can be fixed automatically, then listing what can't.")
    fix = not args.no_fix
    todo = []

    try:
        import rtmidi  # noqa: F401
        op.ok("python-rtmidi installed")
    except ImportError:
        if fix and _try([sys.executable, "-m", "pip", "install", "--user",
                         "--quiet", "python-rtmidi"]):
            op.ok("python-rtmidi installed automatically")
        else:
            op.warn("python-rtmidi missing")
            todo.append("pip3 install --user python-rtmidi")

    try:
        ports = midi.list_ports()
        found = midi.find_port(ports["inputs"]) is not None
        if found:
            op.ok(f"MicroFreak visible on CoreMIDI: {ports['inputs']}")
        else:
            op.warn("MicroFreak not visible to CoreMIDI")
            todo.append("Plug the MicroFreak into the Mac by USB and power it on")
    except Exception as exc:
        op.warn(f"could not enumerate MIDI ports: {exc}")

    mcc_path = mccauto.find_mcc()
    if mcc_path:
        op.ok(f"MIDI Control Center installed ({mcc_path})")
    else:
        op.warn("MIDI Control Center not found")
        todo.append("Install MIDI Control Center from arturia.com")

    if mccauto.have_cliclick():
        op.ok("cliclick installed (MCC automation possible)")
        try:
            mccauto.pointer()
            op.ok("Accessibility permission granted to this terminal")
        except Exception:
            op.warn("cliclick cannot read the pointer - Accessibility not granted")
            todo.append("System Settings > Privacy & Security > Accessibility: "
                        "enable your terminal app. Without this, MCC steps are manual.")
    elif fix and shutil.which("brew") and _try(["brew", "install", "cliclick"]):
        op.ok("cliclick installed automatically")
        try:
            mccauto.pointer()
            op.ok("Accessibility permission already granted")
        except Exception:
            todo.append("System Settings > Privacy & Security > Accessibility: "
                        "enable your terminal app. One click, saves ~20 manual drags.")
    else:
        op.warn("cliclick missing - MCC steps will be manual")
        todo.append("brew install cliclick   (optional, removes ~20 manual drags)")

    if Path("/Applications/MIDI Monitor.app").exists():
        op.ok("MIDI Monitor installed (fallback capture route available)")
    else:
        op.info("MIDI Monitor not installed - only needed if the proxy route fails")

    if todo:
        op.banner("DO THESE, THEN RE-RUN", "\n".join(f"  {i+1}. {t}" for i, t in enumerate(todo)))
        return EXIT_NEEDS_HUMAN
    op.banner("Ready", "Nothing needs a person right now. Next: mfcap backup")
    return 0


def cmd_ports(args) -> int:
    print(json.dumps(midi.list_ports(), indent=2))
    return 0


# --------------------------------------------------------------------------
# backup - fully autonomous, and mandatory before any write
# --------------------------------------------------------------------------

def cmd_backup(args) -> int:
    op = Operator(args.work)
    out = Path(args.work) / "backup"
    dev = midi.Device.open()
    op.ok(f"connected: in={dev.in_name!r} out={dev.out_name!r}")

    start = time.time()

    def progress(i, n, name):
        if i % 8 == 0 or i == n - 1:
            done = i + 1
            rate = done / max(time.time() - start, 0.01)
            eta = (n - done) / max(rate, 0.001)
            print(f"\r  slot {done}/{n}  {name[:22]:22s}  eta {int(eta)}s   ",
                  end="", flush=True)

    try:
        index = midi.backup(dev, out, slots=args.slots, progress=progress)
    finally:
        dev.close()
    print()

    named = sum(1 for v in index["presets"].values() if (v.get("name") or "").strip())
    dumped = sum(1 for v in index["presets"].values() if v.get("sha256"))
    op.ok(f"{named} named slots, {dumped} blobs dumped -> {out}")
    op.info(f"timing: {json.dumps(index['timing'])}")
    if dumped < args.slots * 0.9:
        op.warn("many slots failed to dump - check the len-byte assumption in sysex.py "
                "before trusting this as a backup")
        return 1
    op.mark("backup_complete", {"path": str(out), "slots": args.slots})
    return 0


# --------------------------------------------------------------------------
# calibrate
# --------------------------------------------------------------------------

def cmd_calibrate(args) -> int:
    op = Operator(args.work)
    cal = mccauto.Calibration(Path(args.work) / "calibration.json")

    if not mccauto.have_cliclick():
        op.banner("Calibration unavailable",
                  "cliclick is not installed, so MCC can't be driven for you.\n"
                  "  brew install cliclick\n"
                  "Without it every capture needs a drag by hand - the run still\n"
                  "works, it just asks you five times instead of none.")
        return EXIT_NEEDS_HUMAN

    op.run(Step(
        name="open MCC with the MicroFreak selected",
        instruction=("Open MIDI Control Center, select the MicroFreak, and get the "
                     "preset browser on screen with both your library list and the "
                     "device's slot list visible. Then come back."),
        auto=lambda: mccauto.launch_mcc() and mccauto.mcc_window_origin() is not None,
        why="calibration records positions relative to this window",
    ))

    def ask(prompt: str) -> str:
        return input(f"  hover over {prompt}, then return (or type skip): ").strip().lower()

    if mccauto.calibrate(cal, ask, op.info):
        op.ok(f"calibrated {len(cal.points)} controls -> {cal.path}")
        op.info("This is the only pointing you have to do. Captures replay it.")
        return 0
    op.warn("calibration failed; captures will run in guided-manual mode")
    return 1


# --------------------------------------------------------------------------
# capture
# --------------------------------------------------------------------------

def cmd_capture(args) -> int:
    op = Operator(args.work, unattended=args.unattended)
    work = Path(args.work)
    backup_index = work / "backup" / "index.json"

    if not backup_index.exists():
        op.banner("Backup first", "mfcap backup\n\nNothing writes to the device until "
                                  "every slot is safely on disk.")
        return 1

    slot_a = args.slot_a or vf.pick_scratch_slot(backup_index)
    slot_b = args.slot_b or (
        vf.pick_scratch_slot(backup_index, exclude=(slot_a,)) if slot_a is not None
        else None)
    if slot_a is None or slot_b is None:
        op.banner("No expendable slots", "No slot in the backup is blank or a "
                                         "mass-duplicated factory Init. Pass "
                                         "--slot-a/--slot-b naming two you are willing "
                                         "to overwrite; they are restorable from the "
                                         "backup.")
        return EXIT_NEEDS_HUMAN
    op.ok(f"scratch slots: {slot_a} and {slot_b} (both expendable per the backup)")

    master = work / "capture.jsonl"
    proxy = Proxy(capture_path=master)
    proxy.start()
    op.ok(f"proxy up, publishing a virtual port named {proxy.port_name!r}")

    try:
        adopted = op.run(Step(
            name="get MCC talking through the proxy",
            instruction=(f"In MIDI Control Center, choose the MIDI port named "
                         f"'{proxy.port_name}' that this tool just published (not the "
                         f"hardware one), then click on the MicroFreak so MCC talks to it."),
            auto=lambda: mccauto.launch_mcc() and proxy.probe(timeout=25),
            done_when=lambda: proxy.count("out") > 0,
            why="if MCC uses the real port instead, we see nothing",
            timeout=300,
        ))

        if not adopted:
            op.banner("Falling back to MIDI Monitor", mmlog.INSTALL_HINT)
            op.info("Capture with MIDI Monitor, save the log, then run:")
            op.info(f"  mfcap import-mm <saved-log.txt> --work {work}")
            return EXIT_NEEDS_HUMAN

        cal = mccauto.Calibration(work / "calibration.json")
        mcc = None
        if cal.load():
            mcc = mccauto.MccAuto(cal, wire_count=proxy.count)
            op.ok("calibration found - captures will drive MCC themselves")
        else:
            op.info("no calibration - each capture will ask you to do one drag")

        cases = build_cases(slot_a, slot_b)
        counts = run_cases(op, proxy, mcc, cases)
    finally:
        proxy.stop()

    files = split_capture(master, work / "cases")
    op.ok(f"split into {len(files)} case files under {work / 'cases'}")
    op.info(json.dumps(counts, indent=2))
    op.info("Next: mfcap analyze")
    return 0


CASE_ORDER = ["c1_presetA_slotA", "c2_presetA_slotB", "c3_presetB_slotA",
              "c4_init_slotA", "c5_rename"]


def cmd_import_mm(args) -> int:
    op = Operator(args.work)
    out = Path(args.work) / "capture.jsonl"
    n = mmlog.convert(Path(args.log), out)
    op.ok(f"imported {n} messages from MIDI Monitor -> {out}")

    if not args.split:
        op.warn("MIDI Monitor logs have no case markers. Re-run with --split if this "
                "log holds all five cases in order, separated by pauses.")
        return 0

    rows = [json.loads(l) for l in out.read_text().splitlines()]
    bursts = mmlog.split_bursts(rows, gap=args.gap)
    op.info(f"{len(bursts)} bursts found with a {args.gap}s silence threshold: "
            + ", ".join(f"{len(b)} msgs @ t={b[0].get('t', 0):.1f}s" for b in bursts))
    if len(bursts) != len(CASE_ORDER):
        op.warn(f"expected {len(CASE_ORDER)} bursts (the five cases, in order). "
                f"Adjust --gap, or recapture with clearer pauses between actions.")
        return 1

    cases_dir = Path(args.work) / "cases"
    cases_dir.mkdir(parents=True, exist_ok=True)
    for key, burst in zip(CASE_ORDER, bursts):
        p = cases_dir / f"{key}.jsonl"
        p.write_text("".join(json.dumps(r) + "\n" for r in burst))
        op.ok(f"{key}: {len(burst)} messages -> {p}")
    op.info("Next: mfcap analyze")
    return 0


# --------------------------------------------------------------------------
# analyze / verify
# --------------------------------------------------------------------------

def cmd_analyze(args) -> int:
    op = Operator(args.work)
    cases = Path(args.work) / "cases"
    mapping = {
        "slot_a": cases / "c1_presetA_slotA.jsonl",
        "slot_b": cases / "c2_presetA_slotB.jsonl",
        "preset_a": cases / "c1_presetA_slotA.jsonl",
        "preset_b": cases / "c3_presetB_slotA.jsonl",
        "init": cases / "c4_init_slotA.jsonl",
        "rename": cases / "c5_rename.jsonl",
    }
    out = Path(args.work) / "findings.md"
    text = an.report(mapping, (args.slot_a, args.slot_b), out)
    print(text)
    op.ok(f"written to {out}")
    return 0


def cmd_verify(args) -> int:
    op = Operator(args.work)
    work = Path(args.work)
    rows = an.load(work / "cases" / "c1_presetA_slotA.jsonl")
    rewrites = [vf.Rewrite(**r) for r in json.loads(Path(args.rewrites).read_text())]
    dev = midi.Device.open()
    try:
        result = vf.run_gate(dev, rows, args.source_slot, args.scratch_slot,
                             rewrites, work / "gate", op.info)
    finally:
        dev.close()
    if result["passed"]:
        op.banner("GATE PASSED",
                  "Write -> read back -> identical.\n"
                  "The write path is real. Phase 1 can start.", color="\033[38;5;71m")
        return 0
    op.banner("gate failed", json.dumps(result, indent=2), color="\033[38;5;167m")
    return 1


# --------------------------------------------------------------------------

def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="mfcap", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--work", default=str(DEFAULT_WORK), help="working directory")
    p.add_argument("--unattended", action="store_true",
                   help="never block on a person; stop with NEEDS_HUMAN.md instead")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("doctor")
    d.add_argument("--no-fix", action="store_true",
                   help="report only; don't install anything")
    d.set_defaults(fn=cmd_doctor)
    sub.add_parser("ports").set_defaults(fn=cmd_ports)

    b = sub.add_parser("backup")
    b.add_argument("--slots", type=int, default=512)
    b.set_defaults(fn=cmd_backup)

    sub.add_parser("calibrate").set_defaults(fn=cmd_calibrate)

    c = sub.add_parser("capture")
    c.add_argument("--slot-a", type=int, default=None, dest="slot_a")
    c.add_argument("--slot-b", type=int, default=None, dest="slot_b")
    c.set_defaults(fn=cmd_capture)

    m = sub.add_parser("import-mm")
    m.add_argument("log")
    m.add_argument("--split", action="store_true",
                   help="split the log into the five case files by silence gaps")
    m.add_argument("--gap", type=float, default=3.0,
                   help="seconds of silence that separate two cases (default 3)")
    m.set_defaults(fn=cmd_import_mm)

    a = sub.add_parser("analyze")
    a.add_argument("--slot-a", type=int, required=True, dest="slot_a")
    a.add_argument("--slot-b", type=int, required=True, dest="slot_b")
    a.set_defaults(fn=cmd_analyze)

    v = sub.add_parser("verify")
    v.add_argument("--source-slot", type=int, required=True)
    v.add_argument("--scratch-slot", type=int, required=True)
    v.add_argument("--rewrites", required=True,
                   help="JSON list of {frame_index, offset, kind} from findings.md")
    v.set_defaults(fn=cmd_verify)

    args = p.parse_args(argv)
    Path(args.work).mkdir(parents=True, exist_ok=True)
    if not hasattr(args, "unattended"):
        args.unattended = False
    if not hasattr(args, "no_fix"):
        args.no_fix = True
    try:
        return args.fn(args)
    except midi.MidiUnavailable as exc:
        print(f"\n  {exc}\n")
        return EXIT_NEEDS_HUMAN
    except KeyboardInterrupt:
        print("\n  stopped")
        return 130


if __name__ == "__main__":
    sys.exit(main())
