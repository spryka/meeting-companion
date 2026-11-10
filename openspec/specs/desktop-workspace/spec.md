# desktop-workspace Specification

## Purpose

Единая библиотека, текущая расшифровка и плеер с сохранением состояния и native input priority.

Принятый контракт beta.30; снятые проверки и исследовательский scope зафиксированы в [итоговой приёмке](../../../docs/beta30-acceptance.md).

## Requirements

### Requirement: W01 Integrated recording workspace
Система SHALL показывать библиотеку, один current transcript и player в одном нативном окне, переиспользуя review session/repositories без второго писателя.

#### Scenario: W01.1 Open selected result
- **GIVEN** есть поддерживаемая запись
- **WHEN** запись выбрана или открыта из капсулы
- **THEN** workspace показывает current по прежней creation-date/name authority до schema validation, без второго окна или запуска моделей; повторная команда фокусирует тот же workspace/session
- **AND** selectedResultID не влияет на выбор, unsupported newest не вызывает fallback на старый result
- **AND** Компоновка, информационная архитектура и взаимодействие SHALL воспроизводить эталон Open Design ([reference/index.html](../../changes/archive/2026-11-06-refresh-macos-interface/reference/index.html)) 1 в 1: библиотека слева (sidebar 304, адаптивно <=1023: 264), центрированный документ справа (max-width 840, padding 48; при <=1023: 32×24; при узком окне <=767 — единая область с кнопкой «Все записи»/back), плеер закреплён снизу документа и не уплывает при скролле. Единый toolbar содержит слева «Транскрипт»/back, справа icon export, переполнение «…» с пятью действиями по W01.2, разделитель и заметную синюю кнопку «Новая запись». Кнопка «+» в заголовке библиотеки SHALL быть заменена на «Обновить библиотеку» по L01–L03 capability library-refresh. В wide/compact (>767 pt) единственная видимая «Новая запись» находится в toolbar. В narrow list (<=767 pt), когда toolbar документа скрыт, отдельная «Новая запись» SHALL быть показана под заголовком списка перед поиском; в narrow detail она скрыта вместе со списком, а действие toolbar доступно. Все входы создания и ⌘N SHALL открывать одну прежнюю guarded форму без автоматического старта записи; floating action button отсутствует. Реплика содержит кликабельный таймкод (seek), цветной маркер, само имя как кнопку назначения спикера и сдержанную кнопку «Редактировать». Действие капсулы SHALL открывать запись здесь. История/выбор версий SHALL отсутствовать; resultID остаётся внутренней идентичностью.

#### Scenario: W01.2 Compact More actions

- **GIVEN** в workspace выбран entry и доступно переполнение «…»
- **WHEN** пользователь открывает More pointer/клавиатурой/VoiceOver
- **THEN** показаны пять компактных first-level action rows с icons в порядке: «Повторить обработку», «Переименовать», «Копировать транскрипт», «Настройки», затем после разделителя «В Корзину…»; без технического пункта «Контекст, файлы и проблемы», дополнительных информационных строк и вложенного retry
- **AND** «В Корзину…» относится к identity выбранной записи, использует общий guarded trash command и явное подтверждение; busy/unsupported/modal состояния отключают пункт с доступной причиной
- **AND** retry использует прежние eligibility/layout/raw-pair/working/modal guards; rename остаётся видимым и disabled для неподдерживаемого layout/working/modal; copy доступен только для сохранённого текста и не обходит modal; disabled состояния не удаляют обязательные строки
- **AND** сохранены context/files/logs/diagnostics/data и существующие иные routes; Settings ведёт в P01 modal, а каждый stale callback повторно проверяет admission перед действием

#### Scenario: W01.3 Retire unreachable presentation residue

- **GIVEN** workspace использует меню More и отдельную независимую capsule NSPanel
- **WHEN** удаляются недостижимый technical sheet, неподключённая старая login-команда и прежний main-window morph с obsolete self-check
- **THEN** live export/rename/retry/copy/Settings, обычный workspace header/min-size/activation, capsule sizes/position key/screen clamp и сохранённые пользовательские данные остаются прежними
- **AND** удаление старого sheet не удаляет context/problems/log readers; проверка старого превращения окна не является проверкой independent panel
- **AND** seam не исправляется произвольным offset: источник рассогласования подтверждается actual common-space/backing bounds либо остаётся OPEN/UNVERIFIED

