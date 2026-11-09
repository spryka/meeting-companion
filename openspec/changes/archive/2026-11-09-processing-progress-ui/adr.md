# ADR review

Проверка выполнена по master `32de9bb`, 2026-11-09. Прочитаны ADR0001–0007. В силе: ADR0001 кроме заменённых user-visible history clauses; ADR0002; ADR0003 кроме тех же clauses; ADR0004 кроме flat-retry clause; ADR0005; ADR0006 кроме отдельного Settings window; ADR0007. Частичные замены задают ADR0004, ADR0005 и ADR0007 соответственно.

Общие Application services, изолированный worker и независимые NSWindow/NSPanel переиспользуются. Новый durable architectural decision не вводится, root ADR не создаётся. Удаление пользовательского Hide — явно запрошенная UI-политика: дельта R06 в этом change, не переписывание accepted ADR. Atomic publication/current result/draft/modal guards сохранены.
