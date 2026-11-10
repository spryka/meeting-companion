## MODIFIED Requirements

### Requirement: W07 Honest record states and actions
Система SHALL различать реальные loading/empty/no matches/processing/ready/warning/failed. Context/problems/Finder/audio preview и допустимый retry SHALL сохраняться. Retry требует canonical layout и exact contained raw pair. Rename SHALL менять только displayTitle через existing history repository/metadata; identities/paths/context прежние, ongoing jobs и flat исключены.

#### Scenario: W07.1 Ready with warning
- **GIVEN** текст готов с source warning
- **WHEN** запись открывается
- **THEN** текст доступен, warning раскрывается отдельно; приглашённые не выданы за count говорящих

#### Scenario: W07.2 Retry failed processing
- **GIVEN** standard entry с exact raw originals, modal закрыт
- **WHEN** явно запрошен retry
- **THEN** единая очередь закрывает старую session до enqueue, сохраняет старые файлы/edits, блокирует editable reopen до teardown, затем разрешает current заново
- **AND** precommit failure сохраняет прежний current, postcommit failure сохраняет новый с warning, unsupported current не вызывает fallback

#### Scenario: W07.3 Persist display name
- **GIVEN** standard idle entry с calendar title и unknown precise metadata; без optional displayTitle действуют прежние title/context/stem
- **WHEN** новое название сохраняется и библиотека заново читается с диска
- **THEN** list/heading/title search показывают displayTitle; context/unknown metadata/identities/paths и recognition/audio hashes прежние
- **AND** refresh/lifecycle save/retry не теряют displayTitle; identical effective name — no-op; дата/сортировка/recording URL/stem/resultID/edits не меняются

#### Scenario: W07.4 Invalid or unsafe display name
- **GIVEN** rename modal открыт
- **WHEN** введены blank, более 120 grapheme clusters либо control characters, включая NUL/CR/LF
- **THEN** Save отклонён с причиной, input остаётся, metadata прежняя
- **AND** Unicode/кавычки/path-like символы допустимы только как текст, никогда как path/markup/command

#### Scenario: W07.5 Rename error or competing work
- **GIVEN** до Save entry стал capture/saving/admitting/queued/processing либо atomic metadata save недоступен
- **WHEN** выполняется Save
- **THEN** нет частичного durable изменения или оптимистичного успешного title; прежний title остаётся, modal/input/error доступны для Cancel/повтора
- **AND** lifecycle API с retain-unsaved-memory не выдаёт rename за успешное сохранение

#### Scenario: W07.6 Legacy rename is unavailable
- **GIVEN** canonical folder basename не равен recording stem
- **WHEN** entry отображается либо rename вызван программно
- **THEN** rename отклонён до side effects; entry остаётся list + свой contained saved TXT read-only, файлы прежние

#### Scenario: W07.7 Discoverable reprocessing of saved old text

- **GIVEN** standard dedicated-folder entry с distinct contained raw host/remote WAVs, в том числе с standalone saved TXT или unsupported current
- **WHEN** пользователь открывает обычное меню действий записи
- **THEN** «Повторить обработку» доступно на первом уровне меню через прежний retry/enqueue и cached capabilities, без технического диалога; age/producer/schema текста не являются disable condition
- **AND** busy/modal/ongoing-job admission сохраняется; успешная обработка публикует current прежним способом, исходные audio/results/edits не уничтожаются
- **AND** flat placement и отсутствие безопасной exact пары остаются недоступны с прежней причиной; нет автоматической миграции, подстановки mixed M4A или второго фиктивного источника

#### Scenario: W07.8 Warning belongs to the selected recording
- **GIVEN** запись A имеет предупреждение, а текущий результат B не содержит предупреждений
- **WHEN** пользователь переключается с A на B, затем возвращается к A
- **THEN** сообщение A не показывается как ошибка B; собственное предупреждение A остаётся доступным у A, результаты и правки не меняются

#### Scenario: W07.9 Late background feedback retains its owner
- **GIVEN** открыта B либо нет выбранной записи, а обработка A продолжается
- **WHEN** приходит terminal warning или ошибка сохранения, относящаяся к A
- **THEN** selection/current не меняются, сообщение не приписывается B; предупреждение и terminal feedback доступны в контексте A

#### Scenario: W07.10 Library-wide errors remain visible
- **GIVEN** ошибка относится к библиотеке в целом и не имеет recording owner
- **WHEN** выбранная запись меняется либо selection пуста
- **THEN** общая ошибка не скрывается как чужое предупреждение; её причина доступна, ошибки записи и библиотеки не смешиваются
