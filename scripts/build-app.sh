#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-$(cat "$ROOT_DIR/.codesign/identity" 2>/dev/null || printf '%s' '-')}"
if [[ "$(uname -m)" != arm64 ]]; then
  echo "Meeting Companion requires Apple Silicon." >&2
  exit 1
fi
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$ROOT_DIR"
swift build -c release --arch arm64 --product MeetingCompanionApp
swift build -c release --arch arm64 --product MeetingTranscriptionWorker
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p dist
STAGE="$(mktemp -d "$ROOT_DIR/dist/.build-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Meeting Companion.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/aec" "$APP/Contents/Frameworks"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "${RELEASE_UPDATES:-0}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :MCEnableUpdates true' "$APP/Contents/Info.plist"
fi
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
ditto "$ROOT_DIR/Vendor/LICENSES" "$APP/Contents/Resources/VendorLicenses"
cp "$ROOT_DIR/Vendor/dependency-licenses.json" "$APP/Contents/Resources/vendor-dependency-licenses.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Copy main app and native worker binaries
cp "$BIN_DIR/MeetingCompanionApp" "$APP/Contents/MacOS/MeetingCompanion"
cp "$BIN_DIR/MeetingTranscriptionWorker" "$APP/Contents/MacOS/MeetingTranscriptionWorker"
chmod +x "$APP/Contents/MacOS/MeetingCompanion" "$APP/Contents/MacOS/MeetingTranscriptionWorker"

# Copy Metal and resource bundles
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done

# Copy Sparkle framework
ditto "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"

# Build and bundle native AEC
bash scripts/build-aec.sh "$APP/Contents/Resources/aec"

# Code signing inside out
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
for bundle in "$APP/Contents/Resources"/*.bundle; do
  if [ -d "$bundle" ]; then
    codesign --force --sign "$IDENTITY" "$bundle"
  fi
done
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/aec/libwebrtc-audio-processing-2.1.dylib"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/aec/meeting-aec"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/MeetingTranscriptionWorker"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/MeetingCompanion"
codesign --force --sign "$IDENTITY" "$APP"

"$ROOT_DIR/scripts/check-bundle.sh" "$APP"
rm -rf "$ROOT_DIR/dist/Meeting Companion.app"
mv "$APP" "$ROOT_DIR/dist/Meeting Companion.app"
echo "Built $ROOT_DIR/dist/Meeting Companion.app"
