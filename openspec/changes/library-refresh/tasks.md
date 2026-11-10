# Dev-loop: library-refresh

Цель: явное обновление библиотеки через кнопку, «Вид → Обновить библиотеку» и ⌘R; одна видимая «Новая запись» на каждой ширине. Сохранить query/selection, scroll/focus, текущую session/playback и protections repository. Полная готовность требует native UAT, а не только source review и сборки.

Согласование: A/B первоначально утверждены 2026-11-10 («да, давай»); план продолжения явно принят («план принят, давай выполнять») в BB-треде thr_jbr8ivttua. Реализацию ведёт основной агент; независимый reviewer gpt-6.1-sol/high без истории родителя, read-only. Не более двух ремонтов на этап.

Baseline: `19c84249e8141442601eab88b7846a0b9592f6f7`, ветка `library-refresh`. Продолжен существующий dirty/untracked diff, без повторной реализации и отката чужих правок. Исходные файлы/diff/hashes сохранены в хранилище BB-треда (`implementation-baseline/`); actual GitHub master сверён и совпал с baseline. Основной checkout не изменён.

Ограничения: без watcher, pruning, миграций, реальных пользовательских записей, изменения форматов, моделей или capture/pipeline. **Текущее установленное приложение не завершать, не перезапускать, не заменять и не устанавливать поверх него.** Владелец ведёт важную запись. Native app/fixture hosts, UAT с записью/обработкой и операции с аудиоустройствами отложены до явного подтверждения окончания записи. Установка, выпуск и архивирование до приёмки не разрешены.

## Этапы

- [x] A. Команда и данные: guarded admission и off-main scan; request/root ownership; missing/nil/partial read, retry/error ownership; synthetic trash→restore без дубликатов и записи в пользовательские файлы. RED→GREEN и независимое ревью завершены.
- [ ] B. UI и сквозной результат: кнопка/меню/⌘R, narrow form action, inline busy/error/VoiceOver, scroll/focus/session/playback. Суммарное source review A+B, обязательные проверки, native UAT и CHANGELOG. Непроведённая обязательная UAT блокирует отметку завершения B.
- [ ] Передать PR с подтверждёнными результатами и открытыми проверками; не архивировать change до приёмки.

## Проверка B

- [ ] Wide/compact/narrow list/detail и resize туда/обратно; light/dark, прежние header/divider/toolbar. Ровно одна видимая «Новая запись»; narrow action перед поиском, минимум 44 pt; refresh 36×36 или 44×44 pt.
- [ ] Pointer, «Вид», ⌘R из списка/документа/обычного поиска вызывают общий command. Busy запрещает повтор без очереди. Modal/draft/Settings/native sheet/trash, inactive/hidden/minimized/form/capsule не обходят admission; native input сохраняет приоритет. ⌘N и обе видимые кнопки открывают прежнюю форму без старта capture.
- [ ] Query/selection, list anchor **и offset**, focus, та же review session, text scroll и непрерывный playback при добавлении/изменении entries. При исчезновении anchor по независимому событию — ближайшая сохранившаяся строка. Refresh не выбирает восстановленную запись и не переоткрывает текущий документ.
- [ ] Busy/error на месте под поиском, список остаётся доступным. Missing/unreadable/partial root не выдаётся за пустой успех; успешный retry убирает только refresh error. VoiceOver: «Библиотека обновлена», без переноса фокуса/toast/alert.
- [ ] Synthetic restore, metadata/edits, ошибки и retry; coexistence с capture/processing без остановки. Не использовать реальные записи владельца.
- [ ] `swift build -c release`, полный `swift test`, bundle validation при упаковке. Не выдавать filtered native-engine tests за полный набор.
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

Environment blocker default engine: `cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`. Компонент не установлен. Полные release/test/bundle проверки не подтверждены; Metal blocker нельзя объявлять продуктовой регрессией или закрывать filtered GREEN.

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
