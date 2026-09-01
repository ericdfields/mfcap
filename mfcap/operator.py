"""Human-in-the-loop plumbing.

The whole point of this module: a human is expensive and probably standing at
the synth, not at the keyboard. So:

  1. Every step declares an autonomous attempt. It runs first, silently.
  2. Only if that fails does a human get asked, and then they get ONE
     instruction in plain words, spoken aloud and pushed as a notification.
  3. Wherever possible the step detects its own completion (MIDI traffic,
     a file appearing, a port showing up) instead of asking for a keypress.
  4. If nobody is there (--unattended / no TTY), the run stops cleanly,
     writes NEEDS_HUMAN.md, and exits 75 so an orchestrating agent can
     surface it verbatim instead of hanging forever.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

EXIT_NEEDS_HUMAN = 75

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
AMBER = "\033[38;5;178m"
RED = "\033[38;5;167m"
GREEN = "\033[38;5;71m"


def _tty() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


@dataclass
class Step:
    """One unit of work that would rather do itself than bother you.

    auto          - callable returning True on success. Tried first, silently.
    instruction   - what to tell the human, in plain words, if auto fails or
                    there is no auto path at all.
    done_when     - callable polled after the instruction is given. When it
                    returns True the step advances by itself; the human never
                    has to come back to the keyboard to confirm.
    why           - one line of context, shown under the instruction.
    timeout       - seconds to wait on done_when before re-announcing.
    device_action - True if the human has to physically touch the MicroFreak.
                    These get a louder alert because the person is across the
                    room with their hands on hardware.
    """
    name: str
    instruction: str
    auto: Optional[Callable[[], bool]] = None
    done_when: Optional[Callable[[], bool]] = None
    why: str = ""
    timeout: float = 600.0
    device_action: bool = False
    optional: bool = False


class Operator:
    def __init__(self, workdir: Path, voice: bool = True, notify: bool = True,
                 unattended: bool = False, resume: bool = True):
        self.workdir = Path(workdir)
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.voice = voice and shutil.which("say") is not None
        self.notify = notify and shutil.which("osascript") is not None
        self.unattended = unattended or not _tty()
        self.state_path = self.workdir / "state.json"
        self.state = self._load_state() if resume else {}
        self.log_path = self.workdir / "run.log"

    # ---------- persistence so a re-run skips what already worked ----------

    def _load_state(self) -> dict:
        if self.state_path.exists():
            try:
                return json.loads(self.state_path.read_text())
            except json.JSONDecodeError:
                pass
        return {}

    def _save_state(self) -> None:
        self.state_path.write_text(json.dumps(self.state, indent=2))

    def mark(self, key: str, value=True) -> None:
        self.state[key] = value
        self._save_state()

    def done(self, key: str) -> bool:
        return bool(self.state.get(key))

    # ---------- output ----------

    def log(self, line: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        with self.log_path.open("a") as fh:
            fh.write(f"{stamp} {line}\n")

    def info(self, text: str) -> None:
        print(f"{DIM}  {text}{RESET}")
        self.log(f"info: {text}")

    def ok(self, text: str) -> None:
        print(f"{GREEN}  OK{RESET}  {text}")
        self.log(f"ok: {text}")

    def warn(self, text: str) -> None:
        print(f"{AMBER}  !!{RESET}  {text}")
        self.log(f"warn: {text}")

    def banner(self, title: str, body: str = "", color: str = AMBER) -> None:
        width = min(shutil.get_terminal_size((88, 24)).columns, 88)
        rule = "─" * width
        print(f"\n{color}{rule}")
        print(f"{BOLD}{title}{RESET}{color}")
        if body:
            print(f"{RESET}{body}{color}")
        print(f"{rule}{RESET}\n")

    def _speak(self, text: str) -> None:
        if not self.voice:
            return
        try:
            subprocess.Popen(["say", "-r", "180", text],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    def _notify(self, title: str, text: str) -> None:
        if not self.notify:
            return
        safe_t = text.replace('"', "'")
        safe_h = title.replace('"', "'")
        script = (f'display notification "{safe_t}" with title "mfcap" '
                  f'subtitle "{safe_h}" sound name "Submarine"')
        try:
            subprocess.run(["osascript", "-e", script],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass

    # ---------- the escalation ladder ----------

    def needs_human(self, step: Step) -> None:
        """Announce, loudly and once, that a person has to do something."""
        head = "TOUCH THE MICROFREAK" if step.device_action else "YOUR TURN"
        self.banner(f"{head}  -  {step.name}", step.instruction,
                    color=RED if step.device_action else AMBER)
        if step.why:
            print(f"{DIM}  why: {step.why}{RESET}\n")
        self._notify(step.name, step.instruction)
        self._speak(step.instruction)
        # A machine-readable marker so an orchestrating agent can surface this
        # verbatim rather than guessing what the run is stuck on.
        print(f"::needs-human:: {json.dumps({'step': step.name, 'instruction': step.instruction, 'device': step.device_action})}")
        self.log(f"NEEDS HUMAN [{step.name}]: {step.instruction}")

    def bail_unattended(self, step: Step) -> None:
        path = self.workdir / "NEEDS_HUMAN.md"
        path.write_text(
            f"# mfcap is waiting on a person\n\n"
            f"**Step:** {step.name}\n\n"
            f"**Do this:** {step.instruction}\n\n"
            f"{('**Why:** ' + step.why) if step.why else ''}\n\n"
            f"{'This one needs hands on the MicroFreak itself.' if step.device_action else 'This one is on the Mac.'}\n\n"
            f"Then re-run the same command. Completed steps are skipped.\n"
        )
        self.banner("STOPPED - needs a person", str(path), color=RED)
        sys.exit(EXIT_NEEDS_HUMAN)

    def run(self, step: Step) -> bool:
        """Try to do it ourselves; ask a human only if that fails."""
        key = f"step:{step.name}"
        if self.done(key):
            self.info(f"{step.name} - already done, skipping")
            return True

        if step.auto is not None:
            self.info(f"{step.name} - trying automatically")
            try:
                if step.auto():
                    self.ok(f"{step.name} - handled automatically")
                    self.mark(key)
                    return True
            except Exception as exc:  # a failed auto path is not fatal
                self.warn(f"{step.name} - auto attempt failed: {exc}")
            self.warn(f"{step.name} - could not do this without you")

        if self.unattended:
            self.bail_unattended(step)

        self.needs_human(step)

        if step.done_when is not None:
            if self._poll(step):
                self.ok(f"{step.name} - detected, moving on")
                self.mark(key)
                return True
            if step.optional:
                self.warn(f"{step.name} - skipped")
                return False
            return False

        try:
            input(f"{BOLD}  press return when that's done "
                  f"(or type 'skip'): {RESET}").strip().lower()
        except EOFError:
            self.bail_unattended(step)
        self.mark(key)
        return True

    def _poll(self, step: Step) -> bool:
        """Wait for the step to finish itself. Re-announce, never nag silently."""
        deadline = time.time() + step.timeout
        last_ping = time.time()
        spin = "|/-\\"
        i = 0
        while time.time() < deadline:
            try:
                if step.done_when():
                    print()
                    return True
            except Exception:
                pass
            left = int(deadline - time.time())
            print(f"\r{DIM}  {spin[i % 4]} waiting for you  ({left}s){RESET}   ",
                  end="", flush=True)
            i += 1
            time.sleep(0.4)
            if time.time() - last_ping > 90:
                self._speak(step.instruction)
                last_ping = time.time()
        print()
        self.warn(f"{step.name} - timed out after {int(step.timeout)}s")
        return False

    # ---------- small helpers ----------

    def confirm(self, question: str, default: bool = False) -> bool:
        if self.unattended:
            self.info(f"unattended: assuming {'yes' if default else 'no'} for: {question}")
            return default
        suffix = "[Y/n]" if default else "[y/N]"
        try:
            answer = input(f"{BOLD}  {question} {suffix} {RESET}").strip().lower()
        except EOFError:
            return default
        if not answer:
            return default
        return answer.startswith("y")

    def wait_quiet(self, activity: Callable[[], float], quiet_for: float = 1.5,
                   timeout: float = 120.0, min_events: int = 1,
                   count: Callable[[], int] = lambda: 1) -> bool:
        """Return True once traffic has started and then gone quiet.

        This is how a capture ends without anyone pressing a key: MCC finishes
        its burst, the wire goes silent for `quiet_for` seconds, we stop.
        """
        deadline = time.time() + timeout
        started = False
        while time.time() < deadline:
            since = activity()
            if count() >= min_events:
                started = True
            if started and since > quiet_for:
                return True
            time.sleep(0.1)
        return started
