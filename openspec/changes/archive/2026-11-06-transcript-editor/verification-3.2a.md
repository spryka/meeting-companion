# Verification 3.2a — Core window coordinator

Core coordinator и lifecycle приняты независимым Sol reviewer. Проверены канонические пути, повторное открытие/фокус, независимость окон, legacy/corrupt/unavailable состояния, закрепление версии и закрытие во время persistence callback. Закрытая сессия не меняет retained active ID и window mode; завершённая запись выбора на диск не откатывается. Callback очищается, устаревшее закрытие не затрагивает новое окно.

- Полный Swift suite: **127 tests / 13 suites GREEN**.
- Независимый повторный запуск `TranscriptWindowCoordinatorTests|TranscriptReviewSessionTests`: **28 tests GREEN**.
- Независимый compiled reentrant probe: GREEN.
- Release build, `openspec validate transcript-editor --strict`, `git diff --check`: exit 0.
- Baseline integrity: 186/189 файлов неизменны, только три согласованных Swift-файла изменены; tracked/staged diff идентичны baseline.

Полные команды и логи: временный каталог `section3-3.2a` в approved OpenCode temp, файлы `sol-builder.md`, `sol-review.md`, `sol-green.log`, `sol-release.log`, `sol-review-tests.log`, `sol-review-probe.log`, `sol-review-integrity.log`.

Это приёмка только Core 3.2a. AppKit window integration, audio, editing, visual/accessibility UAT не проверялись; 3.2 и 5.2 остаются открытыми. Python tests не запускались по ограничению текущей итерации.
