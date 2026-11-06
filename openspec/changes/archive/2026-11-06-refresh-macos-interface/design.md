# Design

## Context

Текущая реализация использует Core/Application/Platform и изолированный Swift/MLX worker. [Caller map](context.md), [requirements matrix](requirements-matrix.md) и [HTML reference](reference/index.html) описывают границы. Реализация не меняется при release finalization.

Работа продолжается поверх Core/Application/Platform по ADR0003, isolated worker по ADR0002, immutable results/edits по оставшимся clauses ADR0001, current authority по ADR0004 и ownership по ADR0005. Workspace и отдельный panel заменили прежнее превращение одного окна в capsule. Встроенный review переиспользует прежние repository/session/playback, без нового recognizer/store.

## Goals / Non-Goals

Цель — согласованный нативный workspace с current text/player, независимая капсула, status menu и пять settings sections без утраты записи, правок, export и safety.

Не входят WebView implementation, новые ASR/models, runtime migration, новая result/edits schema, version chooser, saved undo/history, identity inference, path rename/move/delete, новые зависимости или публичная публикация. HTML остаётся неизменным provenance, включая устаревший demo text.

## Decisions

### Нативная композиция и визуальный язык

Owner clarification 2026-11-05 о настоящих системных controls сохраняется для обычного workspace NSWindow. Позднейшее прямое решение SETTINGS-MENU1 заменяет только отдельное settings window: Settings теперь modal без собственных traffic lights по ADR0007. Ручное перемещение/resize/tint/reparent кнопок не допускается; нативная titlebar имеет приоритет над HTML координатами. Окружающий content сохраняет Open Design; shared services/window lifecycle прежние. Владелец отдельно разрешил локальную signed preview beta и guarded install/relaunch при раскрытых остатках/full validation failures, без вывода о полном product PASS; последующая release finalization разрешена отдельно и не архивирует change.

SwiftUI split content существующего редактора в обычном NSWindow: library слева, current text справа, player снизу. Выделить review content из host, не копировать repositories/session/playback. Все пути открытия — list, capsule result, menu, reopen — ведут в workspace. У отдельного editor window не остаётся продуктового caller; не держать второй host «на всякий случай».

Системные шрифт/SF Symbols, нейтральные поверхности, синий accent, тонкие разделители, минимум карточек. HTML tokens: light surface #ffffff/sidebar #f2f4f7/ink #202630/accent #1762cf; dark #20242b/#191e25/#f0f2f6/#8ab9ff. Точные исходные метрики (reference/index.html): viewport 1440×1040, внешние margins 24 вне native окна, .app 1392×992, sidebar 304 (при <=1023: 264), toolbar 72, document 840 с padding 48 (при <=1023: 32×24; при <=767: одна область с back), title 32/40, transcript 16/28, turn 48+gap 16 с padding 16×12, player ~103 высотой в две строки. Нативные метрики и accessibility сохраняют эти точные пропорции и информационную архитектуру/parity действий без приблизительной интерпретации. Снимки для приёмки сравниваются строго по matching app-region размерам без добавления внешних canvas-полей внутрь нативного окна.

macOS 15 material обязателен; новые glass API только с availability guard, без обязательной новой технологии. Контраст >=4.5:1, keyboard/VoiceOver/reduced motion/transparency. Не переносить fake waveform из demo JS. Воспроизведение current mix требует обязательной настоящей waveform, рассчитываемой ограниченным потоком (bounded envelope) вне MainActor без полной загрузки длинного аудио в RAM, реального управления скоростью (1×, 1.25×, 1.5×, 2× через AVPlayer.rate), честного seek по клику и видимого переключателя follow. Обычный slider больше не считается эквивалентной заменой waveform. При недоступности звука показывается честное пояснение без подставного сигнала. Processing дискретный, без непрерывного decorative spinner.

### Одна application composition root и независимые hosts

