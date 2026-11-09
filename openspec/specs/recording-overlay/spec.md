# recording-overlay Specification

## Purpose

Независимая капсула записи и обработки на общих сервисах приложения.

Принятый контракт beta.30; снятые проверки и исследовательский scope зафиксированы в [итоговой приёмке](../../../docs/beta30-acceptance.md).

## Requirements

### Requirement: R01 Successful start before hiding workspace

Система SHALL разрешать выбор встречи или запись без встречи и выбор микрофона. Основное окно SHALL скрываться только после успешного начала capture, отдельная капсула SHALL оставаться доступной.

#### Scenario: R01.1 Successful start

- **GIVEN** источники доступны
- **WHEN** захват успешно начинается
- **THEN** основное окно скрыто, отдельная nonactivating NSPanel капсула показана на shared Application session, запись использует выбранные источники и контекст

#### Scenario: R01.2 Failed start

- **GIVEN** нет разрешения или устройство недоступно
- **WHEN** попытка старта завершается ошибкой
- **THEN** форма и конкретная ошибка остаются доступны, ложный таймер активной записи не показывается

#### Scenario: R01.3 Creation form without previous result dashboard

- **GIVEN** ранее уже записана встреча
- **WHEN** открывается «Новая запись»
- **THEN** форма содержит inputs и текущие start/stop/cancel/error состояния, без блока «Последняя запись» и его Open/Finder/reprocess действий; прежние результаты доступны в библиотеке, shared last-recording state не удаляется

### Requirement: R02 Independent workspace visibility

Система SHALL позволять открыть и закрыть библиотеку во время записи без остановки capture, второго старта и превращения основного окна в капсулу. Видимость окон SHALL не управлять записью данных.

#### Scenario: R02.1 Return during recording

- **GIVEN** идёт capture и показана капсула
- **WHEN** пользователь открывает библиотеку через меню и закрывает её
- **THEN** capture продолжается без разрыва и без нового writer/session, капсула остаётся отдельной одновременно с workspace, закрытие последнего обычного окна не завершает приложение

### Requirement: R03 Rounded capsule and long duration

Система SHALL сохранять округлую форму капсулы (горизонтальный pill) и композицию эталона Open Design (.capsule): индикатор записи → таймер → название/подстрока → кнопка микрофона → кнопка остановки. UI SHALL показывать MM:SS до часа и H:MM:SS начиная с часа. Капсула SHALL вмещать не менее 8:00:00 без обрезки и прыжков кнопок.

#### Scenario: R03.1 Hour and eight hour boundaries

- **GIVEN** таймер достигает часа или восьми часов
- **WHEN** обновляется длительность
- **THEN** после 59:59 показано 1:00:00, затем возможно 8:00:00, mute/stop остаются на месте

#### Scenario: R03.2 Compact fixed capsule

- **GIVEN** recording, processing, completed, error либо overtime и длинное название/сообщение
- **WHEN** капсула показана в своей компактной фиксированной ширине примерно420pt, уточнённой по обязательным controls
- **THEN** таймер8:00:00, overtime postpone, mute/stop и state actions доступны без clipping; строки используют ellipsis с полным hover/accessibility text, genuine progress сохранён; marquee/continuous processing animation, resize handle и настройки ширины отсутствуют

#### Scenario: R03.3 Rounded transparent exterior on light and dark backdrops

- **GIVEN** capture, processing, completed, error либо transition на белом или тёмном backdrop
- **WHEN** отображается общая поверхность капсулы
- **THEN** округлый exterior не создаёт прямоугольный светлый halo/край; Open/drag/buttons и компактная geometry сохранены; удаление source shadow без actual final-surface white/dark proof не считается visual PASS

### Requirement: R04 Explicit microphone mute
Система SHALL сохранять mute только микрофона и целостность раздельных потоков.

#### Scenario: R04.1 Mute microphone only
- **AND** Системный звук SHALL продолжать записываться. Mute SHALL не сохранять микрофон в WAV/CAF, включая задержанную доставку. В основном окне капсулы отсутствуют старые вертикальные шкалы громкости или искусственный popover: отображение проверки уровней звука сохраняется в форме новой записи и в настройках/диагностике. Состояние mute и предупреждения источника выражаются в предусмотренных слотах значка микрофона и подстроки.

- **GIVEN** поступают оба источника
- **WHEN** пользователь выключает микрофон
- **THEN** микрофон не сохраняется, системный звук продолжается, индикация не выдаёт mute за остановку записи

#### Scenario: R04.2 Microphone disappears

- **GIVEN** микрофон перестал отдавать данные
- **WHEN** обновляется UI
- **THEN** показано предупреждение об источнике, состояние системного звука не подменено общей ошибкой остановки

### Requirement: R05 Preserve short cancellation and overtime

Система SHALL сохранять текущую отмену записи короче 10 секунд с явным обозначением действия. Напоминание SHALL появляться после конца встречи либо часа без встречи и откладываться на 15 минут без остановки capture.

#### Scenario: R05.1 Short cancellation

- **GIVEN** прошло 9 секунд
- **WHEN** пользователь нажимает обозначенную отмену
- **THEN** применяется существующий cancelShortRecording, показано сообщение об отмене, ошибка отмены сохраняет исходники

#### Scenario: R05.2 Normal stop boundary

- **GIVEN** длительность достигла 10 секунд
- **WHEN** пользователь нажимает остановку
- **THEN** выполняется обычное сохранение без отмены как короткой записи