#### Scenario: W01.4 Continuous header column divider paint

- **GIVEN** wide/compact workspace имеет sidebar и существующий отдельный vertical divider; inner actions начинается у правой границы divider
- **WHEN** header и content отрисованы в light/dark
- **THEN** тот же semantic gray vertical separator непрерывно продолжается через header, без белого непокрашенного reserved slot
- **AND** inner actions width/позиция, sidebar/body, public layout guide ownership, настоящие controls/drag/hit/a11y и intentional sidebar/detail/toolbar цвета остаются прежними; outer right accessory включает существующий separator slot как leading decorative child того же host, без наложения поверх другого неизвестного owner
- **AND** narrow list не получает column divider; narrow detail сохраняет существующую цельную toolbar base и bottom separator, без изменения collapse/back topology
- **AND** source relationships и actual AFTER bounds/raster имеют разный статус; без native allowance новые bounds/images/input/drag/a11y остаются UNVERIFIED, прошлые bounds другой ревизии не считаются новыми AFTER

#### Scenario: W01.5 Header divider ownership through width transitions

- **GIVEN** переиспользуются existing native brand/actions accessories и текущие Settings guards на actions child
- **WHEN** workspace проходит wide/compact/narrow list/detail и обратные переходы
- **THEN** nonnarrow accessory владеет ровно существующим1pt divider slot, inner actions сохраняет прежний right edge и padding; divider не принимает hit и скрыт от accessibility
- **AND** narrow не получает column divider: list сохраняет нулевую actions width и скрытый full-row background, detail — прежний toolbar fill/bottom line/public constraints; устаревший wide root/paint не сохраняется
- **AND** ineffective wide column paint в contentView не дублируется; owner beta22 painted failure остаётся historical failure, source-only correction не является visual acceptance

### Requirement: W02 Window width navigation
Система SHALL показывать список слева при достаточной ширине, позволять скрыть/вернуть его и явно вернуться к библиотеке в узком окне с сохранением состояния.

#### Scenario: W02.1 Resize and return
- **GIVEN** выбран transcript
- **WHEN** окно сужается и список возвращается
- **THEN** выбор, позиция, session и modal input сохраняются; контролы не обрезаны, поведение определяется шириной, не классом устройства
- **AND** пустые отступы нарисованной карточки записи и общих кнопок входят в pointer hit area; нажатие вызывает тот же существующий guarded command, disabled/modal guards не обходятся

### Requirement: W03 Local library search
Система SHALL искать локально по отображаемому названию и доступному сохранённому тексту с text/name edits, без моделей, сети, чтения аудио и блокирования MainActor. Устаревший запрос SHALL не заменять новый; ошибка чтения SHALL отличаться от отсутствия совпадений. Flat entry SHALL читать только собственный contained saved TXT.

#### Scenario: W03.1 Search and clear
- **GIVEN** текст, имя или название успешно сохранены
- **WHEN** пользователь ищет новую фразу/имя/название и очищает поиск
- **THEN** поиск отражает сохранённые правки, затем полный список, без потери current editor

#### Scenario: W03.2 Unreadable data
- **GIVEN** один текст не читается, запрос сменился до completion
- **WHEN** результаты поступают
- **THEN** видны доступные совпадения актуального запроса и причина частичного чтения; ошибка не выдана за пустую библиотеку, устаревший ответ игнорируется

### Requirement: W04 Preserve transcript review contract
Система SHALL сохранять text/name edits current result, immutable recognition, отдельный edits.json, CAS/lock/containment и identities. Modal editing SHALL блокировать navigation/retry/close до явного разрешения input; error сохраняет draft. Saved undo/history/special Cmd-Z SHALL отсутствовать; native field undo и Cancel до save/confirm сохраняются.

#### Scenario: W04.1 Unsaved text and save failure
- **GIVEN** modal содержит ввод
- **WHEN** запрошены navigation/retry/close либо Save завершается ошибкой
- **THEN** уход/enqueue заблокированы, ошибка видна, ввод и current остаются
- **AND** доступны повтор Save, явный Cancel ввода и продолжение редактирования; стандартный field undo работает до сохранения

