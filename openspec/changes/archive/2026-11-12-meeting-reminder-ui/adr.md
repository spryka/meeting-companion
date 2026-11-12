# ADR review: meeting-reminder-ui

Проверен корневой набор ADR-0001–0007, новых номеров на baseline нет. Новых долгосрочных архитектурных решений нет; repository-level ADR не создаётся и принятые записи не переписываются.

Действующий контекст:
- ADR-0001/0002/0003: immutable recognition/separate edits, isolated worker и shared Application services; clauses user-visible history/selection ADR-0001/0003 заменены ADR-0004.
- ADR-0004: one current, identity/CAS и teardown; flat retry clause заменён ADR-0005.
- ADR-0005: dedicated recording folder, flat read-only; напоминание не меняет layout или файлы.
- ADR-0006: workspace и capsule независимы, общий lifecycle/admission; отдельный Settings window clause заменён ADR-0007.
- ADR-0007: Settings владеет modal input; reminder actions не обходят эту блокировку.

ADR review завершён: меняются reminder presentation и chooser, сохраняются существующий NSPanel и startMeeting/session services. Принятие дизайна не означает реализацию или native UAT.

Уточнение владельца: редкие ошибки заканчивают текущую попытку с понятной причиной. Новый ручной вход заново проходит актуальные guards; автоматические повторы, fallback-пути и восстановление workflow не вводятся. Session identity и сохранность данных обязательны; ошибка stop не разрешает start, чужую session останавливать нельзя. Это ограничение данного change, нового root ADR не требует.
