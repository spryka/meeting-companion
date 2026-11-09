# Проверка processing-progress-ui

## Состояние

Реализация и автоматические проверки завершены. Независимое source/integration review — PASS после одного ремонта P01/P03. После отдельного запроса владельца выполнены исправление открытия библиотеки и локальная установка beta.33/build69. Публикация не выполнялась. Полный физический UAT, VoiceOver и приёмка владельца остаются открытыми; change не архивирован.

## Baseline и импорт

2026-11-09: freshly fetched `origin/master` и исходный чистый HEAD совпали с baseline пакета `32de9bb1d16f5d47666fea8820fd52abc5869d59`. Импортирован только отсутствовавший `processing-progress-ui`, без перезаписи файлов. Архивы, root ADR, зависимости, release metadata и пользовательские данные не изменены.

Первый strict validation отклонил переименование R06.1 как удаление canonical scenario. Сохранён заголовок `R06.1 Dismiss processing`; новый текст поведения из пакета не менялся. Повторная strict validation — PASS. Независимое plan review проведено до product edits.

## Требования и доказательства

| Требование | Реализация | Проверка |
|---|---|---|
| P01 | `ProcessingService` владеет transient snapshot одного job; frozen5/6/7 маршрут, N/M/K, состояния обеих дорожек и причины, сериализация callback events до принятия результата. Pipeline сообщает начало загрузки моделей, завершение после assignment/cascade; Worker — publication. | `processingRouteFrozenSourcesAndIdentity`, `processingLocalTruthAndSavingAcceptance`, `processingServiceDrainsOrderedProgressBeforeAcceptedResult`, `processingWireLifecycleValidation`, `processingLifecycleWireSurvivesPlatformAdapter` |
| P01/P03 очередь | До настоящего `audio.started` нет текущей станции; оба UI сообщают ожидание. AEC — общий host-only этап; две дорожки обязательны для модельных этапов. | `queuedProgressWaitsForActualAudioStart`: реальная удерживаемая A и queued B; RED3assertions → GREEN. `queuedProgressPresentationReportsWaiting` проверяет production presentation. |
| P02/P05 | Капсула420×84pt, один Details/Open, title/count/route без локального процента и ручного dismiss. Panel/recording controls переиспользованы. | `processingCapsuleRejectsManualDismiss`, native panel flags/geometry, актуальные PNG обеих тем/5и7этапов/длинного title/terminal states |
| P03 | Workspace показывает тот же snapshot, адаптивный маршрут и детали, честную локальную долю, предупреждения и допустимый retry. Failed retry имеет приоритет над старым загруженным current; старые файлы сохранены. | `processingFailedRetryDetailsOverrideActualPriorCurrent` с реально открытым сохранённым TXT и проверкой сохранности bytes; native full-workspace и narrow/wide PNG |
| P04/R06 | Details использует shared modal/draft admission; progress не меняет selection, close/reopen не создаёт job. Terminal Open требует outcome именно текущей попытки, deadline/job/generation guards сохранены. | `processingDetailsUsesSharedAdmissionAndCloseDoesNotRestartJob` и полный `Capsule24Tests`, включая cached-current late-modal rejection, guarded timeout и resumed processing после short-cancel feedback |

`ProcessingService`, producer events, App views и все связанные callers проверены независимым reviewer по cumulative diff и полному релевантному коду. Review snapshots: `review-initial-manifest.json`, `final-manifest.json`; финальные17source/test/changelog hashes совпадают. Единственное замечание очереди принято и закрыто тем же reviewer. Счётчики: P01/P03 repair1/2, остальные0/2.

## TDD и исходные сбои

- Первичный RED до реализации reducer/dismiss: exact-source isolated harness успешно собрался, два теста дали шесть ожидаемых assertion failures; затем те же два теста GREEN.
- Ремонт очереди: настоящий RED с удерживаемой A/queued B до product edits, затем17focused tests GREEN.
- Тесты новой Details-обёртки существующего admission и приоритета failed retry написаны после первой реализации. Их отдельные isolated baseline/scaffold RED сохранены, за test-first не выдаются. Это явное отклонение хронологии, компенсированное регрессиями реального job/previous TXT/modal/close/reopen и независимым ревью.
- Начальные canonical команды остановились до тестов: sandbox, Metal при выбранных CommandLineTools, затем старый cryptex path. Эти ошибки не считаются поведенческим RED. Найден действующий установленный Metal32023.922, очищен только lookup cache `xcrun`. Два generated debug XCBuildData plans со старым путём перенесены целиком в evidence, после чего canonical suite прошёл. Xcode/компоненты не устанавливались; global developer directory, app/runtime/model caches и данные не менялись.

