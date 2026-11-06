# Назначение имён говорящих: блок 4.1 (TranscriptSpeakerAssignment)

Дата: 2026-10-31. Builder: `google/antigravity-gemini-3.8-flash-high`; независимый reviewer: `codex-lb/gpt-6.1-sol#high` (принято после 2 циклов fix). Свидетельства: `Wsection4-4.1/high-final-review.md`.

## Scope и результат

- `Sources/MeetingCompanionCore/TranscriptEditsRepository.swift`:
  - Добавлен минимальный internal-хелпер `mutateOverrides` на существующем `operationGate` / `saveOverridesInternal` для атомарной транзакции read-modify-write без отдельного неатомарного шага чтения.
- `Sources/MeetingCompanionCore/TranscriptSpeakerAssignment.swift`:
  - `TranscriptSpeakerAssignmentService`:
    - Назначение одной реплике (`assignSpeakerName(resultID:turnID:displayName:)`): мутирует только указанную реплику, сохраняя остальные реплики группы и существующие `text` overrides.
    - Массовое назначение группе голоса (`assignSpeakerName(resultID:speakerID:displayName:replaceManuallyAssigned:)` и по `voice: TranscriptVoiceKey`): группы host и remote с одинаковым `localID` независимы.
    - Политика замены ручных имён: `replaceManuallyAssigned: false` сохраняет существующие ручные имена; `true` заменяет все имена группы. Во всех случаях `text` overrides сохраняются.
    - Непроницаемый и защищённый от подделки превью `TranscriptBulkAssignmentPreview` (`internal init`): связывает канонический путь записи, `resultID`, `speakerID`, `sourceID`, `localID`, `revision`, `snapshotOverrides`, подтверждённые списки `targetTurnIDs`, `affectedTurnIDs`, `replacedTurnIDs`.
    - Применение по превью (`assignSpeakerName(preview:displayName:)`): транзакционно валидирует ревизию, совпадение канонического каталога записи, снимок overrides и отсутствие промежуточных изменений перед мутацией; отклоняет чужие записи и устаревшие превью с `TranscriptEditsError.conflict`.
    - Снятие назначения (`unassignSpeakerName`): удаляет `displayName`, сохраняя исправленный текст реплики и восстанавливая отображение по умолчанию Speaker N.
    - Контракты отклонения: пустые строки, строки из одних пробелов, неизвестные turnID/speakerID отклоняются без изменения диска и истории отмены; входные строки не нормализуются молча.
  - Интеграция `TranscriptReviewSession`:
    - API контроллера сессии с проверкой `!isClosed` (выбрасывает `TranscriptReviewSessionError.closed`).
    - Проверка `preview.resultID == activeResultID`: предотвращает применение превью неактивной версии после переключения.
- `Tests/MeetingCompanionCoreTests/TranscriptSpeakerAssignmentTests.swift`:
  - 15/15 GREEN: назначение одиночной реплике, независимость групп host/remote при равных localID, превью и сохранение текста при replace=false/true, атомарный undo группы одной операцией с верификацией на диске и повторным открытием, побайтовая сохранность audio и result.json, валидация некорректных ID и пробельных имён без мутаций, снятие назначения с сохранением текста, жизненный цикл и закрытие сессии, конфликт внешней ревизии 50 с сохранением undo, конфликт устаревшего превью при промежуточном изменении, детерминированная конкуррентность текста и назначения через `atomicReplaceHook`, отклонение превью неактивной версии при switch, отклонение превью другой записи, отклонение устаревшего превью при внешнем переименовании с той же ревизией после reload, отклонение сфабрикованного превью с неверными целями.

## Независимая верификация Sol

1. Полный набор Swift: **164/164 GREEN** (16 сьютов), включая 15 тестов назначения; focused 79/79 GREEN.
2. `swift build -c release --disable-automatic-resolution --skip-update`: exit 0.
3. `openspec validate transcript-editor --strict`: exit 0.
4. `git diff --check`: exit 0.
5. Baseline integrity: все 205 исходных файлов побайтово идентичны, параллельные миграции не затронуты.

## Ограничения

- Реализовано и проверено Core API назначения (4.1); UI форма назначения, подсказки календаря и подтверждение группы в окне относятся к 4.2 и открыты.
- Редактирование текста (4.4) и экспорт (4.5) не реализовывались.
