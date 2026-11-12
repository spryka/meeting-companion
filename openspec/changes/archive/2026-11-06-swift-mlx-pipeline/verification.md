# Проверки изменения

## Single-current scope — 2026-11-03, beta.6/build42

Новый явно разрешённый scope удаляет GUI историю распознаваний, selection APIs и
recordingFormatVersion gate. Сохраняет edits/CAS, originals, shared services,
contained read-only TXT и explicit retry из raw/flat пары. Current выбирается
до schema validation по creation date/name; directory rename — единственный commit,
per-result TXT обязателен, root TXT — derived cache. Postcommit ошибки дают warning
и сохраняют новый current. Retry admission разрешает draft до enqueue и закрывает
obsolete editor до terminal; async-switch path удалён.

Semantic RED: disk reload/marker duplicates, newest B против selected A,
отменённый admission всё же запускает runner, supported current ошибочно читает
небезопасный root cache. Исправленный before publisher probe отдельно подтвердил
throw после успешного rename при ошибке root export; первоначальная publisher
фикстура была невалидна и не считается доказательством этого дефекта.

Финальный полный Swift run: **240 tests** (189 Core/Application, 11 App, 23 Pipeline,
7 Vendor, 10 Assets), exit0. После него менялись только docs и compile-only harness;
production code тот же. Все release products собраны; три GUI harnesses только
скомпилированы. Evaluated transitive graph, boundary check и strict OpenSpec для
single-current-transcript/swift-mlx-pipeline/transcript-editor прошли.

Подписанный dist candidate: 2.0.0-beta.6/build42, local.meeting-companion,
Authority Interview Recorder Code Signing; deep strict verification и check-bundle
exit0. Exact commands/logs, requirement→caller→test, before integrity,
incremental patch, source/bundle manifests и SHA-256 находятся во внешнем
`completion-native-only/single-result-simplification/final-report.md`.
ADR-0001/0002/0003 не изменены; ADR-0004 supersedes только history-selection clauses.

Независимая приёмка этой ревизии ещё не выполнена. Physical beta UAT — WAITING_UAT.
Новых model inference/downloads, длинных аудиопроверок или установки не было;
исторические 15-file SHA/30s JSON-AAC/AEC2 evidence не выданы за новые проверки.
Research/performance и deferred gates остаются открытыми в прежних пределах.

## Corrective pass3 — 2026-11-03

Исторический авторский отчёт pass3 (не итоговая приёмка): шесть production-boundary замечаний были заявлены исправленными через App/CLI callers:
throwing callback выбора версии, отдельная in-memory политика terminal status при
ошибке metadata, capability-based совместимость с additive recordingFormatVersion=1,
встроенный contained read-only TXT reader, восстановление presentation из атомарных
service snapshots и awaited history/result I/O вне MainActor. Provenance gating
заменён прямой политикой владельца: поддерживаемый JSON v1 сохраняет функции без
различения Python/Swift producer и без миграции существующих записей.

RED зафиксировал подавление ошибки production callback, зависший terminal status,
неработающие constructor guards, потерю будущего marker в неполной metadata и
обход ограничения дублированным marker. GREEN проверяет реальные callback/session/
window model, completion/cancellation/retry, raw/flat sources, отсутствие TXT,
повреждённый/отсутствующий result, будущий/некорректный формат и ordered reattachment
recording/preparing/checking/queue. Metadata header проверяется существующим parser,
отдельно от необязательных описательных полей истории; discovery не пишет файлы.

Полный Swift run pass3: 257 tests (213 Core/Application, 10 Assets, 7 Vendor,
19 Pipeline, 8 App), exit 0. После финального ремонта header повторены все
213 Core/Application и 9 App tests, exit 0; прежний полный run не выдаётся за
полный run окончательной ревизии. Три GUI harnesses только скомпилированы.
Evaluated transitive graph и boundary checks подтверждают Foundation-only
Core/Application и отсутствие Pipeline/MLX в App/CLI. Strict OpenSpec прошёл.

Release products и подписанный test bundle: 2.0.0-beta.5/build41,
local.meeting-companion, Authority Interview Recorder Code Signing.
Окончательные commands/status, binary SHA-256, patch против неизменного pass3
before/ и requirement→caller→test находятся во внешнем evidence
`completion-native-only/strong-builder-pass3/`. Bundle не устанавливался.

Независимый reviewer pass3 выдал CHANGES_REQUESTED: P1 marker duplication при повторных saves и P2 draft loss при async-switch. Ревизия не принята; физический beta UAT — WAITING_UAT.
Retry eligibility подтверждает exact contained/readable пару source paths;
декодирование аудио проверяет прежний worker при выполнении, не history scan.
Модели/Pipeline/AEC не исправлялись этим проходом, новые inference/downloads и
длинные записи не запускались. Прежние bounded bootstrap/30s/AEC evidence
используются с их исходными ограничениями; deferred research/performance gates
остаются открытыми. Python tests повторно не запускались: Python runtime не менялся.

## Пункт 2.4: фиксация corpus и методики — 2026-11-02

Зафиксированы 20 WAV: обе дорожки трёх 300 s фрагментов, полный hour30,
отдельные held-out ranges meeting29/meeting28 и восемь edge/source-duty fixtures.
Проверены формат, длины, SHA-256, точное PCM-содержимое относительно исходников,
рецепты synthetic/duty, полнота inventory и непересечение выделенных ranges.
Held-out ранее использовался в PoC; запрет настройки применяется с этой фиксации.
Source-duty 100/25/5% не означает подтверждённый процент речи.

Baseline source/environment/model manifests сохранены и проверены по содержимому:
frozen Python source и executable, ровно 37 package identities, native/reference
assets и 808 файлов native source closure. Пакеты не разрешались заново.
Все исходные WAV, веса, frozen source и production sources остались неизменными.

Settings, точные recording-stem/layout команды и критерии закреплены до inference.
Instrumented manifest определяет per-source/model checkpoints, reset/sync scope,
current/peak RSS отдельно от MLX и post-exit child verification. Ненаблюдавшиеся
значения — null. Для коротких и полных серий требуется warm-up + 3 fresh processes
на профиль, Parakeet on/off отдельно; команды inference пока structure-only.

Frozen Python grouping использует 15 s без punctuation branch; текущий product —
30 s с punctuation split после 15 s. Scheduling-only Python comparison сохраняет
frozen profile в обоих расписаниях. Product grouping проверяется отдельным bridge,
без ложного exact между разными профилями. Численные и same-profile gates сохранены.
Контрпример [0,14] + [15,16] даёт две frozen turns и одну product turn; проверены
реальные owning functions без model imports.

RED воспроизвёл реальные ошибки guard/profile assertions. Self-check и 32 регрессии
прошли у builder и координатора; отдельные CLI probes подтвердили отказ при
missing/rebound source, неполном inventory, подмене expected asset hash и порче/
усечении PCM даже с обновлённым manifest SHA. Независимое ревью PASS, R1–R8 закрыты;
1298 файлов review guard не изменились. Приватные artifacts run
`20261102T053527Z-0fd678a8`: `builder-2.4/`, `sol-fallback-2.4/`,
`coordinator-2.4/` и `task2.4-review-final.md`.

По просьбе владельца Gemini заменён на свежий Sol medium/AUTO. Бюджеты сохранены:
Gemini initial 1 / repairs 2 (последняя прервана), Sol 2 dispatches. Это подготовка
методики: inference/parity/performance, реальная speech/quiet/overlap coverage,
исполнение consumer 8+8, UI и physical UAT не принимались.

## Пункт 2.3: выбранные численные профили — 2026-11-02

Приватные probes проверили все 561 GigaAM tensors: stored F16, native default F16,
F32 expansion, shapes, finite values и точное совпадение expansion. Полное
соответствие 560 Python / 561 native keys, convolution transposes, tokenizer
1024 pieces/IDs, decode и RNNT ties проверены. Разница объединённого LSTM bias
0.0009765625 сохранена как source/precision bridge, а не равенство разных exports.

