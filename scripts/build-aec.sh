#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:?Usage: build-aec.sh OUTPUT_DIRECTORY}"
SHA256=46dc45181de1b19cf9a76d2fe3c9107498d5233ea9f7b334e7801b89cec2e090
URL=https://files.pythonhosted.org/packages/77/59/33ad10cf1d7d5280f3d92077f42c262ade6420dcf89525ad18b88595e5c5/aec_audio_processing-1.0.0.dev9.tar.gz
CACHE="$ROOT/.build/webrtc-aec"
mkdir -p "$OUTPUT" "$CACHE"
OUTPUT="$(cd "$OUTPUT" && pwd)"
TEMP="$(mktemp -d "$CACHE/build.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
ARCHIVE="$CACHE/source.tar.gz"
digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
if [[ ! -f "$ARCHIVE" ]] || [[ "$(digest "$ARCHIVE")" != "$SHA256" ]]; then
  curl --fail --location --silent --show-error --max-time 30 --max-filesize 20000001 \
    "$URL" -o "$TEMP/source.tar.gz"
  [[ "$(digest "$TEMP/source.tar.gz")" == "$SHA256" ]] || { echo 'AEC source checksum mismatch' >&2; exit 1; }
  mv "$TEMP/source.tar.gz" "$ARCHIVE"
fi

# Only the verified, pinned archive is extracted; never run its package setup.
tar -xzf "$ARCHIVE" -C "$TEMP"
PACKAGE="$TEMP/aec_audio_processing-1.0.0.dev9"
PROJECT="$PACKAGE/webrtc-audio-processing"
LIBRARY="$OUTPUT/libwebrtc-audio-processing-2.1.dylib"
cp "$PACKAGE/src/files/libwebrtc-audio-processing-2.dylib" "$LIBRARY"
install_name_tool -id '@rpath/libwebrtc-audio-processing-2.1.dylib' "$LIBRARY"
clang++ -std=c++17 -O2 -arch arm64 -DNDEBUG \
  -DWEBRTC_APM_DEBUG_DUMP=0 -DWEBRTC_POSIX -DWEBRTC_MAC \
  -I "$PROJECT/webrtc" -I "$PROJECT/subprojects/abseil-cpp-20240722.0" \
  "$ROOT/Sources/WebRTCAEC/aec.cpp" "$LIBRARY" '-Wl,-rpath,@executable_path' \
  -o "$OUTPUT/meeting-aec"

NOTICES="$OUTPUT/THIRD_PARTY_NOTICES.txt"
: > "$NOTICES"
FIRST=1
find "$PACKAGE" -type f \( -name 'LICENSE*' -o -name 'COPYING*' -o -name PATENTS -o -name AUTHORS \) | LC_ALL=C sort > "$TEMP/notices-list"
while IFS= read -r path; do
  relative="${path#"$PACKAGE/"}"
  case "/$relative/" in */build/*|*/install/*) continue ;; esac
  if [[ "$FIRST" == 0 ]]; then printf '\n\n---\n\n' >> "$NOTICES"; fi
  FIRST=0
  printf '%s\n\n' "$relative" >> "$NOTICES"
  # Match the former text reader's CRLF normalization for upstream notices.
  sed $'s/\r$//' "$path" >> "$NOTICES"
done < "$TEMP/notices-list"
[[ -s "$NOTICES" ]]
