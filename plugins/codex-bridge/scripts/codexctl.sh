#!/usr/bin/env bash
# codexctl — the single entry point for running Codex from Claude Code.
# Every codex flag is baked in here. Callers only get the modes below.
set -uo pipefail

RUNS_DIR="${CODEX_RUNS_DIR:-$HOME/.claude/codex-runs}"
STALL_SECONDS="${CODEX_STALL_SECONDS:-180}"

die() { echo "ERROR: $*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
codexctl — run Codex through a fixed set of modes.

  codexctl run     --cwd DIR (--prompt TEXT | --prompt-file F) [--model M] [--effort L]
      Task with write access. Blocks until done — run it in the background.

  codexctl review  --cwd DIR [--base REF] [--prompt TEXT] [--model M] [--effort L]
      Review with no write access. Blocks until done — run it in the background.

  codexctl resume  --id ID (--prompt TEXT | --prompt-file F) [--effort L]
      Follow-up in the same Codex session. Blocks until done.

  codexctl status  [--id ID]      Run state: running / silent / done / failed.
  codexctl result  [--id ID]      Outcome: Codex's answer and what changed in the repo.
  codexctl cancel  [--id ID]      Stop a run.
  codexctl list                   Recent runs.

--model and --effort are passed through untouched. Omit them and Codex uses its
own defaults; set a standing preference in ~/.codex/config.toml.

There are no other flags. Sandbox, network, .git access and environment
filtering are handled inside.
USAGE
}

# ---------- helpers ----------

json_get() { python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],''))
except Exception: print('')
" "$1" "$2" 2>/dev/null; }

json_set() { python3 -c "
import json,sys,os
p=sys.argv[1]
d=json.load(open(p)) if os.path.exists(p) else {}
for i in range(2,len(sys.argv),2): d[sys.argv[i]]=sys.argv[i+1]
json.dump(d,open(p,'w'),ensure_ascii=False,indent=1)
" "$@"; }

# Project root for the current directory: the git top level if there is one, else $PWD.
current_project() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# Newest run whose meta field $1 equals $2. Exits 1 when there is no match.
find_run() {
python3 - "$RUNS_DIR" "$1" "${2:-}" <<'FIND'
import json,os,sys
runs,field,want=sys.argv[1],sys.argv[2],sys.argv[3]
if not want or not os.path.isdir(runs): sys.exit(1)
best=None
for name in os.listdir(runs):
    meta=os.path.join(runs,name,'meta.json')
    if not os.path.exists(meta): continue
    try: d=json.load(open(meta))
    except Exception: continue
    if str(d.get(field,'')) != want: continue
    try: t=int(d.get('started_at') or 0)
    except Exception: t=0
    if best is None or t>best[0]: best=(t,os.path.join(runs,name))
if best is None: sys.exit(1)
print(best[1])
FIND
}

# Picks the run to act on. With no --id the choice is never "whatever ran last on
# this machine": a run started by another Claude Code session in another project
# must not be reachable by accident, because resume takes its working directory
# from the run it continues.
resolve_run() {
  local id="${1:-}" r here rcwd
  here=$(current_project)
  if [ -n "$id" ]; then
    [ -d "$RUNS_DIR/$id" ] || die "no such run: $id"
    r="$RUNS_DIR/$id"
    rcwd=$(json_get "$r/meta.json" cwd)
    if [ -n "$rcwd" ] && [ "$rcwd" != "$here" ]; then
      echo "WARNING: run $id belongs to $rcwd, not to $here" >&2
    fi
    echo "$r"; return 0
  fi
  # 1. the newest run started by this Claude Code session
  if r=$(find_run session_id "${CLAUDE_CODE_SESSION_ID:-}"); then echo "$r"; return 0; fi
  # 2. failing that, the newest run in the current project
  if r=$(find_run cwd "$here"); then
    echo "note: no run from this session, using the newest run of $here" >&2
    echo "$r"; return 0
  fi
  die "no run belongs to this session or to $here — choose one explicitly: codexctl list, then --id <ID>"
}

human_age() {
  local s=$1
  if   [ "$s" -lt 60 ]   ; then echo "${s}s"
  elif [ "$s" -lt 3600 ] ; then echo "$((s/60))m $((s%60))s"
  else echo "$((s/3600))h $(((s%3600)/60))m"; fi
}

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# Prints events from the jsonl log starting at line $2, then the total line count.
print_events() {
python3 - "$1" "$2" <<'PY'
import json,sys,time
path,start=sys.argv[1],int(sys.argv[2])
try: lines=open(path,encoding='utf-8',errors='replace').read().splitlines()
except FileNotFoundError: lines=[]
for i,line in enumerate(lines[start:],start=start):
    try: d=json.loads(line)
    except Exception: continue
    if d.get('type')!='item.completed': continue
    it=d.get('item') or {}
    kind=it.get('item_type') or it.get('type') or ''
    ts=time.strftime('%H:%M:%S')
    if kind in ('agent_message','AgentMessage'):
        txt=(it.get('text') or '').replace('\n',' ')[:150]
        print(f"[{ts}] thinks  {txt}",flush=True)
    elif kind in ('command_execution','CommandExecution'):
        cmd=it.get('command')
        if isinstance(cmd,list): cmd=' '.join(cmd[-1:])
        cmd=(str(cmd or '')).replace('\n',' ')[:150]
        print(f"[{ts}] runs    {cmd}",flush=True)
    elif kind in ('file_change','FileChange'):
        n=len(it.get('changes') or it.get('files') or [])
        print(f"[{ts}] edits   files: {n if n else '?'}",flush=True)
print(f"__LINES__{len(lines)}")
PY
}

thread_id_of() {
  python3 -c "
import json,sys
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    try: d=json.loads(line)
    except Exception: continue
    if d.get('type')=='thread.started': print(d.get('thread_id','')); break
" "$1" 2>/dev/null
}

has_turn_completed() { grep -q '"type":"turn.completed"' "$1" 2>/dev/null; }

# Validates --effort if one was given. The plugin never substitutes a value of its
# own: with no flag, the model's own default applies, and a standing preference
# belongs in the user's ~/.codex/config.toml, not in here.
check_effort() {
  local want="${1:-}"
  [ -n "$want" ] || return 0
  case "$want" in
    low|medium|high|xhigh|max|ultra) echo "$want";;
    *) die "unknown --effort: $want (low, medium, high, xhigh, max, ultra; not every model supports every level)";;
  esac
}

