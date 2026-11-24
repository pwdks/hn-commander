#!/usr/bin/env bash
# hn-commander installer (macOS / Linux / Git Bash)
#   install:   curl -fsSL https://raw.githubusercontent.com/pwdks/hn-commander/main/install.sh | bash
#   uninstall: curl -fsSL https://raw.githubusercontent.com/pwdks/hn-commander/main/install.sh | bash -s -- --uninstall
set -eu

REPO="pwdks/hn-commander"
BRANCH="${HN_BRANCH:-main}"
HN_HOME="${HN_HOME:-$HOME/.hn-commander}"
SKILLS="hn-setup hn-mod-role"
SKILL_DIRS="$HOME/.claude/skills $HOME/.agents/skills"   # Claude Code, Codex

say() { printf '%s\n' "$*"; }

if [ "${1:-}" = "--uninstall" ]; then
  for d in $SKILL_DIRS; do for s in $SKILLS; do rm -rf "$d/$s"; done; done
  rm -rf "$HN_HOME"
  say "hn-commander removed. (Project files such as .harness/ were not touched.)"
  exit 0
fi

for c in curl tar; do command -v "$c" >/dev/null 2>&1 || { say "error: '$c' is required"; exit 1; }; done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "Downloading $REPO ($BRANCH)..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -f "$src/harness/bin/hn.sh" ] || { say "error: unexpected archive layout"; exit 1; }

rm -rf "$HN_HOME"; mkdir -p "$(dirname "$HN_HOME")"; mv "$src" "$HN_HOME"
chmod +x "$HN_HOME/harness/bin/hn.sh"

for d in $SKILL_DIRS; do
  for s in $SKILLS; do mkdir -p "$d/$s"; cp "$HN_HOME/skills/$s/SKILL.md" "$d/$s/SKILL.md"; done
done

say ""
say "hn-commander $(cat "$HN_HOME/VERSION") installed -> $HN_HOME"
say "  Claude Code : /hn-setup , /hn-mod-role"
say "  Codex       : \$hn-setup , \$hn-mod-role"
say ""
for c in claude codex git; do
  if command -v "$c" >/dev/null 2>&1; then say "  [ok]      $c"; else say "  [missing] $c  (needed only if you use it)"; fi
done
say ""
say "Restart Claude Code / Codex, open your project folder, and run /hn-setup (Codex: \$hn-setup)."