#### Scenario: R05.3 Postpone reminder

- **GIVEN** достигнут конец встречи или час без встречи
- **WHEN** пользователь продолжает ещё 15 минут
- **THEN** capture продолжается, напоминание отложено на 15 минут

### Requirement: R06 Processing and recovery lifecycle

Система SHALL различать saving, дискретный processing, completed, warning и failed по реальным событиям. Капсула SHALL не иметь пользовательских команд закрытия/Hide в saving, processing и terminal-состояниях. Закрытие workspace SHALL не отменять очередь и не скрывать капсулу. Ошибка capture/export SHALL не блокировать транскрибацию финализированных WAV и SHALL сохранять исходники и логи.

#### Scenario: R06.1 Dismiss processing

- **GIVEN** идёт распознавание
- **WHEN** пользователь закрывает основное окно
- **THEN** очередь продолжается, капсула остаётся видимой; «Подробнее» открывает тот же workspace на этой записи с актуальным snapshot без нового job

#### Scenario: R06.2 Failure or capture warning

- **GIVEN** обработка дала ошибку либо capture завершился с предупреждением и валидным WAV
- **WHEN** пользователь открывает запись
- **THEN** доступны причина, аудио/логи и допустимый retry, финализированные WAV можно обработать через общую очередь; manual retry доступен только standard entry с exact contained raw host/remote pair, flat остаётся list + saved TXT read-only; прошлые результаты сохранены

#### Scenario: R06.3 Retry terminal deadline isolation

- **GIVEN** completed/failed запись повторно поступает в общую очередь
- **WHEN** прежний terminal timeout доставлен во время admission, queued или running нового job
- **THEN** он не скрывает новую обработку; только актуальный terminal job может скрыться по собственному 60-секундному deadline; ручной Hide отсутствует, active job не скрывается по timeout

#### Scenario: R06.4 Native stage progress and reminders

- **GIVEN** native progress содержит completed/total без optional step/steps
- **WHEN** total известен либо приходит автоматическое calendar reminder
- **THEN** экран записи показывает долю текущего этапа, echo PCM frame counts представлены процентом, неизвестный total не создаёт долю; капсула показывает только общий маршрут и `Этап N из M` по processing-progress; reminder не скрывает активную обработку и само остаётся доступным

#### Scenario: R06.5 Owned completed Open

- **GIVEN** капсула принадлежит completed result
- **WHEN** Open принят и реальный target загружен в shared workspace
- **THEN** скрывается только эта terminal capsule; modal/invalid/unreadable target сохраняет feedback, concurrent capture/job или смена presentation generation не маскируются; deadline/session/current-result guards сохраняются; пользовательские Hide/close команды удалены
- **AND** dismiss требует успешного outcome именно этой shared-load/Open попытки и повторной проверки modal admission после await; cached current target и failure == nil не заменяют outcome

#### Scenario: R06.6 Cached current and late modal rejection

- **GIVEN** completed A действительно загружена в workspace, current A и failure == nil уже существуют, её terminal capsule видна
- **WHEN** новый Open A удержан в async admission, в это время появляется Settings или другой modal и manager.open отклоняет попытку, сохранив cached current A/failure nil
- **THEN** capsule остаётся видимой, rejected попытка не выдаётся за accepted; selection/session/job/deadline guards сохраняются; ручного Hide нет
- **AND** после закрытия modal последующий действительный accepted Open A скрывает только её terminal capsule при неизменных ownership guards, без запуска обработки

### Requirement: R07 Position focus and Spaces

Система SHALL сохранять перетаскивание и восстановление позиции капсулы в visibleFrame доступного монитора, доступность в Spaces/fullscreen и отсутствие перехвата фокуса при обновлениях.

#### Scenario: R07.1 Disconnect display

- **GIVEN** капсула на внешнем экране
- **WHEN** экран отключается
- **THEN** капсула видна на оставшемся экране и capture продолжается

#### Scenario: R07.2 Fullscreen meeting

- **GIVEN** созвон в fullscreen Space
- **WHEN** обновляется таймер
- **THEN** капсула доступна, приложение не переключает Space и фокус на каждый тик

#### Scenario: R07.3 Pointer background and text drag

- **GIVEN** обычная borderless capsule с native buttons
- **WHEN** пользователь перетаскивает фон либо текстовый слот настоящим pointer drag
- **THEN** actual panel frame меняется, позиция сохраняется и clamp/screens действуют; buttons независимо выполняют прежние guarded actions, flags/AXPress не являются drag proof

### Requirement: R08 Protected quit and install

Система SHALL сохранять preventsTermination и запрет установки поверх активной записи, подготовки, диагностики или транскрибации. Выход SHALL не обрывать незавершённую работу.

#### Scenario: R08.1 Busy quit

- **GIVEN** идёт операция, запрещающая выход
- **WHEN** пользователь выбирает выход
- **THEN** завершение отклонено с объяснением и операция продолжается

#### Scenario: R08.2 Idle quit

- **GIVEN** активных операций и несохранённого modal input нет
- **WHEN** пользователь выходит
- **THEN** приложение завершается без лишнего предупреждения

#### Scenario: R08.3 Quit with modal input

- **GIVEN** операций нет, но workspace modal содержит несохранённый ввод
- **WHEN** запрошен quit через menu или Cmd-Q
- **THEN** уход блокируется и modal/input остаются до явного Save/Cancel; не создаётся второй cross-window prompt и input не теряется молча
