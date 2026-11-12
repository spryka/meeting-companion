# processing-progress Specification

## Purpose
Общий маршрут обработки записи, компактная капсула и подробности текущего этапа в workspace с достоверным прогрессом и сохранением lifecycle/admission guards.

## Requirements

### Requirement: P01 Job route and honest progress

Система SHALL строить маршрут job: сборка аудио → необязательное эхоподавление → разделение голосов с отбором окон Nemotron → распознавание → необязательное уточнение терминов → сохранение, по зафиксированным опциям AEC/Parakeet. Отдельный этап поиска речи SHALL отсутствовать. Номер этапа SHALL быть 1-based. Состояния SHALL определяться реальными событиями, не таймером или изменением Settings.

#### Scenario: Optional stages and two sources
- **WHEN** AEC и Parakeet отключены
- **THEN** маршрут содержит 4 этапа; при обеих опциях 6; завершение микрофонной дорожки не завершает этап до системной; переключение дорожки не увеличивает N

#### Scenario: Unknown progress and skipped stage
- **WHEN** total неизвестен либо необязательный этап пропущен/завершился с предупреждением
- **THEN** процент не выдумывается; включённый этап сохраняется с причиной и отличим от успеха; старые события другого job не меняют текущий маршрут

### Requirement: P02 Compact non-dismissible capsule

Капсула SHALL иметь только название, счётчик `Этап N из M`, общий маршрут и «Подробнее», как в [design.md](../../changes/archive/2026-11-09-processing-progress-ui/design.md). Отдельные «далее K» и «последний» SHALL отсутствовать в подписи и её accessibility-тексте. До начала этапа SHALL отображаться `В очереди · M этапов`. Пользователь SHALL не иметь команды закрыть капсулу в active или terminal-состоянии. Проценты, дорожки и отдельный локальный бар SHALL отсутствовать.

#### Scenario: Inspect compact progress
- **WHEN** выполняется этап 4 из 6
- **THEN** видно `Этап 4 из 6`, три завершённые станции, текущая и две будущих; последний этап подписан `Этап 6 из 6`; progress текущей дорожки не меняет общий маршрут; close/Hide/Escape/⌘W не скрывают капсулу

### Requirement: P03 Detailed recording screen

Экран записи SHALL показывать полный маршрут, текущую модель/дорожку, один достоверный локальный прогресс и предупреждения по [design.md](../../changes/archive/2026-11-09-processing-progress-ui/design.md), используя тот же job snapshot, что капсула.

#### Scenario: Details and late completion
- **WHEN** идёт распознавание системного звука, затем сборка/публикация результата
- **THEN** видны модель, дорожка 2 из 2 и реальные окна/процент; «Сохранение» остаётся текущим до принятого успешного завершения; ошибка не выдаётся за готовый результат

#### Scenario: Nemotron gate model label
- **WHEN** Nemotron завершает источник и рассчитана его маска окон
- **THEN** подробности показывают единственный этап «Разделение голосов» с моделью «Nemotron»; предупреждение о недоступных интервалах не теряется
- **AND** в capsule/details и счётчике нет отдельной станции поиска речи; завершение одного источника не завершает станцию до второго

### Requirement: P04 Details navigation and independent window

«Подробнее» SHALL открывать существующий workspace на записи job через текущий admission. Закрытие workspace SHALL не отменять/скрывать обработку или капсулу. Показ/закрытие SHALL не создавать job/окно повторно и не сбрасывать snapshot.

#### Scenario: Reopen and guarded navigation
- **WHEN** пользователь несколько раз закрывает основное окно и открывает его из капсулы
- **THEN** job продолжается, показан актуальный этап, один workspace; при Settings/несохранённом вводе сохраняются admission и введённые данные, отклонённый переход получает feedback, не создаёт дубликат и не скрывает капсулу

#### Scenario: Select a saved recording after reopening through Settings
- **GIVEN** workspace закрыт, затем показан через Settings, и Settings закрыты без несохранённого ввода
- **WHEN** пользователь выбирает прежнюю или другую запись мышью либо стрелками библиотеки
- **THEN** через общий navigation admission восстанавливается запрос загрузки и открывается существующий сохранённый текст; не запускается новый job, narrow library navigation сохраняет текущую панель, файлы записи не меняются

### Requirement: P05 Accessibility and terminal state

Оба UI SHALL сохранять темы, читабельность, keyboard/VoiceOver и фиксированную геометрию капсулы по [design.md](../../changes/archive/2026-11-09-processing-progress-ui/design.md). Terminal lifecycle SHALL соответствовать изменённому R06, без пользовательского dismiss.

#### Scenario: Completion and other recording
- **WHEN** job завершён с замечанием, а пользователь читает другую запись
- **THEN** её selection не меняется автоматически; капсула сообщает готовность/замечание и «Открыть», не имеет крестика; принятие Open, timeout и stale-result guards соответствуют R06