# -u flags stripping Claude Code variables from the environment Codex inherits
unset_flags() { env | grep -oE '^CLAUDE[A-Z_]*' | sed 's/^/-u /' | tr '\n' ' '; }

# ---------- core: a single run ----------

# execute_run <run_dir> <cwd> <sandbox> <prompt_file> <model> <resume_thread|""> <effort|"">
execute_run() {
  local RUN="$1" CWD="$2" SANDBOX="$3" PROMPT_FILE="$4" MODEL="$5" RESUME="$6" EFFORT="${7:-}"
  local args=()

  if [ -n "$RESUME" ]; then
    # `codex exec resume` has no --cd and no -s: the working directory comes from
    # cd, the sandbox only from -c. Verified 2026-09-02, do not "simplify" back.
    args=(exec resume --json -c "sandbox_mode=\"$SANDBOX\"")
  else
    args=(exec --json --cd "$CWD" -s "$SANDBOX")
  fi
  if [ "$SANDBOX" = "workspace-write" ]; then
    args+=(-c "sandbox_workspace_write.writable_roots=[\"$CWD/.git\"]")
  fi
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  [ -n "$EFFORT" ] && args+=(-c "model_reasoning_effort=\"$EFFORT\"")
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || args+=(--skip-git-repo-check)
  args+=(-o "$RUN/final.md")
  [ -n "$RESUME" ] && args+=("$RESUME")
  args+=(-)

  echo "launching: codex ${args[*]}" > "$RUN/cmd.txt"

  # shellcheck disable=SC2046
  ( cd "$CWD" && exec env $(unset_flags) codex "${args[@]}" ) \
      < "$PROMPT_FILE" > "$RUN/run.jsonl" 2> "$RUN/err.log" &
  local pid=$!
  json_set "$RUN/meta.json" pid "$pid" state running

  local line=0 warned=0 out
  while kill -0 "$pid" 2>/dev/null; do
    out=$(print_events "$RUN/run.jsonl" "$line")
    echo "$out" | grep -v '^__LINES__' | grep -v '^$'
    line=$(echo "$out" | sed -n 's/^__LINES__//p' | tail -1); line=${line:-0}
    local age=$(( $(date +%s) - $(mtime "$RUN/run.jsonl") ))
    if [ "$age" -gt "$STALL_SECONDS" ] && [ "$warned" -eq 0 ]; then
      echo "[!] Codex has been silent for $(human_age "$age") — it may be stuck. Check: codexctl status"
      warned=1
    elif [ "$age" -le "$STALL_SECONDS" ]; then warned=0; fi
    sleep 3
  done
  wait "$pid"; local code=$?

  out=$(print_events "$RUN/run.jsonl" "$line")
  echo "$out" | grep -v '^__LINES__' | grep -v '^$'

  local tid; tid=$(thread_id_of "$RUN/run.jsonl")
  local state="done"
  if [ "$code" -ne 0 ]; then state="failed"
  elif ! has_turn_completed "$RUN/run.jsonl"; then state="incomplete"; fi
  json_set "$RUN/meta.json" state "$state" exit_code "$code" thread_id "${tid:-}" \
           finished_at "$(date +%s)"

  echo
  case "$state" in
    done)       echo "OUTCOME: Codex finished normally." ;;
    failed)     echo "OUTCOME: Codex exited with an error (code $code). Tail of err.log:"; tail -5 "$RUN/err.log" ;;
    incomplete) echo "OUTCOME: Codex was cut off mid-turn. Tail of err.log:"; tail -5 "$RUN/err.log" ;;
  esac
  summarize_changes "$RUN"
  echo "run id: $(basename "$RUN")"
  [ "$state" = "done" ] && return 0 || return 1
}

