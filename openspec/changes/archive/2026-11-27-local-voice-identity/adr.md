# ADR Review Manifest

- Status: completed
- Review date: 2026-11-21

## Review Summary

ADR review completed for this change: сверены текущие исходники `7a83dd9`,
основные specs, design и действовавшие root ADR. Дополнения от 2026-11-21 сверены с базой `28c2eab`. Форматы, outbox и worker mode конкретизируют ADR-0008. Принятые ADR сохранены; групповое автоназначение по `Speaker N` и отбор чистых подокон оформлены новым [ADR-0011](../../../../adr/0011-group-voice-matching-and-clean-subwindows.md) без изменения принятых `ADR-0008` и `ADR-0009`.

## In-Force ADRs Reviewed

| ADR | Применимая часть |
| --- | --- |
| [0001](../../../../adr/0001-preserve-recognition-and-user-edits.md) | immutable recognition и отдельные правки; UI history/selection заменены 0004 |
| [0002](../../../../adr/0002-isolated-swift-transcription-worker.md) | один изолированный Swift/MLX worker, явная подготовка |
| [0003](../../../../adr/0003-separate-application-from-ui.md) | Core/Application/Platform/Pipeline и общие services; version selection заменена 0004 |
| [0004](../../../../adr/0004-single-current-transcript.md) | один current, staging commit, no edit transfer; flat retry clause заменена 0005 |
| [0005](../../../../adr/0005-standard-recording-layout.md) | canonical placement, flat read-only, без миграции/чужого audio fallback |
| [0006](../../../../adr/0006-independent-workspace-and-recording-overlay.md) | независимые workspace/capture, shared admission; separate Settings clause заменена 0007 |
| [0007](../../../../adr/0007-workspace-settings-modal.md) | Settings modal поверх workspace, ownership/focus; состав разделов замещён ADR-0008 |
| [0008](../../../../adr/0008-local-voice-identity-profiles.md) | локальные профили, происхождение имён, отбор речи, сопоставление, worker |
| [0009](../../../../adr/0009-enrol-voices-through-name-edits.md) | обучение через ручное назначение, заменяет явный импорт и условия начала обучения в 0008 |
| [0011](../../../../adr/0011-group-voice-matching-and-clean-subwindows.md) | отбор чистых подокон 3–6 с, fallback на `words`, порядок-независимая сборка и групповое автоназначение по `Speaker N` |

ADR-0008 замещает состав разделов Settings в ADR-0007. ADR-0009 замещает действие импорта в §1 и допуск старой разметки через импорт в §5 ADR-0008. Отзыв уже учтённых образцов сохраняется. ADR-0011 (`proposed`) замещает §4 (fallback на `words` при отсутствии `voice-quality.v1.json`, порядок-независимый отбор начального профиля) и §6.5–6.6 (чистые подокна и групповое автоназначение по `Speaker N`) в ADR-0008 без правки принятого ADR-0008. Остальные решения исходных ADR действуют.

## New Durable ADRs Created

[ADR-0009](../../../../adr/0009-enrol-voices-through-name-edits.md) принят после отказа владельца от формы импорта. [ADR-0010](../../../../adr/0010-confirm-existing-speaker-name.md) описывает предложенное уточнение. Подтверждение сохраняет назначение выбранной реплики с `origin == nil` или `manual` и отсутствующим `personID` через прежний writer. [ADR-0011](../../../../adr/0011-group-voice-matching-and-clean-subwindows.md) фиксирует отбор чистых подокон 3–6 с, максимальное согласованное подмножество при первичной сборке профиля и групповое автоназначение по `Speaker N` с защитой от смешанных кластеров. Решения 0010 и 0011 проверяются в этом change.

## Review Evidence and Limits

Повторное архитектурное ревью Astra high `wfr_506bb172-65df-4327-9ca7-292cae9a5938`
завершилось `pass`, findings=[] для root ADR-0008 с SHA-256
`9d91652118d2bada3fb0ed0bfc61fce4ae6d096da10eea74b3d376ee19bfd9f8`.
Замечания reviewer о детализации outbox/recovery приняты: конкретный порядок
commit, reconciliation, deletion/retry barrier и crash scenarios добавлены в design/specs.
Отмеченные calibration/blind-test/license gates сохранены в задачах.

Astra High в треде `thr_uaqvxmvuy7` отдельно сверила исходные ADR/SDD и эталон
на базе `28c2eab`. Владелец подтвердил предложенные уточнения. Implementation
review, измерение качества и native UAT остаются задачами.
