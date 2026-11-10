# Dev-loop: library-refresh

Цель: явное обновление библиотеки через кнопку, «Вид → Обновить библиотеку» и ⌘R; одна видимая «Новая запись» на каждой ширине. Сохранить query/selection, scroll/focus, текущую session/playback и protections repository. Полная готовность требует native UAT, а не только source review и сборки.

Согласование: A/B первоначально утверждены 2026-11-10 («да, давай»); план продолжения явно принят («план принят, давай выполнять») в BB-треде thr_jbr8ivttua. Реализацию ведёт основной агент; независимый reviewer gpt-6.1-sol/high без истории родителя, read-only. Не более двух ремонтов на этап.

Baseline: `19c84249e8141442601eab88b7846a0b9592f6f7`, ветка `library-refresh`. Продолжен существующий dirty/untracked diff, без повторной реализации и отката чужих правок. Исходные файлы/diff/hashes сохранены в хранилище BB-треда (`implementation-baseline/`); actual GitHub master сверён и совпал с baseline. Основной checkout не изменён.

Ограничения: без watcher, pruning, миграций, пользовательских записей в тестах и изменения capture/pipeline. Первоначальная важная запись и обработка явно завершены владельцем; по новому запросу разрешена локальная установка beta.36/build72. Она выполнена без остановки активной работы: прежнее приложение уже было закрыто. Новые активные записи/обработку не прерывать. Публичные push/release и архивирование до приёмки по-прежнему не разрешены.

## Этапы