summarize_changes() {
  local RUN="$1" CWD BASE
  CWD=$(json_get "$RUN/meta.json" cwd); BASE=$(json_get "$RUN/meta.json" baseline_tag)
  [ -d "$CWD/.git" ] || return 0
  local dirty commits
  dirty=$(git -C "$CWD" status --short 2>/dev/null | wc -l | tr -d ' ')
  commits=0
  [ -n "$BASE" ] && commits=$(git -C "$CWD" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)
  echo "changes: $dirty uncommitted file(s), $commits new commit(s) since ${BASE:-—}"
}

# ---------- modes ----------

cmd_run() {
  local CWD="" PROMPT="" PROMPT_FILE="" MODEL="" SANDBOX="workspace-write" MODE="run" BASE="" EFFORT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) CWD="$2"; shift 2;;
      --prompt) PROMPT="$2"; shift 2;;
      --prompt-file) PROMPT_FILE="$2"; shift 2;;
      --model) MODEL="$2"; shift 2;;
      --effort) EFFORT="$2"; shift 2;;
      --base) BASE="$2"; shift 2;;
      --readonly) SANDBOX="read-only"; MODE="review"; shift;;
      *) die "unknown flag: $1 (see codexctl --help)";;
    esac
  done
  [ -n "$CWD" ] || die "--cwd is required"
  [ -d "$CWD" ] || die "no such directory: $CWD"
  CWD=$(cd "$CWD" && pwd)
  command -v codex >/dev/null 2>&1 || die "codex is not installed"
  EFFORT=$(check_effort "$EFFORT") || exit 2

  local ID RUN
  ID="$(basename "$CWD")-$(date +%Y%m%d-%H%M%S)"
  RUN="$RUNS_DIR/$ID"; mkdir -p "$RUN"

  if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "no such file: $PROMPT_FILE"
    cp "$PROMPT_FILE" "$RUN/prompt.md"
  elif [ -n "$PROMPT" ]; then
    printf '%s\n' "$PROMPT" > "$RUN/prompt.md"
  else die "--prompt or --prompt-file is required"; fi

  if [ "$MODE" = "review" ]; then
    local target="the uncommitted changes"
    [ -n "$BASE" ] && target="the changes relative to branch $BASE"
    { echo; echo "Review $target. Do not fix anything — only list the problems you find,"
      echo "each with file and line, what is wrong, and why it is a defect."
      echo "If there are no problems, say so."; } >> "$RUN/prompt.md"
  fi

  local HEAD_SHA="" TAG=""
  if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    HEAD_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
    if [ "$MODE" = "run" ] && [ -n "$HEAD_SHA" ]; then
      TAG="codex-baseline-$(date +%Y%m%d-%H%M%S)"
      git -C "$CWD" tag "$TAG" >/dev/null 2>&1 || TAG=""
    fi
  fi
  json_set "$RUN/meta.json" id "$ID" cwd "$CWD" mode "$MODE" sandbox "$SANDBOX" \
           baseline_sha "$HEAD_SHA" baseline_tag "$TAG" started_at "$(date +%s)" state starting \
           session_id "${CLAUDE_CODE_SESSION_ID:-}" effort "$EFFORT" model "$MODEL"

  echo "run $ID | mode ${MODE} | sandbox ${SANDBOX} | model ${MODEL:-<default>} | effort ${EFFORT:-<default>} | project $CWD"
  [ -n "$TAG" ] && echo "rollback tag: $TAG"
  echo "---"
  execute_run "$RUN" "$CWD" "$SANDBOX" "$RUN/prompt.md" "$MODEL" "" "$EFFORT"
}

