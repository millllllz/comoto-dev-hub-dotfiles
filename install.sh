#!/usr/bin/env bash
# Run by GitHub Codespaces when the codespace is created. Because this file exists, Codespaces no longer
# symlinks dotfiles on its own, so link them here and hook .millz.sh into the shell rc files.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in .millz.sh .bash-functions.sh .git-helpers; do
  ln -sfn "$DOTFILES_DIR/$f" "$HOME/$f"
done

# Run On Save formatter; chmod here because a file added through the GitHub web editor is not executable.
chmod +x "$DOTFILES_DIR/bin/format-on-save"
mkdir -p "$HOME/.local/bin"
ln -sfn "$DOTFILES_DIR/bin/format-on-save" "$HOME/.local/bin/format-on-save"

SOURCE_LINE='[ -f "$HOME/.millz.sh" ] && source "$HOME/.millz.sh"'

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  touch "$rc"
  grep -qxF "$SOURCE_LINE" "$rc" || printf '\n%s\n' "$SOURCE_LINE" >> "$rc"
done
