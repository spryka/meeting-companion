# Согласование контракта JSON v1 и файловой структуры: блок 1.0

Дата: 2026-10-31. Documentation-only отчёт; TDD для документации не требуется по CONTRIBUTING.md.
Согласование: Сопровождающий/пользователь явно подтвердил (2026-10-31) бизнес-правила
и контракт файловой системы JSON v1 после обсуждения задачи 1.0. Контракт зафиксирован
как язык-независимая спецификация формата и хранилища (ADR-0001 сохраняет силу,
перезапись корневого ADR не требуется). Чекбокс задачи 1.0 в `tasks.md` остаётся
неотмеченным (`[ ]`) до завершения независимого ревью.

## 1. Восемь согласованных принципов контракта

1. **Неизменяемый baseline и изоляция версий**: результат распознавания фиксируется
   в `raw/transcripts/<resultID>/result.json` и никогда не модифицируется после публикации.
   Пользовательские правки хранятся строго отдельно в `edits.json`. Повторная обработка
   формирует независимый каталог `<newResultID>` и не изменяет опубликованные данные.
2. **Baseline vs final**: `baselineWords` сохраняет исходный вывод GigaAM до применения
   терминологической коррекции. При отключённой или завершившейся сбоем коррекции
   текст и временные интервалы `words` и `baselineWords` пословна совпадают.
3. **Голоса источников, а не личности людей**: метки `speakers[].id` и пара `sourceID`/`localID`
   идентифицируют локальные акустические кластеры моделей, а не людей. Уникальный
   `displayNumber` назначается детерминированно (микрофон 1..N, удалённые со смещением).
   Пользовательские имена являются переопределениями в `edits.json` и не меняют ID спикеров.
4. **Различие неизвестного числа голосов и нуля**: `detectedVoiceCount: 0` означает
   подтверждённое моделью отсутствие речи (`diarizationStatus == "completed"`); `null` —
   число неизвестно (диаризация выключена или завершилась ошибкой). Значение фиксируется
   до назначения голосов словам.
5. **AEC requested != applied**: флаг запроса эхоподавления (`aec.requested == true`)
   не гарантирует успешное применение. Инвариант: `aec.requested == (aec.outcome != "disabled")`.
   При `outcome == "applied"` обязательна отдельная копия микрофона внутри версии;
   при `failed` обязательно предупреждение.
6. **Микс на версию и отсутствие fallback**: готовый микс фиксируется внутри каталога версии
   (`raw/transcripts/<resultID>/mix.m4a`). При сбое смешивания версия публикуется со статусом
   `playback.status == "unavailable"`, `playback.mixPath == null` и предупреждением.
   Автоматическая подмена одиночной дорожкой или миксом другой версии запрещена.
7. **Снимок контекста календаря (приглашены, а не присутствовали)**: объект `context`
   фиксирует метаданные встречи на момент захвата. Список `attendees` содержит
   приглашённых лиц и не является доказательством их фактического присутствия или авторства реплик.
8. **Повреждённые и неподдерживаемые документы не перезаписываются**: при обнаружении
   неизвестной версии схемы, нарушении структуры, некорректных ссылках или попытке выхода
   за пределы папки чтение завершается ошибкой без перезаписи файлов на диске.

## 2. Матрица верификации задачи 1.0

