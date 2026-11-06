## MODIFIED Requirements

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