Selected-profile F32 frontend Python/Swift: max abs 1.9073486328125e-6.
Nemotron original BF16: DSP max abs 1.9073486328125e-6, synthetic 31-layer core
forward max abs 0.0001956680789589882 / max relative 0.03710073190969187.
Общий comparator проверяет оба forward limits независимо; четыре контрпримера
старого false PASS отвергаются. Materialized positive control и повреждённые
weights/config/frontend fixtures проходят проверки ожидаемых отказов.

Дополнительная Double64 диагностика остаётся FAIL: 0.0013027191162109375 > 1e-3.
Этот критерий появился в плане probe, отсутствует в принятой спецификации и не
подменяет выбранный F32 FFT profile или нормативные semantic/parity gates.
Координатор и независимый reviewer явно разграничили его с task2.3. Порог,
inputs, assets и результат не изменялись. Причина на уровне hardware остаётся
гипотезой; Python F32/Double stage comparison не изолирует hardware cause и
не является dump промежуточных Swift tensors.

Исторические claims первоначального PASS после подмены reference, неверные
версии пакетов и claims sampled coverage отозваны authoritative coordinator
report; raw evidence сохранено. Первая sandbox GPU-попытка координатора exit255
не считается проверкой; разрешённый независимый повтор exact probe — exit0,
с теми же passed selected-profile checks и failed extra diagnostic.

Приватный run `20261102T053527Z-0fd678a8`: `builder-2.3-fresh/`,
`coordinator-2.3/`, `reports/task2.3-coordinator-disposition.md` и final review.
Gemini initial1, repairs2, Sol0; clarification2/2. Независимое ревью PASS,
1057 source paths / 93 relevant artifacts hashes+modes сохранены. Пустой файл
`0.01`, случайно созданный в initial attempt, зафиксирован и перенесён в private
logs; исходники продукта не менялись. Reviewer read-only инструктивный.

Это приёмка synthetic selected-profile checks. Fixed-capacity wrappers,
corpus/held-out parity, model-first orchestration, performance, app integration,
packaging и physical UAT (`WAITING_UAT`) остаются отдельными открытыми gates.

## Пункт 2.2: pinned model source и единый MLX graph — 2026-11-02

Добавлены минимальные pinned GigaAMKit (29 файлов), Nemotron (11), Silero (2)
и локальный MLXAudio package. Корневой lock закрепляет MLX Swift 0.32.3 и
прежний Sparkle 2.9.6; транзитивные pins сохранены из проверенного PoC.
App/CLI/Core/Platform не зависят от MLX/model targets. Model bodies совпадают
с исходными PoC copies; существенный новый neural port не выполнялся.

Vendor содержит provenance, воспроизводимые patches, фактические transitive
и embedded license texts/notices, точный frozen Python DSP source hash.
Все 767 entries проверяются по SHA-256 и единственному полю размера `size`.
Исходные недостоверные narrative SHAs/версии и неудачные/перезаписанные ранние
логи сохранены как ограничения trace; они не приняты как доказательство.
Текущие pins и лицензии сверены с owning source, а команды повторены отдельно.

Координатор воспроизвёл assertion RED на immutable исходном manifest после
успешного его вычисления; отсутствуют нужные model targets. Текущие resolve,
evaluated graph, GPU addition/eval/sync, boundary guard и release build прошли.
Полный Swift command выполнил два test executables: model/vendor suite
(после ремонта 7 tests) и 200 прежних tests / 19 suites. Python offline:
107 tests, 1 skipped, exit 0. Внешняя sandbox сначала запретила вложенную
SwiftPM sandbox; разрешённый повтор прошёл, ошибка сохранена.

Независимый reviewer выявил неверные версии в license ledger, пропущенные
embedded licenses и неточные metadata/размеры. Два ремонта Gemini закрыли
все замечания; финальное ревью PASS. Последний ремонт меняет только metadata
и assertions: targeted RED/GREEN и независимый повтор 7 tests PASS; прежние
full-suite/release/boundary результаты применимы, повторные сборки не нужны.
1057 source paths и evidence hashes/modes сохранены до/после финального review.
Reviewer только читал; read-only ограничение инструктивное.

Приватный SDD run: `20261102T053527Z-0fd678a8`. Initial 1, Gemini repairs 2,
Sol fallback 0. Пункт 2.2 принят; numerical model/profile checks 2.3 и далее,
app integration, packaging и физический UAT (`WAITING_UAT`) остаются открытыми.

## Пункт 2.1: Xcode/Metal и upstream tests — 2026-11-02

Проверены Xcode 27.2 (27B52), Apple Swift 6.4.2, SDK 27.2 и Metal 32023.922
через per-command `DEVELOPER_DIR`. Глобальный `xcode-select -p` остался
CommandLineTools. Без `DEVELOPER_DIR` поиск Metal завершился exit 72;
с выбранным Xcode фактические Metal compilation и metallib link прошли.

В отдельной копии pinned GigaAM `95bd42a4b9a65450a24e1898c7d84b85e0e88509`
release build прошёл; `BuildWordsTests` выполнил 7 tests без ошибок отдельно
в release и debug. Контрольные суммы 50 upstream files, включая manifest/lock,
совпали с исходной копией до/после. Синтетические probes MLX 0.31.3 и 0.32.3
выполнили addition на `Device(gpu, 0)`, `MLX.eval` и GPU stream synchronization
с проверкой вычисленных значений. Общий продуктовый dependency graph и модели
в этом пункте не проверяются.

Координатор независимо повторил оба GPU probes и 7 release upstream tests
с запретом сети для процесса: exit 0. Исходные builder-команды использовали
cached sources, но сеть у них принудительно не запрещалась. Неудачные compile
и запуск probe без расположенного рядом Metal bundle сохранены; успешный
повтор использует штатное upstream resource co-location. Первоначальный
вложенный sandbox координатора завершился exit 71; штатный разрешённый повтор
прошёл. Эти ошибки среды не считаются TDD RED; к проверке toolchain TDD
не применяется. Отдельный временный `test.metal` не сохранился; pinned Metal
sources, успешная upstream compilation и выполненные GPU probes доступны.

Независимое ревью: PASS без существенных замечаний. Содержимое и режимы
288 файлов проекта совпали до/после builder и reviewer; дополнительная проверка
110 внешних source/evidence files после reviewer также чистая. Reviewer только
читал, не выполнял проверки и не менял файлы; ограничение инструктивное.
Сырые команды/cwd/start/end/exit, исходники probes, source snapshots и review
сохранены в приватном SDD run `20261102T053527Z-0fd678a8`. Gemini initial 1,
repairs 0, fallback не требовался. Упаковка приложения и физический UAT открыты.

## NTR-MOD-1: перенос macOS adapters — 2026-11-02

Первый срез принятой ADR-0003: capture/recorder/audio export, process client
транскрибации и AVPlayer transport перенесены из Core в Platform. Foundation
DTO/progress и существующий редактор остались в Core. App/CLI подключают оба
модуля; очереди, история и UI сохраняют прежнее поведение. Application,
Pipeline/Worker и модели в этом срезе не реализуются; пункты 4.0/5.0 открыты.

- Baseline: 189 Swift tests / 18 suites и release build, exit 0.
- Boundary assertion RED: capture imports/linker settings в старом Core, exit 1;
  GREEN после переноса, exit 0. Это проверка границы, не нового поведения.
- После переноса: 191 Swift tests / 19 suites и release build, exit 0.
  Первый прогон выявил старую линковку Core-only у четырёх subprocess probes;
  после подключения Platform все probes проходят без изменения assertions.
- Координатор проверил 18 synthetic recording checks, transcription failure/retry,
  progress, history и live output, exit 0. Первые recording/process self-checks
  упали во внешней sandbox; штатный повтор вне неё прошёл.
- Python: 107 tests, OK / 1 skipped, exit 0; выполнены offline из готового cache.
  Первый запуск не получил доступ к uv cache; штатный повтор прошёл.
