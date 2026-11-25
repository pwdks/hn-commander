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
  x="${CODEX_HOME:-$HOME/.codex}/AGENTS.md"   # remove only the language block that hn-commander added
  if [ -f "$x" ] && grep -q '<!-- hn-commander:lang -->' "$x"; then
    awk '/<!-- hn-commander:lang -->/ { skip = 1; next } /<!-- hn-commander:lang-end -->/ { skip = 0; next } !skip { print }' "$x" > "$x.tmp" && mv "$x.tmp" "$x"
  fi
  say "hn-commander removed. (Project files such as .harness/ were not touched.)"
  exit 0
fi

for c in curl tar; do command -v "$c" >/dev/null 2>&1 || { say "error: '$c' is required"; exit 1; }; done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "Downloading $REPO ($BRANCH)..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -f "$src/harness/bin/hn.sh" ] || { say "error: unexpected archive layout"; exit 1; }

projects=""   # projects set up with hn-commander (kept across updates)
[ -f "$HN_HOME/projects.txt" ] && projects="$(cat "$HN_HOME/projects.txt")"
rm -rf "$HN_HOME"; mkdir -p "$(dirname "$HN_HOME")"; mv "$src" "$HN_HOME"
[ -n "$projects" ] && printf '%s\n' "$projects" > "$HN_HOME/projects.txt"
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
say "Updating projects:"
bash "$HN_HOME/harness/bin/hn.sh" update-all || true
say ""
say "Restart Claude Code / Codex. New project: open its folder and run /hn-setup (Codex: \$hn-setup)."
