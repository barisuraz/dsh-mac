#!/bin/bash
# Real-environment acceptance test: default paths, real ~/.dsh, unsandboxed.
set -uo pipefail
APP="/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeekHarness"
LOG="$HOME/Library/Logs/DeepSeekHarness/wrapper.log"
SUPPORT="$HOME/Library/Application Support/DeepSeekHarness"

# Start from a genuinely clean managed state, as a new user would have.
rm -rf "$SUPPORT" "$LOG"

wait_for() { # pattern timeout
  local n=0
  while (( n < $2 )); do
    grep -qE "$1" "$LOG" 2>/dev/null && return 0
    sleep 2; n=$((n + 2))
  done
  return 1
}

echo "### LAUNCH 1 — fresh state, real ~/.dsh, default port (3080 is busy)"
"$APP" >/dev/null 2>&1 &
P1=$!
wait_for "main frame 200" 90 && echo "  served: yes" || echo "  served: NO"
wait_for "ready for next launch" 300 && echo "  staged a verified slot: yes" || echo "  staged: NO"
echo "  --- evidence ---"
grep -E "port 3080 is busy|no managed slot|booting|installing |verified in slot|update deferred" "$LOG" \
  | sed 's/token=[^& ]*/token=REDACTED/' | sed 's/^/    /'
kill $P1 2>/dev/null; wait $P1 2>/dev/null; sleep 3

echo
echo "### LAUNCH 2 — must boot the managed slot, not PATH"
rm -f "$LOG"
"$APP" >/dev/null 2>&1 &
P2=$!
wait_for "main frame 200" 90 && echo "  served: yes" || echo "  served: NO"
grep -E "booting managed slot|booting the harness from PATH|already the newest|verified in slot" "$LOG" \
  | sed 's/token=[^& ]*/token=REDACTED/' | sed 's/^/    /'
kill $P2 2>/dev/null; wait $P2 2>/dev/null; sleep 2

echo
echo "### RESULTING STATE"
python3 -c "
import json
d = json.load(open('$SUPPORT/state.json'))
for k, v in sorted(d['slots'].items()):
    print(f\"    slot {k}: {v['version']}  broken={v['broken']}  verified={v['verifiedAt'] is not None}  earlyExits={len(v['earlyExits'])}\")
print('    preferred:', d.get('preferred'), '| staged:', d.get('staged'), '| rejected:', list(d.get('rejected', {})))
"
echo "### DONE"
