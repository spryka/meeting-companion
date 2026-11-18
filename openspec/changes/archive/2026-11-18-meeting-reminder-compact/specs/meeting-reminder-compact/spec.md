## ADDED Requirements

### Requirement: C01 Точная компактная поверхность
Система SHALL воспроизводить размеры reference/geometry.md: outer width 360 pt при доступном месте, border 1 pt внутри frame, padding 16 pt, corner radius 16 pt. Title SHALL иметь 21 pt и сохранённый leading, controls — явные размеры без добавленных стандартным style отступов. Height SHALL зависеть от содержимого, не от прежней fixed большой панели.

#### Scenario: Два обычных состояния
- **GIVEN** короткое название «Агент B2C», время «Сегодня, 12:30–13:00» и при recording строка «Сейчас: Планирование · 42:18»
- **WHEN** reminder показан в desktop layout при 2×
- **THEN** frame, padding, границы, шрифты, primary и secondary controls соответствуют geometry.md и фактическим PNG с этими данными
- **AND** 360 logical pt занимают 720 физических px; тень не включается в ширину frame

### Requirement: C02 Два действия и честное состояние
Idle SHALL показывать «Начать запись»; recording SHALL показывать «Завершить и начать новую», строку текущей записи с настоящим elapsed и compact divider 1 pt. Footer SHALL содержать «Другая встреча» и «Пропустить». Обычный поясняющий абзац большого варианта SHALL отсутствовать.

#### Scenario: Обычная текущая запись
- **WHEN** reminder показан поверх продолжающейся записи
- **THEN** её название/elapsed взяты из текущего state, новая выбранная встреча показана отдельно, primary не обрезана, capture продолжается до явного действия

#### Scenario: Короткая текущая запись
- **GIVEN** действующая policy отменяет записи короче 10 секунд
- **WHEN** показан recording reminder для такой записи
- **THEN** короткое условное предупреждение сообщает об отмене, высота растёт по содержимому; rule и stop/start путь не изменяются

### Requirement: C03 Раздельный список без поиска
Chooser SHALL быть отдельным от reminder layout, width до 336 pt, radius 12 pt, border/footer divider 1 pt; rows SHALL иметь min height 52 pt и содержимое по geometry.md. Кандидаты SHALL сохранять действующие правила, поиск SHALL отсутствовать.

#### Scenario: Двенадцать встреч
- **GIVEN** доступны 12 кандидатов
- **WHEN** открыт «Другая встреча»
- **THEN** reminder frame не меняется, список ограничен visibleFrame и прокручивается, «Без встречи» доступно в footer, выбор помечен галочкой

#### Scenario: Выбор или отмена
- **WHEN** строка выбрана pointer/Enter/Space либо chooser закрыт Escape/кликом снаружи
- **THEN** только явный выбор меняет reminderMeeting без старта capture; после закрытия focus возвращается trigger
- **AND** Up/Down перемещают focus, текущая строка видима

### Requirement: C04 Длинные названия и узкая ширина
Система SHALL сохранять title 21 pt и перенос полного названия, без fixed-height clipping, font shrinking или скрытого текста. Width SHALL уменьшаться только при нехватке visibleFrame. Touch target variant SHALL отдельно соблюдать 44 logical units на narrow/mobile preview, без подмены desktop размеров.

#### Scenario: Длинная встреча
- **WHEN** выбрано длинное название из reference
- **THEN** высота увеличивается на фактические дополнительные строки, padding и ширина не увеличиваются, primary и нижние действия доступны

#### Scenario: Узкий экран
- **GIVEN** ширина viewport 360 logical px в narrow/mobile preview эталона
- **WHEN** reminder показан
- **THEN** карточка занимает доступную ширину за вычетом 16 с каждого края, controls не обрезаны и имеют targets не менее 44, список остаётся в экране
- **AND** native macOS desktop сохраняет desktop controls независимо от ширины reminder; при нехватке visibleFrame ширина карточки уменьшается с полями 16 pt, содержимое переносится и controls остаются доступны

### Requirement: C05 Сохранение recording contracts
Primary SHALL использовать прежний startMeeting с expectedSessionID reminder. Busy/modal/diagnostic/session guards, stop-before-start, short cancellation, calendar eligibility/acknowledgement/timeout SHALL сохраняться. Новая session/store/queue/fallback SHALL не создаваться.

#### Scenario: Замена записи
- **WHEN** пользователь подтверждает переход при всё ещё актуальной session
- **THEN** stop текущей завершён прежде start новой; repeated accept не запускает параллельный переход

#### Scenario: Ошибка или stale callback
- **WHEN** session изменилась либо stop/start завершились ошибкой
- **THEN** чужая session не останавливается, ложный успех не показан, ошибка отображена существующим способом без обходного workflow

#### Scenario: Пропуск и timeout
- **WHEN** reminder пропущен, истёк прежний timeout либо он заменён
- **THEN** закрыты только его reminder/chooser, capture/processing продолжаются; автоматический показ не перехватывает focus и не скрывает capsule
