#!/usr/bin/env bash
# codexctl — единственная точка запуска Codex из Claude Code.
# Все флаги codex зашиты здесь. Вызывающему доступны только режимы ниже.
set -uo pipefail

RUNS_DIR="${CODEX_RUNS_DIR:-$HOME/.claude/codex-runs}"
STALL_SECONDS="${CODEX_STALL_SECONDS:-180}"

die() { echo "ОШИБКА: $*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
codexctl — запуск Codex с фиксированными режимами.

  codexctl run     --cwd DIR (--prompt TEXT | --prompt-file F) [--model M]
      Задача с правом записи. Блокирует до конца — запускать в фоне.

  codexctl review  --cwd DIR [--base REF] [--prompt TEXT] [--model M]
      Ревью без права записи. Блокирует до конца — запускать в фоне.

  codexctl resume  --id ID (--prompt TEXT | --prompt-file F)
      Дозадача в ту же сессию Codex. Блокирует до конца.

  codexctl status  [--id ID]      Состояние прогона: работает / молчит / готов / упал.
  codexctl result  [--id ID]      Итог: ответ Codex и что изменилось в репозитории.
  codexctl cancel  [--id ID]      Остановить прогон.
  codexctl list                   Последние прогоны.

Других флагов нет. Песочница, сеть, доступ к .git и фильтрация окружения — внутри.
USAGE
}

# ---------- общие помощники ----------

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