RecorderAppDelegate продолжает создавать ровно по одному RecordingHistoryRepository, RecordingSessionService и ProcessingService и передавать их presentation. Capture/queue/preparation/history принадлежат Application. NSWindow workspace и отдельный nonactivating NSPanel capsule имеют один shared model/snapshots; Settings переиспользует одну modal presentation внутри текущего workspace по ADR0007.

Panel показывает capture после подтверждённого старта; workspace скрывается только после success. Общее открытие workspace не скрывает capsule и не перезапускает capture/worker. Open конкретного completed result скрывает только его terminal capsule после принятого navigation и успешной загрузки реального target; invalid/modal rejection и новый capture/job/presentation generation сохраняют feedback. После stop panel показывает saving/processing/terminal state, пока не скрыта пользователем. Dismiss presentation не cancel job. Одновременный capture и прежний processing различаются по identities, не одним busy boolean.

CAPSULE-FEEDBACK1 uses one compact fixed width, selected against 8:00:00 plus mandatory overtime/mute/stop controls. Text truncates with full hover/accessibility content. Native WindowDragGesture belongs to existing passive background/text views, not a control-covering overlay; real pointer/frame proof and independent button actions are required. Existing clamp/screens/position persistence and discrete progress remain. No marquee/resize setting, timer framework, header or audio change. Halo is owner-observed closed in beta16 usage; historical native gaps remain evidence, not rewritten acceptance.

Из common surfaces убрана лишняя explicit SwiftUI shadow с сохранением transparent nonopaque shadowless NSPanel, размеров, gestures и controls. Это не доказало конкретную причину прежнего края; владелец принял halo для сообщённого использования, полный white/dark/native matrix остаётся непроверенным.

Workspace получает key/focus только от явного open/new/edit действия. Timer/progress не вызывает activate/makeKeyAndOrderFront и не переключает Spaces. Panel floating, canJoinAllSpaces/fullScreenAuxiliary; drag/сохранённая позиция/visibleFrame clamping и display-disconnect восстановление переиспользуются. Для keyboard capsule controls — явный переход фокуса, без фокуса на каждом tick. Закрытие workspace не завершает capture/queue. Закрытие settings останавливает diagnostic monitoring через прежний visibility contract. Композиция нормальной капсулы строго соответствует эталону (.capsule): индикатор записи → таймер → название/подстрока → микрофон → остановка. В основном плавающем окне капсулы отсутствуют старые вертикальные шкалы громкости или искусственный popover/toolbar. Обязанность отображения проверки уровней звука сохраняется в форме новой записи и в настройках/диагностике. Состояния mute и предупреждений источника отображаются в штатных icon/subtitle слотах капсулы. Фактическая семантика capture, mute только микрофона и целостность дорожек остаются неизменными. preventsTermination и Sparkle busy policy остаются на authoritative snapshots, включая initial attachment.

Выбор NSPanel — минимальный AppKit host, без XPC/дополнительного процесса. Альтернатива одно transforming NSWindow не даёт одновременно workspace и capsule. Это долгосрочная граница в accepted [ADR0006](../../../../adr/0006-independent-workspace-and-recording-overlay.md), принятом владельцем 2026-11-04; это не implementation/UAT acceptance.

### Current, retry и модальное редактирование

Current resolve остаётся прежним: newest contained non-staging result directory по filesystem creation date, descending name tie-break, до JSON validation. Нельзя фильтровать supported results и выбирать более старый; selectedResultID/format markers не authority. Directory no-replace rename staged mandatory artifacts+text — commit; root TXT только derived cache. До commit failure сохраняет прежний current, после commit новый current остаётся с warning. Ни новой current pointer metadata, ни миграции.

Review session привязана к immutable resultID. Text/name editor — sheet/modal workspace с Save/Cancel/confirm и запретом interactive dismissal с вводом. Пока modal открыт, selection/new-recording/navigation/close и retry этой записи недоступны, включая shortcuts и программные callbacks. Stay = продолжить ввод; explicit Cancel = отказаться от ввода; Save закрывает modal только после durable success. Для group сначала preview и confirm; Cancel до confirm ничего не пишет. Save/CAS error оставляет input/modal и прежние данные, без auto-save или silent discard. Обычный field undo остаётся.

