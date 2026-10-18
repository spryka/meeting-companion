#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/Meeting Companion.app}"
"$ROOT_DIR/scripts/check-bundle.sh" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$ROOT_DIR/dist/Meeting-Companion-$VERSION-arm64.dmg"
if [[ -e "$OUTPUT" ]]; then
  echo "Already exists: $OUTPUT. Do not overwrite a published release archive." >&2
  exit 1
fi
STAGE="$(mktemp -d "$ROOT_DIR/dist/.build-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/contents"
ditto "$APP" "$STAGE/contents/Meeting Companion.app"
ln -s /Applications "$STAGE/contents/Applications"
hdiutil create -volname "Meeting Companion" -srcfolder "$STAGE/contents" \
  -format UDZO "$STAGE/Meeting Companion.dmg"
hdiutil verify "$STAGE/Meeting Companion.dmg"
mv "$STAGE/Meeting Companion.dmg" "$OUTPUT"
echo "Built $OUTPUT"
