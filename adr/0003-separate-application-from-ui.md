# ADR-0003: Сценарии приложения независимо от UI

Status: accepted
Accepted: 2026-11-02
Date: 2026-11-02
Supersedes: none

## Context

Запуск обработки, очередь и обновление истории находятся в RecorderViewModel.
Core объединяет контракты, хранение, macOS capture/process и состояние окон.
Переделка UI должна сохранять сценарии записи, обработки и редактирования.
Изоляция моделей процессом закреплена ADR-0002, неизменяемость результатов и
отдельные правки — ADR-0001.

## Decision

Закрепить зависимости отдельными SwiftPM targets:
Core для контрактов и хранения, Application для сценариев и состояния,
Platform для macOS adapters, Pipeline для обработки и MLX. App и CLI собирают
Application с Platform; worker собирает Pipeline. Application зависит от Core,
Platform реализует определённые Application interfaces. Pipeline зависит от
Core и model libraries, App/CLI не линкуют его.

Очередь, recording session и история принадлежат application services, UI
передаёт команды и наблюдает snapshots. Закрытие окна не отменяет обработку.
Проверенные editor repositories/session/playback transport переиспользуются;
существующее файловое хранение не требует отдельной универсальной абстракции.

Карта компонентов и порядок выделения:
[design.md](../openspec/changes/swift-mlx-pipeline/design.md#границы-модулей-приложения).
JSON v1, edits, selected version и оба вида audio preview сохраняются.

## Alternatives

- Каталоги внутри нынешних targets: меньше перемещений, но зависимости UI и
  обработки не проверяются компилятором.
- Полная переработка domain/storage и protocol для каждого типа: больше
  изменений без необходимости для отделения UI.

## Consequences

UI можно менять поверх application API; App и CLI используют общие сценарии.
Нужны перенос типов/API/tests и проверка dependency graph; перенос выполняется
небольшими срезами с сохранением поведения. Это дополняет ADR-0001/0002.
Согласовано сопровождающим 2026-11-02 командой о принятии спецификации
и запуске реализации через sdd-orchestrate. Принятие решения не означает
завершённую реализацию или проверку сценариев.
