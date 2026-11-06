# Сохранение правок: блок 2.2d (session UNDO)

Дата: 2026-10-30. Роли: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (принято с 1-го fix цикла). Свидетельства: `W/2.2d-review.md`, `W/2.2d-followup1.md`, `W/2.2d-builder.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: реализована сессионная отмена правок `canUndo`/`undo`:
  - `undo` захватывает `operationGate(.undo)` ДО выбора целевого состояния и удерживает гейт до коммита/pop; внутренний `saveOverridesInternalGated` исключает рекурсивный deadlock на гейте.
  - Предыдущие overrides восстанавливаются через атомарный CAS-конвейер сохранения в новую ревизию; стек снимается только после успешного коммита, при ошибках история сохраняется (retryable).
  - Внешний reload с изменением содержимого сбрасывает стек undo.
- Уточнение свидетельств RED: лог билдера содержал `HookTimeoutError`, семантическое воспроизведение и закрытие гонки доказаны независимым зондом ревьюера `2.2d-review-fix1-race.swift`.

## Проверки и ограничения

1. `TranscriptEditsUndoTests`: 9/9 GREEN.
2. Все тесты Swift (9 сьютов): 69/69 GREEN (exit 0).
3. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
