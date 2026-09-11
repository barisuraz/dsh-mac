#!/usr/bin/env python3
"""Mark known-informational plugin session events as `ignorable`.

Why this exists
---------------
A stored session log containing an event type the harness does not know is
refused outright, unless the event carries the envelope marker
`ignorable: true`:

    session "..." contains event type "web/keiro-search-request" (seq 18)
    unknown to this harness and not marked ignorable; refusing to interpret
    the log — it was likely written by a newer harness

That refusal is deliberate and correct: silently skipping an event that shapes
reconstruction would resume a subtly wrong session. But the harness's known-type
catalog is generated in-repo, so an **out-of-repo plugin's** events are outside
it `by construction` — and `Session.append()` gives a plugin no way to set the
`ignorable` marker. So a plugin that appends its own event type writes a log
that no harness can ever reload, including the one that wrote it. `append` does
not validate on write, so nothing fails until the next time the session is
opened.

This tool is the recovery path. It marks the named event types as skippable so
the log loads again.

Current-format logs only
------------------------
It works on `session.v3.jsonl.zstd`. Older `session.jsonl.zstd` logs are read
through a migration layer with its own disposition table for historical event
types, so the current known-type set is the wrong yardstick for them and this
tool refuses them rather than reporting noise.

Use it only for events you know are informational
------------------------------------------------
Marking an event ignorable tells every future reader to discard it. That is
safe when losing the event cannot change how the rest of the log is read —
request records, timings, telemetry — and unsafe otherwise. The event type must
therefore be named explicitly; this tool never guesses. Read the plugin's
source and confirm the event is informational before passing `--type`.

Nothing else in the log is touched: only the offending lines are re-serialized,
and every other byte of every other line is preserved exactly. A copy of each
original is kept outside the sessions tree, where the harness will not see it.

The session must not be open
----------------------------
A running harness holds its session in memory and rewrites the log when it
flushes, so edits made while it runs are lost. Re-run this after the harness
that owns the session has exited.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

BACKUP_ROOT = os.path.expanduser("~/.dsh/session-format-repairs")


def known_types() -> set:
    """The harness's event catalog, exported next to this script.

    Regenerate with:
      node -e 'const m=require("@deepseek-ai/dsh-session"); \\
        console.log(JSON.stringify([...m.KNOWN_SESSION_EVENT_TYPES]))' \\
        > tools/known-event-types.json
    """
    override = os.environ.get("DSH_KNOWN_TYPES")
    candidates = [
        override,
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "tools", "known-event-types.json"),
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            with open(path) as handle:
                return set(json.load(handle))
    raise SystemExit(
        "error: no known-event-types.json found; set DSH_KNOWN_TYPES to one")


def decompress(path: str) -> bytes:
    result = subprocess.run(["zstd", "-dc", path], capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode().strip() or "zstd failed")
    return result.stdout


def scan(raw: bytes, known: set) -> dict:
    """Unknown, non-ignorable event types in a decompressed log, with counts."""
    counts: dict = {}
    for index, line in enumerate(raw.split(b"\n")):
        line = line.strip()
        if not line or index == 0:
            continue  # the first line is the stored header, not an event
        try:
            event = json.loads(line)
        except Exception:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind and kind not in known and event.get("ignorable") is not True:
            counts[kind] = counts.get(kind, 0) + 1
    return counts


def lock_holders(path: str) -> str:
    """Names of processes holding the session's lock file, if any.

    A harness keeps the session in memory and rewrites the log when it flushes,
    so a repair applied underneath a running harness is simply overwritten. The
    lock is how that is detected rather than guessed at.
    """
    lock = os.path.join(os.path.dirname(path), "session.lock")
    if not os.path.exists(lock):
        return ""
    result = subprocess.run(["lsof", "-t", lock], capture_output=True)
    pids = result.stdout.decode().split()
    if not pids:
        return ""
    names = set()
    for pid in pids:
        shown = subprocess.run(["ps", "-p", pid, "-o", "comm="],
                               capture_output=True).stdout.decode().strip()
        names.add(f"{os.path.basename(shown) or 'pid ' + pid} (pid {pid})")
    return ", ".join(sorted(names))


def backup(path: str) -> str:
    os.makedirs(BACKUP_ROOT, exist_ok=True)
    session_id = os.path.basename(os.path.dirname(path))
    destination = os.path.join(BACKUP_ROOT, f"{session_id}.{int(time.time())}.zstd")
    shutil.copy2(path, destination)
    return destination


def rewrite(path: str, raw: bytes, types: set) -> int:
    """Mark events of `types` ignorable. Returns how many were changed."""
    out = []
    changed = 0
    for index, line in enumerate(raw.split(b"\n")):
        keep = line
        stripped = line.strip()
        if index > 0 and stripped:
            try:
                event = json.loads(stripped)
            except Exception:
                event = None
            if (isinstance(event, dict) and event.get("type") in types
                    and event.get("ignorable") is not True):
                event["ignorable"] = True
                keep = json.dumps(event, separators=(",", ":"),
                                  ensure_ascii=False).encode()
                changed += 1
        out.append(keep)

    if changed == 0:
        return 0

    # Compress beside the target and replace atomically, so an interrupted run
    # cannot leave a half-written session.
    temp = os.path.join(os.path.dirname(path), ".session-repair.tmp.zst")
    proc = subprocess.run(["zstd", "-q", "-f", "-o", temp], input=b"\n".join(out))
    if proc.returncode != 0:
        raise RuntimeError("could not recompress the log")
    os.replace(temp, path)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mark informational plugin events as ignorable so their "
                    "sessions load again.")
    parser.add_argument("sessions", nargs="+",
                        help="session.v3.jsonl.zstd files")
    parser.add_argument("--type", action="append", default=[], metavar="TYPE",
                        help="event type that may be marked ignorable; repeatable. "
                             "Without it, this only reports.")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change and write nothing")
    args = parser.parse_args()

    known = known_types()
    failures = 0

    for path in args.sessions:
        name = os.path.basename(os.path.dirname(path)) or path
        if not os.path.isfile(path):
            print(f"  missing: {path}")
            failures += 1
            continue

        if not os.path.basename(path).startswith("session.v3."):
            print(f"  {name}: not a current-format log (expected session.v3.*); "
                  f"the migration layer reads this one and needs different handling")
            failures += 1
            continue

        held = lock_holders(path)
        if held and not args.dry_run:
            print(f"  {name}: still open by {held}; a live harness would "
                  f"overwrite the repair — close it first")
            failures += 1
            continue

        try:
            raw = decompress(path)
        except Exception as error:
            print(f"  {name}: cannot read: {error}")
            failures += 1
            continue

        before = scan(raw, known)
        if not before:
            print(f"  {name}: loads fine, nothing to do")
            continue

        unknown_to_tool = set(before) - set(args.type)
        if unknown_to_tool:
            print(f"  {name}: has unknown event types not named with --type:")
            for kind in sorted(unknown_to_tool):
                print(f"      {before[kind]:5d}x  {kind}")
            if not args.type:
                print("      re-run with --type <TYPE> once you have confirmed "
                      "the event is informational")
            failures += 1
            continue

        if args.dry_run:
            print(f"  {name}: would mark " +
                  ", ".join(f"{n}x {t}" for t, n in sorted(before.items())))
            continue

        try:
            saved = backup(path)
            changed = rewrite(path, raw, set(args.type))
        except Exception as error:
            print(f"  {name}: FAILED: {error}")
            failures += 1
            continue

        after = scan(decompress(path), known)
        if after:
            print(f"  {name}: still has unknown events after the rewrite: {after}")
            failures += 1
            continue

        print(f"  {name}: marked {changed} event(s) ignorable; loads now")
        print(f"      original kept at {saved}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