- `swift package dump-package`: Core без dependencies/linker settings,
  Platform → Core, App/CLI → Core + Platform; новые package dependencies отсутствуют.
- Прежние `TranscriptDocument.swift` и encoding test побайтово сохранены;
  контрольные хеши запрещённых transcription/experiments/Resources совпали.

Все Swift-команды использовали Xcode через per-command `DEVELOPER_DIR`,
штатную `.build` и cache `/private/tmp/meeting-companion-swiftpm-cache`.
Сырые логи, snapshots и diffs хранятся в приватном SDD run
`20261101T225235Z-a15fd3c6`.

Независимое ревью выявило false GREEN в новых boundary checks. Два ремонта
Gemini заменили текстовый разбор манифеста на evaluated SwiftPM graph. Первый
незавершённый GREEN-прогон блокировался вложенным SwiftPM lock; проверка
манифестов во временных копиях устранила конфликт, сборки продукта остались
в штатной `.build`. У одного незавершённого запуска перезаписан лог; он не
засчитан как PASS, последующие завершённые прогоны сохранены отдельно.

Sol fallback исправил обязательность Platform target/каталога/пяти adapters
и заменил внешние временные fixtures на самодостаточные. Отрицательные проверки
требуют конкретную причину отказа, а не любой ненулевой exit. Итог: 11 boundary
tests (включая семь случаев отсутствующего Platform), полный Swift набор
200 tests / 19 suites, release build и no-argument shell check — PASS.
Координатор повторил boundary tests и прежний Core-only контрпример: теперь
он отклоняется с `MISSING_TARGET` и `MISSING_PLATFORM_DIRECTORY`.

Итоговое независимое ревью: PASS, все три подтверждённых замечания закрыты.
Хеши и режимы всех 283 файлов проекта совпали до/после последнего ревью;
ревьюер не менял файлы и не выполнял тесты/сборки. Ограничение read-only было
инструктивным, жёсткая sandbox-изоляция не заявляется.
Из бюджетов использованы два ремонта Gemini и первый из двух оставшихся
Sol fallback dispatches; исходный Sol preflight и его usage сохранены.
Принят только автоматизированный срез переноса адаптеров.
Физический UAT записи/разрешений/mute/playback/окон: `WAITING_UAT`.
Установка, запуск приложения, model parity и packaging не выполнялись.
Пользовательское поведение не меняется, отдельная запись CHANGELOG не нужна.

## Предложение модульных границ — 2026-11-02

