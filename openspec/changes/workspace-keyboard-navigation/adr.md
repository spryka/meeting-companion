# ADR Review Manifest

- Status: completed
- Review date: 2026-11-06

## Review Summary

ADR review completed for this change. Прочитаны все семь root ADR; highest sequence — 0007. Дизайн сохраняет существующие границы. Keyboard focus и локальные команды — presentation-детали App, а не новая архитектура, storage contract или глобальный input service. Root ADR не изменялись; принятие старых решений не объявляется приёмкой этой функции.

## In-Force ADRs Reviewed

- [ADR0001](../../../adr/0001-preserve-recognition-and-user-edits.md): immutable recognition и отдельные edits. User-visible history/selection clauses заменены ADR0004; сохранение данных остаётся действующим.
- [ADR0002](../../../adr/0002-isolated-swift-transcription-worker.md): isolated worker; клавиши открытия/просмотра не запускают модели.
- [ADR0003](../../../adr/0003-separate-application-from-ui.md): App передаёт команды существующим services. User-visible history/selection clauses заменены ADR0004; границы модулей действуют.
- [ADR0004](../../../adr/0004-single-current-transcript.md): один current, admission, CAS/result identity и stale-completion protection. Flat-source retry clause заменён ADR0005.
- [ADR0005](../../../adr/0005-standard-recording-layout.md): standard ownership и legacy read-only; клавиатура не расширяет возможности неподдерживаемых entries.
- [ADR0006](../../../adr/0006-independent-workspace-and-recording-overlay.md): App владеет focus/visibility, shared session/queue не дублируются; прогресс не перехватывает focus. Только separate-Settings-window clause заменён ADR0007.
- [ADR0007](../../../adr/0007-workspace-settings-modal.md): Settings блокируют фоновые keyboard/menu commands и возвращают focus после закрытия. Статус ограничен явно принятой presentation policy, как записано в самом ADR.

Граф частичных supersession: `0004 → 0001/0003` (только history/selection), `0005 → 0004` (только flat retry), `0007 → 0006` (только Settings presentation). Ни один из этих ADR не исключается целиком вместе с остальными действующими clauses.

## New Durable ADRs Created

Дополнение Esc (K09), план утверждён владельцем 2026-11-06 ответом «да»: закрытие через существующие App cancel routes соответствует ADR0006/0007 и сохраняет admission/защиту edits ADR0004. Новых root ADR, modal manager, global monitors или изменений Core/transport для этого дополнения не требуется.

Уточнение 2026-11-06 после R2, явно согласованное владельцем: transient play intent и toggle переносятся из App в существующий Core playback controller, получающий typed transport events. Это исправляет ownership внутри уже существующего controller; focus/visibility остаются App, transport protocol и наблюдаемые states сохраняются. ADR0001–0007 не меняются, новое долговременное архитектурное решение не требуется.

None — no major durable architectural decisions were introduced; новых repository-level ADR нет. Перед задачами проверка архитектурных решений завершена. Продуктовый контракт ожидает согласования; реализация и UAT не выполнены.
