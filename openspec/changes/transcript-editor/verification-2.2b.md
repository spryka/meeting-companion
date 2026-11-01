# Сохранение правок: блок 2.2b (LOCK ONLY)

Дата: 2026-10-30. Роли: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (принято с 1-го цикла без замечаний). Свидетельства: `W/2.2b-review.md`, `W/2.2b-builder.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: реализована блокировка записи per-recording через OS `flock`:
  - `acquireWriteLock`: неблокирующий `flock(fd, LOCK_EX | LOCK_NB)` на `.transcript-editor.lock`, при занятости возвращает точный `lockDenied`.
  - Безопасность путей: `isContained`, открытие с `O_NOFOLLOW | O_CLOEXEC` (права `0o600`), symlink отвергается (`ELOOP` -> `malformed`). Файл блокировки не удаляется (no unlink).
  - Дескриптор удерживается до явного `releaseWriteLock()` или `deinit`.
  - Потокобезопасность под `NSLock`; идемпотентность повторного вызова на том же экземпляре; раздельные экземпляры на записи A получают отказ, пока запись B доступна; OS release при завершении/SIGKILL процесса.
- Сохранение и отмена правок не реализовывались.

## Проверки и ограничения

1. `TranscriptEditsLockTests`: 6/6 GREEN (2 child process + 4 local lock; 0 выживших процессов).
2. `TranscriptEditsReadingTests`: 20/20 GREEN; `TranscriptDocumentTests`: 16/16 GREEN.
3. Тесты сохранения (conflict2, presence2, save_failure2, undo2, repository): ожидаемый RED на вызовах `save` (`.notImplemented`).
4. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
