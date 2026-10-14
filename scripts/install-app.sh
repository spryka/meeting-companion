#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/Meeting Companion.app"
if pgrep -x InterviewRecorder >/dev/null; then
  echo "Quit Meeting Companion / Interview Recorder before installing." >&2
  exit 1
fi
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == - ]]; then
  for installed in "$APP_PATH" /Applications/InterviewRecorder.app; do
    if [[ -d "$installed" ]] && codesign -dv "$installed" 2>&1 | grep -q '^Authority='; then
      echo 'Set CODESIGN_IDENTITY to the existing certificate to preserve macOS permissions.' >&2
      exit 1
    fi
  done
fi
CODESIGN_IDENTITY="$IDENTITY" "$ROOT_DIR/scripts/build-app.sh"
STAGE="$(mktemp -d /Applications/.meeting-companion.XXXXXX)"
trap 'if [[ -d "$STAGE/previous.app" ]]; then echo "Previous app preserved in $STAGE/previous.app" >&2; else rm -rf "$STAGE"; fi' EXIT
ditto "$ROOT_DIR/dist/Meeting Companion.app" "$STAGE/Meeting Companion.app"
"$ROOT_DIR/scripts/check-bundle.sh" "$STAGE/Meeting Companion.app"
if [[ -d "$APP_PATH" ]]; then
  mv "$APP_PATH" "$STAGE/previous.app"
fi
if ! mv "$STAGE/Meeting Companion.app" "$APP_PATH"; then
  if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$APP_PATH"; fi
  exit 1
fi
rm -rf "$STAGE/previous.app"
echo "Installed $APP_PATH"
