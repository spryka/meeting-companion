> Актуализация 2026-11-03: history picker, selectedResultID и async-switch clauses
> superseded [ADR-0004](../../../adr/0004-single-current-transcript.md) и
> [single-current-transcript](../single-current-transcript/design.md). Ниже сохранена
> история прежней реализации/приёмки; её counts/UAT не являются проверкой beta.6.
> Ручные text/name edits, CAS, export и playback сохранены. Новая приёмка pending,
> физический UAT beta.6 — WAITING_UAT; архивирование не выполняется.

# ADR Review Manifest

- Status: completed
- Review date: 2026-10-29

## Review Summary

Проверка архитектурных решений завершена. Зафиксирован согласованный принцип
сохранения исходного распознавания и пользовательских правок. Это приёмка
архитектурного принципа, а не реализации: задачи редактора остаются открытыми.
Выбор JSON пока остаётся предложением в design.md, отдельный ADR не создаётся.

Уточнения плана сохраняют ADR-0001: baseline GigaAM, итоговые слова, фактически
использованный обработанный источник и готовый микс фиксируются до публикации
версии. Сбой смешивания даёт окончательную текстовую версию, а не последующее
изменение опубликованного результата. Модель одного писателя приложения и JSON v1
остаются деталями этого дизайна. Новых долгосрочных ADR не требуется; принятый
ADR-0001 не изменялся. Пороги performance-UAT отдельно согласованы сопровождающим
и закреплены в спецификации; сам UAT ещё не выполнен.

## In-Force ADRs Reviewed

До этого изменения корневых ADR не было. Дизайн сверён с новым ADR-0001.

## New Durable ADRs Created

- [ADR-0001: Раздельное хранение распознавания и пользовательских правок](../../../adr/0001-preserve-recognition-and-user-edits.md)


## Latest owner cutoff — ADR-0005 (2026-11-03)

Full functionality requires canonical folder basename == recording stem, independent of raw existence/age/producer/markers. Standard capture starts before raw exists; valid structured data without originals retains editor/playback. Retry separately requires exact contained raw host+remote WAVs, never automatic flat fallback. Nonstandard placement is list + available standalone contained saved TXT read-only, with no shared structured lookup, context/calendar mutation, durable history writes, capture or processing. Flat display metadata stays at its exact root path even if raw appears. Enforce guards before side effects in Application enqueue/start, every durable history writer, Platform Recorder/Transcription, and Worker recording mode. Explicit developer pair mode keeps its separate output-directory contract. Preserve all files and prior one-current/publication/draft/service safeguards; no migration. This supersedes earlier flat-retry clauses only; accepted ADR1–4 remain unchanged.
