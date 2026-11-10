# library-refresh Specification

## Purpose
Явное обновление текущей библиотеки без повторного распознавания, с сохранением
рабочего состояния и защитой от устаревших результатов и конфликтующих операций.

## Requirements

### Requirement: L01 Explicit guarded library refresh

Система SHALL предоставлять одну команду «Обновить библиотеку» через кнопку в заголовке списка, нативное меню «Вид» и ⌘R. Команда SHALL сканировать текущий configured root вне MainActor через существующий shared history repository, без моделей, импорта или записи пользовательских файлов.

#### Scenario: Restore from Trash and refresh
- **GIVEN** целая поддерживаемая папка записи возвращена из системной Корзины на прежнее место внутри текущего root
- **WHEN** пользователь вызывает любой из трёх входов обновления
- **THEN** запись появляется ровно один раз по прежней canonical identity, с прежними metadata/edits и сортировкой, без ASR/retry
- **AND** query сохраняется; восстановленная запись видна только при соответствии текущему фильтру, не выбирается автоматически

#### Scenario: Command admission and duplicate requests
- **GIVEN** видимая активная библиотека открыта в списке или документе, а modal/draft/native sheet/Settings/trash admission отсутствуют
- **WHEN** пользователь вызывает обновление, в том числе из обычного поля поиска
- **THEN** общий guarded command запускает один scan; повторы во время initial scan/refresh не создают второй запрос и не откладываются
- **AND** открытая capture/processing job сама по себе не блокирует refresh

#### Scenario: Blocked or inactive workspace
- **GIVEN** открыт modal/draft/Settings/native sheet, идёт trash admission/deletion, показана форма записи либо workspace скрыт/свёрнут/не является active keyboard target
- **WHEN** поступает shortcut/menu callback обновления
- **THEN** scan не начинается и не выполняется после снятия блокировки; native input сохраняет приоритет, capsule не получает глобальный shortcut
- **AND** pointer и programmatic route не обходят соответствующие общие guards; поздний callback повторно проверяет admission до старта

### Requirement: L02 Preserve workspace and concurrent work

Обновление SHALL сохранять query, focus, scroll и выбор/session/playback оставшейся
выбранной записи. Полный успешный scan SHALL убирать отсутствующие незанятые строки
текущего root; ошибочный scan SHALL сохранять прежние строки. Shared merge SHALL
защищать revisions, working/reserved/unsaved entries, ввод и trash races.
Сверка SHALL менять только память без изменения файлов или storage layout.

#### Scenario: Refresh while reading or playing
- **GIVEN** пользователь читает выбранный документ либо воспроизводит его, список и текст прокручены
- **WHEN** scan добавляет другие записи или обновляет metadata, выбранная запись остаётся на диске
- **THEN** выбранный документ не переоткрывается, session/scroll/playback сохраняются, список не прыгает к началу и focus не переносится

#### Scenario: Work, trash and stale root
- **GIVEN** после старта scan изменилась запись, началось/завершилось её удаление либо configured root сменился
- **WHEN** приходит старый результат
- **THEN** он не перетирает и не убирает более свежую revision/working/reserved/unsaved entry, не возвращает удалённую строку и не публикует данные/ошибки старого root в новом запросе
- **AND** штатная загрузка нового root не теряется из-за занятости прежнего refresh

#### Scenario: Externally removed standard or legacy recording
- **GIVEN** idle-запись в отдельной папке либо legacy flat-запись исчезла с диска после предыдущей загрузки
- **WHEN** полный scan текущего root успешно завершился
- **THEN** отсутствующая запись исчезает из списка, счётчика и поиска; оставшиеся файлы не меняются
- **AND** успешно прочитанная пустая библиотека убирает все незанятые отсутствующие строки; записи вне текущего root не затрагиваются

#### Scenario: Removed selected recording
- **GIVEN** выбранная запись отсутствует в успешно обновлённом списке, modal/draft/native input отсутствуют
- **WHEN** ручное обновление завершается
- **THEN** selection сбрасывается, прежняя review session и player закрываются, показано «Выбери запись» без автоматического выбора соседней встречи
- **AND** если после старта scan появился ввод, обновление сохраняет выбранную строку и её presenting view, не закрывает ввод; очистка строки/selection/session выполняется следующим явно разрешённым обновлением

#### Scenario: Partial scan preserves cached rows
- **GIVEN** scan не смог прочитать root или часть дерева, некоторые прежние записи не обнаружены
- **WHEN** scan завершается с ошибкой
- **THEN** прежние строки сохраняются, доступные новые записи добавляются, показана ошибка по L03; отсутствие в неполной выдаче не считается удалением

#### Scenario: Active and concurrently changed missing recording
- **GIVEN** запись отсутствует в выдаче, но работает, имеет work/trash reservation, несохранённое состояние или изменилась после начала scan
- **WHEN** полный scan завершается
- **THEN** её строка и состояние сохраняются; последующий полный scan после снятия защиты может убрать отсутствующую строку

#### Scenario: Restore externally removed recording
- **GIVEN** строка убрана обновлением, затем запись восстановлена по прежнему пути
- **WHEN** пользователь обновляет библиотеку повторно
- **THEN** запись возвращается ровно один раз с прежними сохранёнными metadata/edits без распознавания и изменения файлов

### Requirement: L03 Honest refresh feedback

Система SHALL показывать busy/error состояния на месте рядом со списком, сохраняя существующие строки; повторный запрос SHALL быть недоступен до завершения. Отказ чтения SHALL отличаться от успешно прочитанной пустой библиотеки.

#### Scenario: Loading and successful completion
- **WHEN** начинается ручное обновление
- **THEN** icon-button показывает progress в той же области, команда disabled, под поиском показано «Обновляем библиотеку…»; список не заменяется полноэкранным spinner
- **AND** после успеха busy исчезает без alert/toast/focus jump, VoiceOver сообщает «Библиотека обновлена»

#### Scenario: Unreadable or missing root
- **GIVEN** root отсутствует, недоступен либо scan прочитал только часть содержимого
- **WHEN** запрос завершается
- **THEN** показаны сообщение «Не удалось полностью обновить библиотеку. Повторите обновление» и безопасная причина, доступные и прежние записи сохранены, повтор разрешён
- **AND** нет ложного успеха или empty state вместо ошибки; успешный повтор убирает только принадлежащую refresh ошибку
