#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Сброс разрешений доступен только на macOS.' >&2
  exit 1
fi

status=0
pgrep -x MeetingCompanion >/dev/null || status=$?
if [[ "$status" != 1 ]]; then
  echo 'Закрой Meeting Companion через меню → «Выйти». Если приложение закрыто, проверь ошибку pgrep.' >&2
  exit 1
fi

echo 'Будут сброшены разрешения только Meeting Companion: экран/системный звук, микрофон и календарь.'
echo 'После сброса доступы нужно выдать заново. Записи, модели и настройки сохранятся.'
read -r -p 'Сбросить? Введи y для подтверждения: ' answer
if [[ "$answer" != y ]]; then
  echo 'Отменено; разрешения не изменены.'
  exit 0
fi

for service in ScreenCapture Microphone Calendar; do
  if ! tccutil reset "$service" local.meeting-companion; then
    echo "Не удалось сбросить $service; оставшиеся разрешения не изменены." >&2
    exit 1
  fi
done
echo 'Запусти Meeting Companion, выдай доступы и перезапусти приложение для проверки.'
