# Сохранение правок: блок 2.1c (RED presence conflict tests)

Дата: 2026-10-30. Роли: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (независимое Sol review accepted, 0 замечаний). Свидетельства: `W/2.1c-review.md`, `W/2.1c-builder.md`.

## Scope и результат

- `Tests/MeetingCompanionCoreTests/TranscriptEditsPresenceConflictTests.swift`: 2 RED-теста внешнего изменения наличия `edits.json`:
  1. `testConflictWhenExternalWriterCreatesEditsAfterInitialAbsentLoad`: `loadEdits` при отсутствии файла → синхронное внешнее создание валидного `edits.json` → `saveTurnOverride` ожидает `TranscriptEditsError.conflict`.
  2. `testConflictWhenExternalWriterDeletesEditsAfterInitialLoad`: `loadEdits` существующего `edits.json` → синхронное внешнее удаление до `save` → `saveTurnOverride` ожидает `TranscriptEditsError.conflict` (не пересоздаёт молча).
- Assertions строго матчат `.conflict`. Future assertions: внешние байты / отсутствие файла сохранены, `result.json` и аудио побайтно неизменны, локальные draft значения сохранены без UI-гарантий.
- Каркас репозитория не менялся. Блок 2.2 не реализовывался.

## Проверки и ограничения

1. `swift test ... --filter TranscriptEditsPresenceConflictTests`: Exit 1; 2/2 runtime RED на prerequisite `loadEdits` (`.notImplemented`).
2. `swift test ... --filter TranscriptEditsConflictTests`: Exit 1; 2/2 RED сохранён.
3. `swift test ... --filter TranscriptEditsRepositoryTests`: Exit 1; 2/2 RED сохранён.
4. `swift test ... --filter TranscriptDocumentTests`: Exit 0; 16/16 GREEN.
5. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.

Ограничения: assertions конфликта недостижимы до 2.2, детекция не доказана. Блок 2.2 и remainder 2.1 открыты.
