# ADR Review Manifest

- Status: completed
- Review date: 2026-11-06

## Review Summary

Удаляется частная presentation/admission развилка в существующем updater. Архитектура, application state, update signing и data contracts сохраняются.

## In-Force ADRs Reviewed

- ADR0001 — immutable recognition и отдельные edits, без изменений.
- ADR0002 — isolated worker, без изменений.
- ADR0003 — application/UI boundaries, без изменений.
- ADR0004 — current/session/CAS, без изменений.
- ADR0005 — standard recording ownership, без изменений.
- ADR0006 — workspace/overlay independence и busy protection, без изменений.
- ADR0007 — Settings modal/admission; собственный Settings check и запрет restart при input сохраняются.

Частичные supersession 0004→0001/0003, 0005→0004, 0007→0006 сохранены. Accepted ADR не переписываются.

## New Durable ADRs Created

Нет: сохраняется существующий Sparkle, новая архитектура или persistence не вводятся.