latest_run() { ls -1dt "$RUNS_DIR"/*/ 2>/dev/null | head -1 | sed 's:/$::'; }

resolve_run() {
  local id="${1:-}" r
  if [ -n "$id" ]; then
    [ -d "$RUNS_DIR/$id" ] || die "прогон не найден: $id"
    echo "$RUNS_DIR/$id"
  else
    r=$(latest_run); [ -n "$r" ] || die "прогонов ещё не было"
    echo "$r"
  fi
}

human_age() {
  local s=$1
  if   [ "$s" -lt 60 ]   ; then echo "${s}с"
  elif [ "$s" -lt 3600 ] ; then echo "$((s/60))м $((s%60))с"
  else echo "$((s/3600))ч $(((s%3600)/60))м"; fi
}

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# Печатает события из jsonl начиная со строки $2 (1-based). Возвращает число обработанных строк.
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
        print(f"[{ts}] думает  {txt}",flush=True)
    elif kind in ('command_execution','CommandExecution'):
        cmd=it.get('command')
        if isinstance(cmd,list): cmd=' '.join(cmd[-1:])
        cmd=(str(cmd or '')).replace('\n',' ')[:150]
        print(f"[{ts}] команда {cmd}",flush=True)
    elif kind in ('file_change','FileChange'):
        n=len(it.get('changes') or it.get('files') or [])
        print(f"[{ts}] правка  файлов: {n if n else '?'}",flush=True)
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

# Список -u для вырезания переменных Claude Code из окружения Codex
unset_flags() { env | grep -oE '^CLAUDE[A-Z_]*' | sed 's/^/-u /' | tr '\n' ' '; }

# ---------- ядро: один прогон ----------

# execute_run <run_dir> <cwd> <sandbox> <prompt_file> <model> <resume_thread|"">
execute_run() {
  local RUN="$1" CWD="$2" SANDBOX="$3" PROMPT_FILE="$4" MODEL="$5" RESUME="$6"
  local args=()

  if [ -n "$RESUME" ]; then
    # У `codex exec resume` нет --cd и нет -s: рабочий каталог задаётся через cd,
    # песочница — только через -c. Проверено 02.09.2026, не «упрощать» обратно.
    args=(exec resume --json -c "sandbox_mode=\"$SANDBOX\"")
  else
    args=(exec --json --cd "$CWD" -s "$SANDBOX")
  fi
  if [ "$SANDBOX" = "workspace-write" ]; then
    args+=(-c "sandbox_workspace_write.writable_roots=[\"$CWD/.git\"]")
  fi
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || args+=(--skip-git-repo-check)
  args+=(-o "$RUN/final.md")
  [ -n "$RESUME" ] && args+=("$RESUME")
  args+=(-)

  echo "запуск: codex ${args[*]}" > "$RUN/cmd.txt"

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
      echo "[!] Codex молчит уже $(human_age "$age") — возможно, застрял. Проверь: codexctl status"
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
    done)       echo "ИТОГ: Codex завершил работу штатно." ;;
    failed)     echo "ИТОГ: Codex завершился с ошибкой (код $code). Хвост err.log:"; tail -5 "$RUN/err.log" ;;
    incomplete) echo "ИТОГ: Codex оборвался, не закончив ход. Хвост err.log:"; tail -5 "$RUN/err.log" ;;
  esac
  summarize_changes "$RUN"
  echo "ID прогона: $(basename "$RUN")"
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
  echo "изменения: незакоммиченных файлов $dirty, новых коммитов $commits (от метки ${BASE:-—})"
}

# ---------- режимы ----------

cmd_run() {
  local CWD="" PROMPT="" PROMPT_FILE="" MODEL="" SANDBOX="workspace-write" MODE="run" BASE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) CWD="$2"; shift 2;;
      --prompt) PROMPT="$2"; shift 2;;
      --prompt-file) PROMPT_FILE="$2"; shift 2;;
      --model) MODEL="$2"; shift 2;;
      --base) BASE="$2"; shift 2;;
      --readonly) SANDBOX="read-only"; MODE="review"; shift;;
      *) die "неизвестный флаг: $1 (см. codexctl --help)";;
    esac
  done
  [ -n "$CWD" ] || die "нужен --cwd"
  [ -d "$CWD" ] || die "каталог не существует: $CWD"
  CWD=$(cd "$CWD" && pwd)
  command -v codex >/dev/null 2>&1 || die "codex не установлен"

  local ID RUN
  ID="$(basename "$CWD")-$(date +%Y%m%d-%H%M%S)"
  RUN="$RUNS_DIR/$ID"; mkdir -p "$RUN"

  if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "файл не найден: $PROMPT_FILE"
    cp "$PROMPT_FILE" "$RUN/prompt.md"
  elif [ -n "$PROMPT" ]; then
    printf '%s\n' "$PROMPT" > "$RUN/prompt.md"
  else die "нужен --prompt или --prompt-file"; fi

  if [ "$MODE" = "review" ]; then
    local target="незакоммиченные изменения"
    [ -n "$BASE" ] && target="изменения относительно ветки $BASE"
    { echo; echo "Отревьюй $target. Ничего не исправляй — только перечисли найденные проблемы,"
      echo "по каждой: файл и строка, суть, почему это ошибка. Если проблем нет — так и скажи."; } >> "$RUN/prompt.md"
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
           baseline_sha "$HEAD_SHA" baseline_tag "$TAG" started_at "$(date +%s)" state starting

  echo "прогон $ID | режим ${MODE} | песочница ${SANDBOX} | проект $CWD"
  [ -n "$TAG" ] && echo "метка отката: $TAG"
  echo "---"
  execute_run "$RUN" "$CWD" "$SANDBOX" "$RUN/prompt.md" "$MODEL" ""
}

cmd_resume() {
  local ID="" PROMPT="" PROMPT_FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) ID="$2"; shift 2;;
      --prompt) PROMPT="$2"; shift 2;;
      --prompt-file) PROMPT_FILE="$2"; shift 2;;
      *) die "неизвестный флаг: $1";;
    esac
  done
  local OLD; OLD=$(resolve_run "$ID") || exit 2
  local TID; TID=$(json_get "$OLD/meta.json" thread_id)
  [ -n "$TID" ] || die "у прогона $(basename "$OLD") нет thread_id — продолжать нечего"
  local CWD; CWD=$(json_get "$OLD/meta.json" cwd)

  local NEW_ID RUN
  NEW_ID="$(basename "$OLD")-r$(date +%H%M%S)"
  RUN="$RUNS_DIR/$NEW_ID"; mkdir -p "$RUN"
  if [ -n "$PROMPT_FILE" ]; then cp "$PROMPT_FILE" "$RUN/prompt.md"
  elif [ -n "$PROMPT" ]; then printf '%s\n' "$PROMPT" > "$RUN/prompt.md"
  else die "нужен --prompt или --prompt-file"; fi

  json_set "$RUN/meta.json" id "$NEW_ID" cwd "$CWD" mode resume sandbox workspace-write \
           baseline_tag "$(json_get "$OLD/meta.json" baseline_tag)" \
           baseline_sha "$(json_get "$OLD/meta.json" baseline_sha)" \
           started_at "$(date +%s)" state starting parent "$(basename "$OLD")"
  echo "продолжение $NEW_ID | сессия Codex $TID | проект $CWD"
  echo "---"
  execute_run "$RUN" "$CWD" "workspace-write" "$RUN/prompt.md" "" "$TID"
}

cmd_status() {
  local ID=""; [ "${1:-}" = "--id" ] && ID="$2"
  local RUN; RUN=$(resolve_run "$ID") || exit 2
  local state pid started log_age now
  state=$(json_get "$RUN/meta.json" state); pid=$(json_get "$RUN/meta.json" pid)
  started=$(json_get "$RUN/meta.json" started_at); now=$(date +%s)
  log_age=$(( now - $(mtime "$RUN/run.jsonl") ))

  local alive=нет
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=да

  local verdict
  if [ "$alive" = "да" ]; then
    if [ "$log_age" -gt "$STALL_SECONDS" ]; then verdict="МОЛЧИТ — нет событий $(human_age "$log_age"), возможно застрял"
    else verdict="РАБОТАЕТ — последнее событие $(human_age "$log_age") назад"; fi
  else
    case "$state" in
      done) verdict="ГОТОВ — завершился штатно";;
      failed) verdict="УПАЛ — код $(json_get "$RUN/meta.json" exit_code)";;
      incomplete) verdict="ОБОРВАЛСЯ — не закончил ход";;
      cancelled) verdict="ОТМЕНЁН";;
      *) verdict="ПРОЦЕССА НЕТ, итог не записан — прогон оборван внешне";;
    esac
  fi

  echo "прогон:    $(basename "$RUN")"
  echo "состояние: $verdict"
  echo "идёт:      $(human_age $(( now - ${started:-$now} )))"
  echo "проект:    $(json_get "$RUN/meta.json" cwd)"
  echo "последнее:"
  print_events "$RUN/run.jsonl" "$(( $(wc -l < "$RUN/run.jsonl" 2>/dev/null || echo 0) - 6 ))" 2>/dev/null \
    | grep -v '^__LINES__' | tail -5 | sed 's/^/  /'
  echo "лог:       $RUN/run.jsonl"
}

cmd_result() {
  local ID=""; [ "${1:-}" = "--id" ] && ID="$2"
  local RUN; RUN=$(resolve_run "$ID") || exit 2
  echo "прогон: $(basename "$RUN") | состояние: $(json_get "$RUN/meta.json" state)"
  echo "--- ответ Codex ---"
  if [ -s "$RUN/final.md" ]; then cat "$RUN/final.md"; else echo "(пусто — Codex не дал финального ответа)"; fi
  echo
  summarize_changes "$RUN"
  local CWD BASE; CWD=$(json_get "$RUN/meta.json" cwd); BASE=$(json_get "$RUN/meta.json" baseline_tag)
  if [ -d "$CWD/.git" ]; then
    echo "--- изменённые файлы ---"; git -C "$CWD" status --short | head -40
    if [ -n "$BASE" ]; then
      local n; n=$(git -C "$CWD" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)
      [ "$n" != "0" ] && { echo "--- коммиты Codex ---"; git -C "$CWD" log --oneline "$BASE"..HEAD; }
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
    echo "прогон $(basename "$RUN") остановлен"
  else
    echo "прогон $(basename "$RUN") уже не выполняется (состояние: $(json_get "$RUN/meta.json" state))"
  fi
}

cmd_list() {
  [ -d "$RUNS_DIR" ] || { echo "прогонов ещё не было"; return 0; }
  local d
  for d in $(ls -1dt "$RUNS_DIR"/*/ 2>/dev/null | head -10); do
    d=${d%/}
    local st; st=$(json_get "$d/meta.json" state); st=${st:-«до codexctl»}
    printf '%-46s %-13s %s\n' "$(basename "$d")" "$st" "$(json_get "$d/meta.json" cwd)"
  done
}

# ---------- диспетчер ----------
case "${1:-}" in
  run)    shift; cmd_run "$@";;
  review) shift; cmd_run --readonly "$@";;
  resume) shift; cmd_resume "$@";;
  status) shift; cmd_status "$@";;
  result) shift; cmd_result "$@";;
  cancel) shift; cmd_cancel "$@";;
  list)   shift; cmd_list "$@";;
  -h|--help|help|"") usage;;
  *) die "неизвестный режим: $1";;
esac
