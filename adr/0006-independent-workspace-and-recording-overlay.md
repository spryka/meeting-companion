# ADR-0006: Независимые workspace и recording overlay

Status: accepted
Date: 2026-11-04
Accepted: 2026-11-04
Supersedes: none

## Context

Нынешний AppWindowState превращает один NSWindow в capsule, а review manager открывает отдельный editor window. Принятый пользователем визуальный UX требует workspace со списком/current text/player и независимой округлой capsule, доступной при открытой библиотеке во время capture.

Accepted ADR0003 уже закрепляет shared application services/session/queue/history. ADR0004 заменяет только user-visible history/selection clauses ADR0001/0003; ADR0005 ограничивает standard recording ownership и заменяет flat-source retry clause ADR0004. Эти гарантии нужны новому UI.

## Decision

Приняты обычный NSWindow workspace и отдельный nonactivating floating NSPanel recording/processing overlay. Settings window переиспользуется отдельно. Один composition root создаёт общие RecordingSessionService, ProcessingService и RecordingHistoryRepository; hosts наблюдают те же snapshots и передают команды. Отдельной capture/session/queue/store у panel нет; MLX остаётся в isolated worker.

Visibility и focus принадлежат App, lifecycle capture/processing — Application. Workspace скрывается только после подтверждённого start; явное открытие библиотеки не останавливает capture и не скрывает panel. Закрытие обычного окна не завершает приложение/работу, dismiss processing UI не cancel job. Явные open/edit действия могут активировать окно; timer/progress не перехватывает focus/Space. Panel сохраняет drag/position/visibleFrame clamp и доступность Spaces/fullscreen; keyboard controls остаются доступны явной фокусировкой.

Review content встраивается в workspace, без обязательного отдельного editor window или второго writers/session для той же записи. Модальный ввод блокирует конфликтующие navigation/retry/close до явного Save/Cancel/confirm, с сохранением input при error. Admission всё равно проверяет draft/identity, закрывает прежнюю session до retry и запрещает editable reopen до terminal teardown.

**Supersedes не требуется:** это дополнение presentation ownership ADR0003. Поведение ADR0004 draft admission не ослабляется: ввод разрешён до enqueue, старая session закрыта, reopening gated. Убирается лишь UX отдельного history-window запроса к editor-window prompt. Result/current/publication, CAS/lock/stale-completion, standard-layout и worker guards остаются. Если потребуется разрешить retry поверх неразрешённого modal, понадобится отдельное решение, а не трактовка этого ADR.

Product decisions scoped speaker edits/display rename/no saved undo подробно закреплены в change specs/design, не вводят новую durable result/edits architecture и не требуют отдельного ADR.

## Consequences

Можно одновременно показать workspace и capsule, не дублируя capture и processing. Нужны явные activation/Spaces/display rules, переиспользование review lifecycle и проверки command admission/stale completion. macOS 15/Apple Silicon, bundle/storage/signing identity, offline, original timeline/mute, capture warnings, immutable results/separate edits/current authority и canonical layout сохранены.

Альтернатива transforming NSWindow локально проще, но не выполняет независимый одновременный показ. XPC/new process/store не нужны.

## Maintainer acceptance

2026-11-04 владелец подтвердил «да со всеми согласен», затем на конкретный вопрос о принятии ADR0006 ответил «принимаю». Подтверждение передано product parent через coordinator и записано в maintainer-acceptance.md run evidence. Принято: workspace со встроенным review, независимая nonactivating panel на shared services/session/queue/history; закрытие UI не отменяет capture/processing. Supersedes: none. Это принятие архитектуры, не свидетельство реализации, поставки или UAT.
