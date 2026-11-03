# ADR Review Manifest

- Status: completed
- Review date: 2026-11-02

## Review Summary

Проверены accepted ADR-0001 и существующий ADR-0002 на базе приложения
`520f7d3a9d826d14c26380dc502aa3007b531760`. ADR-0001 не изменён.
Владелец разрешил актуализацию и начало реализации 2026-11-02 в прежней
границе отдельного worker; ADR-0002 отмечен accepted на основании этой команды.
Архитектура моделей не переписывается, новый формат редактора не вводится.

Принят ADR-0003 для отделения application services от UI и macOS adapters.
Он дополняет ADR-0001/0002: модели/MLX остаются в завершающемся worker,
формат и неизменяемые версии сохраняются. Проверка совместимости решений
выполнена; владелец принял спецификацию 2026-11-02 и разрешил реализацию.

## In-Force ADRs Reviewed

- [ADR-0001](../../../adr/0001-preserve-recognition-and-user-edits.md), accepted:
  неизменяемые recognition versions, отдельные правки конкретной версии,
  отсутствие автоматического переноса между версиями. Редактор уже включён
  в базовый commit; JSON v1/selection/edits/export/preview сохраняются.
- [ADR-0002](../../../adr/0002-isolated-swift-transcription-worker.md), accepted
  2026-11-02: отдельный завершающийся worker, одна загрузка каждой модели,
  независимое state host/remote и teardown до следующего этапа.

## New Durable ADRs Created

- [ADR-0003](../../../adr/0003-separate-application-from-ui.md), accepted 2026-11-02:
  Core/Application/Platform/Pipeline, App/CLI composition roots, application-owned
  queue/history и наблюдение из UI. Согласован командой владельца о принятии спеки.
  Карта компонентов и альтернативы описаны в [design.md](design.md).

Accepted ADR-0001/0002 при этом обновлении не изменены; Supersedes нет.

## Corrective pass3 ADR review (2026-11-03)

ADR-0001/0002/0003 remain unchanged and accepted. Additive recording metadata
versioning follows the direct maintainer request; it does not change JSON v1,
result identity, edits or worker isolation. Capability validation and authoritative
transient state complete ADR-0003. No new long-term ADR is proposed in this pass.

## Owner-authorized simplification (2026-11-03)

Pass3 marker/selection decisions выше superseded accepted [ADR-0004](../../../adr/0004-single-current-transcript.md).
ADR0001/2/3 не переписывались; заменены только history-selection clauses. Один current,
no marker gate, immutable result/edit separation и прежняя worker isolation. Это согласование
архитектуры владельцем, не принятие реализации или UAT.


## Latest owner cutoff — ADR-0005 (2026-11-03)

Full functionality requires canonical folder basename == recording stem, independent of raw existence/age/producer/markers. Standard capture starts before raw exists; valid structured data without originals retains editor/playback. Retry separately requires exact contained raw host+remote WAVs, never automatic flat fallback. Nonstandard placement is list + available standalone contained saved TXT read-only, with no shared structured lookup, context/calendar mutation, durable history writes, capture or processing. Flat display metadata stays at its exact root path even if raw appears. Enforce guards before side effects in Application enqueue/start, every durable history writer, Platform Recorder/Transcription, and Worker recording mode. Explicit developer pair mode keeps its separate output-directory contract. Preserve all files and prior one-current/publication/draft/service safeguards; no migration. This supersedes earlier flat-retry clauses only; accepted ADR1–4 remain unchanged.


## UAT baseline-speaker correction (2026-11-03)

Reviewed accepted ADR0001–0005: immutable recognition/baseline and separate edits, isolated Worker/model graph, Application ownership, one-current atomic publication and canonical layout remain unchanged. This restores existing contracts; no new ADR or change to accepted ADRs. Same independent reviewer PLAN_PASS and explicit owner authorization precede implementation.
