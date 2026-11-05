# Сохранение правок: блок 2.1b (RED conflict tests)

Дата: 2026-10-30. Модели: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (независимое ревью, P3 исправлен за 1 cycle, принят).

## Scope и результат

- `Tests/MeetingCompanionCoreTests/TranscriptEditsConflictTests.swift`: 2 самостоятельных RED-теста конфликта существующего `edits.json`:
  1. Внешнее изменение revision и валидных overrides.
  2. Внешнее изменение текста/имени при неизменных revision, размере и nanosecond mtime (`utimensat` проверен).
- Обе future assertions строго матчат `TranscriptEditsError.conflict` (ошибка `.notImplemented` отвергается). Проверяются сохранение внешних байт, побайтовая неизменность `result.json` и аудио. Caller draft assertions являются только локальным sanity-check без гарантий UI/сессии.
- Каркас репозитория не менялся. Блок 2.2 не реализовывался.

## Проверки

Команды зафиксированы в `W/review-commands.json` (`W=/private/var/folders/p0/09r407rx6ylc_rkx9th9q2pr0000gp/T/opencode/transcript-editor-2.1b-q6wfie_x`), флаг плагина:
`-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`.

1. `swift test --disable-automatic-resolution <plugin-flag> --filter TranscriptEditsConflictTests`: Exit 1; 2/2 runtime RED на prerequisite `loadEdits` (`.notImplemented`).
2. `swift test ... --filter TranscriptEditsRepositoryTests`: Exit 1; 2/2 runtime RED сохранён.
3. `swift test ... --filter TranscriptDocumentTests`: Exit 0; 16/16 GREEN.
4. `swift build -c release`: Exit 0; `openspec validate transcript-editor --strict` и `git diff --check`: Exit 0.

## Ограничения

Отчёт фиксирует RED: conflict assertions недостижимы до 2.2, обнаружение конфликтов НЕ доказано. Locks, crash, UI/UAT, create/delete, undo и Python не проверялись. Задачи 1.0, 2.1, 2.2 открыты. Токен-статистика: unavailable. Полные логи в `W/builder-report.md`, `W/reviewer-report.md`, `W/reviewer-followup.md`.
