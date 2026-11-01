# Сохранение правок: блок 2.2c (atomic SAVE + conflict detection)

Дата: 2026-10-30. Исходный builder: `google/antigravity-gemini-3.8-flash-high`; rescue builder: `codex-lb/gpt-6.1-sol`; независимый reviewer: `codex-lb/gpt-6.1-sol#medium` (принято после Sol rescue cycle 1). Свидетельства: `W/2.2c-sol-rescue-review.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: реализованы методы сохранения правок `saveTurnOverride` и `saveEdits`:
  - Автоматический захват/удержание блокировки записи (`acquireWriteLock`) на первой записи.
  - Полная сериализация операций сохранения, чтения и освобождения через `operationGate` с observer-координацией; внутренний `loadEditsGated` исключает рекурсивный deadlock.
  - Эксклюзивное создание staging-файла (`O_CREAT | O_EXCL`) и регистрация `unlink` до записи; устранение double-close дескрипторов.
  - Двухэтапная CAS-проверка конфликтов (до staging и перед заменой): внешнее создание, удаление или изменение ревизии/байтов бросает точный `conflict`.
  - Гарантированная запись данных после хука, атомарный POSIX `rename`, retry со следующей ревизией.

## Проверки и ограничения

1. 60 GREEN тестов: `SaveTests` 10, `SaveFailureTests` 2, `LockTests` 6, `ConflictTests` 2, `PresenceConflictTests` 2, `RepositoryTests` 2, `ReadingTests` 20, `DocumentTests` 16.
2. Мутационные свидетельства (`mutant-{save,load}.diff`): удаление гейта ломает тесты реальными семантическими ошибками (конфликт, сбой ревизий).
3. `UndoTests`: 2 ожидаемых RED (до 2.2d).
4. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
