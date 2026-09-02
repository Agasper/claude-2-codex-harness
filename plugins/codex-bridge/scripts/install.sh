#!/usr/bin/env bash
# Prepares codexctl: checks prerequisites and puts a symlink on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CODEXCTL_BIN_DIR:-$HOME/.local/bin}"
ok=0

say() { printf '%s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; ok=1; }
good() { printf '  ✓ %s\n' "$*"; }

say "Prerequisites:"
for c in bash python3 git; do
  command -v "$c" >/dev/null 2>&1 && good "$c" || bad "$c not found"
done
if command -v codex >/dev/null 2>&1; then
  good "codex $(codex --version 2>/dev/null | head -1)"
  if codex login status >/dev/null 2>&1; then good "codex is authenticated"
  else bad "codex is not authenticated — run: codex login"; fi
else
  bad "codex not found — install it: npm install -g @openai/codex"
fi

say ""
say "Installing codexctl:"
mkdir -p "$BIN_DIR"
ln -sf "$HERE/codexctl.sh" "$BIN_DIR/codexctl" && good "$BIN_DIR/codexctl -> $HERE/codexctl.sh"
case ":$PATH:" in
  *":$BIN_DIR:"*) good "$BIN_DIR is already on PATH" ;;
  *) bad "$BIN_DIR is not on PATH — add to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say ""
if [ "$ok" -eq 0 ]; then say "Done. Try: codexctl list"; else say "Some items need attention — see ✗ above."; fi
exit "$ok"
