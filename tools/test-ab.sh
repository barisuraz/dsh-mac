#!/bin/bash
#
# End-to-end tests for the A/B update and recovery behaviour.
#
# These drive the real app binary against fake harness copies, so the update
# machinery is exercised for real — slots, state file, health checks, rollback —
# without downloading anything or touching the user's own sessions.
#
# The scenarios encode the promise the app makes: a release that cannot start,
# or that starts and then dies, never leaves you without a working harness, and
# never costs you the previous good copy.
#
# Usage: tools/test-ab.sh [path/to/DeepSeekHarness]

set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HERE/build/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness}"

if [[ ! -x "$APP" ]]; then
  echo "no app binary at: $APP"
  echo "build it first with ./build.sh"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-ab-tests.XXXXXX")"
APP_PID=""
PASS=0
FAIL=0

cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
  # The app supervises its server, but a fake copy may outlive it briefly.
  pkill -f "$WORK" 2>/dev/null
  sleep 1
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { echo "  [ ok ] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ── helpers ──────────────────────────────────────────────────────────────────

# A fake harness that serves one HTTP 200 and stays up.
write_good_harness() {
  cat > "$1" <<'SCRIPT'
#!/bin/zsh
PORT=0
while [[ $# -gt 0 ]]; do case "$1" in --port) PORT="$2"; shift 2;; *) shift;; esac; done
exec python3 -c "
import http.server, socket, sys, time
port = $PORT
if port == 0:
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', port), H)
print(f'dsh web: http://127.0.0.1:{port}/?token=FAKETOKEN', flush=True)
while True: srv.handle_request()
"
SCRIPT
  chmod +x "$1"
}

# A fake harness that cannot start at all — a broken upstream release.
write_broken_harness() {
  cat > "$1" <<'SCRIPT'
#!/bin/zsh
echo "simulated broken release: cannot boot" >&2
exit 1
SCRIPT
  chmod +x "$1"
}

# A fake harness that serves, then dies seconds later — a crash loop.
write_crashy_harness() {
  cat > "$1" <<'SCRIPT'
#!/bin/zsh
PORT=0
while [[ $# -gt 0 ]]; do case "$1" in --port) PORT="$2"; shift 2;; *) shift;; esac; done
python3 -c "
import http.server, socket, sys, threading, time
port = $PORT
if port == 0:
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', port), H)
print(f'dsh web: http://127.0.0.1:{port}/?token=FAKETOKEN', flush=True)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(2); sys.exit(1)
"
exit 1
SCRIPT
  chmod +x "$1"
}

# Seed the state file: $1 = dir, $2 = preferred slot, $3 = staged slot or "-"
seed_state() {
  local dir="$1" preferred="$2" staged="$3" a_version="$4" b_version="$5"
  python3 - "$dir" "$preferred" "$staged" "$a_version" "$b_version" <<'PY'
import json, sys
d, preferred, staged, a_version, b_version = sys.argv[1:6]
now = __import__("time").time() - 978307200  # JSONEncoder uses the reference date
def slot(v):
    return {"version": v, "installedAt": now, "verifiedAt": now, "broken": False, "earlyExits": []}
state = {"slots": {"a": slot(a_version), "b": slot(b_version)},
         "preferred": preferred, "updatedAt": now, "rejected": {}}
if staged != "-":
    state["staged"] = staged
json.dump(state, open(f"{d}/state.json", "w"))
PY
}

# Read a field from the state file: $1 = dir, $2 = python expression over `d`
state_query() { python3 -c "
import json; d = json.load(open('$1/state.json'))
print($2)"; }

# Launch the app against a scratch support dir and wait for a log line.
# $1 = support dir, $2 = port
launch_app() {
  DSH_APP_SUPPORT="$1" \
  DSH_HOME="$WORK/home" \
  DSH_NO_AUTO_UPDATE=1 \
  DSH_WRAPPER_LOG="$1/wrapper.log" \
  DSH_WRAPPER_PORT="$2" \
  "$APP" >/dev/null 2>&1 &
  APP_PID=$!
}

# Wait until the log matches a pattern, or time out.
await_log() {
  local file="$1" pattern="$2" timeout="${3:-45}" waited=0
  while (( waited < timeout )); do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

mkdir -p "$WORK/home"

# ── Scenario 1: a staged release that cannot start ───────────────────────────
#
# The update was staged and verified by the previous run, but on this launch it
# cannot boot. The app must fall back to the previous version and mark the bad
# one so it is not tried again.

echo "scenario 1: staged release fails to start"
S1="$WORK/s1"
mkdir -p "$S1/slots/a/node_modules/.bin" "$S1/slots/b/node_modules/.bin"
write_good_harness   "$S1/slots/a/node_modules/.bin/dsh"
write_broken_harness "$S1/slots/b/node_modules/.bin/dsh"
seed_state "$S1" a b "0.1.4-good" "0.1.5-broken"

launch_app "$S1" 3481
if await_log "$S1/wrapper.log" "main frame 200" 45; then
  ok "recovered and served the interface"
else
  bad "never reached the interface"
fi

check "bad slot marked broken"  "$(state_query "$S1" "d['slots']['b']['broken']")" "True"
check "good slot untouched"     "$(state_query "$S1" "d['slots']['a']['version']")" "0.1.4-good"
check "prefers the good slot"   "$(state_query "$S1" "d['preferred']")" "a"
check "bad version blacklisted" "$(state_query "$S1" "'0.1.5-broken' in d['rejected']")" "True"
grep -q "booting managed slot a" "$S1/wrapper.log" \
  && ok "booted the good slot" || bad "did not boot the good slot"
grep -q "rolled back" "$S1/wrapper.log" && ok "logged the rollback" || bad "no rollback in the log"

kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
sleep 2

# ── Scenario 2: a release that starts, then keeps dying ──────────────────────
#
# The harder case: it boots and serves, so the startup check passes. Only
# repeated early exits reveal that it is broken. The crash-loop guard must
# notice, and — critically — the fallback copy must survive so there is
# something to roll back to.

echo
echo "scenario 2: staged release keeps crashing after startup"
S2="$WORK/s2"
mkdir -p "$S2/slots/a/node_modules/.bin" "$S2/slots/b/node_modules/.bin"
write_good_harness  "$S2/slots/a/node_modules/.bin/dsh"
write_crashy_harness "$S2/slots/b/node_modules/.bin/dsh"
seed_state "$S2" a b "0.1.4-good" "0.1.6-crashes"

launch_app "$S2" 3482
if await_log "$S2/wrapper.log" "rolled back" 90; then
  ok "detected the crash loop and rolled back"
else
  bad "never rolled back after repeated crashes"
fi
# Give the fallback a moment to come up.
sleep 6

check "bad slot marked broken"     "$(state_query "$S2" "d['slots']['b']['broken']")" "True"
check "counted the early exits"    "$(state_query "$S2" "len(d['slots']['b']['earlyExits'])")" "3"
check "fallback survived intact"   "$(state_query "$S2" "d['slots']['a']['version']")" "0.1.4-good"
check "fallback not marked broken" "$(state_query "$S2" "d['slots']['a']['broken']")" "False"
check "prefers the fallback"       "$(state_query "$S2" "d['preferred']")" "a"
grep -q "booting managed slot b" "$S2/wrapper.log" \
  && ok "tried the staged version first" || bad "never tried the staged version"
grep -q "booting managed slot a" "$S2/wrapper.log" \
  && ok "switched to the fallback slot" || bad "never switched to the fallback"
grep -q "early exits in the window" "$S2/wrapper.log" \
  && ok "logged the crash-loop counts" || bad "no crash-loop counts in the log"

kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
sleep 2

# ── Scenario 3: a healthy version is booted and recorded ─────────────────────
#
# The control case: nothing is broken, so nothing is disturbed.

echo
echo "scenario 3: healthy boot leaves a verified slot and a clean record"
S3="$WORK/s3"
mkdir -p "$S3/slots/a/node_modules/.bin" "$S3/slots/b/node_modules/.bin"
write_good_harness "$S3/slots/a/node_modules/.bin/dsh"
write_good_harness "$S3/slots/b/node_modules/.bin/dsh"
seed_state "$S3" a "-" "0.1.5-rc.1" "0.1.4-good"

launch_app "$S3" 3483
if await_log "$S3/wrapper.log" "main frame 200" 45; then
  ok "served the interface"
else
  bad "never reached the interface"
fi

check "booted the preferred slot" "$(state_query "$S3" "d['slots']['a']['version']")" "0.1.5-rc.1"
check "nothing marked broken"     "$(state_query "$S3" "any(s['broken'] for s in d['slots'].values())")" "False"
check "no crash history"          "$(state_query "$S3" "sum(len(s['earlyExits']) for s in d['slots'].values())")" "0"
check "nothing blacklisted"       "$(state_query "$S3" "len(d['rejected'])")" "0"
[[ -z "$(state_query "$S3" "d.get('staged')")" || "$(state_query "$S3" "d.get('staged')")" == "None" ]] \
  && ok "auto-update stayed off, so nothing was staged" \
  || bad "staged something despite DSH_NO_AUTO_UPDATE=1"

kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""

echo
echo "──────────────────────────────────────────"
echo "A/B recovery tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
