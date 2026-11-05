# ADR-0007: Настройки поверх текущего workspace

Status: accepted (только явно выбранная владельцем presentation policy)
Date: 2026-11-05
Supersedes: ADR0006 — только clause «Settings window переиспользуется отдельно»

## Context

Владелец сообщил, что отдельное окно Settings со своим светофором расходится с prototype: «в дизайне меню это не отдельное окно, это модалка поверх текущего экрана», при которой нельзя действовать в библиотеке. Это прямое решение о представлении настроек; оно не меняет независимость workspace и recording capsule или shared Application services.

## Decision

Настройки представлены одной переиспользуемой модалкой с backdrop внутри текущего workspace, без отдельного Settings NSWindow и собственных системных close/minimize/zoom controls. Главное окно остаётся обычным NSWindow с настоящими системными controls. Cmd+, status menu, sidebar, More и существующий вход из формы записи используют одну presentation/admission boundary. Скрытый workspace показывается с той же модалкой; повторный вход не создаёт экземпляр и не сбрасывает состояние.

Settings владеет своей блокировкой фонового ввода, включая pointer, keyboard, native-toolbar и программные команды библиотеки. Закрытие другого modal не освобождает этот ownership. Уже открытые draft/rename/details не обходятся; X/Escape закрывает Settings с корректным возвратом фокуса, не закрывая workspace и не теряя ввод формы записи. Visibility принадлежит App; закрытие/скрытие настроек останавливает только принадлежащий им monitoring, не capture/processing.

Пять разделов, значения/ключи, operation-specific guards, diagnostics/update routes и version/build из Bundle сохраняются. Shared services/session/queue/history, isolated worker, current-result/draft/CAS/teardown и data ownership по ADR0001–0006 остаются в силе. Новые persistence keys, framework или session/store не нужны. Детали UI и проверки — в active change design/specs.

## Consequences

Отдельный settingsWindow заменяется одной presentation внутри существующей композиции. Недостаточно затемнить content: AppKit toolbar, focus и shared admission должны использовать ту же границу. Независимые capture/processing controls и фоновые события продолжают работать по прежним policies. Автоматические проверки admission/outcome не доказывают реальный render, pointer или focus.

## Основание статуса и граница приёмки

Статус фиксирует уже переданное прямое решение владельца о Settings modal; продуктовый координатор явно поручил оформить эту узкую supersession в SETTINGS-MENU1. Нового ответа «принимаю ADR0007» не было и не приписывается. ADR0006 не переписан, другие его clauses не отменены. Contract checkpoint ещё проходит coordinator review; реализация, независимое review, render/UAT и доставка этим record не подтверждаются.
