# Сохранение правок: блок 2.1f (RED undo + version isolation)

Дата: 2026-10-30. Роли: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (1 cycle, 2 P2 findings исправлены, accepted). Свидетельства: `W/2.1f-review.md`, `W/2.1f-followup.md`, `W/2.1f-builder.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: минимальный skeleton API сессионного undo (`canUndo`, `undo`, ошибка `noUndoHistory`). Контракты хранения неизменны.
- `Tests/MeetingCompanionCoreTests/TranscriptEditsUndoTests.swift`: 2 RED-теста undo и изоляции версий на синтетической записи с версиями `res_a` и `res_b`:
  1. `testUndoRestoresPreviousSavedStateAsNewRevisionAndDoesNotAffectOtherVersion`: отмена единичной правки возвращает прежнее состояние в ревизии 3; версия B со совпадающим `turn_1` не затронута; новая сессия `repo2` имеет пустой стек undo (`canUndo == false`, точный `noUndoHistory`).
  2. `testBatchOverridesUndoAtomicallyRevertsAllTurnTargetsAndLeavesOtherVersionUntouched`: групповая правка атомарно отменяется за один шаг undo; версия B не затронута.
- В fix cycle 1 (P2): проверены полные overrides до и после undo (на диске и в возвращаемых значениях); проверка новой сессии выполнена до потребления истории, доказана побайтовая неизменность вокруг отклонённого undo.

## Проверки и ограничения

1. `swift test ... --filter TranscriptEditsUndoTests`: Exit 1; 2/2 runtime RED на prerequisite `save` (`.notImplemented`).
2. Предыдущие тесты (lock2, save_failure2, presence2, conflict2, repository2): Exit 1 (10 RED сохранены).
3. `swift test ... --filter TranscriptDocumentTests`: Exit 0; 16/16 GREEN.
4. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.

Ограничения: assertions undo и изоляции недостижимы до 2.2. Блок 2.2 остаётся открытым.