**ADR0004 draft admission не меняется.** До explicit retry draft должен быть разрешён, old session закрыта, reopen заблокирован до terminal teardown. Меняется UI-механизм: пользователь сначала Save/Cancel в modal, а не получает prompt в отдельном editor window из другого history window. Существующая retryAdmission граница остаётся как синхронизация: проверка modal/draft, identity и закрытие старой session до enqueue. Программная команда при input отклоняется с причиной, не создаёт deferred prompt и не теряет draft. После terminal — fresh current resolve. Если позднее потребуется разрешить уход поверх активного draft, это уже изменение контракта, не скрытый fallback.

Сохраняются admitting/queued/active exclusion, cancellation/worker teardown, resultID/draftID/confirmation payload identity, editing write lock, revision/byte CAS и generation checks loading/playback/search/export. Один экран не устраняет async races. Close protection переносится на workspace/modal: нельзя просто orderOut с несохранённым input. Отдельный cross-window requestWindowClose/continuation plumbing удаляется лишь после закрытия всех его продуктовых callers; нужные guards переиспользуются.

### Text/name scope, preview и undo

Уточнение владельца 2026-11-04: preview пересчитывается при открытии формы, вводе имени, выборе подсказки и области, без записи. В footer только «Отменить» и «Подтвердить замену»; пустое имя и zero changes запрещают commit. Internal preview identity/revision/CAS сохраняются; явный Confirm — единственная запись. Порядок: контекст → календарная подсказка → wrapping chips → имя/help → две области → preview → footer.

Одна реплика по умолчанию. Вторая область — текущий turn и последующие в стабильном document.turns порядке с теми же исходными sourceID/localID (voice), независимо от displayName/manual overrides. Не сравнивать имя и не расширять scope на другую source с тем же localID. Existing allVoiceGroup не удовлетворяет контракту: включает предыдущие turns и считает assignments без target name.

Минимально адаптировать TranscriptSpeakerAssignmentService preview/apply и session API для anchor turn + target name; тот же predicate в preview и commit. Preview связывает recording/result/revision/snapshot/anchor/source/voice/target name/target set. Из scope исключить turns с тем же effective name, чтобы no-op не создавал revision. В scope включить старые manual assignments, дать count реально меняемых и замен manual, до трёх примеров с временем/прежним именем/текстом. Никакого opt-in «не заменять manual» для этой области. При изменении draft или snapshot preview перестаёт действовать; atomic CAS mutation всего пакета, не per-turn saves. Turn text override сохраняется дословно. Earlier turns/другие источники/время/recognition неизменны.

Saved undo исключён из нового GUI по пользовательскому решению: не добавлять toolbar action, историю, special Cmd-Z и snapshot subsystem. Existing on-disk result/edits contracts не меняются. Удалять dead in-memory undo helpers только после проверки всех callers; это не основание менять durable format. Cancel до save/confirm и стандартный native text-field undo сохраняются.

Календарные suggestions берутся из уже сохранённого current document.context.attendees этой записи, как в нынешнем loadCalendarAttendees. Дополнить существующими manual names, без глобального адресного справочника. Отсутствие context/permission/network ничего не блокирует. Не делать EventKit запрос при открытии editor, не считать приглашение или host channel личностью. Saved names не обновляются вслед за календарём.

Search/export/copy используют current document + успешно saved edits; invalidate search после save/rename. Не сканировать аудио и не запускать модели. Поиск off MainActor, generation/cancellation с проверкой выбранной записи при завершении. Export allowlist/warning mapping/HH:MM:SS/destination protection неизменны, unsaved draft не объявляется saved.

### Rename: только display metadata

Изучены RecordingEntry.title/metadata/readArtifacts и RecordingHistoryRepository.updateThrowing/lockedPutThrowing. Просто изменить title нельзя: readArtifacts восстанавливает meeting.summary и затрёт rename. Изменить context.title нельзя: это saved calendar snapshot и immutable result export. Path rename нарушит ownership ADR0005.

