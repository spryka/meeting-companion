#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
SPARKLE_DIR="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/StartupCheck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - "$ROOT" "$STAGE" "$APP" <<'PY'
from pathlib import Path
import plistlib
import sys
root, stage, app = map(Path, sys.argv[1:])
source = (root / 'Sources/MeetingCompanionApp/AppMain.swift').read_text()
assert source.count('@main\n') == 1
(stage / 'AppMain.swift').write_text(source.replace('@main\n', '', 1))
with (app / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(dict(CFBundleIdentifier='local.meeting-companion-upgrade-check',
                      CFBundleExecutable='StartupCheck', CFBundlePackageType='APPL'), handle)
PY
SOURCES=()
for source in Sources/MeetingCompanionApp/*.swift; do
  if [[ "$source" != Sources/MeetingCompanionApp/AppMain.swift ]]; then SOURCES+=("$source"); fi
done
if [[ -f "$BIN_DIR/MeetingCompanionCore.o" ]]; then
  CORE_OBJECTS=("$BIN_DIR/MeetingCompanionCore.o")
else
  CORE_OBJECTS=("$BIN_DIR/MeetingCompanionCore.build/"*.o)
fi
swiftc -parse-as-library -I "$BIN_DIR" -I "$BIN_DIR/Modules" \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
  "${SOURCES[@]}" "$STAGE/AppMain.swift" scripts/check-transcription-startup.swift \
  "${CORE_OBJECTS[@]}" -o "$APP/Contents/MacOS/StartupCheck"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/StartupCheck"
"$APP/Contents/MacOS/StartupCheck" --available
