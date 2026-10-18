#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Meeting Companion.app"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT=local.meeting-companion
"$ROOT_DIR/scripts/check-bundle.sh" "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MCEnableUpdates' "$APP/Contents/Info.plist")" == true ]]
[[ "$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" ]]
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$ROOT_DIR/dist/updates/$VERSION"
[[ ! -e "$OUTPUT" ]] || { echo "Архив этой версии уже подготовлен: $OUTPUT" >&2; exit 1; }
mkdir -p "$ROOT_DIR/dist/updates"
STAGE="$(mktemp -d "$ROOT_DIR/dist/updates/.prepare.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ARCHIVE="$STAGE/Meeting-Companion-$VERSION-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
cp "$ROOT_DIR/appcast.xml" "$STAGE/appcast.xml"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://gitlab.lamoda.tech/api/v4/projects/3810/packages/generic/meeting-companion/$VERSION/" \
  "$STAGE"
SIGNATURE="$("$TOOLS/sign_update" --account "$ACCOUNT" -p "$ARCHIVE")"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$ARCHIVE" "$SIGNATURE"
mv "$STAGE" "$OUTPUT"
echo "Готово: $OUTPUT. Сначала опубликуй ZIP, затем обнови appcast.xml в master."
