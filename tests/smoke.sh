#!/usr/bin/env bash
# Fast codexctl checks that need no Codex call and burn no usage limits.
set -uo pipefail
CTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/codex-bridge/scripts" && pwd)/codexctl.sh"
fails=0

check() { # description, expected exit code, command...
  local desc="$1" want="$2"; shift 2
  local out code
  out=$("$@" 2>&1); code=$?
  if [ "$code" -eq "$want" ]; then printf '  ✓ %s\n' "$desc"
  else printf '  ✗ %s (exit %s, expected %s)\n     %s\n' "$desc" "$code" "$want" "$(echo "$out" | head -1)"; fails=1; fi
}

echo "codexctl smoke tests:"
bash -n "$CTL" && echo "  ✓ syntax" || { echo "  ✗ syntax"; fails=1; }
check "usage with no arguments"        0 bash "$CTL"
check "unknown mode is rejected"       2 bash "$CTL" no-such-mode
check "unknown flag is rejected"       2 bash "$CTL" run --cwd /tmp --nosuchflag
check "run without --cwd is rejected"  2 bash "$CTL" run --prompt x
check "run without a prompt is rejected" 2 bash "$CTL" run --cwd /tmp
check "missing directory is rejected"  2 bash "$CTL" run --cwd /no/such/path --prompt x
check "unknown run id is rejected"     2 bash "$CTL" status --id no-such-run

echo
[ "$fails" -eq 0 ] && echo "all green" || echo "failures present"
exit "$fails"
