#!/bin/sh
#
# Tests for tools/repair-sessions.py.
#
# The tool rewrites a user's session logs, so its refusals matter more than its
# rewrites: a repair applied to the wrong thing, or underneath a running
# harness, loses data quietly. These build synthetic logs in a scratch directory
# and check both the repairs and the guards.

set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$HERE/tools/repair-sessions.py"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

PASS=0
FAIL=0

check() {
	if [ "$2" = "1" ]; then
		echo "  [ ok ] $1"
		PASS=$((PASS + 1))
	else
		echo "  [FAIL] $1"
		FAIL=$((FAIL + 1))
	fi
}

command -v zstd >/dev/null || {
	echo "error: zstd is required" >&2
	exit 1
}

# A minimal current-format log: one header line, then events. The unknown event
# is the one the tool is allowed to mark; the known one must be left alone.
make_log() {
	python3 - "$1" "$2" <<'PY'
import json, subprocess, sys
out, kind = sys.argv[1], sys.argv[2]
lines = [
    json.dumps({"type": "session", "version": 3, "id": "synthetic",
                "createdAt": 0, "cwd": "/tmp", "isSeeded": False,
                "delegationDepth": 0}, separators=(",", ":")),
    json.dumps({"type": "turn/start", "seq": 0, "time": 1, "data": {}},
               separators=(",", ":")),
]
if kind != "clean":
    lines.append(json.dumps(
        {"type": "web/keiro-search-request", "seq": 1, "time": 2,
         "data": {"endpoint": "https://example.test"}}, separators=(",", ":")))
lines.append(json.dumps({"type": "turn/end", "seq": 2, "time": 3, "data": {}},
                        separators=(",", ":")))
payload = ("\n".join(lines) + "\n").encode()
subprocess.run(["zstd", "-q", "-f", "-o", out], input=payload, check=True)
PY
}

echo "session repair tests"

# ── the repair itself ────────────────────────────────────────────────────────

mkdir -p "$SCRATCH/ok/session-aaaa"
LOG="$SCRATCH/ok/session-aaaa/session.v3.jsonl.zstd"
make_log "$LOG" unknown

if python3 "$TOOL" "$LOG" --type web/keiro-search-request >"$SCRATCH/out" 2>&1; then
	check "repairs a log with a named unknown event" 1
else
	check "repairs a log with a named unknown event" 0
	sed 's/^/        /' "$SCRATCH/out"
fi

# The marker must be present on exactly the offending event, and the rest of
# the log must be unchanged.
python3 - "$LOG" <<'PY' && check "marks only the named event, leaving others intact" 1 \
	|| check "marks only the named event, leaving others intact" 0
import json, subprocess, sys
raw = subprocess.run(["zstd","-dc",sys.argv[1]], capture_output=True, check=True).stdout
events = [json.loads(l) for l in raw.split(b"\n") if l.strip()][1:]
unknown = [e for e in events if e["type"] == "web/keiro-search-request"]
others = [e for e in events if e["type"] != "web/keiro-search-request"]
assert len(unknown) == 1 and unknown[0].get("ignorable") is True, unknown
assert all("ignorable" not in e for e in others), others
# Order and sequence numbers must be untouched.
assert [e["seq"] for e in events] == [0, 1, 2], events
PY

# ── the guards ───────────────────────────────────────────────────────────────

mkdir -p "$SCRATCH/clean/session-bbbb"
make_log "$SCRATCH/clean/session-bbbb/session.v3.jsonl.zstd" clean
if python3 "$TOOL" "$SCRATCH/clean/session-bbbb/session.v3.jsonl.zstd" \
	--type web/keiro-search-request >/dev/null 2>&1; then
	check "leaves an already-loadable log alone" 1
else
	check "leaves an already-loadable log alone" 0
fi

# Without --type it must report and refuse, never guess.
mkdir -p "$SCRATCH/guess/session-cccc"
make_log "$SCRATCH/guess/session-cccc/session.v3.jsonl.zstd" unknown
if python3 "$TOOL" "$SCRATCH/guess/session-cccc/session.v3.jsonl.zstd" \
	>/dev/null 2>&1; then
	check "refuses to guess which event type is safe" 0
else
	check "refuses to guess which event type is safe" 1
fi

# An unnamed unknown type must not be touched even when another type is named.
mkdir -p "$SCRATCH/other/session-dddd"
make_log "$SCRATCH/other/session-dddd/session.v3.jsonl.zstd" unknown
if python3 "$TOOL" "$SCRATCH/other/session-dddd/session.v3.jsonl.zstd" \
	--type something/else >/dev/null 2>&1; then
	check "refuses an event type that was not named" 0
else
	check "refuses an event type that was not named" 1
fi

# Legacy logs are read by the migration layer; the current type set is the
# wrong yardstick for them, so the tool must decline rather than guess.
mkdir -p "$SCRATCH/legacy/session-eeee"
make_log "$SCRATCH/legacy/session-eeee/session.jsonl.zstd" unknown
if python3 "$TOOL" "$SCRATCH/legacy/session-eeee/session.jsonl.zstd" \
	--type web/keiro-search-request >/dev/null 2>&1; then
	check "refuses a legacy-format log" 0
else
	check "refuses a legacy-format log" 1
fi

# A dry run must not modify anything.
mkdir -p "$SCRATCH/dry/session-ffff"
DRY="$SCRATCH/dry/session-ffff/session.v3.jsonl.zstd"
make_log "$DRY" unknown
BEFORE=$(shasum -a 256 "$DRY" | awk '{print $1}')
python3 "$TOOL" "$DRY" --type web/keiro-search-request --dry-run >/dev/null 2>&1 || true
AFTER=$(shasum -a 256 "$DRY" | awk '{print $1}')
if [ "$BEFORE" = "$AFTER" ]; then
	check "a dry run writes nothing" 1
else
	check "a dry run writes nothing" 0
fi

# A backup must be kept for every repair.
mkdir -p "$SCRATCH/backup/session-gggg"
BK="$SCRATCH/backup/session-gggg/session.v3.jsonl.zstd"
make_log "$BK" unknown
python3 "$TOOL" "$BK" --type web/keiro-search-request >/dev/null 2>&1 || true
if [ "$(find "$HOME/.dsh/session-format-repairs" -name 'session-gggg.*' 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]; then
	check "keeps a backup of the original" 1
	rm -f "$HOME"/.dsh/session-format-repairs/session-gggg.* 2>/dev/null || true
else
	check "keeps a backup of the original" 0
fi

echo
echo "──────────────────────────────────────────"
echo "session repair tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1