#### Scenario: W04.2 Current replacement and legacy
- **GIVEN** существуют старые файлы и более новый current, в том числе unsupported
- **WHEN** запись открывается либо retry завершает teardown
- **THEN** current разрешается заново без выбора старой версии или переноса edits; unsupported показывает причину и доступный saved TXT read-only
- **AND** flat legacy — list + contained standalone saved TXT, без structured lookup/edit/rename/retry; standard supported result без originals сохраняет editing/playback

#### Scenario: W04.3 Group speaker assignment
- **GIVEN** одинаковые local labels и отображаемые имена есть в разных sources
- **WHEN** выбирается массовое назначение
- **THEN** preview ограничен исходным source/voice текущего turn, не совпадением имени; source/voice и реальный count видны до confirm

#### Scenario: W04.4 Edit one utterance text
- **GIVEN** supported current доступен и не обрабатывается
- **WHEN** выбраны «Редактировать», затем Save или Cancel
- **THEN** Save сохраняет текст дословно отдельной правкой и обновляет display/search/export; Cancel не пишет, recognition/ID/time прежние
- **AND** unchanged text — no-op без revision/file write; blank/whitespace-only текст отклонён без потери ввода

#### Scenario: W04.5 Assign one utterance
- **GIVEN** modal имени с default областью «Только эта реплика»
- **WHEN** имя введено/выбрано и подтверждено
- **THEN** изменено только имя этого turn current result; текст, время, соседние turns и source/voice ID прежние
- **AND** unchanged effective имя — no-op без фиктивной правки
- **AND** preview виден и пересчитывается при открытии, вводе, выборе подсказки и области без записи; footer содержит только «Отменить» и «Подтвердить замену», blank/zero changes запрещают commit; только явный Confirm сохраняет актуальный preview через прежние identity/CAS проверки

#### Scenario: W04.6 Assign same voice from current utterance to end
- **GIVEN** выбрана область «Реплики этого спикера отсюда до конца»
- **WHEN** пользователь явно подтверждает актуальный preview
- **THEN** меняются текущий и следующие turns того же исходного source/voice в порядке document.turns, включая предыдущие ручные назначения внутри области
- **AND** более ранние turns, другие sources/voices, текст и другие resultID не меняются
- **AND** до confirm видны target name, source/voice, count реально изменяемых turns, count замен manual assignments и до трёх примеров с временем/прежним именем/текстом; zero changes не пишет
- **AND** изменение name/scope/revision/result/draft требует нового preview; CAS/error не применяет частичный пакет, сохраняет ввод; Cancel до confirm не пишет

#### Scenario: W04.7 Calendar names are suggestions
- **GIVEN** current содержит saved meeting context именно этой записи
- **WHEN** открыт выбор имени
- **THEN** пригодные attendee names — явные подсказки рядом с manual names; ручной ввод всегда доступен
- **AND** приглашение не доказывает присутствие/личность, host не означает владельца Mac; календарь/приглашения не меняются

#### Scenario: W04.8 Missing calendar and custom name
- **GIVEN** календарь отключён, запрещён, не привязан либо имён нет
- **WHEN** открыт modal имени
- **THEN** отсутствие подсказок объяснено, manual input доступен без permission/network/EventKit refresh на editing path
- **AND** blank имя отклонено, имена/текст показаны как данные; Cancel не пишет, изменение календаря не переписывает сохранённые имена

#### Scenario: W04.9 Admission and late completion
- **GIVEN** modal открыт либо старый async callback ещё не завершён
- **WHEN** retry/navigation/close вызван через shortcut/programmatic route
- **THEN** admission SHALL повторно проверить отсутствие draft; при input команда отклонена с причиной без deferred cross-window prompt
- **AND** после явного Save/Cancel старая session закрывается до enqueue, editable reopen запрещён до terminal teardown; fresh open разрешает current заново
- **AND** late callback SHALL не открыть чужую запись, не восстановить старую session и не записать draft в другой resultID

#### Scenario: W04.10 Cancel and standard field undo
- **GIVEN** text/name input ещё не сохранён/подтверждён
- **WHEN** пользователь отменяет ввод либо применяет native field undo
- **THEN** Cancel SHALL ничего не писать; field undo сохраняется; GUI не предлагает undo сохранённых правок, историю отката или отдельный Cmd-Z handler
- **AND** попытка закрыть modal с input сохраняет его до явного Cancel/Save/confirm; прежние result/edits и recognition schema SHALL не мигрировать и не удаляться

