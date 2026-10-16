#!/usr/bin/env bash
set -euo pipefail
APP="${1:?Usage: check-bundle.sh PATH.app}"
plutil -lint "$APP/Contents/Info.plist"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
grep -Eq "^## \[${VERSION//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$ROOT_DIR/CHANGELOG.md"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" == 'Meeting Companion' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == local.meeting-companion ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" == AppIcon ]]
[[ -s "$APP/Contents/Resources/AppIcon.icns" ]]
[[ -x "$APP/Contents/MacOS/MeetingCompanion" ]]
for name in transcribe.py transcribe-recording.py check-local.py run.sh uv uv-LICENSE-MIT; do
  [[ -s "$APP/Contents/Resources/transcription/$name" ]]
done
[[ -x "$APP/Contents/Resources/transcription/run.sh" ]]
"$APP/Contents/Resources/transcription/uv" --version
codesign --verify --deep --strict "$APP"
echo "Bundle check passed"
