## ADR Review Completed

Проверка действующих ADR выполнена для speaker-review-ui по baseline, указанному в README. Это проверка проектных ограничений, не независимое code review реализации.

## In-force ADR Context

| ADR | Статус и применение |
| --- | --- |
| ADR-0001 | accepted; immutable recognition, отдельные правки и стабильные turn ID внутри result. History/selection clauses частично заменены ADR-0004 |
| ADR-0002 | accepted; isolated worker не участвует в назначении имён, модели не загружаются |
| ADR-0003 | accepted; App presentation использует существующие Core/session/storage, границы targets сохраняются |
| ADR-0004 | accepted; один current result, CAS/result identity, прежние данные сохраняются |
| ADR-0005 | accepted; standard folder ownership; legacy flat остаётся read-only |
| ADR-0006 | accepted; review встроен в workspace, без второго editor/session/store; capture независим от видимости UI |
| ADR-0007 | accepted в указанной самим ADR presentation policy; Settings ownership/admission не обходятся новым экраном |

В Supersedes: ADR-0004 заменяет только history/selection clauses ADR-0001/0003; ADR-0005 уточняет flat-source clause ADR-0004; ADR-0007 заменяет только отдельное Settings window из ADR-0006. Остальные положения сохраняются.

## Decision

Новых долгосрочных архитектурных решений не введено. Общий разбор — presentation существующих assignment/session/edits contracts; ограничение interval добавляется к текущему player. Новые repository-level ADR не созданы. Принятые ADR не изменялись.

## Follow-up

При реализации проверить, что общие native modal/admission guards распространяются на новый draft и переход из точечной правки. Статус документа не подтверждает build/test, независимое ревью или native UAT.