Карта зависимостей, владение состоянием и порядок выделения находятся в
[design.md](design.md#границы-модулей-приложения); ADR-0003 имеет статус proposed.
Proposal, specs, ADR review и tasks согласованы между собой. Перенос модулей
не выполнен; новые сценарии lifecycle ещё требуют реализации и тестов.

`openspec validate swift-mlx-pipeline --strict`: PASS. Проверены локальные ссылки,
пробелы и code fences в 10 Markdown files change/ADR. Подтверждено отсутствие
изменений ранее проверенного source diff. Swift/Python suites повторно не
запускались: этот срез меняет только документацию.

## Актуализация и encoding JSON v1 — 2026-11-02

В `TranscriptDocument` и его вложенные типы добавлен `Encodable` через `Codable`.
Поля схемы и decoder/валидация сохранены; в четырёх encoder methods nullable
обязательные поля записываются через `encode`, а не пропускаются как nil.
Не добавлены отдельная DTO-схема, миграция, запись поверх старых результатов,
MLX dependency, модельный builder или worker/app integration.

TDD: до изменения source шесть общих valid fixtures прочитаны текущим decoder;
runtime requirement на `Encodable` падает во всех шести случаях. Это ожидаемый
RED отсутствующей возможности, не ошибка импорта/компиляции. После реализации
все шесть fixtures проходят semantic JSON equality и повторный `TranscriptDocument.load`
с неизменными schema/result/word IDs и turn references. Финальный тест использует
прямой `JSONEncoder.encode(document)`; RED-версия и исходный source сохранены
в приватных артефактах. Decoder/validation bodies механически сверены с snapshot.

Срез реализует только сериализацию существующей модели документа. Построение
нового result из model outputs, mix/publication и полный пункт 4.2 остаются открытыми.

## Проверки актуализации

- `openspec validate swift-mlx-pipeline --strict`: PASS, exit 0.
- Ссылки и trailing whitespace в 10 Markdown files change/ADR после консолидации: PASS.
- Исходная база: 188 Swift tests в 17 suites PASS до нового encoding.
- Encoding RED: exit 1, шесть ожидаемых runtime failures отсутствующего Encodable.
- Encoding GREEN: exit 0, один параметризованный test / шесть случаев PASS.
- Полный Python набор: 107 tests, 106 OK / 1 skipped (AEC), exit 0.
- `swift build -c release`: PASS, exit 0 (Command Line Tools 6.4).
- Итоговый `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:
  189 tests в 18 suites PASS, exit 0; новый encoding test включает шесть случаев.

Первый запуск внутри внешней sandbox не позволил SwiftPM применить вложенную
sandbox; `afconvert` вернул exit 2. Повтор через штатное расширение разрешений
подтвердил Python PASS. Последующий полный Swift-прогон CLT остановился на
`TestingMacros ... plugin not found`. Swift 6.4.2 из Xcode в отдельном scratch-каталоге
выполнил тесты, но четыре старых subprocess-теста взяли модули из штатной `.build`
от CLT и получили SDK 27.0/27.2 mismatch. Итоговый повтор выполнен Xcode в штатной
`.build` и прошёл, без изменения global developer path или исходников старых тестов.

Валидация OpenSpec и regression baseline не являются model parity или физическим UAT.


Консолидация документов по замечанию владельца: отдельный refresh-документ
удалён, контракт и порядок работ находятся в design.md, результаты — здесь.
В действующем design исправлены базовый HEAD и статусы ADR; в spec устранена
ссылка на удалённые бюджеты. Старые INT8/Q8 bridge prerequisites заменены
проверкой выбранного BF16 профиля, исторические заметки перенесены в research.md.
Это правка документации; source/tests при консолидации не менялись.

## Исторические проверки подготовительного этапа (2026-10-30/31)

> Исторический материал экспериментов 2026-10-30/31. Текущая база и решение
> владельца от 2026-11-02: [design.md](design.md).
> Прежние Air gates/budgets исключены, старый перечень Python differences
> снят как неактуальный. Упоминания ниже описывают состояние на дату пробы,
> не действующие блокеры или новый PASS. Контракт редактора берётся из текущего master.

Исходная дата: 2026-10-30. Scope: исследование, SDD и отдельно разрешённые console PoC.

## Выполнено

- Изолированный worktree, branch `research/swift-mlx-pipeline`, base
  `7306d80917fbc8c020ca09b1e287d1090a387b30`. На исходном этапе добавлены документы
  этого change и proposed ADR-0002; позднее отдельно разрешён console PoC ниже.
  Чужие изменения не переносились и не откатывались.
- Проверены фактические full-MLX исходники, manifests весов и dtype, environment,
  18 результатов прежнего эксперимента, новый offline run на копиях двух дорожек.
  Код копии остался побайтово равен frozen source manifest после тестов.
- Python: `python -B -m unittest discover -s transcription -p 'test_*.py' -q`
  через подготовленный offline uv environment, 83 tests / 82 passed / 1 skipped.
  Это проверка baseline, не тест Swift implementation.
- Source-level review трёх готовых Swift реализаций и HF model metadata.
  Не ограничивались README. Ревизии, различия и непроверенное в research.md.
- `openspec validate swift-mlx-pipeline --strict`: passed.
- `git diff --check`: passed. Дополнительно проверены новые Markdown файлы
  на trailing whitespace, локальные ссылки и стиль, поскольку файлы ещё untracked.

## Уточнение SDD: обработка по моделям

По запросу пользователя в proposal/design/specs/tasks и proposed ADR-0002
добавлено model-first расписание: одна загрузка модели на запись, последовательные
host/remote, независимое состояние, освобождение до следующей модели и сохранение
исходного GigaAM до Parakeet. Добавлены сценарии state isolation, source-local
failure и монотонного прогресса, а также отдельное сравнение расписаний в Python
перед оценкой языкового эффекта. Согласование всего плана и ADR не подменяется
этим уточнением; задачи реализации остаются невыполненными.

После правок `openspec validate swift-mlx-pipeline --strict`: passed.
В 10 Markdown файлах change/ADR проверены trailing whitespace и локальные ссылки:
passed. Код, frozen baseline и чужие worktrees не менялись. Это проверка SDD,
не подтверждение reset state, четырёх загрузок или выигрыша времени/памяти.

## Не прошедшее и ограничения

- Stock GigaAM `swift test -c release --filter BuildWordsTests`: exit 1,
  `unable to spawn process 'metal' (No such file or directory)`.
  Отдельно `xcrun --find metal`:
  `xcrun: error: unable to find utility "metal", not a developer tool or in PATH`.
  Это build environment failure до выполнения tests. Не RED логики и не успешный
  тест модели. Внешний полный лог сохранён. В исходной попытке toolchain не
  устанавливался; последующая отдельно разрешённая установка описана ниже.
- Объединённый graph трёх stock packages не разрешался SwiftPM; непересечение
  ranges установлено по manifests, включая exact mlx-swift-lm 3.31.4.
- На подготовительном этапе Swift inference четырёх моделей ещё не был проверен;
  позднее выполнен в отдельном PoC ниже. Одинаковые профили весов, INT8 bridge,
  лицензирование всех transitive/derived artifacts и общий end-to-end parity не подтверждены.
- Не выполнялись app integration, native packaging, новая подпись/test bundle,
  установка, публикация, live recording/AEC UAT или новая clean-cache подготовка.
- ADR-0002 остаётся proposed. Tasks реализации и приёмки не отмечены выполненными.

## Внешнее evidence

По отдельному запросу добавлен одноразовый `experiments/swift-gigaam-poc`:
`main.swift`, минимальный SwiftPM manifest/lock и команды в README. Это только
GigaAM probe, не начало интеграции приложения или согласование всего плана.
Self-check прошёл RED (`self-test: single 25 s window`) и GREEN после реализации.
Dependency resolve успешен. Первоначальный release build под CommandLineTools:
exit 1, `unable to spawn process 'metal' (No such file or directory)`.
После принятия пользователем лицензии выполнены first launch и download Metal
Toolchain. Xcode 27.2 (27B52), Metal 32023.922; global developer path не менялся.
Release build и compiled self-check прошли. Офлайн с запретом сети для процесса
обработаны две копии дорожек одного пятиминутного фрагмента: 154/216 слов,
432/546 токенов с emission frames, 13 окон на дорожку. Слова/start/end точно
совпали с сохранёнными GigaAM словами Python. Это не контроль compute dtype,
тензоров весов, Python token trace или одинакового speech gate; общий паритет не доказан.
Проверены empty/short/silence, invalid stereo/missing model и existing output.
Оригиналы, WAV copies и прежний output сохранили hashes. Raw логи/outputs и
одиночные timing/RSS/MLX measurements находятся только во внешнем evidence.
Задачи model/full-pipeline acceptance остаются невыполненными.

В отдельном evidence cache скачан pinned KRUATECH bundle `2478743`.
SHA-256 manifest, weights, tokenizer и frontend assets совпали с upstream
`checksums.sha256`. README того же snapshot имеет устаревший checksum в этом
файле; на runtime assets расхождение не распространяется.

Локальный каталог evidence содержит frozen Python source и его manifest,
`python-environment.json`, `python-models.json`, `prior-results-audit.json`,
копии прежних summary/measurement файлов, upstream metadata и build log,
новый `baseline-rerun/` с WAV copies, output и `time -l` log.
Он расположен вне git. Модельные файлы проверены в существующем локальном cache,
не добавлены в репозиторий. Ни аудио, ни транскрипты в сеть не отправлялись.

Подготовительный этап не доказывает готовность Swift-конвейера. Следующий шаг
полного переноса после согласования плана: минимальный общий dependency graph и
строгие локальные model probes всех четырёх моделей, затем сравнение.

## Полный одноразовый CLI, отдельно разрешённый пользователем

`experiments/swift-pipeline-poc` собран в release на MLX Swift 0.32.3.
Фактические изменения ограничены экспериментом и этими документами;
app/capture/AEC/accepted ADR/чужие worktrees не менялись. Согласование всего
proposal и product acceptance этим не заменяются.

Проверены strict local load и inference каждой модели на обеих дорожках,
затем полный model-first run: четыре загрузки, последовательные независимые
источники, MLX active после каждого teardown менее 6 KiB, cache0. Последний
полный запуск прошёл с запретом сети и `PATH=/nonexistent`. `otool -L` не
содержит libpython. CLI не запускает Python/uv; Python используется только
внешним baseline/evidence harness.

Восстановлен Python reference из frozen source с теми же исходными profiles,
дополнительной диагностикой и отдельным model-first расписанием. Проверены
версии пакетов: mlx0.32.4/mlx-audio0.5.8, numpy2.5.4, soundfile0.14.0,
huggingface-hub2.4.0. Frozen Python source hashes после прогонов не изменились.
Это instrumented reference harness, не поставка изменения Python baseline.

На двух копиях 300 s:

- 370 GigaAM words/start/end/speaker и 978 token IDs/pieces/frames/times точно
  совпали с Python. Маски speech gate совпали (10/13 host, 11/13 remote окон).
- Итоговые исправленные слова и временные реплики merged transcript совпали
  и с новым reference, и с сохранённым Python baseline. Метаданные/JSON CLI
  исследовательские; продуктовые форматы этим не проверены.
- Nemotron: 1/2 голоса, 32/67 интервалов против Python BF16 39/70.
  Swift использует INT8 **другой source revision**, поэтому это не языковая пара.
- Parakeet: 169/223 слова, по одному отличающемуся тексту на дорожку и отличия
  таймкодов до160 ms. Применены те же 3/1 замен, но host journal donor_end
  не побайтово совпадает. Swift cascade/merge на собственных model outputs
  точно совпали с frozen Python функциями. Полный модельный паритет не заявлен.

Pure logic: 107 cascade +150 attribution/group synthetic Python fixtures,
assertions mask/token/seams/invalid timestamp/merge. Cascade прошёл RED/GREEN
в ходе работы; arithmetic regression GigaAM word end дополнительно воспроизведена
во внешней временной копии до исправления, RED/GREEN logs сохранены.
Архитектуры моделей взяты готовыми; integration-first adapter
проверка разрешена исследовательским исключением CONTRIBUTING.

Реальные subprocess checks: fallback дополнительных моделей, неизменность
GigaAM, existing-output rejection, retry в новый каталог, fatal GigaAM,
Parakeet off, invalid stereo, empty/short, silence, quiet/noise speech gate, одинаковые
источники для Nemotron/Parakeet state reset, SIGINT/cancel exit130 и input hashes.
Quiet/noise masks совпали с Python: `[true,true,false]` / `[false,false,false]`.
Первый integration harness потребовал исправления сравнения NSError строк:
адреса объектов нестабильны; тексты/маски проверены отдельно от числа warnings.
Не выдаём этот сбой harness за ошибку или RED приложения.

Замеры сохранены отдельно для RSS и MLX. Разовые новые процессы с тёплым
файловым cache, разными профилями Nemotron/GigaAM и версиями MLX не подтверждают
ускорение/снижение памяти от смены языка. Raw metrics, commands, outputs,
comparison и REPORT находятся во внешнем `swift-pipeline-runs/`, вне git.
Не выполнены BF16/source bridge, held-out и повторная контролируемая серия,
forced disk-full/source-local model faults, SIGKILL/product cancellation bounds,
empty-cache downloader, app integration, packaging/signing и UI/recording UAT.

## BF16 и три полные встречи — 2026-10-31

Готовая сеть адаптирована к тому же BF16 Nemotron checkpoint/source, что
frozen Python. Модель не заменена и заново не реализована. Настройки offline
сохранены; INT8 control остаётся доступным отдельно. Strict loader, checkpoint
DSP и dtype/mask/RoPE adapters описаны в README эксперимента.

Полный последовательный offline run обеих реализаций на копиях встреч
3659.22/1763.54/747.86 s, шесть дорожек, 102.84 min общей временной шкалы:

- Все 11 392 слова GigaAM и 29 063 token IDs/pieces совпали. Все 518 speech gate
  window masks совпали. Отличаются три token frame/start и три word end;
  максимальный сдвиг конца слова240 ms. Остальные word timestamps совпали.
- Совпали слова итогового исправленного текста и число применённых замен
  на каждой дорожке (16/3, 5/5, 1/0). Parakeet donor и часть journal timestamps
  различаются. Сама Swift cascade на Swift outputs совпадает с frozen Python.
- Число голосов совпало на всех дорожках: 1/1, 1/6, 1/6. Два слова имеют
  другой speaker assignment. На последней remote дорожке178 интервалов
  против198, activity-mask Jaccard0.978723 на10ms grid; это не DER.
- Для meeting29/remote различие спикера у слова1455.20–1459.58s объясняется
  конкурирующими overlap около350ms: конец Nemotron1455.54 vs1455.55s меняет
  выбор. Сама attribution logic на одинаковых intervals совпадает с Python.
- Merge на Swift outputs совпадает с frozen Python merge. На часовой записи
  совпало тело полного транскрипта; на двух остальных различаются speaker labels.
- SHA-256 всех21 исходных WAV/сохранённых результатов и шести входных копий
  проверены после запуска; frozen Python source не изменился. Данные вне git.

Дополнительный GigaAM export audit: 503 общих tensors побайтово равны,
50 conv weights равны после transpose0/2/1, шесть renamed weights/buffers равны.
LSTM bias не совпадает после объединения двух Swift biases:893/1280 значений,
max0.0009765625. Это подтверждённая разница, но причина token timing differences
не установлена. Называть export полностью идентичным нельзя.

Parent launch-to-exit Swift/Python:288.183/263.122s,124.253/108.305s,
43.666/37.065s. Разовая серия с тёплым file cache, не controlled warm-up+3
и не cold disk. Swift в этой серии медленнее. RSS Swift/Python(MiB):
1649.4/1979.4,1766.3/1225.8,1661.7/1072.6. MLX peak отдельно:
1130.4/1928.7MiB на всех встречах; не складывается с RSS. Уменьшение RSS
не подтверждено на всём корпусе. Отличия compute/loaders/MLX versions остаются.

Четыре loads=1, sequential sources, после каждого Swift teardown active<6KiB,
cache0. Повторно GREEN257 synthetic fixtures и12 subprocess checks; отдельно
GREEN2 BF16 checks: независимый state при смене порядка/одинаковых дорожках и
отказ при изменённом DSP config. Старый INT8 reset output совпал с control.

Команды, raw outputs, source/weights/binary manifests, сравнение и REPORT
сохранены во внешнем corpus-20261030. Продуктовые gates остаются открыты:
причины модельных расхождений, ручная оценка, контролируемые серии, downloader,
contract/cancellation, packaging/signing/UAT. Приложение не подключено.

## Оптимизация GigaAM PoC — 2026-10-31

Проверены и внедрены три разрешённых изменения: однократный F32 cast в cache,
MLX FFT/matmul frontend на прежних assets и max/index без полной Swift Array
copy. GPU argmax измерен и отклонён: readback вырос с0.052 до2.284s.
Итоговый CPU Accelerate readback использует общую MLX memory через публичный
noCopyIfContiguous API и гарантирует lifetime. Лишний lazy reshape также убран.
Это четыре небольших изменения vendor-файлов, новая архитектура не писалась.

Парная серия одного warm-up и трёх новых последовательных процессов на вариант:
две300s дорожки, одинаковые26 окон, same weights/MLX0.32.3, deny network/PATH
без Python. Медиана GigaAM до/после12.339/8.841s, сокращение времени28.4%.
Frontend2.7870/0.0256s, encoder3.8075/3.5059s, decoder4.3652/3.7515s;
readback0.0521/0.0240s входит в decoder и не суммируется повторно.
Раздельные ablations сохранились во внешнем evidence вместе со всеми binaries.
Это warm file cache, не cold-start и не причинное сравнение языков.

Новые полные прогоны тех же трёх встреч:

| Встреча | Swift full до/после, s | GigaAM до/после, s |
|---|---|---|
| hour30 | 288.183/245.566 | 146.693/97.229 |
| meeting29 | 124.253/105.672 | 63.463/43.319 |
| meeting28 | 43.666/37.671 | 20.923/14.813 |

На всех шести дорожках полностью совпали с прежним Swift:11 392 слова,
29 063 token IDs/pieces/frames/timestamps GigaAM, speech gate masks, Nemotron intervals,
Parakeet donor, correction journals и final segments. Все три transcript.txt
совпали побайтово. Прежние расхождения с Python не устранялись и не скрывались.
Идентичность прочитанных weight files проверена SHA-256; checkpoint/quantization
не менялись. Runtime F32 выделен в отдельный ablation, не смешан со сменой языка.

Цена F32: model-only MLX peak557.1→956.4MiB (+399.3MiB), RSS1048.5/1049.4MiB.
В полном конвейере MLX peak1130.4MiB остался прежним, RSS до/после(MiB):
1649.4/2124.8,1766.3/1613.8,1661.7/1525.6. Эти показатели не складываются.
Исторические full before/after не заменяют controlled парную серию.
После каждого model teardown active<6KiB/cache0, все four loads=1.

RED старого F16 loader подтверждён synthetic test до правки. GREEN:
F32 values/cache, Double-DFT reference, frame count/short/silence и оба callers,
max/score/first tie/blank/empty, F16 и noncontiguous input. Повторно пройдены
257 pure-logic fixtures и12 CLI subprocess checks. Python suite:71 tests,
OK с1 skip (`native AEC binary not supplied`); AEC в этой задаче не менялся.
21 исходный файл и6 копий WAV проверены SHA-256, изменений нет.

Команды, snapshots, hashes, metrics и REPORT — во внешнем
`gigaam-optimizations-20261031/`. Cold/empty-cache preparation, app integration,
packaging/signing и capture/UI UAT остаются вне этой одноразовой оптимизации.

## F16 weights с FFT — 2026-10-31

По вопросу пользователя проверен отказ от F32 expansion при тех же FFT и shared
CPU score selection. Текущий PoC хранит исходные F16 weights, F32 frontend assets
и activations сохранены; это не all-F16 inference. Только loader dtype,
его synthetic checks, README и provenance изменены; новых dependencies/flags нет.
F32 binary сохранён вне git, исходники не откатывались.

До loader change тест native dtype упал именно на ожидаемой F16 assertion
(exit -5, RED message), после — GREEN. Проверены cached/uncached F16/F32 dtype
и values, прежние Double-DFT, shape/short/silence, selection/ties/score cases.
Release build,257 logic fixtures и12 CLI checks прошли повторно. Python code
не менялся; предыдущие71 unittest (1 AEC skip) здесь не запускались заново.

Один Mac, те же локальные checkpoints/settings/audio copies, сеть запрещена,
PATH=/nonexistent, последовательные новые процессы. OS cache тёплый. Короткая
серия: warm-up+3 на каждый вариант, порядок чередуется;2x300s,26 окон без speech gate.

| Метрика | F32 cache | Native F16 cache |
|---|---:|---:|
| Median wall, s | 8.848 | 9.648 |
| GigaAM load, s | 1.277 | 1.148 |
| Frontend, s | 0.0257 | 0.0315 |
| Encoder, s | 3.565 | 3.809 |
| Decoder, s | 3.699 | 4.372 |
| Model-only MLX peak, MiB | 956.4 | 557.2 |
| Model-only RSS peak, MiB | 1047.5 | 1049.4 |

Все370 слов/978 tokens/frames/times и per-source text совпали во всех8 runs.
Readback входит в decoder и повторно не складывается. MLX и RSS не складываются.

Полная встреча3659.22s на каждую дорожку: одна современная последовательная
пара F32 → F16, без статистического вывода по RSS или холодному запуску.

| Метрика | F32 cache | Native F16 cache |
|---|---:|---:|
| Full launch-to-exit, s | 243.965 | 259.871 |
| GigaAM load+host+remote, s | 101.732 | 112.670 |
| Full RSS peak, MiB | 2120.5 | 2125.7 |
| Full MLX peak, MiB | 1130.4 | 1130.4 |

В обоих runs RSS уже достигает указанного peak после speech gate, до GigaAM.
Отказ от F32 не уменьшил полный RSS: прежний рост нельзя приписывать F32 weights.
Причина high-water RSS внутри speech gate требует отдельного профилирования; здесь
это не диагностируется по одному getrusage. GigaAM active allocations после
обеих дорожек848.9/424.5MiB; model-only peak ниже на399.2MiB. Full MLX peak
остаётся у Parakeet. F16 выбран для PoC как профиль с меньшими GigaAM allocations,
с явной ценой ~9% на коротком ASR и ~11s на GigaAM часовой встречи; весь run
дольше на~16s, включая вариацию других этапов.

Все7565 GigaAM words и19083 tokens, времена/спикеры, speech gate masks/probabilities,
Nemotron intervals/count, donor, corrections/suggestions, final segments,
baseline и итоговый TXT совпали точно. Это не WER/DER и не устранение прежних
различий Python/Swift. Современный F32 output также совпал с прежним F32 run.
SHA-25621 original files,6 corpus WAV copies и2 micro WAV сохранены.

Внешний evidence: `gigaam-f16-fft-20261031/REPORT.md`, `runs.json`, `comparison.json`,
RED/GREEN logs, binaries/resources и validation/source manifests. App, installed
bundle, capture/AEC не менялись; empty cache, packaging/signing/UI UAT и причины
RSS внутри speech gate не проверены. Product acceptance gates и proposed ADR не закрыты.

## Пересмотр SDD по PoC — 2026-10-31

Пользователь запросил обновить план реализации по полученным данным. В proposal,
design, обеих specs, ADR review и tasks закреплены F16+FFT GigaAM, исходный BF16
Nemotron, Silero v6 F32 и опциональный Parakeet Q8/F16. Известные Python/Swift
differences остаются blockers, exact Swift before/after не закрывает parity.
Бюджеты Air/speech gate — новые предлагаемые цели для review, не пройденные tests.

Дополнительно прочитаны сохранённые metrics, без повторных inference:

| Часовая встреча, две дорожки | Python model-first | Swift F16+FFT |
|---|---:|---:|
| Process RSS peak до speech gate, GiB | 0.963 | 1.028 |
| Process RSS peak после speech gate, GiB | 1.933 | 2.076 |
| MLX active после speech gate, MiB | 1.402 | 1.207 |
| MLX allocator cache после speech gate, MiB | 724.371 | 724.372 |

Python source: внешний `corpus-20261030/reference-stages.py`, result
`hour30/python-bf16-01/metrics.json`; Swift result
`gigaam-f16-fft-20261031/full/0-f16/metrics.json`. Python harness до speech gate имеет
около0.195MiB active. Эти high-water process snapshots не измеряют размер весов,
live RSS или speech gate-only peak; значения RSS/MLX не складываются. Сброс allocator
cache подтверждён прежними release checkpoints, это не reset `ru_maxrss`.

Для контекста INT8 прочитаны прежние Nemotron-only probes на2x300s: INT8 active
102.32MiB/MLX peak551.34MiB/process RSS peak288.50MiB, BF16 соответственно
189.41/597.60/322.45MiB. Sources: `swift-pipeline-runs/probes-v2/probe-nemotron`
и `corpus-20261030/bf16-green-03`. Разные source revisions не позволяют приписать
всю разницу quantization. GigaAM INT8 и квантизация Silero не измерялись;
Parakeet уже Q8, это не предложение новой оптимизации.

Просмотрен pinned Swift FSMN source: local loader и `.all` есть, но feature/score
и waveform arrays полные; memory advantage не доказано. speech gate alternatives и
источники/ограничения вынесены в research, tasks7 остаются backlog.
Новых зависимостей/весов/запусков/продуктового кода в этом пересмотре нет.
Проверка — согласованность требований/сценариев/задач и strict OpenSpec; новые
runtime tests/TDD не нужны для одной правки документов. Прежние PoC tests
не объявляются повторно выполненными. ADR-0002 остаётся proposed.

`openspec validate swift-mlx-pipeline --strict` после пересмотра: PASS.
Численные бюджеты и PoC-факты разделены, задачи3.2a/3.2b/3.4a/4.5a/5.5a/7
остаются открытыми; завершена только документационная задача6.9.

Уточнение по комментарию пользователя: bounded speech gate начинается с чтения исходного
WAV и инкрементального hash с диска, не с нарезки заранее загруженной часовой
waveform. Добавлены сценарии read/decode request limits, feed tail при размере
порции не кратном512, непрерывный state/absolute samples и EOF-only padding.
Memory/time probe включает file I/O/hash/decode; временные WAV-куски не нужны.
Оконный доступ GigaAM/Parakeet и прежний Nemotron preset сохраняются. Это
уточнение спецификации, новая реализация и замеры не выполнялись;3.2b открыт.

## Чтение WAV порциями: отдельный speech gate PoC — 2026-10-31

Пользователь отдельно разрешил проверить память speech gate в PoC. Добавлен executable
`vad-memory-poc`, без изменения основного `pipeline-poc`, приложения или vendor
кода. Модель прежняя Silero v6 F32/strict16k; revision
`2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06`, SHA-256 weights
`65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff`.
Временный model snapshot исчез; тот же checkpoint восстановлен в изолированном
evidence-каталоге и проверен по прежнему SHA, shared cache не менялся.

Mac M3 Pro, 18 GiB, macOS 26.6.2, battery/Low Power Mode, thermal nominal.
Одинаковые host/remote prefixes hour30; warm-up + три fresh processes на режим
и длительность, последовательные запуски с чередованием порядка. Сеть запрещена,
PATH=/nonexistent. Чтение/hash/decode и сохранение JSON входят в launch-to-exit.
Hash всего исходного WAV включён также для коротких prefixes. Кэш ОС не очищался;
фоновая работа Desktop не изолирована. Новые числа не сравниваются по скорости
с прежними историческими запусками при другом питании/нагрузке.

| min на каждую дорожку | whole RSS MiB | stream RSS MiB | whole MLX MiB | stream MLX MiB | whole wall s | stream wall s |
|---:|---:|---:|---:|---:|---:|---:|
| 5.00 | 206.9 | 45.0 | 42.59 | 2.62 | 4.322 | 3.930 |
| 30.00 | 1071.0 | 54.6 | 247.35 | 2.71 | 30.764 | 24.765 |
| 60.99 | 2146.7 | 65.9 | 671.91 | 2.71 | 83.894 | 44.186 |

RSS — process high-water `getrusage`; live RSS `task_info` есть в checkpoints.
MLX active/cache/peak записаны отдельно, peak не сбрасывался; RSS и MLX не
складываются. Абсолютные peaks в таблице — максимум трёх measured runs, времена —
median. Все отдельные значения, включая warm-up, сохранены. Рост median stream
peak 5 → 61 min: RSS 18.31 MiB, MLX 0.04 MiB. После teardown active 12 bytes,
cache 0; gate возврата в пределах 1 MiB от before-model пройден в этой пробе.

Три режима: `whole` хранит обе PCM-дорожки, detection copy и прежний полный
`predictProba`; `slices` сохраняет обе PCM-дорожки, но ограничивает граф и outputs;
`stream` дополнительно читает WAV порциями по 160000 samples/10 s. В обоих
bounded вариантах graph block 320 feeds/10.24 s, async eval каждые 16 feeds как
прежде. State/context непрерывны; EOF padding только один раз на источник,
между источниками state новый. Hysteresis выполняется прежним upstream методом
над непрерывными probabilities; gain/thresholds/окна/таймкоды не меняются.

Один дополнительный часовой `slices` run: peak RSS 691.0 MiB, MLX 2.64 MiB,
wall 43.955 s. Пик RSS уже достигнут при полной PCM-подготовке до модели.
Значит, ограничение графа даёт существенный эффект, а чтение порциями убирает
оставшийся пик полной загрузки. Это одна ablation, не повторная серия; разность
двух high-water значений не считается точной стоимостью отдельных буферов.

Все 24 серийных запуска: probabilities, sample intervals и masks совпали точно
в 12 парах. Полный hour control также точно совпал с speech gate сохранённого прежнего
full run. На часе по 114351 probabilities на источник, accepted windows
host 128/153, remote 139/153. Reader audit stream: полных PCM нет, read/decode
buffer ≤160000 frames, feed buffer ≤160511 samples. Diagnostic probabilities
хранятся целиком для сравнения (около 0.87 MiB на две часовые дорожки), поэтому
весь output этой пробы не является O(1).

Reader/frame RED ловит oversized reads и padding внутри read boundary; GREEN
проверяет samples/order, prefix, SHA multi-read, actual buffer/request bounds,
EOF и неподдерживаемый формат. Реальные model comparisons: речь/ослабленная
речь/шум/тишина, read blocks 127/512/513/1001/160000, отдельная silent source
после speech source; затем empty/1/511/512/513/1025 samples. Вероятности,
интервалы и маски точны. CLI guards нового output/args проверены. Это differential
evidence, не ручная оценка распознавания, WER или DER. Хеши 21 исходного файла
и двух корпусных WAV не изменились; 46 vendor hashes подтверждены.

Первый диагностический hash через `FileHandle.read` удерживал autoreleased
NSData: до модели RSS рос на объём прочитанных файлов. Добавлен autorelease pool
на каждую порцию. Это ошибка новой пробы, а не доказанная причина старого speech gate
пика. Вариант sync readback каждые 16 feeds давал около 8.5 s против 4.3 s на
5 min и отклонён; async eval16/drain320 устранил этот regression. Ранние варианты
и неудачные preflights сохранены отдельно и исключены из итоговой статистики.

Полный внешний отчёт: `vad-bounded-20261031/REPORT.md`; `runs.json`,
`summary.json`, `boundary.json`, `edge-checks.json`, RED/GREEN/build logs,
frozen sources/binary/resources и manifests. Данные остаются вне git.
Полный конвейер после этой оптимизации не измерен и не изменён; нет Air 8 GiB,
cold-cache/app UAT и нового Python comparison. Задача 6.10 выполнена только для
отдельной PoC-пробы. Продуктовые 3.2a/3.2b, численные Air/full gates и ADR-0002
остаются открытыми; это не приёмка app integration.


## F32 GigaAM + bounded audio / chunk audit (2026-10-31)

Пользователь разрешил совместную проверку F32 и порционной обработки в PoC.
Добавлены исследовательские `--bounded-audio` и `--gigaam-f32`; default остаётся
прежним. Веса/настройки неизменны: только optional GigaAM F16→F32 cache.
Bounded speech gate переиспользует проверенный reader/graph; GigaAM/Parakeet читают
прежние25/24s окна с диска. Nemotron пока читает одну полную дорожку за раз,
сохраняет все mel frames и прежний stateful340/40 offline network.

Короткие два300s источника: warm-up+3 новых последовательных процесса на
bounded профиль, чередование порядка. Median wall F16/F32 19.640/18.921s;
GigaAM total8.588/8.204s. Максимальный RSS среди measured repeats1444.9/1446.0MiB,
MLX full peak1130.4MiB у обоих. GigaAM active424.5/848.9MiB.

Полный час, два источника, по одному проходу каждого варианта:

| Вариант | Wall s | speech gate s | GigaAM s | RSS peak MiB | MLX peak MiB |
|---|---:|---:|---:|---:|---:|
| whole F16 | 299.126 | 89.727 | 125.034 | 2128.5 | 1130.4 |
| bounded F16 | 221.244 | 44.690 | 100.366 | 1046.0 | 1130.4 |
| bounded F32 | 209.994 | 43.841 | 87.569 | 1027.7 | 1130.4 |

F32 сократил wall ещё на5.1%, GigaAM total на12.8% в этой часовой паре.
Это один полный проход, не повторная статистика. Снижение времени остальных
этапов нельзя приписывать GigaAM dtype. Порционный вариант одновременно меняет
полную PCM-подготовку, speech gate graph и ASR disk I/O; весь выигрыш не является только
эффектом speech gate. На короткой серии median wall выигрыш3.7%.

Все source fields кроме window runtime, tokens/words/timings/speech gate/diarization/
donor/journal и final files совпали точно во всех четырёх коротких парах и
часовых вариантах. На часе7565слов/19083tokens; новый whole control совпал
также с frozen full F16. Без warnings/fallback, по одной загрузке каждой модели.
Исходные21файла, отдельные input copies и веса проверены до/после, hashes прежние.

RSS — process getrusage high-water, MLX allocations отдельно, без сложения и
без reset между этапами. Cumulative MLX full peak одинаков из-за более высокого
пика Parakeet. Отсутствие роста RSS F32 в этой паре не отменяет дополнительные
424.4MiB active GigaAM; короткие процессы имели больший RSS, чем длинные.
Нельзя обещать memory bound1GiB или переносить цифры на Air8GiB.

Source audit NVIDIA card, speech-swift@a57702e6, Transformers@66f51e76 и
NeMo-Speech.cpp@20999cc9 подтвердил cache-aware Nemotron. Готовый Swift session
есть, но reflect/no-preemphasis frontend отличается от BF16 zero/preemphasis;
фактическая streaming model parity не проверена. Следующий шаг8.1 открыт.

Release build; dtype RED/GREEN; повторные GigaAM frontend/selection, PCM/window,
257logic fixtures и3CLI research guards прошли. Выделенная speech gate probe после
извлечения общего helper точно совпала со frozen31s/block127 result по всем
source fields, включая reader audit. Vendor46hashes подтверждены.

Evidence: внешний `f32-bounded-audit-20261031/REPORT.md`, `CHUNK-AUDIT.md`,
`runs.json`, `summary.json`, `regression.json`, frozen binary/resources/sources
и upstream source copies. M3 Pro18GiB/Low Power Mode/battery, warm OS cache,
сетевой sandbox/PATH без Python, последовательные модели без compilation.
Нет Air8GiB, cold-cache, app/packaging/signing, нового Python baseline comparison
или ручной оценки качества. F16 product profile, ADR proposed и задачи2–5
остаются без приёмки. В приложение не подключено и не установлено.


## AC F16/F32 retest (2026-10-31)

По запросу пользователя повторена короткая и часовая серия с bounded audio,
одним frozen binary/resource bundles и прежними весами/settings. Runtime не
менялся/не пересобирался. Проверено по реальным progress events всех18процессов:
Nemotron host→remote, speech gate host→remote, GigaAM host→remote, Parakeet host→remote;
каждая модель загружена один раз. Внутри ASR этапа сначала все окна host,
затем все окна remote, без параллельного inference. Model state сбрасывается
между источниками, teardown до следующей модели. Nemotron wrapper пока сохраняет
полную PCM/mel одной дорожки; network340/40 уже stateful chunked.

Первый пилотный F16 warm-up застал Battery→AC. После подтверждения питания от
сети первая полностью AC-пара (iteration1) явно назначена warm-up для обоих
профилей; measured iterations2/3/4 собраны отдельно, порядок чередовался.
Iteration0/1 сохранены как исключённые paired raw observations; исходный manifest
не удалён. Короткая серия запущена заново после длинной: warm-up+3 новых процесса
на профиль. Все measured pre/post snapshots подтверждают AC/Low Power Mode0;
периодические snapshots также показывают AC. Батарейные результаты не смешаны.

| Аудио/профиль | Median wall s | Median GigaAM s | Max measured RSS MiB | MLX peak MiB |
|---|---:|---:|---:|---:|
| short/bounded-f16 | 17.184 | 7.690 | 1446.6 | 1130.4 |
| short/bounded-f32 | 16.408 | 7.129 | 1446.3 | 1130.4 |
| full/bounded-f16 | 198.246 | 91.437 | 1452.5 | 1130.4 |
| full/bounded-f32 | 194.932 | 79.943 | 1446.0 | 1130.4 |

F32 сокращает median full wall на1.67%, GigaAM total на12.57%; короткий full
wall на4.51%. Парные long wall gains4.13/1.56/0.76%. Это3повтора на профиль,
не универсальный выигрыш5%. Parakeet в длинных F32-проходах медленнее во всех
трёх measured парах: median58.781s против54.557s у F16. Причина не профилирована;
это не смена модели Parakeet и не доказанная фоновая помеха. speech gate тоже имеет
разброс, хотя выполняется до GigaAM; нельзя приписывать его время GigaAM dtype.

Max measured RSS близок, но individual peaks сильно меняются между процессами:
у F32 один исключённый AC warm-up достиг1665.2MiB; все raw/warm-up данные
показаны отдельно. Дополнительные active GigaAM allocations сохраняются:
424.5→848.9MiB; full MLX peak1130.4MiB у обоих из-за Parakeet. RSS и MLX не
складываются, RSS1GiB не является верхним пределом. Teardown MLX cache0/active
менее1MiB проверен во всех18процессах и не означает уменьшение RSS high-water.

Все9пар (с pilot/warm-ups) и каждый результат против frozen whole-F16 control
совпали точно по source content кроме window runtime и final files. Long:
7565слов/19083tokens; short:370слов/978tokens. Нет warnings/fallback. Хеши
исходных21файлов, input copies и весов до/после прежние; runtime source hashes
также не изменились. Это Swift precision/orchestration comparison, не Python
parity, WER или DER.

Полный отчёт, individual runs, команды, raw/analysis classification и hashes:
внешний `f32-bounded-repeat-20261031/REPORT.md`, `runs.json`, `initial-runs.json`,
`short-ac/runs.json`, `summary.json`, `telemetry.jsonl` и `validation.json`.
M3 Pro18GiB, prepared warm OS/Metal cache, desktop workload не контролировался;
system swap занят ещё до старта, его общий объём не приписывается worker.
Inference с запрещённой сетью и PATH без Python/uv; Python только во внешнем
измерительном harness. Нет Air8GiB, Parakeet off, cold-cache, нового Python
comparison, packaging/signing или app integration. Задача6.12 выполнена;
продуктовые acceptance gates и базовый F16 profile автоматически не меняются.


## UAT baseline-speaker corrective candidate (2026-11-03)

Beta7 physical UAT failed after source processing at merge with `Некорректная ссылка в расшифровке: голос слова bw_h_4`. The real model outputs were not captured/reproduced; no user recording was read for this pass. The owner explicitly authorized one narrow correction, plan independently reviewed PLAN_PASS before changes.

Actual production regressions first showed semantic RED: mixed [1,1,1,2] and [nil,nil,nil,1] candidates lost the final original identity; extracted unchanged Stage6 threw `голос слова bw_h_2`, and independently `голос слова bw_r_1`. A compilation error in the initial test attempt is recorded separately and is not RED evidence.

Minimal shared fixes: reject mixed-original-speaker candidates before selection; register all final and actually serialized baseline references per source, using the same complete host maximum for remote offset. Baseline substitution for disabled/failed correction and strict Core validation are unchanged. Stage6 moved to an internal pure function called by actual PipelineRunner and synthetic regression tests, not a parallel implementation. No broader cascade parity work.

`focused-green`:28 tests/4 suites passed. `suite-model-free`:192 Core/Application +28 Pipeline +15 App =235 tests/25 suites passed on final product code. A later same-speaker test refinement uses actual alfa→alpha correction and receives a focused rerun. AudioMixer3, EchoCanceller2, ModelAssets10 and ModelVendorGraph7 are deliberately excluded (22 tests) under HARD no-audio/no-model-call scope. No Python packages/tests, model inference/downloads, old matrices or real audio checks ran. Release-all arm64 passed; boundaries/evaluated transitive graph passed. Accepted15SHA bootstrap/30s JSONAAC/AEC2 remain historical at their original bounds.

Exact per-command cwd/start/end/status/stdout/stderr, RED/GREEN logs, final signing/bundle/source manifests and incremental before diff live in the coordinator-owned run's `completion-native-only/uat-baseline-speaker/`. At that authoring handoff this was corrective-candidate evidence, not coordinator acceptance, full model quality/parity or physical UAT. Independent implementation review and physical UAT were pending; installed beta7 was untouched. Later acceptance and installation are recorded below.


Final corrective-candidate packaging: `focused-final` passed28 tests after the same-speaker assertion refinement. `swift build -c release --arch arm64` and `CODESIGN_IDENTITY='Interview Recorder Code Signing' ./scripts/build-app.sh` passed on final product code. Dist is `2.0.0-beta.8`/build44, `local.meeting-companion`; final App and Worker report `Authority=Interview Recorder Code Signing`. Explicit `codesign --verify --deep --strict --verbose=4` and final `check-bundle.sh` passed. Bundle/source/input manifests and exact App/Worker/CLI SHA-256 are saved with raw commands under the pass evidence directory. During that writer pass no installation, application launch or physical/model UAT occurred; independent implementation review and physical UAT were still pending.


## Final beta.8/build44 acceptance and owner GUI UAT (2026-11-03)

Independent implementation review: **PASS**, no material findings, R1–R4 closed.
The coordinator accepted the production guard, complete final/serialized-baseline
speaker registry and shared host offset, unchanged strict validator, and actual
App/CLI→Platform→Worker→PipelineRunner assembly route. Post-review the189-path
source/binary/CLI/patch freeze and all154 actual bundle entries (bytes, modes,
symlinks) were unchanged. The final selected model-free suite remains235 tests
(192 Core/Application +28 Pipeline +15 App), with a later28-test focused rerun;
22 audio/model tests were deliberately not rerun. This is not full257 execution.

On the owner's explicit installation request, the accepted signed beta.8/build44
replaced beta.7/build43 in Applications after idle-process preflights. Stable
bundle ID and exact App/Worker Authority were retained; staged and installed
signature, bundle and all154 manifest entries matched acceptance. Installation
itself did not launch the app, run models or change user recordings/preferences.

The owner subsequently reported «вроде работает» and «аудио тоже норм», then
explicitly confirmed the remaining requested scenarios: «работает» and
«все эти сценарии работают». Accepted owner GUI UAT covers recording → transcript
and audio; saved word/speaker-name corrections surviving close/reopen; retry with
unsaved-edit admission and a new single current result; cancellation then retry.
The requested **beta GUI UAT is PASS (owner-confirmed)**. No additional automated
inference/audio run was used to infer this result. Exact device/backend/permission
variants and durations were not independently measured; this does not establish
model equivalence, WER/DER, performance, both capture backends or extended mute/
delayed-delivery/permissions coverage. Recovery of the earlier failed recording
was not separately identified by the owner.

The coordinator run retains `completion-native-only/uat-baseline-speaker/`
`independent-review.md`, `coordinator-acceptance.md`, `coordinator-post-review.json`,
`installation.json`, `installation-commands.json`, contract/checkpoint owner
observations, and closure status/diff. Earlier failures and snapshots remain
historical evidence. The current narrow beta delivery is accepted; broader
unchecked research/extended-UAT tasks remain unverified. No Git commit, push,
publication, migration or OpenSpec archive was performed by this closeout.
