## ADDED Requirements

### Requirement: M01 Compact reminder matches workspace

Система SHALL показывать отдельное компактное напоминание в стиле workspace по design.md/reference; название и время SHALL быть главными данными. Light/dark, перенос длинных названий, видимый focus и accessibility labels SHALL сохраняться. Автоматический показ SHALL не активировать приложение или скрывать активную капсулу.

#### Scenario: No active recording
- **GIVEN** запись не идёт и календарь предъявляет reminder
- **WHEN** reminder показан
- **THEN** видны «Встреча начинается», название, время, выбор другой встречи, вторичная «Пропустить» и синяя «Начать запись»; пустые поля не заменяют название

#### Scenario: Recording is already active
- **GIVEN** идёт запись другой встречи
- **WHEN** появляется reminder
- **THEN** показаны «Начинается следующая встреча», новая встреча, текущая запись с настоящим elapsed и «Завершить и начать новую»; пояснение различает обычную обработку и прежнюю отмену записи короче 10 секунд
- **AND** текущая капсула продолжает работать; текст и действия не обрезаны фиксированной высотой

#### Scenario: Reminder content exceeds a small screen
- **GIVEN** длинные названия и recording-блок вместе выше доступной области visibleFrame
- **WHEN** reminder показан на малом экране
- **THEN** его высота ограничена доступным экраном, текстовая область прокручивается, primary/secondary действия остаются видимыми и доступными; полный текст доступен прокруткой и VoiceOver
- **AND** controls видимой капсулы не перекрыты, открытие chooser не меняет frame reminder

### Requirement: M02 Separate scrollable meeting chooser without search

Выбор SHALL открываться отдельно от layout напоминания и SHALL не менять frame родительской панели. Кандидаты SHALL сохранять прежние calendar selection правила, исключать текущую recordingMeetingID и включать «Без встречи». Поиск SHALL отсутствовать.

#### Scenario: Twelve or more meetings
- **GIVEN** доступно 12 и более встреч
- **WHEN** пользователь нажимает «Другая встреча»
- **THEN** открыт ограниченный по высоте список с вертикальным scroll, названиями, временем и галочкой выбранной встречи; «Без встречи» доступно снизу, панель reminder не увеличивается, список помещается в visibleFrame

#### Scenario: Select or dismiss
- **GIVEN** список открыт и выбранная строка видима
- **WHEN** пользователь явно выбирает строку pointer либо Enter/Space
- **THEN** меняется только reminderMeeting, список закрывается и focus возвращается на кнопку выбора; capture не запускается
- **AND** Up/Down перемещают focus; Escape/клик снаружи закрывают без изменения выбора

### Requirement: M03 Reuse guarded recording transition

Primary SHALL вызывать прежний startMeeting с выбранным контекстом и expectedSessionID этого reminder; modal/busy/diagnostic/session guards, short cancellation и stop-before-start SHALL сохраняться. UI SHALL не создавать собственный writer/queue/session и не объявлять успех без outcome.

#### Scenario: Finish current and start next
- **GIVEN** reminder относится к всё ещё активной session и выбранная встреча актуальна
- **WHEN** нажата «Завершить и начать новую»
- **THEN** текущая запись завершается прежним путём, затем начинается новая; обычная предыдущая запись обрабатывается общей очередью, short cancellation следует прежнему правилу; повторный клик не создаёт второго перехода

#### Scenario: Rejected transition
- **GIVEN** session сменилась, выбранная встреча стала недействительной либо операция заблокирована modal/busy состоянием
- **WHEN** поступает accept или поздний callback
- **THEN** не останавливается другая session и не начинается новая запись через обход guards; применяются прежние rejection/error outcomes
- **AND** ошибка остановки не запускает новую запись; ошибка старта не показывает ложную active capsule

#### Scenario: Admission changes while stop is pending
- **GIVEN** допустимая попытка остановки текущей session ожидает завершения
- **WHEN** за это время появляется Settings/native modal, выбранная встреча удаляется/изменяется либо session становится занята другой записью
- **THEN** после ожидания проверки повторены перед новым capture и запуск отклонён с конкретной причиной; чужая session не остановлена, завершённая предыдущая запись не возобновлена, её данные и processing сохранены по прежнему lifecycle
- **AND** совпадающий id изменённой встречи не разрешает запуск устаревшего либо молча обновлённого контекста

#### Scenario: Error requires a fresh manual entry
- **GIVEN** проверка актуальности либо stop/start завершились отказом или ошибкой
- **WHEN** результат показан пользователю
- **THEN** показана понятная конкретная причина и попытка закончена; автоматических повторов, fallback-путей и восстановления workflow нет
- **AND** новая попытка доступна только через новый ручной вход в существующее действие записи с актуальными session/meeting/admission checks; завершённая предыдущая запись автоматически не возобновляется
- **AND** аудио и результаты сохраняются по прежним lifecycle guarantees; согласованная short cancellation сохраняется

#### Scenario: Failure with hidden workspace remains visible
- **GIVEN** workspace скрыт и пользователь подтвердил primary в актуальном reminder
- **WHEN** актуальная попытка отклонена проверкой либо stop/start завершается ошибкой
- **THEN** та же reminder panel показывает «Не удалось начать запись», конкретную причину и только «Закрыть», без chooser/primary/retry и автоматического открытия формы или активации приложения
- **AND** существующий modal/input сохраняется; «Закрыть» не меняет capture/processing; поздний outcome старой панели не заменяет новое напоминание или session

#### Scenario: Retained selection is not an admission fallback
- **GIVEN** выбранная встреча ещё отображается в chooser, но удалена или изменена в актуальном календаре
- **WHEN** пользователь подтверждает запись
- **THEN** запуск отклонён с понятной причиной без остановки текущей записи; отображаемый контекст не используется как обход проверки актуальности

### Requirement: M04 Reminder dismissal does not stop work

«Пропустить», существующий auto-dismiss и замена reminder SHALL закрывать только принадлежащие ему UI/chooser. Calendar acknowledgement и сроки показа SHALL оставаться прежними.

#### Scenario: Skip while recording
- **GIVEN** capture/processing продолжаются и reminder виден
- **WHEN** пользователь пропускает напоминание либо наступает прежний timeout
- **THEN** reminder и его chooser закрыты вместе, capture/processing/session продолжаются, новая запись не запущена; закрытие workspace не является остановкой работы