cmd_resume() {
  local ID="" PROMPT="" PROMPT_FILE="" EFFORT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) ID="$2"; shift 2;;
      --effort) EFFORT="$2"; shift 2;;
      --prompt) PROMPT="$2"; shift 2;;
      --prompt-file) PROMPT_FILE="$2"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done
  local OLD; OLD=$(resolve_run "$ID") || exit 2
  EFFORT=$(check_effort "$EFFORT") || exit 2
  local TID; TID=$(json_get "$OLD/meta.json" thread_id)
  [ -n "$TID" ] || die "run $(basename "$OLD") has no thread_id — nothing to continue"
  local CWD; CWD=$(json_get "$OLD/meta.json" cwd)

  local NEW_ID RUN
  NEW_ID="$(basename "$OLD")-r$(date +%H%M%S)"
  RUN="$RUNS_DIR/$NEW_ID"; mkdir -p "$RUN"
  if [ -n "$PROMPT_FILE" ]; then cp "$PROMPT_FILE" "$RUN/prompt.md"
  elif [ -n "$PROMPT" ]; then printf '%s\n' "$PROMPT" > "$RUN/prompt.md"
  else die "--prompt or --prompt-file is required"; fi

  json_set "$RUN/meta.json" id "$NEW_ID" cwd "$CWD" mode resume sandbox workspace-write \
           baseline_tag "$(json_get "$OLD/meta.json" baseline_tag)" \
           baseline_sha "$(json_get "$OLD/meta.json" baseline_sha)" \
           started_at "$(date +%s)" state starting parent "$(basename "$OLD")" \
           session_id "${CLAUDE_CODE_SESSION_ID:-}" effort "$EFFORT" model "$MODEL"
  echo "follow-up $NEW_ID | Codex session $TID | project $CWD"
  echo "---"
  execute_run "$RUN" "$CWD" "workspace-write" "$RUN/prompt.md" "" "$TID" "$EFFORT"
}

