## 1. Подготовка
- [x] 1.1 Сверить свежий master, правила repo и отсутствие конфликта change; импортировать только этот change. Не открывать архивный refresh-macos-interface.
- [x] 1.2 Прочитать specs/design/ADR review и выполнить `openspec validate processing-progress-ui --type change --strict`; при drift обновить дельту R06 из полного canonical baseline.

## 2. Реализация
- [x] 2.1 RED→GREEN P01: маршрут 5/6/7, N/M, две дорожки, неизвестный total, пропуски/ошибки, job identity; добавить реальные события начала/finalization/mix/publication без изменения моделей и форматов записей. Избыточный K убран по последующей обратной связи владельца в разделе 5.
- [x] 2.2 Реализовать P02/P05: компактная капсула по design.md, без локального процента и всех ручных dismiss-путей; сохранить запись/mute/stop, terminal ownership/timeout/Open guards R06.
- [x] 2.3 Реализовать P03: маршрут и детали в существующем workspace, один snapshot, без автонавигации на progress, честное сохранение/ошибка.
- [x] 2.4 RED→GREEN P04/R06: «Подробнее», один workspace, close/reopen без нового job; modal/draft admission и stale events; terminal Open outcome и deadline isolation.

## 3. Проверка
- [x] 3.1 Выполнить relevant regression, release build и strict validation; записать фактические результаты и исходные сбои. Не переносить старый PASS.
- [x] 3.2 Приёмка UI с design.md: native renders/CUA и проверки реализации подтверждены; владелец принял установленную beta.35. Оставшиеся отдельные физические Keyboard/VoiceOver/drag/Spaces/capture/mute/stop проверки сняты как обязательный gate по полной приёмке владельца, а не объявлены выполненными. См. docs/beta35-acceptance.md.
- [x] 3.3 Записать evidence P01–P05/R06, обновить CHANGELOG, получить приёмку, затем архивировать. Исходное ограничение установки изменено отдельным разрешением владельца в разделах4/5; публичный выпуск не выполнялся.

## 4. Дополнение владельца: доступ к текстам и локальная beta

Согласование: владелец прямо попросил установить бету, затем сообщил, что все прежние записи перестали открываться. Это разрешает локальную сборку/установку; публикация и изменение данных записей не запрошены. Исторический запрет установки выше относится к исходному этапу.

- [x] 4.1 Воспроизвести недоступность после close → Settings → выбор записи на сохранённом synthetic TXT; RED → исправить общую library selection boundary → GREEN. Не менять записи и не запускать retry.
- [x] 4.2 Независимое ревью дополнения, проверки; собрать и проверить локальную beta.33/build69 с прежним bundle ID/signing requirement.
- [x] 4.3 Проверить отсутствие активной работы, штатно закрыть app, сохранить прежний bundle, атомарно установить проверенный кандидат, запустить и проверить открытие прежних записей/сохранность данных. Без публикации.

Дополнительный этап завершён: RED — 2 synthetic tests/6 ожидаемых assertions до исправления; GREEN — 72 focused tests, полный canonical suite495tests. Общая `selectLibraryRecording` boundary применяется мышью и стрелками, сохраняет narrow pane и modal/draft guards. Независимый `gpt-6.1-sol high` в свежем BB thread `thr_gj4rrs5qpc`: PLAN_PASS, source PASS и candidate/integration PASS, P04 repairs0/2. Проверены5/5 source hashes,145/145 candidate files, прежний signing requirement и beta.33/build69. Основной агент реализовал дополнение по dev-loop; исходные P01/P03 counters1/2 сохранены.

2026-11-09T13:18:31Z: после штатного Quit и проверки отсутствия app/worker установлен проверенный кандидат; прежний bundle сохранён для отката. Запущен `/Applications/Meeting Companion.app`, beta.33/build69, новый PID44879. В native UI открыты прежние Standup и «Ночной инцидент», текст и экспорт доступны, retry не запускался. Все1637прежних файлов сохранились:1054JSON/TXT hashes и size/mtime остальных файлов неизменны. Дополнительные12файлов — новая запись, которую владелец сделал до установки.

