# macos-status-menu Specification

## Purpose

Команды status menu на фактическом состоянии capture, обработки и модального ввода.

Базовая приёмка beta.30; снятые проверки и исследовательский scope зафиксированы в [итоговой приёмке](../../../docs/beta30-acceptance.md).

## Requirements

### Requirement: M01 Consistent status item click

Система SHALL открывать одинаковое меню по обычному и правому клику на иконку микрофона. Библиотека SHALL открываться явной командой.

#### Scenario: M01.1 Left and right click

- **GIVEN** приложение запущено
- **WHEN** пользователь нажимает status item обычным или правым кликом
- **THEN** открывается одинаковое меню, библиотека не открывается вместо него

### Requirement: M02 State derived commands

Система SHALL строить команды из фактического состояния capture и очереди. Idle содержит новую запись и библиотеку. Recording содержит длительность, stop/cancel, mute, показать капсулу и библиотеку. Processing содержит этап и библиотеку. Несовместимые действия SHALL быть недоступны с понятной причиной; eligibility SHALL повторно проверяться при dispatch по shared Application snapshots и modal boundary W04. Disabled menu item SHALL не заменять command guard.

#### Scenario: M02.1 Concurrent processing

- **GIVEN** идёт capture и обработка прежней записи
- **WHEN** открывается меню
- **THEN** команды записи имеют приоритет, обработка остаётся доступна в библиотеке, UI не показывает idle

#### Scenario: M02.2 Unavailable commands

- **GIVEN** идёт сохранение или несовместимая подготовка
- **WHEN** пользователь открывает меню
- **THEN** команды не запускают вторую несовместимую операцию, причина недоступности понятна

#### Scenario: M02.3 Required state matrix

- **GIVEN** меню получает authoritative capture/processing/preparation snapshots, включая initial attachment и admitting
- **WHEN** формируются пункты и их доступность
- **THEN** применяется следующая матрица; библиотека всегда означает явное открытие workspace, settings/update/quit подчиняются M04

| Фактическое состояние | Основные пункты и eligibility |
|---|---|
| Idle, snapshots присоединены, нет modal input/diagnostic conflict | Новая запись и библиотека доступны; stop/cancel/mute не показаны как активные команды |
| Recording | Длительность, явно обозначенная короткая отмена до 10 s либо обычный stop с 10 s по R05, mute только микрофона, показать капсулу и библиотека; второй start недоступен |
| Preparing/checking models | Реальный статус подготовки/проверки и библиотека; новая запись недоступна по текущему diagnostic guard, capture-команды без capture недоступны |
| Processing/queued без capture | Реальный этап/очередь и библиотека; новая запись допустима при свободном capture и отсутствии saving/preparation/modal conflict; нет второго job для той же записи |
| Saving/stopping capture | Статус сохранения и библиотека; повторные start/stop/cancel/mute этой завершающейся session недоступны до подтверждённого завершения |
| Admitting | Показано ожидание допуска, не idle; duplicate retry/job той же записи недоступен; новый capture допустим только при свободной session и разрешённом modal input |
| Initial attachment не завершён | Не показывается ложный idle; start/update/quit защищены до authoritative snapshots |

- **AND** при recording + processing/queued/admitting другой записи capture-команды имеют приоритет, прежний job виден через библиотеку и не отменяется; saving/admission другого job не подменяют identity текущего capture
- **AND** preparation и новый capture не запускаются поверх несовместимых guards; матрица не вводит processing-cancel, retry, version selector или отдельный history/editor пункт меню

#### Scenario: M02.4 Stale menu and programmatic admission

- **GIVEN** меню открыто в idle, но до dispatch начались capture, saving, preparation/admission либо modal input
- **WHEN** та же команда приходит через menu selector, существующий shortcut или прямой программный callback
- **THEN** actual command boundary повторно проверяет состояние и identity; несовместимый вызов отклонён с понятной причиной без второго capture/job, потери draft или обхода terminal teardown
- **AND** modal input разрешается по W04 Save/Cancel/confirm, без separate-window prompt; поздний callback старой session не меняет новую

