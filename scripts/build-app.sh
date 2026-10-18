#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-$(cat "$ROOT_DIR/.codesign/identity" 2>/dev/null || printf '%s' '-')}"
UV_BIN="$(command -v uv)"
if [[ "$(uname -m)" != arm64 ]]; then
  echo "Meeting Companion requires Apple Silicon." >&2
  exit 1
fi
cd "$ROOT_DIR"
swift build -c release --arch arm64 --product MeetingCompanionApp
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$ROOT_DIR/dist/.build-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Meeting Companion.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/transcription"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/MeetingCompanionApp" "$APP/Contents/MacOS/MeetingCompanion"
for name in transcribe.py transcribe-recording.py check-local.py model_assets.py audio_enhancement.py term_correction.py run.sh uv-LICENSE-MIT; do
  cp "transcription/$name" "$APP/Contents/Resources/transcription/"
done
cp "$UV_BIN" "$APP/Contents/Resources/transcription/uv"
chmod +x "$APP/Contents/MacOS/MeetingCompanion" "$APP/Contents/Resources/transcription/uv" "$APP/Contents/Resources/transcription/run.sh"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/transcription/uv"
codesign --force --sign "$IDENTITY" "$APP"
"$ROOT_DIR/scripts/check-bundle.sh" "$APP"
rm -rf "$ROOT_DIR/dist/Meeting Companion.app"
mv "$APP" "$ROOT_DIR/dist/Meeting Companion.app"
echo "Built $ROOT_DIR/dist/Meeting Companion.app"
