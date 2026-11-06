# Proposal

## Why

После завершения native Swift/MLX delivery интерфейс всё ещё разделяет запуск, историю и редактор. Нужен согласованный workspace по HTML: список записей, один текущий транскрипт и плеер, независимая капсула и упорядоченные настройки.

## What Changes

- RESET-COMMIT1 доводит P05/P08: reset проверяет cancellation, текущую работу и foreign input после async confirmation непосредственно перед destructive commit. Все принятые App enqueue handoffs учитываются независимо от capsule presentation; отказ сохраняет readiness, текущую обработку/progress и feedback. Собственные reset flags не self-block, global quit/install/containment сохранены; service/queue architecture не меняется.
- SETTINGS-MENU1-CLOSURE1: довести четыре принятых остатка beta18 без нового UX: отделить admission собственных Settings reset/check от глобальной защиты quit/install; не возобновлять form monitoring при закрытии Settings; перепроверять сохранённые form callbacks в момент исполнения; сохранять введённое название при автоматической смене calendar context. Capture/status/capsule и accepted ADR0001–0007 не меняются; новая архитектура/права/audio scope не добавляются.
- SETTINGS-MENU1, прямой owner feedback 2026-11-05: одна Settings-модалка с backdrop поверх текущего workspace вместо отдельного settings window/светофора. Все входы, включая форму записи, используют одну presentation, блокируют фоновые library commands и сохраняют ввод, focus и monitoring ownership. Узкий [ADR0007](../../../../adr/0007-workspace-settings-modal.md) заменяет только separate-settings-window clause ADR0006; остальные guarantees сохранены.
- More сохраняет «…» и ровно четыре действия: «Повторить обработку», «Переименовать», «Копировать транскрипт», «Настройки». Удаляется только технический пункт меню, не context/files/logs/diagnostics или данные. Минимальный VF-025-01 fix требует явного outcome конкретной shared-load/Open попытки и late-modal recheck перед dismiss; cached current не доказывает принятый Open.
- Owner beta16 feedback: accepted Open of a completed result dismisses only its own terminal capsule; rejected/invalid Open retains feedback and concurrent capture/job is not hidden. The capsule uses one compact fixed width (approximately420pt, calibrated for mandatory overtime controls), ellipsis with full hover/accessibility text and native background/text dragging; no marquee, resize control or width preference.
- Current fixture C5 feedback reopens the light-on-light exterior halo in this same unfrozen pass. Remove unnecessary explicit surface shadow consistently without changing hosts/controls; final white/dark backdrop proof remains required for visual acceptance. Prior beta16 owner-observed closure remains historical.

- Нативный SwiftUI/AppKit workspace объединяет библиотеку и существующий review content. История версий и отдельное окно редактора в целевой GUI отсутствуют.
- Новая запись начинается из sheet; workspace скрывается только после успешного capture. Отдельная округлая капсула доступна одновременно с вновь открытым workspace.
- Переработка status menu обязательна: обычный и правый клик открывают одно меню из shared snapshots; state matrix, keyboard/programmatic admission и реальные update/quit guards закреплены в M01–M04.
- Пять разделов настроек: Основные, Запись, Транскрибация, Календарь, Диагностика. Прежние ключи, индивидуальные locks и видимый локальный model-check progress сохраняются.
- Text/name edits сохранены. Новая массовая область — тот же исходный source/voice от текущей реплики до конца, с preview и явным подтверждением замены прежних ручных назначений. Календарь даёт только сохранённые подсказки.
- Модальное редактирование блокирует уход/retry до Save/Cancel. Убирается уход из отдельного редакторского окна по команде другого окна; admission, закрытие старой session перед enqueue, CAS и stale-completion guards остаются.
- **BREAKING (GUI):** сохранённый undo, история отката и специальный Cmd-Z handler исключены по прямому решению пользователя. Cancel до save/confirm, стандартный native field undo и сохранность drafts при ошибке обязательны. Формат result/edits не меняется.
- Rename остаётся в scope: только отображаемое название через необязательное поле существующей metadata и Repository boundary, без перемещения файлов/смены identities.

HTML — точная копия визуального референса, не WebView implementation. Устаревшие детали демо перечислены в [context.md](context.md); актуальные спецификации важнее демокода.

## Capabilities

### New Capabilities

