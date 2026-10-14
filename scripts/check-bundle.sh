#!/usr/bin/env bash
set -euo pipefail
APP="${1:?Usage: check-bundle.sh PATH.app}"
plutil -lint "$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" == 'Meeting Companion' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == local.meeting-companion ]]
[[ -x "$APP/Contents/MacOS/MeetingCompanion" ]]
for name in transcribe.py transcribe-recording.py check-local.py run.sh uv uv-LICENSE-MIT; do
  [[ -s "$APP/Contents/Resources/transcription/$name" ]]
done
[[ -x "$APP/Contents/Resources/transcription/run.sh" ]]
"$APP/Contents/Resources/transcription/uv" --version
codesign --verify --deep --strict "$APP"
echo "Bundle check passed"