### Requirement: W05 Current result playback and follow
Система SHALL воспроизводить только фактический mix current через прежний transport с честным управлением скоростью (1×, 1.25×, 1.5×, 2×), отображением обязательной настоящей waveform (вычисляемой ограниченным фоновым потоком без загрузки всего файла в память), круглой кнопкой play/pause, временем elapsed/total, сохраняя pause/seek, все активные overlaps и видимый переключатель follow.

#### Scenario: W05.1 Overlap and follow
- **GIVEN** turns пересекаются
- **WHEN** playback проходит overlap, затем пользователь прокручивает текст
- **THEN** все активные интервалы подсвечены, чтение не прерывается follow до явного возврата
- **AND** Scroll/edit SHALL приостанавливать follow до явного возврата. Audio unavailable SHALL не блокировать текст и показывать честное объяснение без фальшивой waveform.

#### Scenario: W05.2 Missing current mix
- **GIVEN** current mix отсутствует, повреждён или unavailable
- **WHEN** запись открывается
- **THEN** текст/правки доступны с причиной недоступности player; другой result mix, recording.m4a или одиночная дорожка не подставляются
- **AND** прежний Quick Look общей записи сохраняется как явно отдельное действие standard entry

### Requirement: W06 Export current saved result
Система SHALL переиспользовать safe export/copy current document + saved edits: context, statically mapped warnings, HH:MM:SS, имена/текст дословно, allowlist без service fields/сырых diagnostics. Original SHALL не перезаписываться, unsaved draft SHALL не экспортироваться как saved.

#### Scenario: W06.1 Export current edited result
- **GIVEN** current содержит saved text/name edits
- **WHEN** пользователь копирует/экспортирует
- **THEN** используется current и его edits, приглашённые помечены отдельно; selectedResultID/root TXT cache не подменяют structured current
- **AND** display rename не переписывает immutable календарный context в теле export

#### Scenario: W06.2 Export failure
- **GIVEN** назначение недоступно либо защищает исходный файл
- **WHEN** export не завершён
- **THEN** ошибка видна, старый файл/recognition/edits/audio прежние, успех не заявлен

### Requirement: W07 Honest record states and actions
Система SHALL различать реальные loading/empty/no matches/processing/ready/warning/failed. Context/problems/Finder/audio preview и допустимый retry SHALL сохраняться. Retry требует canonical layout и exact contained raw pair. Rename SHALL менять только displayTitle через existing history repository/metadata; identities/paths/context прежние, ongoing jobs и flat исключены.

#### Scenario: W07.1 Ready with warning
- **GIVEN** текст готов с source warning
- **WHEN** запись открывается
- **THEN** текст доступен, warning раскрывается отдельно; приглашённые не выданы за count говорящих

#### Scenario: W07.2 Retry failed processing
- **GIVEN** standard entry с exact raw originals, modal закрыт
- **WHEN** явно запрошен retry
- **THEN** единая очередь закрывает старую session до enqueue, сохраняет старые файлы/edits, блокирует editable reopen до teardown, затем разрешает current заново
- **AND** precommit failure сохраняет прежний current, postcommit failure сохраняет новый с warning, unsupported current не вызывает fallback

#### Scenario: W07.3 Persist display name
- **GIVEN** standard idle entry с calendar title и unknown precise metadata; без optional displayTitle действуют прежние title/context/stem
- **WHEN** новое название сохраняется и библиотека заново читается с диска
- **THEN** list/heading/title search показывают displayTitle; context/unknown metadata/identities/paths и recognition/audio hashes прежние
- **AND** refresh/lifecycle save/retry не теряют displayTitle; identical effective name — no-op; дата/сортировка/recording URL/stem/resultID/edits не меняются

#### Scenario: W07.4 Invalid or unsafe display name
- **GIVEN** rename modal открыт
- **WHEN** введены blank, более 120 grapheme clusters либо control characters, включая NUL/CR/LF
- **THEN** Save отклонён с причиной, input остаётся, metadata прежняя
- **AND** Unicode/кавычки/path-like символы допустимы только как текст, никогда как path/markup/command