Выбран минимальный совместимый вариант: optional String displayTitle в прежнем raw/<stem>.processing.json standard entry, без schema bump/store/migration. Прежний title/context/stem — fallback; effective title = displayTitle ?? прежнее отображение. Не путать с speaker displayName. Repository остаётся единственным writer: throw-on-failure transaction из latest entry под существующим lock, сохраняет unknown precise metadata и публикует snapshot только после atomic success. Rename не использует put/updateStatus с retain-unsaved как success. Сохранённое displayTitle должно переживать scan, lifecycle updates и retry, в том числе реконструирование entry; stale entry не стирает поле.

Ввод trim по краям, 1…120 grapheme clusters, без control characters/NUL/CR/LF. Unicode/кавычки/slash допустимы как display data; не превращать title в путь или markup. Неизменившееся effective title — no-op. Error оставляет прежние title/metadata, input и понятную ошибку, без partial save. Flat entry не пишет metadata даже если raw появился.

Rename исключён при ongoing capture/saving/admitting/queued/processing этой записи. UI и Application повторяют guard на save; serial admission должна исключить race между idle check и commit. Не расширять блокировку на чтение других записей. Имя меняет list/heading/title search, не порядок/date, stem/canonical URL/resultIDs/edits/audio/context. Тело export сохраняет immutable calendar context, имя output file остаётся безопасным существующим canonical hint. Это прямо display rename, не переименование календарного события.

Это небольшое добавление описательной metadata внутри существующего repository, предусмотренное настоящим SDD. Если безопасная сериализация с job admission потребует иной store, path migration или изменения producer contract — остановить этот slice и предложить узкое решение; не подменять rename удалением пункта.

### Settings и menu

#### RESET-COMMIT1: admission непосредственно перед удалением

Actual App callers: Settings reset → общий performCacheReset; App retry/завершённый capture → единственный private enqueue; preparation/check и start/stop выставляют собственную activity до первого await. CLI создаёт свой service, не является caller App composition. ProcessingService read-only APIs currentSnapshot (включая admitting) и currentPreparationState дают свежую service-boundary проверку после confirmation; сервис/queue/session API не меняются.

AppMain учитывает число принятых enqueue handoffs синхронно до создания Task независимо от URL/capture/capsule marker, освобождая ownership через defer после service enqueue. Это небольшой учёт существующего handoff, не новая очередь/lock. Work predicate использует этот ownership наряду с authoritative snapshots/attachment/capture/admission/preparation/audio activity. Собственный reset исключает только свои local diagnostic/reset flags в финальной проверке; foreign input и любая иная работа блокируют commit.

После подтверждения читаются свежие service state, затем на MainActor повторно проверяются текущие work/foreign/cancellation conditions. Default или injected synchronous reset вызывается сразу, без следующего Task.detached/await: иначе новая работа могла бы войти между guard и удалением. Явно запрошенный reset в otherwise-idle приложении может кратко блокировать UI на filesystem removal; асинхронная предварительная оценка сохраняется. Синхронный commit — узкая App-local граница вместо нового service/lock framework. Отказ/cancellation до commit не меняет readiness/terminal state/preparationProgress/feedback; own cleanup не очищает service progress/preparation. Default containment и confirmation не ослабляются.

Один небольшой parameterized production-path regression удерживает confirmation, использует настоящий synthetic ProcessingService/retry admission/runner для pending/running и проверяет injected counter0 при работе/foreign/cancellation, counter1 в idle при own flags. Отдельный параметр покрывает accepted App handoff ещё до service snapshot без присваивания test busy flags. Expected compiled RED до fix; source/raw сохраняются; safe previous guards и strict затем. Никакого реального cache/audio/network/EventKit/models/native; остатки native/full/UAT и previous failure evidence сохраняются.

#### SETTINGS-MENU1-CLOSURE1: четыре точные границы