- [x] A. Команда и данные: guarded admission и off-main scan; request/root ownership; missing/nil/partial read, retry/error ownership; synthetic trash→restore без дубликатов и записи в пользовательские файлы. RED→GREEN и независимое ревью завершены.
- [x] B. UI и сквозной результат: кнопка/меню/⌘R, narrow form action, inline busy/error/announcement, scroll/focus/session/playback. Source review, обязательные проверки и UI-приёмка владельцем завершены; физический VoiceOver исключён из приёмки.
- [x] Передать PR с подтверждёнными результатами и статусом приёмки: общий [PR #18](https://github.com/spryka/meeting-companion/pull/18), SDD closeout перед merge.

## Проверка B

Итоговая приёмка объединяет native regression tests и подтверждение UI владельцем.
Физический VoiceOver не запускался; проверка этой частью приёмки не заявляется.

- [x] Wide/compact/narrow list/detail и resize; одна видимая «Новая запись», narrow action перед поиском и размеры refresh. Native tests и UI-приёмка владельцем.
- [x] Pointer, «Вид», ⌘R из списка/документа/поиска используют общий command; busy/modal/draft/Settings/native sheet/trash/inactive guards и прежняя форма записи. Native regression tests и source review.
- [x] Query/selection, list anchor/offset, focus, review session, text scroll и playback сохраняются. Native regression tests и UI-приёмка владельцем; refresh не выбирает и не переоткрывает документ.
- [x] Inline busy/error, missing/unreadable/partial root и владение refresh error. Native tests/source review; announcement path сохранён, физическая проверка VoiceOver исключена.
- [x] Synthetic restore, metadata/edits, ошибки/retry и coexistence с capture/processing — native tests и source review без изменения реальных записей.
- [x] Полный штатный `swift build -c release`, полный `swift test`, build-app и bundle validation. После установки Metal Toolchain default engine работает; подтверждены все final summaries.
- [x] `openspec validate library-refresh --type change --strict`.
- [x] `bash scripts/check-python-free.sh`.
- [x] `bash scripts/check-module-boundaries.sh`.
- [x] `swift skills/local-audio-transcriber/scripts/find-recording.swift --self-test`.

## Текущее состояние и доказательства

A: **PASS**, reviewer thr_57dcchfygy, Codex gpt-6.1-sol/high, sourceThreadId=null, same workspace, read-only контракт (BB CLI не предоставляет отдельный read-only filesystem mode). Ремонты **2/2**; прежний reviewer другого harness PASS не выдавал. Reviewed `stage-a-repair2.diff` SHA256 `d781865cda196f60a485d8aa351f14eda42a826cba2403dfa0ebfe9e5e73be3b`; все 14 stable hashes совпали. tasks.md — mutable checkpoint, исключён из manifests.

Приняты и исправлены: повторный `history.loading` guard после отложенного Task; nil enumerator как ошибка; синхронная инвалидация repository generation/UI request до смены root. Для всех получен ожидаемый RED. Сначала ошибка компиляции тестовой подстановки и ошибка directory URL equality не считались RED/PASS. CLI entrypoint переименован из `main.swift` в `MeetingCompanionCLI.swift` без изменения содержимого: устранён существующий @main/main.swift conflict штатной сборки, Package.swift не заменялся.

Логи хранятся в хранилище этого BB-треда; это evidence, не второй рабочий план:

- `stage-a-red-2.log`: nil enumerator false success и duplicate scan — ожидаемый RED.
- `stage-a-root-red-2.log`: старый scan публикуется после присваивания root, до выполнения нового Task — ожидаемый RED.
- `stage-a-final-green.log`: **28 tests / 5 suites PASS**, с final summary.
- `stage-b-red.log`: отсутствующий command и stub формы — ожидаемый RED.
- `stage-b-final-green.log`: **32 tests / 5 suites PASS**, с final summary; Core, headless command/form/root, partial enumeration, synthetic trash/rename и pure history error test. Native UI fixtures скомпилированы, но **не запускались**.

Команда GREEN: `DEVELOPER_DIR=<Xcode Developer> nice -n 15 swift test --build-system native -j 2 --filter 'LibraryRefreshTests|LibraryRefreshCommandTests|historyManualMissingRootAndSuccessfulRetryOwnOnlyRefreshError|RecordingTrashTests|RecordingRenameTests'`. Это штатный полный manifest с фильтром; временный subset runner прошлого harness не использован. Native engine — штатный, но deprecated флаг SwiftPM.

Исторический blocker default engine (отсутствовал Metal Toolchain) устранён: официальный компонент Metal Toolchain 27B47 загружен для запрошенной локальной установки. Полные release/test/bundle проверки выполнены штатным default engine, результаты ниже. Старые filtered/native-engine логи остаются историческими доказательствами.

B: source review и cumulative A/B — **PASS**, reviewer thr_a2pwwtctbm, Codex gpt-6.1-sol/high, ремонт **2/2** (включая завершающую EOF-правку). Reviewed stage-b-final.diff SHA256 030a5432df4fc686ac6b6cd7beaffa369810d6df26091207b27c13eb8dfbeeb8; все 18 stable hashes совпали. Приняты и исправлены оба P2: phase refresh больше не включает loading для valid current, сохраняя processing/input guards; status-menu вызывает общий requestRecordingForm. Итоговый headless набор **263 tests / 30 suites PASS**. Native shortcut/menu/session/playback regression только скомпилирована. ScrollPosition/focus/VoiceOver и все пункты native UAT выше остаются **непроверенными**. B целиком не закрыт. Вопрос владельцу об окончании записи и UI/toolchain разрешении пока без ответа. Готовится draft PR, без установки/выпуска/архивирования.

Время: исходная подготовка плана 2026-11-10T00:14:17+03:00; реализация BB начата 2026-11-10T13:21:34+03:00. Первая скомпилированная версия B: 32 tests PASS (точное время — timestamp checkpoint ниже). Полное завершение не наступило; отдельные интервалы ожидания не измерены.

Checkpoint: 2026-11-10T13:49:30+03:00. Код B ещё не прошёл итоговое source review; UAT открыта.

B source review подготовлено: stage-b.diff SHA256 148c9b23045be6e4cd2627bc6b334ccf95560672d0b542656a94d00d86abeb8f, stable stage-b.sha256. Нативная UI/аудио UAT не проводилась. Ремонты B 0/2. Checkpoint 2026-11-10T13:51:03+03:00.

Reviewer B: thr_a2pwwtctbm, Codex gpt-6.1-sol/high, same environment env_khguavvw4t, sourceThreadId=null, parentNotifications=auto. Initial review, ремонты B 0/2; код заморожен.

Дополнительная проверка frozen B: core-regressions-final.log — полный MeetingCompanionCoreTests: 251 tests / 27 suites PASS. final-release-app-native.log — release App product build PASS (34.72s), без запуска. openspec-final/python-free-final/boundaries-final/finder-final.log — EXIT 0. Это не полный swift test и не native UI UAT.

Review B initial — CHANGES_REQUIRED. Оба P2 приняты: refresh phase перезапускает current через loading spinner; status-menu обходит requestRecordingForm при nativeInput. Регрессии stage-b-repair1-red.log воспроизвели оба сбоя без UI/аудио. Исправления: current reuse сохраняет loading=false, но повторяет processing/generation/input guards; delegate использует общий command и показывает окно только при успехе. Сейчас GREEN-проверка ремонта B 1 (ещё не передан reviewer). A остаётся PASS 2/2, B используется 1/2 после передачи. Исторический исходник нового затронутого TranscriptReviewWindow.swift восстановлен из baseline HEAD в implementation-baseline; до этого файл отсутствовал в dirty diff и frozen manifests.

Ремонт B 1/2 — 2026-11-10T14:04:01+03:00: RED stage-b-repair1-red.log, GREEN stage-b-repair1-green.log (34/5), затем final-headless-repair1.log: **263 tests / 30 suites PASS**, штатный native engine. Фильтр: MeetingCompanionCoreTests|LibraryRefreshCommandTests|historyManualMissingRootAndSuccessfulRetryOwnOnlyRefreshError|workspaceCloseInvalidatesPendingOpen. Приняты оба P2, fixes на общем manager/command boundary. Проверяется stage-b-repair1.diff SHA256 eaa19f40596a3d4575484ac2f27e71697f333bd46170bfbfb131de4161824520, stable stage-b-repair1.sha256, reviewer thr_a2pwwtctbm. B 1/2, A закрыт 2/2. Native UI/аудио не запускались; ответа владельца пока нет.

Source phase завершена: 2026-11-10T14:05:25+03:00. A PASS (ремонты 2/2), B source PASS (ремонты 1/2). Полное завершение/UAT не наступили.

Финальные проверки reviewed repair1: final-release-app-repair1.log — release App product PASS (21.01s). openspec-repair1/python-free-repair1/boundaries-repair1/finder-repair1.log — EXIT 0. metal-toolchain-final.log подтверждает отсутствие Metal Toolchain. Default full release, полный swift test и bundle validation остаются открытыми. Для native UAT нужен разрешённый доступ: прежний отказ Computer Use для Library Refresh Checks не обходить другим UI-инструментом. Никаких установок/запусков app или native fixtures в этом продолжении не было. Checkpoint 2026-11-10T14:07:48+03:00.

Финальная staged-проверка включила бывшие untracked files и нашла лишнюю пустую строку EOF LibraryRefreshTests.swift. Удалён ровно один LF, логика не менялась, остальные 17 stable hashes прежние. git diff --cached --check чист. Обновлённый stage-b-final.diff/.sha256 направляется тому же reviewer; консервативный бюджет B **2/2**. Native UAT по-прежнему открыта.

Итоговый source PASS подтверждён 2026-11-10T14:10:43+03:00: thr_a2pwwtctbm, stage-b-final.diff SHA256 030a5432df4fc686ac6b6cd7beaffa369810d6df26091207b27c13eb8dfbeeb8, 18 stable hashes. A 2/2, B 2/2. Только mutable checkpoint/PR metadata могут обновляться без изменения reviewed кода; новые существенные ремонты требуют согласования бюджета. Общая задача и B остаются открыты до native UAT и полных проверок.

Checkpoint 2026-11-10T14:12:37+03:00: reviewed source закоммичен локально: 43e116b (feat: add guarded library refresh), 19 файлов. Push/draft PR **не выполнены**: automatic approval review отклонил публичную публикацию в spryka/meeting-companion, поскольку принятие подготовки PR не сочли явным согласием на эту destination/раскрытие исходников и SDD. Вопрос о конкретном публичном push/PR задан владельцу. Никакой обход не использован; повторять до явного согласия нельзя. Локальные reviewable artifacts: reviewed-library-refresh.patch, pr-body.md, publication-blocker.txt в хранилище BB-треда. Вопрос о завершении важной записи и UI/Metal тоже пока без ответа. Следующий шаг: дождаться соответствующего явного разрешения; native UI/установка/публикация до него не выполняются. Код и source hashes прежние. Полное завершение/UAT не наступили.

## Локальная установка для UAT — запрос владельца 2026-11-10T17:01:02+03:00

Владелец спросил «готово? можем поставить приложение?»: разрешена подготовка локальной установки; прежнее исключение установки расширено этим запросом, публичная публикация по-прежнему не разрешена. Важная запись/обработка пока не подтверждены завершёнными: приложение не останавливать и не заменять. Задан отдельный вопрос об окончании записи. Native UAT не отменена и не объявлена выполненной.

Официальный Metal Toolchain 27B47 загружен через xcodebuild -downloadComponent MetalToolchain. Подпись установленного bundle валидна; designated requirement сохранён в installed-designated-requirement.txt хранилища треда. Все 18 reviewed source hashes совпали до подготовки установки. Следующий шаг: штатный полный release build и проверенный bundle с прежней signing identity, затем установка только после явного подтверждения отсутствия активной записи/обработки. Не сбрасывать разрешения и не менять пользовательские записи.

Для локальной тестовой установки подготовлены только metadata: 2.0.0-beta.36 / build 72 (выше source и установленной beta.35 / 71), Unreleased помечен как предстоящая beta.36, исторические release sections не переписаны. Это не публичный выпуск и не приёмка UI. Функциональный код reviewed версии не изменён; source-ревью A/B и бюджеты не обнуляются. Metadata-only packaging проверяется штатным check-bundle и сравнением designated requirement. До разрешения не завершать/не заменять активное приложение.

Владелец подтвердил 2026-11-10T17:03:48+03:00: «Да, запись и обработка завершены». Recording gate снят для запрошенной локальной установки: допускается штатно закрыть приложение и заменить его после успешной проверки bundle. Текущее приложение пока не остановлено; подготовка сборки идёт. Записи/настройки/permissions не изменять и не сбрасывать. Публичная публикация по-прежнему не разрешена.

Checkpoint установки 2026-11-10T17:10:24+03:00: полный штатный swift build -c release -j 2 **PASS** (250.50s), installation-full-release.log; build-app.sh **PASS**, installation-build-bundle.log. Готов dist bundle beta.36/build72; check-bundle и deep/strict codesign PASS. Designated requirement нового bundle точно совпал с установленной beta.35. Rollback bundle installation-rollback/Meeting Companion beta35.app сохранён и проверен. 17 функциональных reviewed hashes прежние; вне reviewed версии изменены только upcoming-version header CHANGELOG и две version metadata Info.plist. Идёт обязательный полный swift test; установленное приложение ещё не остановлено и не заменено. Native UAT не объявлена выполненной.

## Результат локальной установки — 2026-11-10T17:25:20+03:00

- [x] 2.0.0-beta.36 / build 72 установлена в /Applications/Meeting Companion.app штатным install-app.sh (installation-install.log, EXIT 0).
- [x] Фактически установленный bundle повторно прошёл check-bundle, deep/strict codesign; designated requirement точно совпадает с beta.35. Bundle ID прежний: local.meeting-companion. TCC/настройки/записи не сбрасывались и не удалялись.
- [x] Приложение запущено; installation-result.json подтверждает version/build, PID и executablePath установленной копии. До установки старое приложение уже не работало; force kill не использован.
- [x] Полный default-engine swift test: Swift Testing 7/1, 49/8, 251/27, 239/10 — все PASS; отдельно XCTest ModelAssetsTests 12/12 PASS. Native refreshShortcutFromSearchAndViewMenuShareAdmission, manualLibraryRefreshAdmitsOnlyOneRequestAndPreservesReview и admission cases — PASS. EXIT 0, installation-full-tests.log. Это законченный полный прогон, не прежний subset или exit 0 без summary.
- [x] Полная release-сборка и bundle validation — PASS. Rollback signed bundle beta.35 сохранён в installation-rollback/ хранилища треда.
- [x] UI-приёмка владельцем завершена в ходе совместного закрытия beta.36; физический VoiceOver исключён, native coexistence tests прошли. См. итог ниже.

Функциональный код source-reviewed версии не менялся. Для локальной beta изменены только version/build Info.plist и upcoming-version header CHANGELOG. A/B source review остаются PASS, ремонты A 2/2 и B 2/2 не обнулялись. Публичная публикация не выполнялась. Локальная установка завершена, общая приёмка функции остаётся открытой.

## Совместная приёмка beta.36 — 2026-11-10

UI принят владельцем; разрешены merge в master и завершение SDD вместе с
scope-recording-feedback. Физический VoiceOver исключён из проверок и не запускался.
Существующие статусы ожидания выше относятся к предыдущим checkpoint.

Baseline установленной beta.36 — `3d2691c`; интеграция feedback сохраняет
library-refresh. Совместные тесты: 552 Swift Testing и 12 XCTest PASS, включая
native refresh/keyboard/admission и сохранение session/selection/feedback.
Strict validation обоих changes, Python-free, module boundaries и finder PASS.
Source integration review — PASS, reviewer `thr_fv6ueayu66`, freeze beta36.sha256.
Прежние бюджеты library-refresh A 2/2 и B 2/2 сохранены, новых ремонтов этого feature нет.
Release, signed bundle и установка совместной beta.36 завершены; прежний bundle
сохранён, сертификат и точное установленное содержимое проверены.
Подробный итог проверок: [beta36 acceptance](../../../../docs/beta36-acceptance.md).