cmd_status() {
  local ID=""; [ "${1:-}" = "--id" ] && ID="$2"
  local RUN; RUN=$(resolve_run "$ID") || exit 2
  local state pid started log_age now
  state=$(json_get "$RUN/meta.json" state); pid=$(json_get "$RUN/meta.json" pid)
  started=$(json_get "$RUN/meta.json" started_at); now=$(date +%s)
  log_age=$(( now - $(mtime "$RUN/run.jsonl") ))

  local alive=no
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=yes

  local verdict
  if [ "$alive" = "yes" ]; then
    if [ "$log_age" -gt "$STALL_SECONDS" ]; then verdict="SILENT — no events for $(human_age "$log_age"), possibly stuck"
    else verdict="RUNNING — last event $(human_age "$log_age") ago"; fi
  else
    case "$state" in
      done) verdict="DONE — finished normally";;
      failed) verdict="FAILED — exit code $(json_get "$RUN/meta.json" exit_code)";;
      incomplete) verdict="TRUNCATED — cut off mid-turn";;
      cancelled) verdict="CANCELLED";;
      *) verdict="NO PROCESS, no outcome recorded — killed from outside";;
    esac
  fi

  echo "run:      $(basename "$RUN")"
  echo "state:    $verdict"
  echo "elapsed:  $(human_age $(( now - ${started:-$now} )))"
  echo "project:  $(json_get "$RUN/meta.json" cwd)"
  echo "latest:"
  # Look back far enough that housekeeping events cannot crowd out the real steps.
  print_events "$RUN/run.jsonl" "$(( $(wc -l < "$RUN/run.jsonl" 2>/dev/null || echo 0) - 80 ))" 2>/dev/null \
    | grep -v '^__LINES__' | tail -5 | sed 's/^/  /'
  echo "log:      $RUN/run.jsonl"
}

cmd_result() {
  local ID=""; [ "${1:-}" = "--id" ] && ID="$2"
  local RUN; RUN=$(resolve_run "$ID") || exit 2
  echo "run: $(basename "$RUN") | state: $(json_get "$RUN/meta.json" state)"
  echo "--- Codex's answer ---"
  if [ -s "$RUN/final.md" ]; then cat "$RUN/final.md"; else echo "(empty — Codex produced no final answer)"; fi
  echo
  summarize_changes "$RUN"
  local CWD BASE; CWD=$(json_get "$RUN/meta.json" cwd); BASE=$(json_get "$RUN/meta.json" baseline_tag)
  if [ -d "$CWD/.git" ]; then
    echo "--- changed files ---"; git -C "$CWD" status --short | head -40
    if [ -n "$BASE" ]; then
      local n; n=$(git -C "$CWD" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)
      [ "$n" != "0" ] && { echo "--- commits by Codex ---"; git -C "$CWD" log --oneline "$BASE"..HEAD; }
    fi
  fi
}

cmd_cancel() {
  local ID=""; [ "${1:-}" = "--id" ] && ID="$2"
  local RUN; RUN=$(resolve_run "$ID") || exit 2
  local pid; pid=$(json_get "$RUN/meta.json" pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
    json_set "$RUN/meta.json" state cancelled
    echo "run $(basename "$RUN") stopped"
  else
    echo "run $(basename "$RUN") is not active (state: $(json_get "$RUN/meta.json" state))"
  fi
}

cmd_list() {
  [ -d "$RUNS_DIR" ] || { echo "no runs yet"; return 0; }
  local d here; here=$(current_project)
  echo "  * this session   . this project"
  for d in $(ls -1dt "$RUNS_DIR"/*/ 2>/dev/null | head -10); do
    d=${d%/}
    local st mark=" "
    st=$(json_get "$d/meta.json" state); st=${st:-"(pre-codexctl)"}
    [ "$(json_get "$d/meta.json" cwd)" = "$here" ] && mark="."
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && \
      [ "$(json_get "$d/meta.json" session_id)" = "$CLAUDE_CODE_SESSION_ID" ] && mark="*"
    printf '%s %-46s %-13s %s\n' "$mark" "$(basename "$d")" "$st" "$(json_get "$d/meta.json" cwd)"
  done
}

# ---------- dispatch ----------
case "${1:-}" in
  run)    shift; cmd_run "$@";;
  review) shift; cmd_run --readonly "$@";;
  resume) shift; cmd_resume "$@";;
  status) shift; cmd_status "$@";;
  result) shift; cmd_result "$@";;
  cancel) shift; cmd_cancel "$@";;
  list)   shift; cmd_list "$@";;
  -h|--help|help|"") usage;;
  *) die "unknown mode: $1";;
esac
