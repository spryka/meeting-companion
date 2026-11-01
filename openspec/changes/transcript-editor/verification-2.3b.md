# Выбор версии: блок 2.3b (open session pinning, transactional switch & retry isolation)

Дата: 2026-10-31. Builder: `google/antigravity-gemini-3.8-flash-high`; независимый reviewer: `codex-lb/gpt-6.1-sol#medium` (принято после 2 fix cycles). Свидетельства: `W/2.3b-final-review.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptReviewSession.swift`: `@MainActor` сессия `TranscriptReviewSession`:
  - Закрепление изначально выбранной версии (`activeResultID`) при открытии сессии. Появление новых опубликованных версий или артефактов staging не приводит к автоматическому переключению открытой сессии.
  - Транзакционное переключение версии `switchVersion(to:)`: мутация `_activeResultID` происходит только после успешного сохранения выбора через авторитетный обработчик или селектор. При ошибке сессия, память и диск сохраняют прежнее состояние.
  - Защита от реентерабельного вызова переключения из коллбэка сохранения и безопасное чтение `activeResultID` без deadlock.
  - Полноценная изоляция актора: безопасный actor-hop из фоновых задач (`Task.detached`) без `MainActor.assumeIsolated`.
- `Sources/MeetingCompanionApp/RecordingHistory.swift`:
  - Единая выбрасывающая транзакция сохранения (`putThrowing`, `updateThrowing`, `selectResultIDThrowing`): кандидат мутируется в памяти, кодируется и валидируется, один раз пишется на диск и только после успеха публикуется в `entries`.
  - Устранена двойная запись и проглатывание ошибок; при невалидных данных (например, `duration = .nan`) ошибка выбрасывается до записи на диск.
  - Обычные `put` и `update` безопасно оборачивают throwing-методы с фиксацией ошибки в `self.error` без изменений UI.
- `Tests/MeetingCompanionCoreTests/TranscriptReviewSessionTests.swift`:
  - 11/11 GREEN: закрепление версии, транзакционное переключение, reentrant callback без дедлока, actor-hop, неизменность байт исходников/правок/микса при синтетической публикации/staging/переключении (артефактная симуляция, не запуск Python), probe-тесты с реальным `RecordingHistory` (включая семантический RED на `duration = .nan` до фикса).

## Проверки и ограничения

1. `TranscriptReviewSessionTests`: 11/11 GREEN.
2. `TranscriptVersionSelectionTests`: 17/17 GREEN.
3. Все тесты Swift (11 сьютов): 97/97 GREEN (exit 0).
4. `swift build -c release`, `openspec validate transcript-editor --strict`, `git diff --check`: Exit 0.
5. Ограничение: реализовано и проверено ядро сессии и авторитетной истории (Core/App-history) без UI. Задача 1.0 остаётся открытой `[ ]`.
