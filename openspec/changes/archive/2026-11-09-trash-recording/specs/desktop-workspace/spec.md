## MODIFIED Requirements

### Requirement: W01 Integrated recording workspace
Система SHALL показывать библиотеку, один current transcript и player в одном нативном окне, переиспользуя review session/repositories без второго писателя.

#### Scenario: W01.1 Open selected result
- **GIVEN** есть поддерживаемая запись
- **WHEN** запись выбрана или открыта из капсулы
- **THEN** workspace показывает current по прежней creation-date/name authority до schema validation, без второго окна или запуска моделей; повторная команда фокусирует тот же workspace/session
- **AND** selectedResultID не влияет на выбор, unsupported newest не вызывает fallback на старый result
- **AND** Компоновка, информационная архитектура и взаимодействие SHALL воспроизводить эталон Open Design ([reference/index.html](../../../2026-11-06-refresh-macos-interface/reference/index.html)) 1 в 1: библиотека слева (sidebar 304, адаптивно <=1023: 264), центрированный документ справа (max-width 840, padding 48; при <=1023: 32×24; при узком окне <=767 — единая область с кнопкой «Все записи»/back), плеер закреплён снизу документа и не уплывает при скролле. Единый toolbar содержит слева «Транскрипт»/back, справа icon export, переполнение «…» с пятью действиями по W01.2, разделитель и заметную синюю кнопку «Новая запись». Кнопка «+» в библиотеке и «Новая запись» в toolbar открывают одну и ту же форму. Реплика содержит кликабельный таймкод (seek), цветной маркер, само имя как кнопку назначения спикера и сдержанную кнопку «Редактировать». Действие капсулы SHALL открывать запись здесь. История/выбор версий SHALL отсутствовать; resultID остаётся внутренней идентичностью.

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
