# ADR Review Manifest

- Status: completed
- Review date: 2026-11-10

## Review Summary

ADR review completed for this change. Изменяется тактическая логика сверки
библиотеки в существующих Application/App boundaries. Максимальный номер — 0007.
Семь записей прочитаны; частичные supersession применены только к указанным clauses.

## In-Force ADRs Reviewed

- ADR-0001: immutable recognition и отдельные edits; user-visible history clauses заменены ADR-0004.
- ADR-0002: isolated worker, не затрагивается.
- ADR-0003: shared Application history, presentation в App; history selection clauses уточнены ADR-0004.
- ADR-0004: single current, session teardown и ввод; flat-source retry clause заменён ADR-0005.
- ADR-0005: standard ownership и flat read-only; refresh не пишет файлы.
- ADR-0006: независимые workspace/capsule и общий repository; отдельные Settings заменены ADR-0007.
- ADR-0007: Settings modal/input protection сохраняется.

## New Durable ADRs Created

Нет: новых существенных долгосрочных архитектурных решений нет, корневые ADR
не создавались и не изменялись. Согласование нового поведения отдельно от ADR review.
