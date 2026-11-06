# ADR Review Manifest

- Status: completed
- Review date: 2026-11-05

## Review Summary

ADR review completed for this change. Перед реализацией перечитаны ADR-0001…0007 и частичные Supersedes-связи. Highest sequence: 0007. Новых долгосрочных архитектурных решений нет; корневые ADR не создавались и не изменялись. Порог паузы, оформление и фокус чтения — детали поведения внутри существующих границ. Реализация согласована явным запросом владельца; физический UAT остаётся отдельным.

## In-Force ADRs Reviewed

- [ADR-0001](../../../../adr/0001-preserve-recognition-and-user-edits.md): неизменяемое распознавание, отдельные правки и стабильные ID внутри результата. Положения о пользовательской истории/выборе заменены ADR-0004.
- [ADR-0002](../../../../adr/0002-isolated-swift-transcription-worker.md): offline Swift worker; обработка и модели не переходят в UI.
- [ADR-0003](../../../../adr/0003-separate-application-from-ui.md): Core/Application/Platform/Pipeline/App boundaries; частичное замещение правил истории в ADR-0004. Общие правила представления размещаются в Core.
- [ADR-0004](../../../../adr/0004-single-current-transcript.md): один текущий результат, атомарная публикация, отсутствие переноса правок. Только automatic flat-source retry заменён ADR-0005.
- [ADR-0005](../../../../adr/0005-standard-recording-layout.md): границы поддерживаемых recording folders и read-only legacy.
- [ADR-0006](../../../../adr/0006-independent-workspace-and-recording-overlay.md): встроенный review в workspace; компоновка и lifecycle shared services сохраняются.
- [ADR-0007](../../../../adr/0007-workspace-settings-modal.md): настройки внутри workspace; это изменение их не затрагивает.

## New Durable ADRs Created

- None — no major durable architectural decisions were introduced; no new repository-level ADR files were created.

Accepted ADR не означают реализацию или согласование этого change. Предложение остаётся планом; проверка сценариев и UAT впереди.
