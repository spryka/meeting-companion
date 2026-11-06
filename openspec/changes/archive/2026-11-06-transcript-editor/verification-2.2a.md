# Сохранение правок: блок 2.2a (TDD: чтение и валидация edits)

Дата: 2026-10-30. Исходный builder: `google/antigravity-gemini-3.8-flash-high`; rescue builder: `codex-lb/gpt-6.1-sol`; независимый reviewer: `codex-lb/gpt-6.1-sol#medium` (принято после 2 Gemini cycles и авторизованного Sol rescue). Свидетельства: `W/2.2a-sol-rescue-review.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: реализован read-only метод `loadEdits`:
  - Покомпонентная валидация всей цепочки предков и symlinks (`verifyContainedPath`); выход за пределы папки и висячие ссылки строго отклоняются; только `ENOENT` на финальном файле возвращает initial revision 0 без создания файлов на диске.
  - Строгий лексический сканер верхнего уровня с декодированием строковых экранирований (`\uXXXX`), контролем вложенности и отклонением дубликатов.
  - Точный целочисленный валидатор без lossy Double: принимает 10, 100, `Int.max`; отсекает дроби (`9007199254740992.1`, `1.000...001`), отрицательные числа и overflow.
  - Потокобезопасная фиксация `LoadedSnapshot` под `NSLock` для будущего CAS; сохранение сессионного undo.
- Запись (`saveTurnOverride`, `saveEdits`) и блокировки (`acquireWriteLock`) не реализовывались (no save yet).

## Проверки и ограничения

1. `TranscriptEditsReadingTests`: 20/20 GREEN (exit 0).
2. `TranscriptDocumentTests`: 16/16 GREEN (exit 0).
3. `TranscriptEditsRepositoryTests`: 1 GREEN (отсутствие) + 1 ожидаемый RED (`save` `.notImplemented`).
4. Остальные тесты 2.1: ожидаемый RED на вызовах `save`/`lock`.
5. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