Устранены scoped Settings operation/visibility/form callback контрпримеры. Manager различает собственные Settings и foreign input; модель переиспользует один work predicate, сохраняя global preventsTermination с любой модалкой. Reset и check могут исключить только Settings-owned input, не foreign drafts/work. Actual AppUpdater mayPerform-check использует отдельную check policy; installPreparedUpdate/postpone/restart остаются на глобальной isBusy. Production reset получает малый injected operation seam для теста без удаления cache; containment и confirmation остаются в исходном пути, default operation прежняя. Delegate настраивает обе update policies в общей composition, без запуска Sparkle в тесте.

Visibility формы не разрешает заново запускать монитор после Settings: локальный флаг текущей формы отмечает прерывание Settings, refresh visibility сохраняет остановку. Начальный auto-check policy новой формы и явный Settings check сохраняются; выход из формы освобождает этот локальный флаг. Никакого нового scheduler/таймера/preferences.

Существующие recordingAction closures и прочие deferred form callbacks проверяют Settings непосредственно при исполнении. Shared stop/cancel/mute не получают глобального Settings запрета: capsule/status используют прежнюю session boundary. Малое локальное значение title draft в RecorderView хранит текст и признак ручного изменения; actual TextField и calendar onChange используют это же правило. Пока пользователь не редактировал, название следует встрече; после ручного ввода automatic refresh/expiry меняет живой context, сохраняя текст. Сохраняется start-time meeting validation, не вводится calendar freeze или новое хранилище.

Целевые production-path regressions отделены от compiler/fixture/environment failures, которые не считаются RED. Реальный reset/network/EventKit/Sparkle и native input/focus этими проверками не доказаны; accepted ADR сохраняются.

Owner installed-beta11 correction 2026-11-05: форма создания больше не показывает dashboard последней записи; shared state и lifecycle прежние. Единственная settings-проверка моделей остаётся в Транскрибации, Диагностика сохраняет permissions/audio/log. Общий footer читает version/build текущего Bundle. Hit shape задаётся внутри расширенного/padded label либо общего button style, без overlay и обхода disabled. Cached canRetry выводит прежнюю команду на первый уровень More даже при saved legacyText/unsupported current; ADR0005 exact-layout/raw-pair и ADR0004 admission/storage остаются. Нового durable решения/ADR нет; accepted ADR не изменяется.

SETTINGS-MENU1 переиспользует содержимое SettingsShell/RecorderSettingsView, bindings/defaults и AppUpdater; отдельный SettingsTabViewController/NSHostingView как window host больше не нужен. Выбранный раздел и наличие Settings — одно volatile presentation state существующей App composition, без новых defaults. X/Готово закрывают presentation callback, не `view.window.performClose`.

#### Общая presentation и admission

Все текущие входы уже сходятся в `RecorderAppDelegate.showSettings()`: Cmd+, в AppMain, selector StatusMenu, sidebar/More в RecordingHistoryView и callback FullRecorderView. Delegate обращается к общей model-owned presentation boundary и показывает существующий workspace; не создаёт Settings NSWindow и не инициирует reload/selection при reveal. Повторный вход возвращает focus той же модалке с тем же разделом. Если есть draft/rename/details, вход отклоняется прежним admission, существующий modal показывается без потери ввода.

Минимальная граница — отдельный Settings-owned признак в существующем workspace admission, дополнительно к `externalModal` rename/details и current draft. Открытие Settings проверяет прежние owners до установки своего; закрытие освобождает только своего owner. Поздний чужой onDismiss не может обнулить его. Это не общий lock/scheduler/modal framework. Background state updates продолжаются; generation/session/CAS/teardown и operation-specific locks не меняются.

`RecorderWorkspaceView` рисует backdrop и SettingsShell поверх библиотеки. Если открыта существующая recording-form sheet, тот же presentation state рисуется поверх её content, а не позади sheet; одновременно Settings видна только в активной области. FullRecorderView остаётся mounted, локальный customTitle и выбранные поля не сбрасываются. Нового settings sheet/окна, переноса capture state или второго settings owner нет. Underlay не получает pointer/focus/accessibility input; native-toolbar accessory вне content overlay также disabled по той же границе. В модели/manager повторно проверяются selection/navigation/new/retry/Open; локальные search/back/export/copy/player/edit callbacks и default/cancel формы проверяют ту же границу, включая уже доставленные действия. Независимые stop/mute/Hide capture/processing сохраняют прежние policies.

