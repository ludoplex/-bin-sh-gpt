#!/bin/bash
set -euo pipefail
MODE="${1:-pre}"
ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="${HOME}/.local/share/chatgpt"
HISTORY_FILE="${STATE_DIR}/history.log"
SNAPSHOT="${STATE_DIR}/history.precommit.snapshot"
mkdir -p "$STATE_DIR"

if [ ! -f "$HISTORY_FILE" ]; then
  : > "$HISTORY_FILE"
fi

chmod 400 "$HISTORY_FILE"

# Ensure repository itself does not track or contain the history file.
if git ls-files --error-unmatch "$HISTORY_FILE" >/dev/null 2>&1; then
  git rm --cached "$HISTORY_FILE" || true
fi

case "$MODE" in
  pre)
    cp "$HISTORY_FILE" "$SNAPSHOT"
    chmod 600 "$SNAPSHOT"
    ;;
  post)
    if [ -f "$SNAPSHOT" ]; then
      chmod 600 "$HISTORY_FILE"
      cp "$SNAPSHOT" "$HISTORY_FILE"
      chmod 400 "$HISTORY_FILE"
      rm -f "$SNAPSHOT"
    fi
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 1
    ;;
esac
