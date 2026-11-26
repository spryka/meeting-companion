## MODIFIED Requirements

### Requirement: P02 Compact non-dismissible capsule

Капсула SHALL показывать название встречи, подпись «Этап N из M · Название» и «Подробнее». N, M и название SHALL соответствовать реальному маршруту job. До первого события при известном маршруте отображается очередное состояние «В очереди · M этапов». Графический маршрут, локальный процент и дорожки доступны на экране записи. Пользователь не может закрыть processing capsule, включая terminal.

#### Scenario: Inspect compact progress

- **WHEN** распознавание занимает четвёртое место в маршруте из шести этапов
- **THEN** видно «Этап 4 из 6 · Распознавание». Смена дорожки сохраняет номер. «Подробнее» открывает экран той же записи с полным маршрутом по P03/P04. Отсутствие локального total не создаёт процента, close/Hide/Escape/⌘W не скрывают капсулу.

### Requirement: P04 Details navigation and independent window

«Подробнее» SHALL открывать существующий workspace на записи job через текущий admission и скрывать капсулу именно этого задания по R06. Показ и закрытие workspace SHALL не создавать job или окно повторно, не сбрасывать snapshot и не отменять обработку.

#### Scenario: Reopen and guarded navigation
- **WHEN** пользователь открывает рабочее окно через «Подробнее»
- **THEN** job продолжается и показывает актуальный этап в одном workspace. При Settings или несохранённом вводе сохраняются введённые данные, отклонённый переход получает feedback и оставляет капсулу видимой

#### Scenario: Select a saved recording after reopening through Settings
- **GIVEN** workspace закрыт, затем показан через Settings, и Settings закрыты без несохранённого ввода
- **WHEN** пользователь выбирает прежнюю или другую запись мышью либо стрелками библиотеки
- **THEN** через общий navigation admission восстанавливается запрос загрузки и открывается существующий сохранённый текст. Новый job не запускается, narrow library navigation сохраняет текущую панель, файлы записи сохраняются

### Requirement: P05 Accessibility and terminal state

Оба UI SHALL сохранять темы, читабельность, keyboard/VoiceOver и фиксированную геометрию капсулы по R03 recording-overlay. Terminal lifecycle SHALL соответствовать изменённому R06, без пользовательского dismiss.

#### Scenario: Completion and other recording
- **WHEN** job завершён с замечанием, а пользователь читает другую запись
- **THEN** её selection не меняется автоматически; капсула сообщает готовность/замечание и «Открыть», не имеет крестика; принятие Open, timeout и stale-result guards соответствуют R06
