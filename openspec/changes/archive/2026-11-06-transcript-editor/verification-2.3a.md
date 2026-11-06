# Выбор версии: блок 2.3a (version selection core)

Дата: 2026-10-30. Исходный builder: `google/antigravity-gemini-3.8-flash-high`; rescue builder: `codex-lb/gpt-6.1-sol`; независимый reviewer: `codex-lb/gpt-6.1-sol#medium` (принято после Sol rescue cycle 1). Свидетельства: `W/2.3a-sol-review.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptVersionSelection.swift`: `TranscriptVersionSelector`:
  - Покомпонентная проверка предков (`verifyContainedPath`) для метаданных и `result.json`.
  - Структурный лексический сканер и non-lossy патчер верхнего уровня с декодированием строковых экранирований (`\u0052esultID`), отсечением некорректных типов (чисел) и дубликатов.
  - Сортировка по `createdAt` (последний — первый), отсечение staging, отказ при недоступной версии (`selectedVersionUnavailable`).
- `Sources/MeetingCompanionApp/RecordingHistory.swift`: авторитетное обновление `selectResultID(_:for:)` и сохранение неизвестных полей (`mergeUnknownFields`), сохраняющее выбор и литералы высокой точности при штатных `history.update`.
- Без UI. Закрепление открытой сессии и retry отложены до 2.3b.

## Проверки и ограничения

1. `TranscriptVersionSelectionTests`: 17/17 GREEN (включая компилируемый probe-харнес с реальным `RecordingHistory`).
2. Все тесты Swift (10 сьютов): 86/86 GREEN (exit 0).
3. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
4. Ограничения: задачи 2.3b (pinning сессии, retry) и общая 2.3 открыты.