## Финальные проверки

Команды Swift выполнялись с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

| Проверка | Результат | Raw log |
|---|---|---|
| `swift test` на финальном diff | PASS, exit0;493теста =7+46+228+200 Swift Testing и12XCTest | `full-tests-final.log` |
| `swift build -c release` после ремонта | PASS, exit0 | `release-repair1.log` |
| `bash scripts/check-python-free.sh` | PASS, exit0 | `python-free.log` |
| `bash scripts/check-module-boundaries.sh` | PASS, exit0 | `module-boundaries.log` |
| `swift skills/local-audio-transcriber/scripts/find-recording.swift --self-test` | PASS, exit0 | `finder-self-test.log` |
| `openspec validate processing-progress-ui --type change --strict` | PASS, exit0 | `strict-final.log` |
| `git diff --check` | PASS, exit0 | `diff-final.log` |
| `PROCESSING_PROGRESS_NATIVE_ROOT=… swift test --skip-build --filter processingProgressNativeSyntheticRender` | Рендер PASS, exit0;1test,26PNG на финальном коде. AX отдельно UNVERIFIED. | `native-final.log`, `native-final/` |

Финальные screenshots проверены по `design.md` и HTML: светлая/тёмная темы,5/7станций и фиксированная геометрия, длинный title, narrow detail-first и wide columns, предупреждение/ошибка/успех, интеграция в workspace. Нативное дерево SwiftUI AX в test host оказалось пустым;10 `*-ax-verification.json` явно содержат UNVERIFIED. Исходные strict AX failures сохранены. Пустое дерево не считается проверкой кнопок или VoiceOver. Structural panel/model tests и изображения — отдельные виды доказательств.

Raw logs, исходные команды/exit statuses, snapshots, диффы и reviewer dispositions находятся в `$BB_THREAD_STORAGE/processing-progress-ui` текущего BB thread. Token/cost usage дочерних native sessions недоступен и остаётся `null`; context occupancy не выдаётся за расход токенов.

## Открытые проверки

- Физические клавиши, VoiceOver, настоящий pointer drag, Spaces/fullscreen и отключение монитора.
- Реальная capture/mute/stop и продолжительная обработка аудио; permission flows. Алгоритмы моделей и записи не менялись, но эти сценарии в данном change не запускались.
- Приёмка владельца и архивация после неё. Предыдущая приёмка закрытого редизайна не заменяет приёмку этого change.

## Дополнение: библиотека и установленная beta.33

Владелец отдельно разрешил локальную установку и сообщил, что прежние записи перестали открываться в ещё работающей beta.32/build68. Core read-only probe подтвердил `canReview=true`, `hasSavedText=true`, `reason=nil` для обоих сегодняшних результатов. У Standup3833слова/322реплики, у короткой «без»0слов и предупреждения об отсутствии речи. Данные не требовали миграции или повторной обработки. Владелец затем создал новую короткую запись и сообщил о восстановлении доступа до установки — точный исторический триггер остаётся неизвестным.

Тест `librarySelectionRestoresLoadAfterSettingsReopen` воспроизвёл реальный synthetic saved TXT → close → Settings → dismiss → выбор same/other. До фикса компилируемый RED:6assertion failures в2tests. Общая `selectLibraryRecording` возобновляет request через существующий admission; оба pointer/arrow callers используют её, narrow library pane сохраняется. `librarySelectionPreservesModalAndRealDraftAdmission` проверяет Settings, external modal и настоящий text draft. TXT bytes неизменны, jobs0. GREEN72focused tests, включая keyboard/late-open guards; canonical `swift test` PASS495tests =7+46+228+202SwiftTesting+12XCTest.

Свежий независимый reviewer `gpt-6.1-sol high` (`thr_gj4rrs5qpc`) дал PLAN_PASS, source PASS и preinstall candidate/integration PASS, repairs0/2 для дополнения.5/5source hashes и145/145candidate hashes совпали. После дополнения повторены strict/Python-free/module-boundaries/finder/diff checks — PASS. `scripts/build-app.sh` создал подписанный bundle и выполнил `Bundle check passed`; exit исходного процесса после прерывания не восстановлен, поэтому доказательство кандидата — отдельные успешные проверки фактического bundle, metadata, payload и `codesign --verify --deep --strict`.

