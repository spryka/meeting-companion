#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
UV_FLAGS=(--quiet)
DATA_DIR="$HOME/Library/Application Support/MeetingCompanion"
export UV_CACHE_DIR="$DATA_DIR/runtime/cache"
export UV_PYTHON_INSTALL_DIR="$DATA_DIR/runtime/python"
export HF_HOME="$DATA_DIR/models"
export HF_HUB_CACHE="$HF_HOME/hub"
export HF_XET_CACHE="$HF_HOME/xet"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UV="$DIR/uv"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv)"; fi
SCRIPT="$DIR/transcribe.py"
case "${1:-}" in
  --recording) SCRIPT="$DIR/transcribe-recording.py"; shift ;;
  --check) SCRIPT="$DIR/check-local.py" ;;
  --prepare)
    SCRIPT="$DIR/check-local.py"
    UV_FLAGS=(--no-progress)
    printf '%s\n' 'Подготовка Python и пакетов. Первый запуск может занять несколько минут; при медленном соединении — дольше.' >&2
    ;;
esac
for arg in "$@"; do
  if [[ "$arg" == "--offline" || "$arg" == "--check" ]]; then
    export UV_OFFLINE=1 HF_HUB_OFFLINE=1
  fi
done
exec "$UV" run "${UV_FLAGS[@]}" --python 3.12 --python-preference only-managed \
  --with onnx-asr==0.12.0 \
  --with onnxruntime==1.23.2 \
  --with mlx-audio==0.5.8 \
  --with huggingface_hub \
  --with soundfile \
  python -u "$SCRIPT" "$@"