Сбой живой beta.32 исчез у владельца после новой короткой записи, ещё до установки. Это согласуется с временным состоянием навигации; точный исторический триггер не установлен. Папки записей не переносились. Репродукция close→Settings→selection доказывает исправленный дефект, но не реконструирует действия владельца. Evidence — `beta-install/` того же run directory и [verification.md](verification.md).

## 5. Дополнение владельца: отступ и подпись этапа

Согласование: владелец попросил больше воздуха слева после удаления иконки. Узкая визуальная правка: leading padding32pt вместо16, trailing16pt и внешняя геометрия420×84pt сохраняются. Без изменения поведения; TDD не требуется по CONTRIBUTING. Используется существующий native render и независимое ревью этапа, исходные бюджеты не обнуляются.

Дополнительное прямое согласование владельца: убрать «далее 1/3» как избыточную арифметику. Подпись сокращается до `Этап N из M`, включая последний этап без «последний»; очередь сохраняется. Общий countText используется видимым и accessibility-текстом. RED: два существующих теста компилируются и падают на прежней подписи (caption-red.log, exit1); последующие GREEN/render/review подтверждены ниже. Reviewer thr_bg5pkx4sy7 проверил отступы и расширенный scope, ремонты0/2.

- [x] 5.1 Увеличить отступ и сократить подпись, проверить очередь/первый/средний/последний этап и длинный title/5и7этапов/terminal states в обеих темах на реальных SwiftUI views; независимое ревью без блокирующих замечаний.
- [x] 5.2 Собрать и проверить локальную beta.34/build70; обновить установленную бету после busy guard и сохранить предыдущий bundle для отката. Без публикации.

5.1 evidence: caption RED exit1, два ожидаемых assertion failures на старом тексте; полный GREEN suite495tests, native render1test/26PNG (native-caption), strict validation/diff check/Python-free/module boundaries/finder PASS. Первый/средний/последний этап и очередь проверены. Независимый reviewer thr_bg5pkx4sy7 повторно дал PASS расширенному scope,9/9 source hashes совпали, PNG подтверждают новый текст/отступы420×84; ремонты0/2. Native AX в test host и физический VoiceOver остаются UNVERIFIED. Evidence: capsule-spacing/ в существующем run directory. Новый подписанный кандидат подтверждён в5.2; прерванный package.log exit130 не является evidence готового кандидата.

5.2 завершено: package-final.log exit0, Bundle check passed/Built; отдельный `swift build -c release` PASS. Candidate/integration review того же reviewer PASS:9/9source и145/145payload hashes, beta.34/build70, bundleID/updates/signing requirement сохранены. Stopped-checks reviewer выполнить не мог из-за ограничений среды; координатор выполнил их успешно до staging и перед заменой после normal Quit. Установленная beta.34 запущена как PID62810 по штатному пути; signature/payload/version проверены. Прежний beta.33 bundle сохранён по пути из локального `capsule-spacing/install-state.json`; более ранний backup также не удалялся. CUA: прежний Standup загружен, transcript navigation/export доступны, retry не запускался. Все1661прежних файла неизменны, новых0. Публикации/commit/push не было. Итоговые evidence: capsule-spacing/{package-final.log,release-build.log,candidate-check.json,candidate-manifest.json,install-state.json,installed-proof.json,installed-ui-proof.json,recordings-preservation.json}. Изменение подписи проверено на native renders; живой цикл обработки/VoiceOver/Spaces/длинное аудио не запускались. Окончание локального обновления — время в installed-proof.json, интервалы ожидания отдельно не измерялись. Исходные3.2/3.3 остаются открыты.

## Checkpoint исходного этапа

