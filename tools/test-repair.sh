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
#
# The layout matters as much as the content. The harness writes the header in a
# frame of its own and every durable append batch in another, and it refuses a log
# whose first frame is not *exactly* one line. A fixture compressed as a single
# frame passes every line-based assertion and is still a log no harness will open,
# which is precisely how a frame-flattening bug once shipped here.
make_log() {
	python3 - "$1" "$2" <<'PY'
import json, subprocess, sys
out, kind = sys.argv[1], sys.argv[2]
header = json.dumps(
    {"type": "session", "version": 3, "id": "synthetic",
     "createdAt": 0, "cwd": "/tmp", "isSeeded": False,
     "delegationDepth": 0}, separators=(",", ":"))
events = [
    json.dumps({"type": "turn/start", "seq": 0, "time": 1, "data": {}},
               separators=(",", ":")),
]
if kind != "clean":
    events.append(json.dumps(
        {"type": "example-plugin/telemetry", "seq": 1, "time": 2,
         "data": {"endpoint": "https://example.test"}}, separators=(",", ":")))
events.append(json.dumps({"type": "turn/end", "seq": 2, "time": 3, "data": {}},
                         separators=(",", ":")))

def frame(text):
    return subprocess.run(["zstd", "-q", "-c", "--check"],
                          input=text.encode(), capture_output=True, check=True).stdout

frames = [frame(header + "\n")]
# Two events per frame, as the writer's append batches produce.
for start in range(0, len(events), 2):
    frames.append(frame("\n".join(events[start:start + 2]) + "\n"))
with open(out, "wb") as handle:
    handle.write(b"".join(frames))
PY
}

# Frame count, as the filesystem sees it -- the harness's own yardstick.
frames_of() {
	zstd --list "$1" 2>/dev/null | tail -1 | awk '{print $1}'
}

echo "session repair tests"

# ── the repair itself ────────────────────────────────────────────────────────

mkdir -p "$SCRATCH/ok/session-aaaa"
LOG="$SCRATCH/ok/session-aaaa/session.v3.jsonl.zstd"
make_log "$LOG" unknown

if python3 "$TOOL" "$LOG" --type example-plugin/telemetry >"$SCRATCH/out" 2>&1; then
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
unknown = [e for e in events if e["type"] == "example-plugin/telemetry"]
others = [e for e in events if e["type"] != "example-plugin/telemetry"]
assert len(unknown) == 1 and unknown[0].get("ignorable") is True, unknown
assert all("ignorable" not in e for e in others), others
# Order and sequence numbers must be untouched.
assert [e["seq"] for e in events] == [0, 1, 2], events
PY

# The rewrite must not reflow the log's physical frames. Getting this wrong
# produces a file that satisfies every check above and that the harness refuses
# to open, taking the whole GUI down with it.
if [ "$(frames_of "$LOG")" -gt 1 ]; then
	check "preserves the multi-frame layout" 1
else
	check "preserves the multi-frame layout" 0
fi

python3 - "$LOG" "$TOOL" <<'PY' && check "keeps the header alone in the first frame" 1 \
	|| check "keeps the header alone in the first frame" 0
import importlib.util, sys
path, tool = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("repair_sessions", tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
raw = open(path, "rb").read()
frames = module.frame_ranges(raw)
assert len(frames) > 1, f"expected several frames, found {len(frames)}"
first = module.decompress_bytes(raw[frames[0][0]:frames[0][1]])
# Exactly one line, terminated: header and nothing else.
assert first.count(b"\n") == 1 and first.endswith(b"\n"), first[:200]
PY

# ── the guards ───────────────────────────────────────────────────────────────

mkdir -p "$SCRATCH/clean/session-bbbb"
make_log "$SCRATCH/clean/session-bbbb/session.v3.jsonl.zstd" clean
if python3 "$TOOL" "$SCRATCH/clean/session-bbbb/session.v3.jsonl.zstd" \
	--type example-plugin/telemetry >/dev/null 2>&1; then
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
	--type example-plugin/telemetry >/dev/null 2>&1; then
	check "refuses a legacy-format log" 0
else
	check "refuses a legacy-format log" 1
fi

# A dry run must not modify anything.
mkdir -p "$SCRATCH/dry/session-ffff"
DRY="$SCRATCH/dry/session-ffff/session.v3.jsonl.zstd"
make_log "$DRY" unknown
BEFORE=$(shasum -a 256 "$DRY" | awk '{print $1}')
python3 "$TOOL" "$DRY" --type example-plugin/telemetry --dry-run >/dev/null 2>&1 || true
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
python3 "$TOOL" "$BK" --type example-plugin/telemetry >/dev/null 2>&1 || true
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