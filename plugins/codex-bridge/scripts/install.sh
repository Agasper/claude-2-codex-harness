#!/usr/bin/env bash
# Готовит codexctl к работе: проверяет зависимости и кладёт симлинк в PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CODEXCTL_BIN_DIR:-$HOME/.local/bin}"
ok=0

say() { printf '%s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; ok=1; }
good() { printf '  ✓ %s\n' "$*"; }

say "Зависимости:"
for c in bash python3 git; do
  command -v "$c" >/dev/null 2>&1 && good "$c" || bad "$c не найден"
done
if command -v codex >/dev/null 2>&1; then
  good "codex $(codex --version 2>/dev/null | head -1)"
  if codex login status >/dev/null 2>&1; then good "codex авторизован"
  else bad "codex не авторизован — выполни: codex login"; fi
else
  bad "codex не найден — установи: npm install -g @openai/codex"
fi

say ""
say "Установка codexctl:"
mkdir -p "$BIN_DIR"
ln -sf "$HERE/codexctl.sh" "$BIN_DIR/codexctl" && good "$BIN_DIR/codexctl -> $HERE/codexctl.sh"
case ":$PATH:" in
  *":$BIN_DIR:"*) good "$BIN_DIR уже в PATH" ;;
  *) bad "$BIN_DIR не в PATH — добавь в ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say ""
if [ "$ok" -eq 0 ]; then say "Готово. Проверь: codexctl list"; else say "Есть незакрытые пункты — см. ✗ выше."; fi
exit "$ok"