При входе сохраняется доступный focus target существующего host; initial focus и Tab/Shift-Tab остаются внутри Settings, X/Готово/Escape без дочернего picker/confirmation закрывают только её. При выходе возвращается живой доступный target той же страницы либо безопасный focus fallback, без navigation/capture side effect. Existing AppWindowState hooks нужны только для modal input/focus, без header geometry/background/drag changes. Обычные controls главного окна остаются настоящими; window close/quit продолжают использовать modal/work guards, hide/minimize сохраняют presentation.

Visibility вычисляется по фактической видимости активного workspace/form host, наличию Settings и выбранному разделу, больше не по settingsWindow/controller index. Hide/minimize/occlusion/page switch/close освобождает только Settings-owned audio-check/calendar-settings visibility. Видимая подложка формы не считается активным form level-check owner, пока её закрывает Settings; после выхода возвращается прежняя form visibility без автоматического запуска проверки. Active capture/jobs не останавливаются. Все проверки этой логики используют injected defaults, empty calendar IDs, synthetic providers/monitor/transport до model construction; не запускают реальные проверки звука/моделей.

#### More и конкретный load outcome

Существующий SwiftUI Menu «…» остаётся локальным menu, без новой popover/menu architecture. Внутри четыре обычных Label/Button rows с icons и компактным штатным spacing без дополнительных separators/информационных строк: Повторить обработку → Переименовать → Копировать транскрипт → Настройки. Rename не исчезает для unsupported/flat, а disabled с прежней eligibility; retry/copy сохраняют actual dispatch guards. Убирается только entry «Контекст, файлы и проблемы», не underlying data/diagnostics и не новые compensating routes. Keyboard/focus/a11y стандартного menu сохраняются; соответствие reference и hit areas требует реального наблюдения.

VF-025-01: `loadWorkspace` возвращает простой явный outcome своей попытки (успех/отказ), полученный из actual awaited `workspace.open`, а не inferred из cached current/failure. До возврата успеха проверяются cancellation, request identity и актуальная modal admission; `openResults` после await повторяет late-modal и прежние request/url/job/session/deadline/Hide/terminal checks. Preloaded A с failure nil не превращает thrown/rejected новый Open A в успех. Адаптируются все callers: AppMain.openResults, RecordingHistoryView `.task` (discard outcome явно), delegate showWindow Task и existing composition tests. Manager не получает новых queue/timer слоёв; его current/failure/session semantics сохраняются.

Regression сначала действительно загружает synthetic saved A, затем удерживает новый Open A в существующем async gate, открывает modal и отпускает gate: manager reject оставляет current A/failure nil, capsule видимой. После dismiss следующий valid accepted Open скрывает только owned terminal capsule. Отдельно проверяются обычные accepted/rejected, generation/concurrent work/Hide guards. Compile/environment failure не RED; actual renderer/native focus не заменяются source assertions.

| Раздел | Сохраняемый contract |
|---|---|
| Основные | appearance, SMAppService реальный result/error, Sparkle check, receiveBetaUpdates без downgrade; follow — existing review state, без нового глобального preference |
| Запись | selectedMicrophoneID/unavailable device/refresh, bounded level check, echoCancellation, outputDirectory, captureBackend в Advanced |
| Транскрибация | improveTerms/Parakeet ~740 MB/risk, baseline GigaAM, native check/prepare/progress/details, explicit confirmed owned-cache reset |
| Календарь | EventKit calendar IDs, loading/empty/denied, requireCallLink, setup instructions |
| Диагностика | real permission statuses, system settings link, <=30s audio check и log; stop owned monitoring on section/modal/visible-host departure; model check только в Транскрибации |

Owned reset только native-models и runtime по текущему RecorderDiagnostics, без Python env, user recordings/edits/shared caches. Model check latest file/count и terminal summary видны вне Details по main model-check-progress. Не запускать подготовку при навигации settings; сохранять operation-specific guards. Level check в Recording разделе использует ту же bounded visibility политику: уход из раздела/modal/видимого host останавливает только owned monitoring.

