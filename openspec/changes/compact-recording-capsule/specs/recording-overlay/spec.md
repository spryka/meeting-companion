## MODIFIED Requirements

### Requirement: R03 Rounded capsule and long duration

Капсула SHALL иметь форму горизонтального pill, время полными минутами и фиксированные позиции управляющих кнопок. Обычная запись и обработка SHALL иметь видимую поверхность 340 × 60 pt; для особых состояний (например, overtime) разрешена дополнительная высота.

#### Scenario: R03.1 Hour and eight hour boundaries

- **WHEN** прошло 0–59 секунд, 60 секунд, 59:59, 1:00:00, 1:12:59 или 8:00:00
- **THEN** видны соответственно «< 1 мин», «1 мин», «59 мин», «1 ч», «1 ч 12 мин», «8 ч». Граница cancel/stop по-прежнему 10 секунд. Остальные окна и меню используют свой текущий формат.

#### Scenario: R03.2 Compact fixed capsule

- **WHEN** встреча имеет длинное название или показаны mute, overtime, сохранение, предупреждение или ошибка
- **THEN** таймер и первая строка названия выровнены по базовой линии; полный заголовок встречи и текст предупреждения об источнике доступны через help/VoiceOver, команды состояния остаются видимыми и доступны для самостоятельного нажатия. Ручное изменение ширины и постоянная анимация обработки отсутствуют.

#### Scenario: R03.3 Rounded transparent exterior on light and dark backdrops

- **GIVEN** capture, processing, completed, error либо transition на белом или тёмном backdrop
- **WHEN** отображается общая поверхность капсулы
- **THEN** округлый exterior не создаёт прямоугольный светлый halo/край; Open/drag/buttons и компактная geometry сохранены; удаление source shadow без actual final-surface white/dark proof не считается visual PASS

### Requirement: R06 Processing and recovery lifecycle

Система SHALL различать saving, дискретный processing, completed, warning и failed по реальным событиям. Капсула SHALL не иметь пользовательских команд закрытия/Hide во время сохранения, во время обработки и в terminal-состояниях обработки. При ошибке сохранения и после короткой отмены действие «Закрыть» сохраняется. Закрытие workspace SHALL не отменять очередь и не скрывать капсулу. Ошибка capture/export SHALL не блокировать транскрибацию финализированных WAV и SHALL сохранять исходники и логи.

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
- **THEN** экран записи показывает долю текущего этапа, echo PCM frame counts представлены процентом, неизвестный total не создаёт долю; капсула показывает номер, общее число и название текущего этапа по processing-progress; reminder не скрывает активную обработку и само остаётся доступным

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
