## ADDED Requirements

### Requirement: Optional isolated voice embedding capability
Swift worker SHALL поддерживать версионированное извлечение признаков одной записи
без записи edits/каталога и без перезапуска ASR. MLX/model ownership SHALL оставаться
в Pipeline/Worker; App/CLI/Core/Application SHALL не импортировать MLX.
Задания SHALL использовать общий Application исполнитель тяжёлой работы.

#### Scenario: Независимое извлечение
- **WHEN** переданы валидные source/result snapshot и интервалы
- **THEN** worker выдаёт конечные нормированные векторы, PCM fingerprints и embeddingSpaceID
- **AND** читает ограниченные окна, не декодирует всю встречу в память и не пишет пользовательские данные

#### Scenario: Отмена или несовместимый протокол
- **WHEN** запрос отменён, нарушена схема/containment либо версия capability неизвестна
- **THEN** задание завершается явной ошибкой/отменой без fallback source/runtime
- **AND** запись, чужая транскрибация и ручное сохранение имён не прерываются

#### Scenario: Новый результат той же записи
- **WHEN** после ASR для записи поставлено автоназначение
- **THEN** общий исполнитель отличает voice job от ASR той же записи по виду и resultID
- **AND** isProcessing ASR и история не получают фиктивный результат voice job

### Requirement: Explicit optional voice model preparation
Voice-модель SHALL иметь закреплённые revision/SHA-256/frontend/policy и отдельное
проверяемое состояние готовности. Включение функции/просмотр SHALL не скачивать
её; базовая транскрибация SHALL работать без неё. После явной подготовки voice
inference SHALL работать offline. Распространение весов SHALL требовать разрешения
лицензионного расхождения PoC и включения notices.

#### Scenario: Модель отсутствует или повреждена
- **WHEN** запрошено voice extraction без корректных локальных весов
- **THEN** показана причина и явный путь подготовки в «Голосах»
- **AND** ASR готовность не заменена ошибкой необязательной voice-модели, сеть сама не используется

#### Scenario: Подготовленная модель offline
- **WHEN** voice job выполняется без сети после подготовки
- **THEN** используются только проверенные закреплённые локальные assets и bundled Metal resources
- **AND** отмена не удаляет каталог профилей и shared caches
