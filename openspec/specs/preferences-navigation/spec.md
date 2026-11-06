# preferences-navigation Specification

## Purpose

Единые настройки с существующими guards, подготовкой моделей и безопасными действиями.

Принятый контракт beta.30; снятые проверки и исследовательский scope зафиксированы в [итоговой приёмке](../../../docs/beta30-acceptance.md).

## Requirements

### Requirement: P01 Five settings sections

Система SHALL показывать одну переиспользуемую Settings-модалку с backdrop поверх текущего workspace, без отдельного settings NSWindow/chrome/светофора, с разделами Основные, Запись, Транскрибация, Календарь и Диагностика. Главное окно SHALL сохранять настоящие системные controls. Значения и ключи хранения всех существующих настроек SHALL сохраняться. Это узкая supersession separate-settings-window presentation по ADR0007.

#### Scenario: P01.1 Navigate and reopen

- **GIVEN** настройки уже заданы
- **WHEN** пользователь переключает разделы и повторно вызывает Settings через Cmd+, status menu, sidebar, More либо существующий вход из формы записи
- **THEN** все параметры доступны с прежними значениями, показана та же модалка без duplicate/reset выбранного раздела; скрытый/minimized workspace явно возвращается вместе с ней без фоновой навигации

#### Scenario: P01.2 Full tile and running version

- **GIVEN** открыты настройки в широком либо узком окне
- **WHEN** пользователь нажимает пустой отступ нарисованной плитки раздела или поля выбора
- **THEN** срабатывает тот же переход/выбор, что при нажатии текста, с сохранением disabled и operation guards
- **AND** общий footer показывает версию и build из CFBundleShortVersionString/CFBundleVersion текущего app Bundle рядом с autosave note; при узком окне текст переносится, версии в исходниках не дублируются

#### Scenario: P01.3 Block background commands

- **GIVEN** Settings открыты поверх библиотеки или формы записи
- **WHEN** pointer/keyboard/native-toolbar/программный caller пытается менять selection/search/navigation, открыть запись, начать новую, retry, rename, copy/export, редактировать или управлять плеером под модалкой
- **THEN** фоновое действие не выполняется; backdrop и focus удерживают ввод в Settings, а shared command admission защищает callbacks; dimming или disabled UI сами по себе не считаются защитой
- **AND** независимые capture/processing и их допустимые stop/mute/Hide команды продолжают работать по прежним policies; progress не активирует окно

#### Scenario: P01.4 Existing input and owned dismissal

- **GIVEN** уже открыт draft/rename/details либо Settings владеет модальностью
- **WHEN** запрошены Settings поверх неразрешённого ввода либо приходит поздний dismiss другого modal
- **THEN** существующий ввод не теряется, конфликтующий вход отклоняется с причиной и существующий host показывается; чужой dismiss не снимает Settings-owned блокировку
- **AND** повторный вход в уже открытые Settings лишь возвращает им focus, не начинает новую load/navigation попытку

#### Scenario: P01.5 Close and focus return

- **GIVEN** Settings открыты из доступного элемента workspace или формы
- **WHEN** пользователь нажимает X, Готово либо Escape без активного дочернего picker/confirmation
- **THEN** закрывается только Settings; focus возвращается доступному исходному control того же host или безопасной области текущей страницы, не запускает фоновое действие и не закрывает workspace
- **AND** Tab/Shift-Tab и VoiceOver работают с модалкой, а фон не остаётся keyboard/accessibility target; backdrop не пропускает click и не отменяет modal input

#### Scenario: P01.6 Recording form continuity

- **GIVEN** открыта форма новой записи с введённым названием и выбранной встречей/микрофоном
- **WHEN** из неё открываются и закрываются Settings
- **THEN** Settings видны поверх текущей формы, форма остаётся mounted с прежним вводом; её start/default/cancel и поля не действуют под модалкой, закрытие Settings возвращает в эту форму без capture/start/reset

#### Scenario: P01.7 Hide minimize and background work

- **GIVEN** Settings открыты во время допустимой фоновой работы
- **WHEN** workspace скрыт/minimized либо приложение скрыто, а затем явно показано
- **THEN** capture/jobs продолжаются без cancel/retry, состояние Settings и раздел сохраняются, focus возвращается модалке; невидимые Settings не сохраняют ownership активного level monitoring или calendar-settings visibility
- **AND** повторный показ сам не запускает audio check или model preparation; обычная защита close/quit при modal input и работе сохраняется

### Requirement: P02 General settings continuity

Основные SHALL содержать тему, существующий SMAppService автозапуска, Sparkle-проверку и receiveBetaUpdates. Follow SHALL использовать существующее состояние редактора. Ошибки системных операций SHALL отображаться.