Проверка admission/outcome отделена от runtime overlay/pointer/keyboard/focus. Source review и автоматические тесты не подтверждают эти визуальные границы.

Переработка status menu обязательна по прямому подтверждению владельца. Обычный/right click одинаковы. Recording commands приоритетны при concurrent queue; processing не исчезает из workspace. New/stop/cancel/mute/show capsule/show library/settings/update/quit используют прежние команды/policies. Нормативная матрица idle/recording/preparing/processing/saving/admitting/initial attach и разрешённой concurrency — M02.3; stale selector/shortcut/programmatic admission — M02.4. Подготовка, initial attach и saving не выданы за idle. M04.2–M04.4 связывают Cmd+,/Cmd+Q, Sparkle busy и actual termination/modal guards; disabled menu item не заменяет dispatch guard. Точная трасса нынешнего statusClicked/menu creation/selectors и границы tests/review/UAT — requirements-matrix.md; старое right-only меню/left-click showWindow не сохраняется вторым путём.

## Risks / Trade-offs

- Два hosts и focus/Spaces → shared services, bounded transition tests и отдельный hardware UAT.
- Один экран с async callbacks → identity/CAS/admission/teardown сохраняются; disabled button не замена guard.
- Rename/context collision → отдельный optional displayTitle и reload regression, immutable context не меняется.
- Full-group API отличается от remaining-scope → один общий predicate preview/apply, regression earlier/manual/source/voice/no-op/stale preview.
- Пересечения active specs → точечная назначенная интеграция ниже; implementation review должен проверить actual callers.
- Long physical UAT вне разрешения → synthetic long transcript/clock/transport, physical WAITING_UAT, без фальшивых PASS.

## Интеграция и проверка

Реализация workspace, independent hosts/menu и Settings проходит отдельное
source review; проверки и физическая приёмка имеют разные границы.
Документационная финализация сохраняет все production/test/CI bytes.
Не требуется миграция: optional displayTitle остаётся в прежней metadata,
старое приложение игнорирует неизвестное поле, пользовательские файлы не удаляются.

### Интеграция спецификаций

Main baseline существует: single-current-transcript, python-free-development, model-check-progress. Их guarantees не ослабляются, MODIFIED delta сейчас не нужен: modal разрешает draft до destructive action, close guard сохранён. Если implementation предложит поменять эти guarantees — сначала полный MODIFIED блок, новый owned/snapshotted path и review.

Согласованы три соседних active spec paths. Точечные amendments связывают [transcript-review](../2026-11-06-transcript-editor/specs/transcript-review/spec.md) History entry point, Turn text editing и Explicit speaker assignment с W01/W04: workspace, modal input, remaining source/voice и отсутствие saved undo. [transcript-document](../2026-11-06-transcript-editor/specs/transcript-document/spec.md) уточняет retry session admission/current-only и flat TXT cutoff. [native-transcription-runtime](../2026-11-06-swift-mlx-pipeline/specs/native-transcription-runtime/spec.md) снимает UI undo/separate-window prompt obligations в Enforced module dependencies, Reuse editor and recording boundaries, Compatible artifacts and immutable versions и Retry with an open editor; legacy reading явно ограничен ADR0005.

Это согласование UI contracts, не изменение исторической native acceptance. Immutable versions/edits schema, actual admission/session teardown/CAS/stale callbacks, canonical ownership и main guarantees сохранены. Historical verification/acceptance, ADR0001–0005 и main specs не изменены; старые research gates не становятся новыми условиями redesign. Полная новая UI семантика остаётся в W01/W04, а не копируется в каждый соседний документ.

## Open Questions

Открытых продуктовых или архитектурных вопросов нет. ADR0006/0007 действуют,
UI заморожен. Незакрытые runtime/accessibility/audio сценарии остаются UAT,
не требуют новой архитектуры и не превращаются в подтверждённые результаты.

## Validation boundaries

