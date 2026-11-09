# ADR Review Manifest

- Status: completed
- Review date: 2026-11-09

## Review Summary

ADR review completed: все корневые ADR0001–0007 прочитаны; наибольший номер0007. Исправление остаётся в существующих Platform/Pipeline boundaries и immutable publication/retry policy.

## In-Force ADRs Reviewed

- ADR0001 и0003 кроме user-visible history/selection clauses, заменённых0004.
- ADR0002: isolated worker и offline local model processing.
- ADR0004 кроме flat-retry clause, заменённого0005: one current, immutable versions/edits, draft/admission.
- ADR0005: standard folder ownership и exact source pair.
- ADR0006 кроме Settings presentation, заменённого0007.
- ADR0007: settings/modal admission.

## New Durable ADRs Created

None — новых долгосрочных архитектурных решений нет. Порядок drain/pad и однофреймовый хвост — ограниченное исправление существующего алгоритма, не новый storage/repair contract. Принятые ADR не менялись.