#### Scenario: P02.1 Theme login and beta

- **GIVEN** сохранены пользовательские настройки
- **WHEN** пользователь меняет тему, автозапуск и канал обновлений
- **THEN** тема применяется, автозапуск отражает реальный результат SMAppService, beta-off не обещает downgrade, ошибка не маскируется успехом

#### Scenario: P02.2 Owned update check versus install

- **GIVEN** открыты только Settings, authoritative services присоединены и нет иной работы или foreign draft/rename/details
- **WHEN** запрошена проверка обновлений из Settings
- **THEN** собственная модалка не блокирует допустимый check; actual Sparkle admission использует эту политику, в том числе для updates-enabled build
- **AND** install/restart/quit сохраняют глобальную modal/work защиту; capture, jobs, preparation, diagnostics, audio check, reset и foreign input не считаются idle; disabled-preview message не является доказательством updates-enabled политики

### Requirement: P03 Recording settings continuity

Запись SHALL сохранять микрофон, refresh, проверку уровней, AEC и папку. Backend SHALL оставаться в Дополнительно с прежними значениями. Выбор микрофона перед записью и в настройках SHALL согласовываться.

#### Scenario: P03.1 Unavailable selected device

- **GIVEN** сохранённый микрофон отключён
- **WHEN** открываются настройки
- **THEN** показано недоступное устройство, выбор не заменяется молча

#### Scenario: P03.2 Cancelled folder picker

- **GIVEN** меняется папка будущих записей
- **WHEN** picker отменён или доступ отклонён
- **THEN** прежний путь сохранён, ошибка показана при необходимости, старые файлы не перемещаются и не удаляются

### Requirement: P04 Transcription settings continuity

Транскрибация SHALL сохранять improveTerms, описание Parakeet около 740 МБ и риска замен, baseline GigaAM и native ready/checking/preparing/failed. Проверка готовности и скачивание моделей в настройках SHALL находиться только здесь. Дискретный прогресс, подробности, file/count и success/failure summary SHALL сохраняться при queue snapshots и быть видны вне Details по model-check-progress. Python/uv/старое Python-окружение SHALL отсутствовать.

#### Scenario: P04.1 Prepare and fail

- **GIVEN** модели не готовы
- **WHEN** пользователь запускает подготовку
- **THEN** показан фактический прогресс или ошибка, успех не определяется таймером, допустим повтор, offline-работа после подготовки сохраняется

#### Scenario: P04.2 Check progress survives snapshots

- **GIVEN** запущена локальная проверка готовых native моделей
- **WHEN** приходят file/count progress, затем terminal result и новый queue snapshot
- **THEN** latest progress и success/failure summary видны вне Details и не заменены generic starting; checksum validation остаётся локальной, подробный журнал доступен

### Requirement: P05 Safe owned cache reset

Сброс SHALL требовать явного подтверждения и соблюдать canResetCache. Удаляться SHALL только текущие app-owned подпапки native-models и runtime после проверки containment/symlink и пересечения с recordings. Python-окружение не создаётся и не требуется. Записи, транскрипты, правки и shared caches SHALL сохраняться.

#### Scenario: P05.1 Cancel reset

- **GIVEN** диалог сброса открыт
- **WHEN** пользователь отменяет
- **THEN** файлы и состояние не изменяются

#### Scenario: P05.2 Confirm reset

- **GIVEN** сброс разрешён
- **WHEN** пользователь подтверждает
- **THEN** сбрасывается только разрешённый app-owned cache, пользовательские данные и shared caches сохранены, ошибка показана

#### Scenario: P05.3 Own Settings operation admission

- **GIVEN** открыты только Settings и reset otherwise-safe
- **WHEN** проверяется eligibility и вызывается production reset с явным confirmation
- **THEN** Settings-owned input сам не блокирует свою операцию; foreign input/work/attachment, confirmation и containment/symlink/recordings guards сохранены; global quit/install по-прежнему заблокированы модалкой
- **AND** автоматическая регрессия использует injected reset operation и synthetic directories без удаления реальных cache или пользовательских данных

#### Scenario: P05.4 Revalidate destructive reset commit

- **GIVEN** reset прошёл initial admission и ожидает async size/confirmation со своими reset/local diagnostic flags
- **WHEN** появляется уже принятый pending enqueue, service admission/queued/running/preparation, capture/start/stop, foreign input либо reset task отменён
- **THEN** destructive operation не вызывается; отказ не сбрасывает readiness/transcriptionState/newprogress/feedback и не сообщает «Кэш сброшен»; cleanup освобождает только свою activity, не чужую работу
- **AND** непосредственно перед commit после всех await проверены current service/work, foreign input и cancellation; presentation-only marker не заменяет accepted-work ownership; между последней проверкой и destructive call нет async handoff