2026-11-09: чистый HEAD и freshly fetched origin/master совпадают с baseline пакета `32de9bb1d16f5d47666fea8820fd52abc5869d59`. Импортирован только новый change, архивы не изменены. Первый strict validation отклонил переименование R06.1 как удаление canonical scenario; сохранён исходный заголовок `R06.1 Dismiss processing`, текст содержит новый согласованный контракт. Повторная strict validation PASS. Независимое plan review PASS до product edits. AEC — host-only/common этап, ожидание обеих дорожек относится к модельным этапам. Реализация выполняется одним writer. Логи и snapshots: BB thread storage `thr_twg97dh8hy/processing-progress-ui`. Установка/выпуск исключены, физический UAT и приёмка не выполнены; 3.3 не закрывается до приёмки/архивации.

Согласование: прямой запрос владельца реализовать переданный пакет и выполнить его задачи; дополнительное подтверждение того же scope не нужно. Этот `tasks.md` остаётся единым планом, в том числе после явного запроса `$dev-loop` во время финальных проверок. Историческая реализация выполнена по `sdd-orchestrate`; дальнейшие проверки и документацию ведёт основной агент без нового builder.

Реализация/source review: независимый `gpt-6.1-sol high`, новая сессия без наследования (`/root/implementation_review`), проверил cumulative diff и полный связанный код. Единственное замечание P01/P03 принято: queued job не должен объявлять текущий этап до реального start. Repair1/2: RED с удерживаемой A/queued B (3 ожидаемых assertion failures), GREEN — 17 focused tests. Повторное ревью PASS на `final-manifest.json`; 17/17 hashes совпали, остальные 12 файлов не изменены. Бюджет P01/P03 — 1/2, остальные — 0/2.

Исключение хронологии TDD: тесты новой обёртки Details и приоритета failed retry над старым current написаны после первой реализации. Их isolated baseline/scaffold RED воспроизведения сохранены отдельно, за test-first не выдаются; вызовы существующего admission, реальные previous TXT/job, close/reopen и late modal/outcome guards проверены регрессиями. Первичные P01/dismiss и repair очереди прошли настоящий RED до исправления.

Текущее состояние: source review PASS; canonical full `swift test` PASS493tests, post-repair release build PASS, Python-free/module boundaries/finder self-test/strict validation PASS. Повторный canonical native render на финальном diff PASS1test/26PNG, изображения проверены по темам/ширинам/состояниям. SwiftUI AX-дерево в test host недоступно и явно `UNVERIFIED`; VoiceOver, физические клавиши/drag/Spaces/capture/mute/stop и приёмка остаются открыты. 3.2 и 3.3 намеренно `[ ]`; CHANGELOG и evidence уже обновлены. Подробности — [verification.md](verification.md).

Время: первая зафиксированная контрольная точка подготовки — 2026-11-09T12:04:41Z; времена RED/GREEN/build/review/render сохранены в raw logs и journal. Окончание автоматической части фиксируется финальной записью journal; ожидание физического UAT не имеет заданного срока. Полные интервалы ожидания инструментов не измерялись и не оцениваются по переписке.

## Итоговая приёмка владельца

2026-11-09: «проверил. шикарно работает. давай закрывать этот SDD считаем всё принято». Приёмка распространяется на оба связанных change и установленную beta.35/build71. Остаточные физические QA-гейты сняты владельцем; перечисленные выше непроведённые проверки сохраняют свой фактический статус. Прежние checkpoint-записи описывают состояние на момент этапов и не отменяют эту приёмку. Общая запись: docs/beta35-acceptance.md. Синхронизация specs и архивация выполняются штатным OpenSpec; закрытый refresh-macos-interface не меняется.

Архивация завершена: `2026-11-09-processing-progress-ui`, specsUpdated=true,5added/1modified/0removed/0renamed. Canonical processing-progress создан, R06 recording-overlay синхронизирован; остальные требования recording-overlay сохранены. Активный change закрыт.