Локальный кандидат: `2.0.0-beta.33`, build69, `local.meeting-companion`, `MCEnableUpdates=true`; designated signing requirement совпадает с установленной beta.32. Разрешения и app/runtime/model caches не сбрасывались. После normal Quit проверено отсутствие app/worker; staged payload сверён, замена выполнена атомарно с сохранением предыдущего bundle. Установленный запущенный процесс: PID44879, `/Applications/Meeting Companion.app/Contents/MacOS/MeetingCompanion`;145/145installed files совпали с проверенным кандидатом.

CUA проверка установленной версии: прежний Standup и «Ночной инцидент» открываются, есть transcript navigation и сохранённый текст; экспорт Standup доступен. Retry не запускался. Все1637прежних файлов сохранились,1054JSON/TXT hashes и size/mtime остальных прежних файлов неизменны.12новых файлов относятся к записи владельца, сделанной после исходного inventory, до установки. Это подтверждает локальную установку и открытие старых текстов, но не полную UAT прогресса/VoiceOver/Spaces/длинного аудио.

Evidence дополнения: `beta-install/navigation-red.log`, `navigation-green.log`, `full-tests.log`, `candidate-check.json`, `candidate-manifest.json`, `install-state.json`, `installed-proof.json`, `recordings-preservation.json`, а также BB review thread. Прежний bundle оставлен по пути из `install-state.json` для отката; публикации/commit/push не выполнялись.

## Дополнение: отступ, короткая подпись и установленная beta.34

По прямой обратной связи владельца leading padding текста и маршрута увеличен16→32pt, trailing16/vertical12 и420×84pt сохранены. Общий `countText` сокращён до `Этап N из M` для видимого и accessibility-текста; убраны «далее K» и «последний», очередь сохранена. Specs/design согласованы с этим уточнением. Текстовые/визуальные изменения не требуют TDD, но существующие регрессии обновлены до реализации: RED exit1 с2ожидаемыми assertions на старом тексте; GREEN дополнительно проверяет последний этап. Полный suite495tests PASS, отдельный native render1test/26PNG PASS, strict/diff/Python-free/module boundaries/finder PASS. Native PNG подтверждают обе темы/5и7станций/длинный title/terminal states; физический VoiceOver и AX в test host остаются UNVERIFIED.

Независимый `gpt-6.1-sol high` reviewer `thr_bg5pkx4sy7` дал PASS отступам, затем расширенной подписи и финальному кандидату/интеграции.9/9source и145/145candidate hashes совпали, ремонты0/2. `package-final.log` завершён exit0 (Bundle check passed/Built); отдельный release build PASS. Прерванный ранний package.log exit130 не используется как доказательство готовности.

Локальная beta.34/build70, `local.meeting-companion`, updates=true: deep/strict signature PASS, designated requirement совпадает с beta.33. После normal Quit координатор успешно проверил отсутствие app/worker до staging и перед заменой (у reviewer pgrep недоступен). Exact candidate скопирован/проверен и установлен с сохранением beta.33 для отката; ранее сохранённая beta.32 не удалялась. После запуска PID62810 соответствует `/Applications/Meeting Companion.app/Contents/MacOS/MeetingCompanion`, payload/signature/metadata повторно совпали. Через CUA открыта прежняя Standup: сохранённый текст/transcript navigation/export доступны, retry не запускался. Все1661прежних файлов сохранились с прежними size/mtime и JSON/TXT hashes; добавленных0.

Evidence: `capsule-spacing/stage.diff`, `after-manifest.json`, `caption-red.log`, `full-tests.log`, `caption-green-native.log`, `native-caption/`, `package-final.log`, `release-build.log`, `candidate-check.json`, `candidate-manifest.json`, `install-state.json`, `installed-proof.json`, `installed-ui-proof.json`, `recordings-preservation.json`. Живой цикл обработки на установленной beta.34, physical VoiceOver/Spaces/long-audio не выполнялись. Локальное обновление не заменяет оставшуюся UAT/приёмку и не закрывает3.2/3.3; архивация/публикация/commit/push не выполнялись.

## Итоговая приёмка и закрытие

2026-11-09 владелец проверил установленную beta.35 и явно принял всё: «проверил. шикарно работает. давай закрывать этот SDD считаем всё принято». Дополнительные физические QA-гейты сняты; непроведённые отдельные проверки не считаются выполненными. Фактический длинный processing/retry и восстановленный плеер проверены в связанном align-finalized-audio-tails, с сохранением исходников и прежних правок. Исторические открытые gates выше заменены этой приёмкой; подробности и границы — docs/beta35-acceptance.md. Specs синхронизируются, оба change архивируются; публичный выпуск/commit/push не выполняются.
