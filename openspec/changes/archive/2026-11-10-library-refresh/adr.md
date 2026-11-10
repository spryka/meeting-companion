# ADR review: library-refresh

Baseline: `19c84249e8141442601eab88b7846a0b9592f6f7`. Проверены все семь записей корневого `adr/`; старшие номера отсутствуют.

- ADR-0001: immutable recognition и separate edits остаются; user-visible history/selection clauses заменены ADR-0004.
- ADR-0002: isolated worker без изменений; refresh не запускает модели.
- ADR-0003: shared Application history/session/queue; history/selection clauses уточнены ADR-0004. Новый UI не получает свой store.
- ADR-0004: one current, CAS/identity/teardown сохраняются; flat-source retry clause заменён ADR-0005.
- ADR-0005: canonical dedicated folder; flat — list + свой saved TXT read-only. Refresh не мигрирует layout.
- ADR-0006: независимые workspace/panel, общий lifecycle и modal admission; только отдельное Settings window заменено ADR-0007.
- ADR-0007: Settings внутри workspace владеет input; refresh не обходит блокировку.

ADR review завершён. Новых значимых долгосрочных архитектурных решений нет; новых repository-level ADR не создано. Добавлены локальные UI-команда и её правила поверх действующих services. Принятие документов не означает implementation/UAT acceptance.
