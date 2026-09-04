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
check "bad --effort is rejected"       2 bash "$CTL" run --cwd /tmp --prompt x --effort turbo

# --- run selection: a newer run from another session in another project must not
# --- be picked up when --id is omitted (a real incident, 2026-09-02)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/runs" "$TMP/projA" "$TMP/projB"
mkrun() { # id, cwd, session, started_at
  mkdir -p "$TMP/runs/$1"
  printf '{"id":"%s","cwd":"%s","session_id":"%s","started_at":%s,"state":"done","mode":"run"}\n' \
    "$1" "$2" "$3" "$4" > "$TMP/runs/$1/meta.json"
  : > "$TMP/runs/$1/run.jsonl"
}
mkrun projA-old "$TMP/projA" SESSION-A 100
mkrun projB-new "$TMP/projB" SESSION-B 200   # newer, but a different session and project

picked() { # session, dir -> prints the chosen run id
  ( cd "$2" && CODEX_RUNS_DIR="$TMP/runs" CLAUDE_CODE_SESSION_ID="$1" \
      bash "$CTL" status 2>/dev/null | awk '/^run:/{print $2}' )
}

echo
echo "run selection:"
got=$(picked SESSION-A "$TMP/projA")
[ "$got" = "projA-old" ] \
  && echo "  ✓ own session wins over a newer foreign run" \
  || { echo "  ✗ own session: picked '$got', expected projA-old"; fails=1; }

got=$(picked SESSION-A "$TMP/projB")
[ "$got" = "projA-old" ] \
  && echo "  ✓ session binding survives a wrong working directory" \
  || { echo "  ✗ wrong directory: picked '$got', expected projA-old"; fails=1; }

got=$(picked "" "$TMP/projA")
[ "$got" = "projA-old" ] \
  && echo "  ✓ without a session, falls back to the current project" \
  || { echo "  ✗ fallback: picked '$got', expected projA-old"; fails=1; }

out=$( cd "$TMP" && CODEX_RUNS_DIR="$TMP/runs" CLAUDE_CODE_SESSION_ID=SESSION-UNKNOWN \
       bash "$CTL" status 2>&1 ); code=$?
[ "$code" -eq 2 ] && [ -z "${out##*no run belongs*}" ] \
  && echo "  ✓ neither session nor project matches: refuses instead of guessing" \
  || { echo "  ✗ unmatched: exit $code, output: $(echo "$out" | head -1)"; fails=1; }

echo
[ "$fails" -eq 0 ] && echo "all green" || echo "failures present"
exit "$fails"
