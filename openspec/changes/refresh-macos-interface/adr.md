# ADR Review Manifest

Review dates: 2026-11-04, 2026-11-05.

Прочитаны действующие корневые ADR0001–0007. Принятые records сохраняются
без переписывания. Подготовка документации и release metadata не меняет поведение,
формат данных или архитектуру и не требует нового ADR.

| ADR | Действующая граница |
|---|---|
| 0001 | Immutable recognition и отдельные edits, stable IDs, без переноса правок между результатами |
| 0002 | Отдельный Swift worker, MLX вне UI/capture, офлайн после явной подготовки |
| 0003 | Core/Application/Platform/Pipeline, общие session/queue/history; visibility не управляет lifecycle |
| 0004 | One current до schema validation, atomic directory commit, derived TXT, draft admission/CAS/teardown |
| 0005 | Canonical folder basename == stem; exact raw pair отдельно для retry; flat list + contained TXT read-only |
| 0006 | Обычный workspace NSWindow и независимая nonactivating capsule NSPanel на общих сервисах |
| 0007 | Одна Settings modal поверх текущего workspace/формы, отдельное владение input и monitoring |

ADR0004 supersedes только user-visible history/selection clauses ADR0001/0003;
ADR0005 — только flat-source retry clause ADR0004. ADR0006 дополняет presentation
ownership, не снимая draft admission. ADR0007 supersedes только clause ADR0006
об отдельном Settings window; остальные clauses сохраняются.

ADR0006 принят 2026-11-04. Статус ADR0007 относится к прямо выбранной
presentation policy, без приписывания отдельного подтверждения номера ADR.
Принятие архитектуры само по себе не подтверждает реализацию или UAT.

Display rename остаётся optional metadata прежнего repository, без path migration.
Reset admission/accepted handoffs остаются внутри существующих App/Application
boundaries, без нового service/lock framework. Header divider принадлежит тому же
публичному native actions accessory; narrow-detail background и independent panel
сохранены. Удаление недостижимых старых presentation routes не меняет live autostart.

Source review и геометрия не равны проверке painted layer. Первая попытка
продолжить divider в contentView не устранила видимый gap; после переноса в
accessory владелец принял beta23 для сообщённого использования. Это не полная
проверка input/drag/a11y/audio/Spaces и не основание архивировать change.