Для проверяемой логики использовались целевые behavioral RED→GREEN;
для чистого рисования и удаления dead presentation записаны justified exceptions,
без fake drawing tests. Автоматические результаты не заменяют native/UAT.
Release finalization запускает выбранные безопасные тесты, свежую production
сборку, Python-free/module-boundary/finder/strict и оригинальный App+worker package.
Новый audio/model/EventKit/native run не входит в эту проверку; полная suite
и многочасовое физическое воспроизведение остаются непроведёнными.

## Capsule/header presentation

Публичные titlebar accessories и full-size content используются общими delegate/attach callers. AppKit размещает системные controls; brand/actions остаются настоящими SwiftUI controls. Source/geometry не заменяют native pointer/drag/fullscreen/accessibility проверку.

Terminal dismissal belongs to the current processing job/presentation generation, not URL alone. Admission/working/capture invalidates prior deadlines, including callbacks already delivered to MainActor. Explicit Hide survives progress. The existing reminder caller preserves an active processing capsule. Native stageFraction supplies current-stage progress; echo producer counters are PCM frames, displayed as percentage in shared Core text. No queue, producer, protocol, pipeline or ADR change. ADR0002/0003/0006 retain isolated worker/shared lifecycle/independent panel. Drag/exterior correction requires one actual supported native cause observation; source flags or owner screenshot do not establish its cause.

## Удаление недостижимой presentation

Удалены недостижимый technical sheet, disconnected login selector, legacy main-window morph и obsolete self-check. RecordingCapsuleController остаётся единственным capsule host; live Settings autostart/callback/initial configuration, min-size/activation/header/key/clamp/data сохранены. Отдельные native assertions не запускались автоматически и не считаются visual/drag PASS. Для удаления применено justified no-fake-RED exception с callers/compile/safe regression проверкой.

## Header divider: неудавшаяся первая paint-попытка

Измеренные общие координаты body divider/right accessory совпадали;1pt slot
был реальным divider width. Первая paint-попытка продолжила его в contentView
background, но свежая owner-проверка beta22 показала прежний белый gap.
Причина compositor occlusion без runtime не доказана. Source/geometry review
той попытки не считается painted PASS; размеры и native roots не сдвигаются.

## SEAM-RENDER-CLOSURE1 — existing accessory owns separator

Owner подтвердил свежий beta22 screenshot с прежним белым gap. Первая paint-попытка жил в contentView child; actions accessory начинался после existing1pt slot. `.above` внутри contentView не доказывает visibility относительно titlebar, точный runtime compositor/clip остаётся UNKNOWN. Предшествующие source/geometry результаты сохраняют только свой scope.

Минимальный механизм: existing WorkspaceHeaderHostingView<AnyView>/update сохраняются. Nonnarrow root — HStack(spacing:0) с decorative ODColors.line Rectangle width1 и исходным actions, явно сохраняющим прежнюю actionWidth. Right accessory totalwidth = actionWidth+1; inner actions по source relationship остаётся S+1…W. Settings disabled/hit/a11y modifiers остаются на исходном child. Divider имеет allowsHitTestingfalse/accessibilityHiddentrue; native host mouseDownCanMoveWindow, controls/brand/body/paddings остаются прежними. Это semantic owner existing slot, не offset/overlay/private hierarchy. HistoryView/Delegate/InterfaceStyle edit не нужен.

У contentView background удалить columnDividerX и wide draw branch; создание только narrowdetail, hidden для wide/compact/narrowlist. Сохранить isOpaquefalse, narrow fulltoolbarfill/bottomline, public constraints, hitTestnil/appearance redraw. На каждом update root/frame задаются заново, accessories переиспользуются; nonnarrow↔narrow/list↔detail не должны оставлять старый divider/root. Новых controllers/framework/persistence/logic не вводится.

Pure drawing exception: без fake RED/math mirrors; existing safe checks и fresh compile отдельно. Новых native bounds/images/input/drag/a11y в этой ревизии нет. Владелец принял divider beta23 для сообщённого использования; это не полный parity/accessibility/audio UAT.
