#!/usr/bin/env bash
# Быстрые проверки codexctl, не требующие вызова Codex и не тратящие лимиты.
set -uo pipefail
CTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/codex-bridge/scripts" && pwd)/codexctl.sh"
fails=0

check() { # описание, ожидаемый код, команда...
  local desc="$1" want="$2"; shift 2
  local out code
  out=$("$@" 2>&1); code=$?
  if [ "$code" -eq "$want" ]; then printf '  ✓ %s\n' "$desc"
  else printf '  ✗ %s (код %s, ожидался %s)\n     %s\n' "$desc" "$code" "$want" "$(echo "$out" | head -1)"; fails=1; fi
}

echo "smoke-тесты codexctl:"
bash -n "$CTL" && echo "  ✓ синтаксис" || { echo "  ✗ синтаксис"; fails=1; }
check "справка без аргументов"            0 bash "$CTL"
check "несуществующий режим отвергается"  2 bash "$CTL" такого-нет
check "неизвестный флаг отвергается"      2 bash "$CTL" run --cwd /tmp --нетфлага
check "run без --cwd отвергается"         2 bash "$CTL" run --prompt x
check "run без промпта отвергается"       2 bash "$CTL" run --cwd /tmp
check "несуществующий каталог отвергается" 2 bash "$CTL" run --cwd /нет/такого --prompt x
check "несуществующий прогон отвергается" 2 bash "$CTL" status --id нет-такого-прогона

echo
[ "$fails" -eq 0 ] && echo "всё зелёное" || echo "есть падения"
exit "$fails"
