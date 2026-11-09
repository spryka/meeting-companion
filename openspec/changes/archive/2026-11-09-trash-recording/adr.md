# ADR review

Основание: master `32de9bb`, 2026-11-09; ADR0001–0007 прочитаны ранее в этой сессии, ADR0005 повторно сверён из master. Частичные замены: ADR0004 заменяет user-visible history/selection clauses ADR0001/0003; ADR0005 — flat-retry clause ADR0004; ADR0007 — отдельное Settings window в ADR0006. Остальные части остаются в силе.

Сохранены immutable recognition/separate edits/current, standard folder ownership, shared Application services, worker isolation и modal admission. Явно запрошенный пользователем trash целой отдельной записи — исключение только для подтверждённой команды, не разрешение на cleanup, переписывание результатов или flat-folder deletion. AGENTS.md «Never remove user recordings» продолжает запрещать автоматическое/необратимое удаление и cleanup: узкая запрошенная функция допускает только подтверждённое пользователем перемещение в системную Корзину. Это исключение явно документируется при импорте, остальные invariants не ослабляются.

ADR review этого change завершён; после переноса на master `174beb1` корневые ADR не изменились. Нового долгосрочного архитектурного решения и root ADR нет; принятые ADR не редактируются. Реализация, локальная установка и приёмка владельцем завершены 2026-11-09; публичный выпуск не входит в закрытие.