| Элемент контракта | Требование спецификации / дизайна | Доказательство в документации | Доказательство в фикстурах | Доказательство в Swift reader (`TranscriptDocument.swift`) |
|---|---|---|---|---|
| **Обязательные поля** | 12 полей верхнего уровня (`schemaVersion`, `resultID`, `createdAt`, `sources`, `speakers`, `words`, `turns`, `baselineWords`, `aec`, `playback`, `warnings`, `context`) и обязательные поля вложенных объектов | `design.md` (строки 42–76), `specs/transcript-document/spec.md`, `docs/transcription-pipeline.md` (строки 195–226) | `valid_parakeet_off.json` (все поля), `fixtures/README.md` (раздел 1) | `TranscriptDocumentTests.testRequiredFieldsAndNulls` (проверка отсутствия каждого ключа) |
| **ID и ссылки** | Уникальность ID в своих пространствах (`words`, `baselineWords`, `turns`, `speakers`); ссылки `speakerID` и `wordIDs` валидны; каждое слово входит ровно в одну реплику; интервал реплики охватывает слова | `design.md` (строки 54–59, 78–79), `docs/transcription-pipeline.md` (строки 227–243) | `invalid_duplicate_ids.json`, `invalid_broken_references.json` | `TranscriptDocumentTests.testInvalidIDsReferencesAndOwnership`, `testSeparateIDNamespacesAndOpaqueSpeakerIDs` |
| **Baseline vs final** | При `correctionStatus` in (`disabled`, `failed`) итоговые слова совпадают с `baselineWords` по тексту и интервалам; при `completed` допустимы замены | `design.md` (строки 60–63), `specs/transcript-document/spec.md`, `docs/transcription-pipeline.md` (строки 248–251) | `valid_parakeet_off.json`, `valid_parakeet_on.json`, `valid_partial_failure.json` | `TranscriptDocumentTests.testUncorrectedBaselineMustMatchTextAndTimesPerSource` |
| **Предупреждения** | Объекты `code`, `sourceID` (`host`/`remote`/`null`), `message` без абсолютных путей ОС; обязательны при `playback.status == "unavailable"` и `aec.outcome == "failed"` | `design.md` (строки 69–72), `docs/transcription-pipeline.md` (строки 224–226) | `valid_partial_failure.json` (содержит `correction_failed` и `playback_mix_failed`) | `TranscriptDocumentTests.testPlaybackAndAECConsistency`, `testAppliedAECRequiresVersionCopyAndFailedAECWarning` |
| **Null vs 0** | `detectedVoiceCount`: `0` строго при `diarizationStatus == "completed"` (подтверждённое отсутствие голосов); `null` строго при `disabled`/`failed` (неизвестное число) | `design.md` (строки 48–50), `specs/transcript-document/spec.md`, `docs/transcription-pipeline.md` (строки 217–220) | `valid_empty_voices.json` (`detectedVoiceCount: 0`), `valid_unknown_voices.json` (`null`) | `TranscriptDocumentTests.testUnknownKeysAndExplicitNullsAreAccepted`, `testIntervalsCountsStatusesAndDates` |
| **AEC requested vs outcome** | Инвариант `aec.requested == (aec.outcome != "disabled")`; исход `applied` требует копию микрофона внутри версии (`raw/transcripts/<id>/...`) | `design.md` (строки 64–66), `specs/transcript-document/spec.md`, `docs/transcription-pipeline.md` (строки 252–255, 263–265) | `valid_parakeet_off.json` (`disabled`), `valid_partial_failure.json` (`failed`) | `TranscriptDocumentTests.testAppliedAECRequiresVersionCopyAndFailedAECWarning`, `testPlaybackAndAECConsistency` |
| **Playback ready / unavailable** | `ready` требует относительный путь `mixPath` внутри своей версии; `unavailable` требует `mixPath: null` и хотя бы одно предупреждение; изолированный микс на версию | `design.md` (строки 67–68, 128–135), `docs/transcription-pipeline.md` (строки 221–223, 261–262, 277–280) | `valid_parakeet_off.json` (`ready`), `valid_partial_failure.json` (`unavailable`) | `TranscriptDocumentTests.testReadyMixMustBelongToExactVersion`, `testPlaybackAndAECConsistency` |
| **Снимок контекста** | Поле `context` принимает объект или `null`; поля внутри объекта опциональны; `attendees` — список приглашённых, а не подтверждение присутствия | `design.md` (строки 73–75), `docs/transcription-pipeline.md` (строки 213–216) | `valid_parakeet_off.json` (заполнен), `valid_unknown_voices.json` (`null`) | `TranscriptDocumentTests.testEmptyDocumentAndSparseContext`, `testRequiredFieldsAndNulls` |
| **Общие fixtures и валидация** | 6 валидных и 5 невалидных общих фикстур; валидатор проверяет интервалы, symlinks, path traversal, неподдерживаемые версии без модификации диска | `design.md` (строки 40–42, 79–81, 118–119), `docs/transcription-pipeline.md` (раздел "Фикстуры") | `transcription/fixtures/transcript-document/` (все 11 JSON) | `TranscriptDocumentTests.testSixSharedValidFixturesWithoutAudio`, `testFiveSharedInvalidFixturesHaveSpecificErrors`, `testAudioPathsRejectAbsoluteEscapeAndSymlinkSibling`, `testMalformedReadNeverWrites` |

## 3. Исторические свидетельства совместимости реализаций

- **Python producer (историческое доказательство от 2026-10-30)**:
  В рамках верификации блоков 1.2 и 1.3 (`verification-1.2.md`, `verification-1.3.md`)
  генератор документов `transcript_document.py` и публикатор `publish_result` были проверены
  на полном наборе из 107 Python-тестов. В `verification-1.3.md` дополнительно зафиксировано:
  7 синтетических записей, сгенерированных реальным Python-конвейером, были успешно
  десериализованы production Swift-ридером (`TranscriptDocument.load`) без расхождений.
  Поскольку контракт зафиксирован как язык-независимый JSON-формат, отдельная миграция
  или повторное выполнение Python-генератора в рамках текущего блока не требовались.
- **Swift reader (текущая независимая проверка от 2026-10-31)**:
  Набор из 16 тестов `TranscriptDocumentTests` запущен офлайн с флагом `TestingMacros`:
  все 16 тестов успешно пройдены за 0.087 с.
- **Согласование документации (2026-10-31)**:
  В `openspec/changes/transcript-editor/design.md` внесена минимальная запись о согласовании
  контракта и файловой структуры сопровождающим (2026-10-31).

## 4. Команды и результаты проверок

```sh
rtk proxy swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib --filter TranscriptDocumentTests
rtk proxy openspec validate transcript-editor --strict
rtk git diff --check
```

- Swift Testing: 16/16 passed (0.087 с), 0 failures, 0 skipped.
- OpenSpec CLI: `Change 'transcript-editor' is valid` (strict mode).
- Git diff check: 0 ошибок форматирования / whitespace.

## 5. Границы и ограничения

- **Documentation-only**: изменения в кодовую базу Python или Swift в блоке 1.0 не вносились;
  произведены только актуализация документации согласования и составление матрицы.
- **Без миграции продюсера**: существующий генератор Python признан удовлетворяющим
  согласованному контракту на основе исторических тестов от 2026-10-30; сквозное тестирование
  миграции старых записей не проводилось (сейчас история открывает старый TXT внешним
  приложением через NSWorkspace, а встроенный read-only legacy TXT режим запланирован в 3.2;
  автоматическая миграция плоских записей не предусмотрена).
- **Без UI и UAT**: воспроизведение и интерфейс редактора, а также live UAT не принимаются
  этой проверкой; реализация блокировок отдельно принята в разделе 2.
- **Статус задачи**: 1.0 закрыта после явного согласования сопровождающим 2026-10-31
  и независимой приёмки `codex-lb/gpt-6.1-sol#medium`. Единственный P2 о готовности
  legacy UI исправлен за один цикл и повторно принят. Отчёты reviewer-report.md и
  reviewer-followup.md сохранены в временном каталоге `contract1.0-cZOsAR`.
