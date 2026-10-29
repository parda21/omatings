#!/bin/bash
# Development install: link this checkout into the Omarchy shell plugin dir
# and enable it. (Users install with `omarchy plugin add <repo-url> --enable`.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.config/omarchy/plugins/omatings"
mkdir -p "$(dirname "$DEST")"
if [[ -e $DEST && ! -L $DEST ]]; then
  echo "$DEST exists and is not a symlink; refusing to replace it" >&2
  exit 1
fi
ln -sfn "$ROOT" "$DEST"
omarchy-shell -q shell rescanPlugins
sleep 1
omarchy plugin enable omatings >/dev/null 2>&1 || true
echo "Installed. Open with: omarchy-shell shell toggle omatings '{}'"