#### Scenario: W07.5 Rename error or competing work
- **GIVEN** до Save entry стал capture/saving/admitting/queued/processing либо atomic metadata save недоступен
- **WHEN** выполняется Save
- **THEN** нет частичного durable изменения или оптимистичного успешного title; прежний title остаётся, modal/input/error доступны для Cancel/повтора
- **AND** lifecycle API с retain-unsaved-memory не выдаёт rename за успешное сохранение

#### Scenario: W07.6 Legacy rename is unavailable
- **GIVEN** canonical folder basename не равен recording stem
- **WHEN** entry отображается либо rename вызван программно
- **THEN** rename отклонён до side effects; entry остаётся list + свой contained saved TXT read-only, файлы прежние

#### Scenario: W07.7 Discoverable reprocessing of saved old text

- **GIVEN** standard dedicated-folder entry с distinct contained raw host/remote WAVs, в том числе с standalone saved TXT или unsupported current
- **WHEN** пользователь открывает обычное меню действий записи
- **THEN** «Повторить обработку» доступно на первом уровне меню через прежний retry/enqueue и cached capabilities, без технического диалога; age/producer/schema текста не являются disable condition
- **AND** busy/modal/ongoing-job admission сохраняется; успешная обработка публикует current прежним способом, исходные audio/results/edits не уничтожаются
- **AND** flat placement и отсутствие безопасной exact пары остаются недоступны с прежней причиной; нет автоматической миграции, подстановки mixed M4A или второго фиктивного источника

#### Scenario: W07.8 Warning belongs to the selected recording
- **GIVEN** запись A имеет предупреждение, а текущий результат B не содержит предупреждений
- **WHEN** пользователь переключается с A на B, затем возвращается к A
- **THEN** сообщение A не показывается как ошибка B; собственное предупреждение A остаётся доступным у A, результаты и правки не меняются

#### Scenario: W07.9 Late background feedback retains its owner
- **GIVEN** открыта B либо нет выбранной записи, а обработка A продолжается
- **WHEN** приходит terminal warning или ошибка сохранения, относящаяся к A
- **THEN** selection/current не меняются, сообщение не приписывается B; предупреждение и terminal feedback доступны в контексте A

#### Scenario: W07.10 Library-wide errors remain visible
- **GIVEN** ошибка относится к библиотеке в целом и не имеет recording owner
- **WHEN** выбранная запись меняется либо selection пуста
- **THEN** общая ошибка не скрывается как чужое предупреждение; её причина доступна, ошибки записи и библиотеки не смешиваются

### Requirement: W08 Native accessibility and offline review
Система SHALL следовать reference/index.html с поправками context.md, поддерживать macOS 15+, light/dark, keyboard/VoiceOver/reduced motion/transparency и text contrast >=4.5:1. Обычный offline review SHALL сохраняться без запуска моделей и предварительного декодирования всего аудио в RAM.

#### Scenario: W08.1 Appearance and keyboard
- **GIVEN** light либо dark тема
- **WHEN** пользователь проходит workspace/modal/settings клавиатурой/VoiceOver
- **THEN** фокус/названия команд видны, статус понятен без цвета, работает macOS 15 material; закрытие modal не уничтожает input без явного Cancel
- **AND** workspace использует стандартные AppKit close/minimize/zoom/full-screen controls с обычным поведением и видимостью в light/dark; Settings — modal по P01/ADR0007 без собственных traffic lights. Нативная titlebar имеет приоритет над координатами traffic lights в HTML, без ручного reparent/frame/tint системных кнопок

#### Scenario: W08.2 Offline review
- **WHEN** пользователь открывает, перематывает, редактирует и повторно открывает текущий результат без сети
- **THEN** модели не запускаются, transport использует доступный локальный микс и сохранённые правки остаются доступны

# Owner HEADER1 refinement

Workspace SHALL use one integrated header: genuine native close/minimize/zoom controls beside the reference brand (wide two lines, narrow list one line) and transcript actions on the same level. No separate repeated centered product caption or white title strip. The ordinary titled/closable/miniaturizable/resizable window SHALL retain standard accessibility, keyboard, fullscreen and dragging. Native titlebar/content layout SHALL reserve controls' actual area; header dragging SHALL not steal toolbar, search, tab or recording-card input. Settings presentation follows P01/ADR0007; this header refinement does not change it.
