# Сохранение правок: блок 2.1d (RED save failure + retry)

Дата: 2026-10-30. Роли: Builder — `google/antigravity-gemini-3.8-flash-high`; Reviewer — `codex-lb/gpt-6.1-sol#medium` (1 cycle, 2 P2 findings исправлены, accepted). Свидетельства: `W/2.1d-review.md`, `W/2.1d-followup.md`, `W/2.1d-builder.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`: минимальный injection seam `AtomicReplaceHook` в `init` для тестирования сбоев атомарной замены. Производственный скелет методов (`.notImplemented`) и контракты не менялись.
- `Tests/MeetingCompanionCoreTests/TranscriptEditsSaveFailureTests.swift`: 2 RED-теста инжектированного сбоя и повторной попытки:
  1. `testFailedSavePreservesPreviousEditsAndAllowsRetrySavingNextRevision`: сохранение байт rev 1 и аудио, локальный черновик у вызывающего, retry сохраняет rev 2.
  2. `testFailedSaveWithInitialAbsentEditsLeavesNoFileAndAllowsRetry`: отсутствие файла сохраняется без частичной записи, retry сохраняет rev 1.
- В fix cycle 1 (P2): хук валидирует `destURL == editsFile`, отдельный существующий staging-файл и декодирует pending JSON со следующей ревизией до throw; успешный путь хука — no-op; проверена очистка staging; после retry проверена побайтовая неизменность всех 3 аудиофайлов и `result.json`.

## Проверки и ограничения

1. `swift test ... --filter TranscriptEditsSaveFailureTests`: Exit 1; 2/2 runtime RED на prerequisite `loadEdits` (`.notImplemented`).
2. Предыдущие тесты (presence2, conflict2, repository2): Exit 1 (6 RED сохранены).
3. `swift test ... --filter TranscriptDocumentTests`: Exit 0; 16/16 GREEN.
4. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.

Ограничения: assertions сбоя и retry недостижимы до блока 2.2, обработка сбоев не доказана. Remainder 2.1 и 2.2 открыты.