### Requirement: M03 Status icon and shared state

Иконка SHALL различать idle, recording и processing, сохраняя узнаваемый микрофон в кружке. Меню, капсула и библиотека SHALL использовать одну фактическую модель. Mute SHALL не выглядеть как остановка системного звука.

#### Scenario: M03.1 Mute and return

- **GIVEN** идёт запись
- **WHEN** пользователь выключает и включает микрофон
- **THEN** состояние и команды согласованы с капсулой, статус capture не исчезает

#### Scenario: M03.2 Show existing capsule

- **GIVEN** capture продолжается, капсула скрыта, workspace может быть открыт
- **WHEN** пользователь выбирает «Показать капсулу»
- **THEN** показана независимая panel той же session по R02/R07 без второго capture/worker; workspace не превращается в капсулу, mute и длительность совпадают с меню

### Requirement: M04 Stable utility commands

После основных команд система SHALL показывать разделитель, Настройки с Cmd+comma, проверку обновлений через Sparkle независимо от способа установки публичной сборки и Выйти с Cmd+Q. Автозапуск SHALL находиться в Основных, диагностика в настройках. Защита выхода SHALL сохраняться.

#### Scenario: M04.1 Open settings and update

- **GIVEN** приложение запущено
- **WHEN** пользователь вызывает настройки или проверку обновлений
- **THEN** показывается единственный workspace с той же Settings-модалкой по P01/ADR0007 либо используется существующий Sparkle flow с прежними ограничениями; отдельное settings window не создаётся

#### Scenario: M04.2 Utility shortcuts and workspace route

- **GIVEN** меню открывается любым кликом либо команда вызвана с клавиатуры
- **WHEN** выбрана библиотека, Настройки с Cmd+, или Выйти с Cmd+Q
- **THEN** библиотека явно показывает единственный workspace/current review без отдельного history/editor/version пути; Settings использует тот же modal command route, что Cmd+, sidebar/More/форма записи, включая hidden/minimized workspace и повторный вход без reset
- **AND** открытые Settings блокируют фоновые library/navigation/new/retry команды и stale dispatch, а конфликтующий draft/rename/details не теряется; повторное show library лишь показывает существующий host с модалкой
- **AND** quit идёт через общий termination guard, включая программный NSApp.terminate; сами shortcuts не обходят eligibility
- **AND** автозапуск остаётся в Основных, диагностика в настройках; старые пункты трея не сохраняются как второе меню

#### Scenario: M04.3 Busy update and quit

- **GIVEN** есть capture, starting/stopping/saving, admitting/queued/processing, preparation/check/diagnostic/reset либо ещё не присоединены authoritative snapshots
- **WHEN** пользователь вызывает проверку/установку обновления или quit через меню, Cmd+Q либо программно
- **THEN** прежняя Sparkle busy policy и termination guard предотвращают прерывание работы или установку поверх неё; причина понятна, jobs продолжаются
- **AND** оставшийся modal input дополнительно блокирует уход/перезапуск по W04/R08 до явного Save/Cancel; disabled UI не заменяет проверку при действии

#### Scenario: M04.4 Idle utility commands

- **GIVEN** snapshots присоединены, работы и modal input нет
- **WHEN** выбраны update или quit
- **THEN** update-enabled публичная .app использует Sparkle, disabled local build сообщает об отключённых обновлениях либо приложение завершается без лишнего busy prompt; Homebrew не выбирает другой updater

#### Scenario: M04.5 Installation source does not select updater
- **GIVEN** свободная публичная .app с MCEnableUpdates=true, включая установку с Homebrew receipt
- **WHEN** updater запускается и пользователь проверяет обновления
- **THEN** применяются те же Sparkle flow и beta opt-in, без поиска Caskroom, brew-команд или требования обновляться через терминал
- **AND** ни тип установки, ни наличие receipt не отменяют guards текущей работы и проверки подписи обновления