#### Scenario: P05.5 Idle owned reset commits once

- **GIVEN** confirmation явно положителен, собственные reset flags активны, иной работы/input нет и task не отменён
- **WHEN** выполняется окончательный commit admission
- **THEN** injected operation вызывается ровно один раз; default operation сохраняет containment/symlink/recordings checks, readiness и success summary меняются только для допущенной операции, own flags не self-block
- **AND** short held-confirmation regression использует реальный synthetic service/admission для pending/running work, foreign input, cancellation и idle; cache/audio/network/models не запускаются

### Requirement: P06 Calendar settings continuity

Календарь SHALL показывать реальные календари и сохранять IDs выбора и requireCallLink. Loading, empty и denied SHALL различаться. Инструкция SHALL не подменять отсутствие доступа отсутствием встреч.

#### Scenario: P06.1 Denied or no events

- **GIVEN** доступ запрещён либо событий нет
- **WHEN** пользователь открывает раздел
- **THEN** показаны разные причины, запись без встречи доступна, приглашения не используются для автоматического назначения имён

### Requirement: P07 Diagnostics settings continuity

Диагностика SHALL сохранять реальные разрешения, переход в macOS permissions, проверку звука и журнал. Проверка готовности моделей SHALL оставаться только в Транскрибации, без дублирующей команды в Диагностике. Проверка звука SHALL останавливаться через 30 секунд, при уходе из раздела, закрытии Settings или hide/minimize/невидимости workspace. Автоматический reset разрешений SHALL отсутствовать.

#### Scenario: P07.1 Leave audio check

- **GIVEN** активна проверка звука
- **WHEN** пользователь меняет раздел, закрывает Settings либо скрывает/minimize workspace
- **THEN** принадлежащий этому разделу мониторинг останавливается, после возврата устаревшие уровни не показываются; active capture/jobs и чужой monitoring не отменяются

#### Scenario: P07.2 Denied permission

- **GIVEN** разрешение отклонено
- **WHEN** запускается проверка
- **THEN** показана фактическая причина и переход в permissions, автоматического reset нет

### Requirement: P08 Operation specific locks

Настройки SHALL сохранять индивидуальные блокировки recording, busy, diagnosticRunning, transcriptionJobs и canResetCache. UI SHALL не разрешать опасные изменения и не блокировать тему и чтение данных общей демоблокировкой.

#### Scenario: P08.1 Busy settings

- **GIVEN** идёт capture или обработка
- **WHEN** открываются настройки
- **THEN** каждое действие доступно по существующей политике, backend и микрофон не меняются во время capture, ограничения объяснимы

#### Scenario: P08.2 Leave recording level check

- **GIVEN** проверка уровней начата из раздела Запись
- **WHEN** пользователь уходит из раздела/закрывает Settings/скрывает или minimize workspace либо проходит 30 секунд
- **THEN** тот же bounded monitoring останавливается, устаревшие уровни не показаны; остановка проверки не отменяет активный capture

#### Scenario: P08.3 Form monitoring after Settings

- **GIVEN** начальная форма по прежней policy запустила synthetic level monitoring
- **WHEN** Settings открываются поверх неё и затем закрываются
- **THEN** старый monitoring остановлен, закрытие Settings не начинает и не возобновляет новый; поздние levels прежнего owner игнорируются, допустимый явный check остаётся доступным
- **AND** первоначальное открытие новой формы и обычная прежняя visibility policy вне Settings не переписываются

#### Scenario: P08.4 Deferred form action ownership

- **GIVEN** сохранён callback формы start/active stop/short cancel либо другого deferred form action
- **WHEN** до исполнения открываются Settings
- **THEN** callback перепроверяет Settings ownership и не выполняет действие под модалкой; shared capsule/status stop/cancel/mute с правильной session identity остаются допустимыми, stale session по-прежнему отклоняется

#### Scenario: P08.5 User title and live calendar

- **GIVEN** пользователь изменил название в mounted форме и открыл Settings
- **WHEN** automatic boundary/refresh/expiry обновляет выбранную встречу или оставляет запись без встречи
- **THEN** user-owned название сохраняется; actual selected meeting/context и expiry не замораживаются, start проверяет актуальность встречи прежним способом
- **AND** до ручного ввода название может следовать текущей встрече; нет новых persistence keys/draft framework, source-only flags не доказывают mounted native input