- `desktop-workspace`: список/current text/player, поиск, modal editing, display-name rename, экспорт и доступность (W01–W08).
- `recording-overlay`: независимый host, capture/processing/reminders и lifecycle (R01–R08).
- `macos-status-menu`: одинаковый клик и команды из общих snapshots (M01–M04).
- `preferences-navigation`: пять разделов с текущими native параметрами (P01–P08).

### Modified Capabilities

Нормативный baseline `single-current-transcript` сохраняется: drafts разрешаются до enqueue, старую session закрывают, editable reopen блокируется до terminal teardown. Модальность меняет доступ к действиям, не гарантию. `model-check-progress` и `python-free-development` сохраняются.

Активные `transcript-editor`/`swift-mlx-pipeline` не являются основными specs. Три назначенных spec-файла точечно согласованы с W01/W04 и ADR0004/0005; перечень amendments приведён в design.md. Historical acceptance и main specs сохранены; устаревшие UI-сценарии не становятся обязательной второй реализацией.

## Impact

Baseline HEAD/master: `1e479aa8ed69f82222c82119ff106b1c3aa28002`, 2026-11-04. ADR0001–0005 и финальное native closure перечитаны; прежнее ожидание Python/native не переносится.

App: composition root, window hosts, workspace, review UI/model, status menu/settings. Application: прежние recording/processing/history services, rename через сериализованную границу history. Core: необязательная display metadata и source/voice scoped assignment поверх прежних result/edits/CAS. Platform/Pipeline/worker алгоритмы прежние. Карта callers/кандидаты назначения — context.md.

Нет новых зависимостей, result/edits schema, миграции, path rename, удаления или Python. Сохраняются macOS 15+/Apple Silicon, bundle/storage/signing identity, offline и исходное аудио. [ADR0006](../../../../adr/0006-independent-workspace-and-recording-overlay.md) принят владельцем 2026-11-04: «да со всеми согласен», на конкретный вопрос — «принимаю». Это архитектурное согласование; документы не являются реализацией, build/test/UAT, установкой, выпуском или архивированием. До code assignment требуется focused independent review итоговой редакции документов.

SETTINGS-MENU1 продолжается поверх доставленной beta17/build53: только назначенные App presentation/callers, существующие tests и narrow contract delta. Сейчас подготовлен contract checkpoint; behavior/tests/metadata/package/native ещё не разрешены этим checkpoint. Прежние frozen evidence и лимиты не меняются; после coordinator continuation — тот же проход и один independent review. Внешний вид/focus остаются UNVERIFIED, если действующие native STOP-границы не дают наблюдения.

LEAN-SEAM-CLEANUP1: продукт разрешил узкую чистку поверх beta20/build56 после read-only audit032. Удаляются недостижимый technical sheet и его private presentation helpers, неподключённый toggleLogin и прежний main-window morph вместе с obsolete harness/README command/legacy restore assertions. Реальная independent NSPanel, shared geometry/position compatibility, activation/header/min-size, live More/export/rename/retry/copy, context/diagnostics и данные сохраняются. Seam исправляется только после доказанной причины по actual public after-layout common-space/backing bounds; иначе OPEN без pixel-патча. Один pass/review, без изменения прежних budgets/frozen evidence.

SEAM-CLOSURE1 repair1 активирован по full-window owner PNG и painted pixel evidence: существующий body divider серый, тот же reserved slot в header белый. Actual native034 roots/widths уже aligned0pt/0px и не сдвигаются. Исправляется только непрерывность gray vertical separator через существующий shared header paint owner, без изменения sidebar/action widths, native controls, цветов областей или narrow topology. Это ранее unused условный source repair1/1, не новый раунд. AFTER bounds и painted/render acceptance разделены; при недоступных final images preview раскрывает UNVERIFIED, не подменяет их owner BEFORE.

SEAM-RENDER-CLOSURE1 — отдельно учтённый closure1/1 после нового owner-observed beta22 painted failure («Да, это новый снимок beta22»). Прежний contentView paint не сделал divider видимым; точный runtime occluding layer неизвестен. Existing actions accessory теперь должен владеть и existing1pt slot: leading decorative divider внутри того же host, inner toolbar сохраняет прежнюю width/позицию/guards. Ineffective wide content paint удаляется, narrow detail full-row base/list topology остаются. Source/geometry evidence035 историческое, не raster PASS и не новая geometry; native allowance0, последний шаг — owner visualcheck после reviewed signed preview.
