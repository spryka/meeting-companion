#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ROOTS=(Sources Tests scripts skills)
if [[ -d transcription ]]; then ROOTS+=(transcription); fi
FOUND=$(find "${ROOTS[@]}" -type f \( -name '*.py' -o -name '*.pyc' \))
if [[ -n "$FOUND" ]]; then
  echo "FAIL: first-party Python files remain:" >&2
  echo "$FOUND" >&2
  exit 1
fi
if [[ -f transcription/run.sh ]]; then
  echo "FAIL: obsolete runtime launcher remains" >&2
  exit 1
fi
if grep -RnE --include='*.swift' --include='*.sh' --exclude='check-python-free.sh' \
  '(/usr/bin/python[0-9.]*|^#!.*python|^[[:space:]]*(python[0-9.]*|uv)[[:space:]])' \
  Sources Tests scripts skills; then
  echo 'FAIL: Python interpreter invocation remains' >&2
  exit 1
fi
echo 'Python-free first-party source check passed'
