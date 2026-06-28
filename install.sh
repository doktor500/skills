#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"

mkdir -p "$SKILLS_DIR"

for skill_path in "$REPO_ROOT"/skills/*/*/; do
  skill_name="$(basename "$skill_path")"
  target="$SKILLS_DIR/$skill_name"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$skill_path" ]; then
    echo "  up-to-date: $skill_name"
    continue
  fi

  rm -rf "$target"
  ln -s "$skill_path" "$target"
  echo "  linked: $skill_name -> $skill_path"
done
