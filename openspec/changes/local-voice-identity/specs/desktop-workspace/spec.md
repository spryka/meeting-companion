## MODIFIED Requirements

### Requirement: W04 Preserve transcript review contract
Система SHALL сохранять text/name edits v1/v2 current result, immutable recognition, отдельный edits.json, CAS/lock/containment и identities. Modal editing SHALL блокировать navigation/retry/close до явного разрешения input; error сохраняет draft. Saved undo/history/special Cmd-Z SHALL отсутствовать; native field undo и Cancel до save/confirm сохраняются.

#### Scenario: W04.1 Unsaved text and save failure
- **GIVEN** modal содержит ввод
- **WHEN** запрошены navigation/retry/close либо Save завершается ошибкой
- **THEN** уход/enqueue заблокированы, ошибка видна, ввод и current остаются
- **AND** доступны повтор Save, явный Cancel ввода и продолжение редактирования; стандартный field undo работает до сохранения

#### Scenario: W04.2 Current replacement and legacy
- **GIVEN** существуют старые файлы и более новый current, в том числе unsupported
- **WHEN** запись открывается либо retry завершает teardown
- **THEN** current разрешается заново без выбора старой версии или переноса edits; unsupported показывает причину и доступный saved TXT read-only
- **AND** flat legacy — list + contained standalone saved TXT, без structured lookup/edit/rename/retry; standard supported result без originals сохраняет editing/playback

#### Scenario: W04.3 Group speaker assignment
- **GIVEN** одинаковые local labels и отображаемые имена есть в разных sources
- **WHEN** выбирается массовое назначение
- **THEN** preview ограничен исходным source/voice текущего turn, не совпадением имени; source/voice и реальный count видны до confirm

#### Scenario: W04.4 Edit one utterance text
- **GIVEN** supported current доступен и не обрабатывается
- **WHEN** выбраны «Редактировать», затем Save или Cancel
- **THEN** Save сохраняет текст дословно отдельной правкой и обновляет display/search/export; Cancel не пишет, recognition/ID/time прежние
- **AND** unchanged text — no-op без revision/file write; blank/whitespace-only текст отклонён без потери ввода

#### Scenario: W04.5 Assign one utterance
- **GIVEN** единый редактор с default областью «Только эта реплика»
- **WHEN** имя введено/выбрано и подтверждено
- **THEN** изменено только имя этого turn current result; текст, время, соседние turns и source/voice ID прежние
- **AND** unchanged effective имя и personID — no-op без фиктивной правки
- **AND** preview виден и пересчитывается при открытии, вводе, выборе подсказки и области без записи; blank/zero changes запрещают commit; только явный Confirm сохраняет актуальный preview через прежние identity/CAS проверки

#### Scenario: W04.6 Assign same voice from current utterance to end
- **GIVEN** выбрана область «Реплики этого спикера отсюда до конца»
- **WHEN** пользователь явно подтверждает актуальный preview
- **THEN** меняются текущий и следующие turns того же исходного source/voice в порядке document.turns, с сохранением прежних ручных имён и имён неизвестного происхождения, пока явно не разрешена их замена
- **AND** более ранние turns, другие sources/voices, текст и другие resultID не меняются
- **AND** до confirm видны target name, source/voice, count реально изменяемых turns, count замен manual assignments и до трёх примеров с временем/прежним именем/текстом; zero changes не пишет
- **AND** изменение name/scope/revision/result/draft требует нового preview; CAS/error не применяет частичный пакет, сохраняет ввод; Cancel до confirm не пишет

#### Scenario: W04.7 Calendar names are suggestions
- **GIVEN** current содержит saved meeting context именно этой записи
- **WHEN** открыт выбор имени
- **THEN** пригодные attendee names — явные подсказки рядом с manual names; ручной ввод всегда доступен
- **AND** приглашение не доказывает присутствие/личность, host не означает владельца Mac; календарь/приглашения не меняются

#### Scenario: W04.8 Missing calendar and custom name
- **GIVEN** календарь отключён, запрещён, не привязан либо имён нет
- **WHEN** открыт единый редактор
- **THEN** отсутствие подсказок объяснено, manual input доступен без permission/network/EventKit refresh на editing path
- **AND** blank имя отклонено, имена/текст показаны как данные; Cancel не пишет, изменение календаря не переписывает сохранённые имена

#### Scenario: W04.9 Admission and late completion
- **GIVEN** modal открыт либо старый async callback ещё не завершён
- **WHEN** retry/navigation/close вызван через shortcut/programmatic route
- **THEN** admission SHALL повторно проверить отсутствие всех нерешённых черновиков; при input команда отклонена с причиной без deferred cross-window prompt
- **AND** после явного Save/Cancel старая session закрывается до enqueue, editable reopen запрещён до terminal teardown; fresh open разрешает current заново
- **AND** late callback SHALL не открыть чужую запись, не восстановить старую session и не записать draft в другой resultID

#### Scenario: W04.10 Cancel and standard field undo
- **GIVEN** text/name input ещё не сохранён/подтверждён
- **WHEN** пользователь отменяет ввод либо применяет native field undo
- **THEN** Cancel SHALL ничего не писать; field undo сохраняется; GUI не предлагает undo сохранённых правок, историю отката или отдельный Cmd-Z handler
- **AND** попытка закрыть modal с input сохраняет его до явного Cancel/Save/confirm; прежние result/edits и recognition schema SHALL не мигрировать и не удаляться

#### Scenario: W04.11 Two speaker assignment entry points
- **WHEN** пользователь нажимает имя у реплики либо количество говорящих в описании встречи
- **THEN** оба входа открывают единый редактор в правой области workspace с начальной областью single от реплики и group из шапки
- **AND** редактор возвращает к выбранной реплике; на узкой панели список и детали доступны поочерёдно

#### Scenario: W04.12 Shared calendar suggestions
- **GIVEN** current result содержит ручные имена, в том числе в частично назначенных группах
- **WHEN** любой вход строит calendar suggestions
- **THEN** уже назначенные имена исключены по NFC/краевым пробелам/регистронезависимости, ручной ввод сохранён
- **AND** полная шапка и список приглашённых в описании транскрипта не фильтруются
