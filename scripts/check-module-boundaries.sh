#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_PATH="${1:-$ROOT_DIR}"

if [[ -f "$TARGET_PATH" ]]; then
    PACKAGE_DIR="$(cd "$(dirname "$TARGET_PATH")" && pwd)"
elif [[ -d "$TARGET_PATH" ]]; then
    PACKAGE_DIR="$(cd "$TARGET_PATH" && pwd)"
else
    echo "FAIL: Package path '$TARGET_PATH' does not exist" >&2
    exit 1
fi

echo "=== Verifying module boundaries in $PACKAGE_DIR ==="

FORBIDDEN_FRAMEWORKS=("AVFoundation" "CoreMedia" "CoreAudio" "ScreenCaptureKit" "AppKit" "SwiftUI" "Combine" "MLX")

FAILURES=0

# 1. Check forbidden imports in Sources/MeetingCompanionCore
CORE_SRC="$PACKAGE_DIR/Sources/MeetingCompanionCore"
if [[ -d "$CORE_SRC" ]]; then
    echo "1. Checking forbidden imports in $CORE_SRC..."
    for framework in "${FORBIDDEN_FRAMEWORKS[@]}"; do
        MATCHES=$(grep -rnE "(import[[:space:]]+${framework}\b|@preconcurrency[[:space:]]+import[[:space:]]+${framework}\b)" "$CORE_SRC" 2>/dev/null || true)
        if [[ -n "$MATCHES" ]]; then
            echo "FAIL: Forbidden import of '${framework}' found in MeetingCompanionCore:"
            echo "$MATCHES"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# 2. Check forbidden imports in Sources/MeetingCompanionApplication
APP_SRC="$PACKAGE_DIR/Sources/MeetingCompanionApplication"
if [[ -d "$APP_SRC" ]]; then
    echo "2. Checking forbidden imports in $APP_SRC..."
    for framework in "${FORBIDDEN_FRAMEWORKS[@]}"; do
        MATCHES=$(grep -rnE "(import[[:space:]]+${framework}\b|@preconcurrency[[:space:]]+import[[:space:]]+${framework}\b)" "$APP_SRC" 2>/dev/null || true)
        if [[ -n "$MATCHES" ]]; then
            echo "FAIL: Forbidden import of '${framework}' found in MeetingCompanionApplication:"
            echo "$MATCHES"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# 3. Check MLX isolation: App and CLI must NOT import MLX
for target in "MeetingCompanionApp" "MeetingCompanionCLI"; do
    SRC_DIR="$PACKAGE_DIR/Sources/$target"
    if [[ -d "$SRC_DIR" ]]; then
        echo "Checking MLX isolation in $SRC_DIR..."
        MATCHES=$(grep -rnE "(import[[:space:]]+MLX\b|import[[:space:]]+MeetingTranscriptionPipeline\b)" "$SRC_DIR" 2>/dev/null || true)
        if [[ -n "$MATCHES" ]]; then
            echo "FAIL: Target $target illegally imports MLX or MeetingTranscriptionPipeline:"
            echo "$MATCHES"
            FAILURES=$((FAILURES + 1))
        fi
    fi
done

# 4. Evaluate Package.swift structured graph via isolated temporary manifest copy
echo "3. Evaluating Package.swift structured graph via swift package dump-package..."
TMP_PKG_DIR=$(mktemp -d /tmp/mc-boundary-eval.XXXXXX)
trap 'rm -rf "$TMP_PKG_DIR"' EXIT

if [[ ! -f "$PACKAGE_DIR/Package.swift" ]]; then
    echo "FAIL: Package.swift not found in $PACKAGE_DIR" >&2
    exit 1
fi

cp "$PACKAGE_DIR/Package.swift" "$TMP_PKG_DIR/Package.swift"

DUMP_JSON=$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift package --package-path "$TMP_PKG_DIR" \
    --cache-path "$TMP_PKG_DIR/cache" --config-path "$TMP_PKG_DIR/config" \
    --security-path "$TMP_PKG_DIR/security" dump-package) || {
    echo "FAIL: swift package dump-package failed for $PACKAGE_DIR" >&2
    exit 1
}

if [[ -z "$DUMP_JSON" ]]; then
    echo "FAIL: Empty package graph dumped for $PACKAGE_DIR" >&2
    exit 1
fi

# 5. Validate structured target graph using standard JSON decoding
if ! printf '%s\n' "$DUMP_JSON" | DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift "$ROOT_DIR/scripts/check-package-graph.swift"; then
    echo "FAIL: Package manifest structured boundary verification failed" >&2
    FAILURES=$((FAILURES + 1))
fi

# 6. Require the platform source directory and all extracted adapters
PLATFORM_SRC="$PACKAGE_DIR/Sources/MeetingCompanionPlatform"
if [[ ! -d "$PLATFORM_SRC" ]]; then
    echo "FAIL: MISSING_PLATFORM_DIRECTORY: $PLATFORM_SRC"
    FAILURES=$((FAILURES + 1))
else
    echo "4. Checking platform adapters in $PLATFORM_SRC..."
    REQUIRED_PLATFORM_FILES=(
        "$PLATFORM_SRC/AudioCapture.swift"
        "$PLATFORM_SRC/RecorderCore.swift"
        "$PLATFORM_SRC/SourceAudioFiles.swift"
        "$PLATFORM_SRC/Transcription.swift"
        "$PLATFORM_SRC/TranscriptAVPlayerTransport.swift"
    )
    for file in "${REQUIRED_PLATFORM_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo "FAIL: REQUIRED_PLATFORM_FILE: '$file' does not exist"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

if [[ $FAILURES -gt 0 ]]; then
    echo "=== FAILED: $FAILURES module boundary assertion failure(s) ===" >&2
    exit 1
fi

echo "=== PASS: All module boundary assertions passed ==="
