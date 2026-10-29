#!/bin/bash
# Load-check one or more omatings QML files headlessly, without touching the
# running omarchy-shell. Prints QML warnings/errors and console output.
#
#   tools/check.sh pages/DisplaysPage.qml
#   tools/check.sh            # checks Settings.qml and every page
#
# Exit code is non-zero if any file fails to compile/instantiate or logs a
# QML warning/error.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Quickshell resolves `qs.Commons` / `qs.Ui` relative to the config root, so
# build a throwaway root that links Omarchy's shell modules next to the harness.
HARNESS="${XDG_RUNTIME_DIR:-/tmp}/omatings-harness"
mkdir -p "$HARNESS"
ln -sfn "${OMARCHY_PATH:-/usr/share/omarchy}/shell/Commons" "$HARNESS/Commons"
ln -sfn "${OMARCHY_PATH:-/usr/share/omarchy}/shell/Ui" "$HARNESS/Ui"
cp "$ROOT/tools/harness.qml" "$HARNESS/shell.qml"
WAIT="${OMATINGS_CHECK_WAIT:-2500}"

if (( $# == 0 )); then
  set -- Settings.qml pages/*.qml
fi

status=0
for f in "$@"; do
  path="$(cd "$ROOT" && realpath -- "$f")"
  echo "== $f"
  out="$(OMATINGS_ROOT="$ROOT" OMATINGS_CHECK="$path" OMATINGS_CHECK_WAIT="$WAIT" \
    timeout 20 quickshell -p "$HARNESS" 2>&1 \
    | sed -E 's/\x1b\[[0-9;]*m//g')"
  # Drop quickshell's own startup chatter.
  filtered="$(printf '%s\n' "$out" | grep -vE 'qt.qpa.services: Failed to register with host portal|Launching config|Shell ID|Saving logs|Configuration Loaded|^\s*$' )"
  printf '%s\n' "$filtered" | sed 's/^/   /'
  if ! grep -q OMATINGS_CHECK_DONE <<<"$out" || grep -qE 'OMATINGS_CHECK_FAIL|WARN|ERROR|TypeError|ReferenceError|is not defined|Cannot assign|Unable to assign|Binding loop' <<<"$filtered"; then
    echo "   -> FAIL"
    status=1
  else
    echo "   -> ok"
  fi
done
exit $status
