# Предупреждения о лимите голосов и 16 независимых групп: блок 4.3

Дата: 2026-10-31. Builder: `google/antigravity-gemini-3.8-flash-high`; независимый reviewer: `codex-lb/gpt-6.1-sol#high` (принято после 1 цикла fix). Свидетельства: `Wsection4-4.3/high-followup1.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptDocument.swift`:
  - `localizedSourceLabel(for:)`: возвращает «Микрофон» для `.host` и «Системный звук» для `.remote`.
  - `diarizationWarning(for:)`: выводит предупреждение о лимите голосов при `detectedVoiceCount >= 8` на дорожке со статусом `.completed`; дедуплицирует строго по точному каноническому коду `diarization_voice_limit` и `sourceID`, сохраняя несвязанные предупреждения (например, `recognition_voice_limit_recovery_failed`).
  - `presentationWarnings`: возвращает все активные предупреждения документа и выведенные предупреждения о лимите голосов без изменения сериализованного JSON на диске.
  - Строгое предотвращение ложных предупреждений: отсутствие diarization (null/disabled), 0 голосов или менее 8 голосов не создают предупреждений; число приглашённых в календаре никогда не подменяет счётчик голосов модели.
  - 16 независимых групп говорящих (host 1–8 и remote 1–8) получают уникальные номера `displayNumber` (Speaker 1–16). Пользовательские назначения не ограничиваются 8 или 16 (проверено 18+ уникальных имён).
- `Sources/MeetingCompanionApp/TranscriptReviewWindow.swift`:
  - `PresentationWarningItem`: структурированная модель предупреждений с уникальным стабильным ID (`sourceTag_code_occurrence`), локализованным лейблом источника и текстом сообщения. Устранена коллизия `ForEach(id: \.self)` при идентичных текстах предупреждений хоста и удалённого источника.
  - Отображение предупреждений в окне: каждая дорожка («Микрофон» и «Системный звук») выводится в отдельной плашке с лейблом дорожки.
  - Секция «Приглашены: [список]»: выводится строго при наличии `context.attendees` и опускается при отсутствии; не выполняет автоматического сопоставления.
  - Лейблы дорожек в выборе группы и диалоге подтверждения используют канонические имена «Микрофон» и «Системный звук».
- Тесты и проверки:
  - 20/20 GREEN в `TranscriptSpeakerAssignmentTests.swift`.
  - 66/66 checks GREEN в `scripts/check-transcript-speaker-assignment-ui.swift`.
  - 27 checks GREEN в `scripts/check-transcript-player-window.swift`.
  - 15 checks GREEN в `scripts/check-transcript-window.swift`.
  - 169/169 full Swift suite GREEN.

## Независимая верификация Sol

1. Набор проверок AppKit UI: **66 speaker UI + 27 player + 15 window GREEN**.
2. Полный набор Swift: **169/169 GREEN** (16 сьютов).
3. 107 adversarial checks: 18 имён, 16 идентичностей, null/status/calendar20 cases, точное сохранение байтов.
4. `swift build -c release --disable-automatic-resolution --skip-update`: exit 0.
5. `openspec validate transcript-editor --strict`: exit 0.
6. `git diff --check`: exit 0.
7. Baseline integrity: все 207 исходных файлов побайтово идентичны.

## Ограничения

- Реализованы и проверены Core-хелперы и UI предупреждений о лимите голосов и приглашённых (4.3).
- Редактирование текста реплик (4.4) и экспорт (4.5) не реализовывались.
