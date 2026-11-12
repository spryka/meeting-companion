> Закрыто по приёмке владельца 2026-11-06. Оставшиеся `[ ]` — исторические снятые проверки/исследования, а не незавершённые обязательства и не PASS. Без follow-up/backlog. Решение: [итоговая приёмка](../../../../docs/beta30-acceptance.md).

# Текущий план реализации (актуализирован 2026-11-02)

Статус на 2026-11-04: согласованная продуктовая поставка принята владельцем и
закрыта; см. [итог приёмки](../../../../docs/native-completion-acceptance.md).
Непроведённые исследовательские и расширенные проверки ниже сохраняются как
история без ложных отметок выполнения; они не блокируют новую спецификацию.

База: `master` `520f7d3a9d826d14c26380dc502aa3007b531760`, включая редактор.
Владелец разрешил начало реализации в прежней границе отдельного Swift worker.
Границы модулей и порядок их выделения приняты владельцем 2026-11-02:
[design.md](design.md).

Порядок: проверить текущий контракт редактора/превью → отдельные проверяемые
части worker с TDD → текущие model/full checks → интеграция приложения.
Незакрытые продуктовые задачи не считаются выполненными благодаря PoC.

## 1. Исходное состояние и согласование

- [x] 1.1 Прочитать AGENTS/CONTRIBUTING, pipeline docs, действующие ADR и относящиеся активные changes. Создать изолированный worktree без переноса чужих dirty changes.
- [x] 1.2 Сохранить внешний Python full-MLX snapshot, SHA-256 source/weights, configs/dtypes/environment. Проверить реальные прежние JSON результатов и новый offline run на копиях. Повторить Python tests; результаты в baseline.md.
- [x] 1.3 Проверить готовые Swift source/licenses/loaders/timings/quantization/MLX ranges. Зафиксировать ошибку toolchain, не считать Swift tests выполненными; research.md.
- [x] 1.4 Актуализировать proposal/specs/design/ADR по команде владельца 2026-11-02: сохранить процессную границу и профиль, закрепить текущую базу редактора, JSON v1 и превью. Разрешено начало реализации; runtime gates и продуктовая приёмка не объявлены пройденными.
- [x] 1.5 Согласовать ADR-0003 и карту модулей в design.md до переноса кода между SwiftPM targets. Проверено соответствие ADR-0001/0002; владелец принял спецификацию и разрешил выполнение через sdd-orchestrate 2026-11-02.

## 2. Toolchain, dependencies и сравнимые профили

- [x] 2.1 Проверить поддерживаемые Xcode/Metal tools, воспроизвести upstream build/tests в изолированном каталоге. Xcode 27.2 / Swift 6.4.2 / Metal 32023.922: реальная Metal compilation/link, stock GigaAM release build и 7 upstream tests в debug/release, GPU eval/sync MLX 0.31.3 и 0.32.3 — PASS. Координатор повторил GPU probes и 7 release tests с запретом сети; независимое ревью PASS. Глобальный developer path и исходники проекта сохранены. См. verification.md; продуктовые зависимости и модели этим не принимаются.
- [x] 2.2 Зафиксировать минимальный source closure GigaAM/SpeechVAD, MLXAudio products и общий MLX 0.32.3; подтвердить resolve/build/test, записать upstream SHAs, patches и transitive licenses. При существенном новом порте остановиться и пересогласовать. Проверены pinned graph, source/patch/license inventory, GPU eval/sync; 7 model/vendor checks + 200 прежних Swift tests, release, Python 107 tests (1 skipped), независимое ревью PASS. См. verification.md; model/parity и упаковка остаются открытыми.
- [x] 2.3 Подтвердить численные GigaAM tensors/tokenizer/frontend, strict-load и dtype текущих pinned profiles. Для Nemotron использовать выбранный исходный BF16 checkpoint и прямое сравнение Python/Swift. Проверены 561 tensors/1024 tokenizer pieces, полный 560/561 bridge, strict negative fixtures и synthetic selected-profile Python/Swift; независимое ревью PASS. Дополнительный Double64 diagnostic сохранил FAIL и отдельно разобран как ненормативный критерий; corpus/parity/UAT этим не закрываются. См. verification.md.
- [x] 2.4 Перед новой продуктовой серией закрепить corpus/held-out, settings, команды, instrumented manifests и численные критерии. Подготовить отдельные copies/results, hashes до/после. Закрепить полный baseline environment, не разрешать пакеты заново. Проверены 20 immutable WAV, исходные PCM slices, source/model/environment identities и 32 регрессии; независимое ревью PASS. Frozen grouping 15 s и product 30 s/punctuation 15 s разделены, same-profile gates сохранены. Inference, speech coverage и consumer 8+8 этим не проверены; см. verification.md.
- [ ] 2.5 В отдельной Python копии проверить model-first против frozen channel-first: сначала RED/GREEN orchestration/state/progress, затем integration parity и замеры по общей методике. Зафиксировать patch/revision, расписание и фактические загрузки; baseline не менять. Подготовить Python model-first для сравнения со Swift при одинаковом расписании.
- [ ] 2.6 Зафиксировать текущие revisions/control и проверить новые model/full результаты по evaluation spec. Фактические отклонения локализовать, исправлять или отдельно согласовывать.

## 3. Отдельные модели

- [ ] 3.1 Сначала RED на GigaAM empty/short padding, token trace, baseline word end, seams/validation; минимальный adapter, затем GREEN. Строгая локальная загрузка и integration run на одинаковом аудио.
- [ ] 3.2 Сначала RED на speech gate branch completeness, boosted detection copy, 25/24 grid, sample intervals и masks; минимальный adapter, затем GREEN. Моделями проверить 100/25/5% речь, seams, тишину и шум.
- [ ] 3.2a Сначала speech gate-only и profiling trace: current/peak RSS до WAV/до модели/после каждого источника, MLX active/cache/peak отдельно, PCM/boost copies и retained graph/state;5/30/60min на тех же prefixes. Не считать cumulative peak расходом весов speech gate.
- [ ] 3.2b RED/GREEN чтения WAV и SHA-256 порциями с диска без предварительной полной загрузки/декодирования и без temp WAV chunks; bounded read requests/live PCM buffers.512/64 feed state, неполный хвост, block-size invariance (включая не кратные512), seams/EOF, source reset и fallback. Точные masks/intervals и downstream content против прежнего Swift Silero v6; затем file-to-mask warm-up+3 memory/time runs, включая reader/hash, по методике evaluation spec. Не менять модель/агрегацию/ASR окна ради результатов памяти.
- [ ] 3.3 Сначала RED на Nemotron source labels, overlap, short intervals, limit warnings и thresholds; adapter к готовому offline API, затем GREEN. Сравнить probability/frame/state/segments/count с frozen Python и bridge профилями.
- [ ] 3.4 Сначала RED на Parakeet subword join, seam/order/bounds и FP16/Q8 profile validation; adapter и GREEN. Проверить donor tokens/words и тишину реальными весами.
- [ ] 3.4a Обеспечить public Parakeet timing API upstream либо объявленный public pinned adapter с tests/notices. Обычный release build без `@testable import`/`-enable-testing`; exact tokens/words/seams/journals на corpus/held-out до/после.
- [ ] 3.5 Сохранить model-level отчёт и verdict по каждому strict gate; не переходить дальше с необъяснённым различием или нерабочей моделью.

## 4. Управляющая логика и полный CLI worker

- [x] 4.0 Выделен общий Core-контракт (`MeetingCompanionCore`), изоляция MLX в worker-only `MeetingTranscriptionPipeline`/executable `MeetingTranscriptionWorker` по design.md. MLX полностью исключен из dependency closure App и CLI. Реализованы нативный pipeline, streaming worker CLI, progress protocol, subprocess runner с корректной эскалацией SIGTERM->SIGKILL и тесты валидации.
- [ ] 4.1 RED/GREEN для speaker assignment и ties, SequenceMatcher/cascade/STOP/чисел/дефисов/conflicts, merge/paragraphs и warnings. Differential fixtures плюс независимые assertions, без личных текстов.
- [ ] 4.2 На канонической базе `520f7d3` реализовать native producer JSON v1 через RED/GREEN: общие fixtures, текущие reader/selection/edits/export, atomic versions, nullable fields, result/edits/audio immutability, journal/mix/write failure, legacy paths и symlink/source alias guards. Сохранить отдельный Quick Look `<base>.m4a` и mix выбранной версии; не менять UI/схему и не копировать dirty files. Начать с тестов этой границы, затем подключать модельные выходы. Для grouping брать текущий `transcribe.group_turns`: 30 s max, punctuation split после 15 s и pause < 2 s; прежний PoC с 15 s limit не копировать как контракт.
  - [x] 4.2a Через TDD добавить encoding существующего `TranscriptDocument` (JSON v1) для будущего native producer: шесть общих fixtures, семантически точный round-trip с явными null, ID/таймкодами и чтением текущим валидатором. RED: шесть runtime failures отсутствующего Encodable; GREEN: шесть round-trip cases, полный набор 189 Swift tests / 18 suites и release build PASS. Decoder/validation неизменны; см. verification.md. Это сериализация, не построение результата из моделей, publication/mix или app integration.
- [ ] 4.3 RED/GREEN native worker args, progress protocol и partial failures. Сохранить AEC helper, перенести только wrapper, проверить args/output/bypass/failure/timeline с тем же helper.
- [ ] 4.3a RED/GREEN model-first lifecycle: одна загрузка каждой нужной модели, последовательный host/remote, чистый state после источника и допустимого сбоя, teardown до следующей модели, GigaAM baseline до Parakeet. Проверить монотонный progress при skipped/fallback/empty/Parakeet/AEC on/off. Реальными моделями сравнить оба порядка источников со свежими независимыми запусками; измерить память отдельно от allocator cache.
- [ ] 4.4 RED/GREEN bounded cancellation, SIGTERM/SIGKILL, child teardown, EOF, retry и отсутствие false success/visible staging. Проверять реальным subprocess, а не только mock.
- [ ] 4.4a Перенести проверенный оконный disk reader GigaAM/Parakeet: bounded PCM и SHA без полной загрузки WAV/temp chunks; RED/GREEN samples/offsets/overlap/short tail, speech gate fallback и Parakeet off. Затем exact corpus/held-out outputs против full-PCM Swift control. Ограничение полного PCM/mel Nemotron учитывать отдельно.
- [ ] 4.5 Выполнить последовательные per-model/full-pipeline серии: warm-up + 3 новых процесса на профиль, чередование порядка, startup/load/stages/total, RSS отдельно от MLX, hashes и held-out. Отдельно показать эффект расписания Python channel-first/model-first и языка Python/Swift model-first, а также source/precision bridges. Сохранить raw evidence вне git.
- [ ] 4.5b Перед любым предложением сменить базовый F16 на F32 выполнить precision ablation из evaluation spec: exact corpus/held-out и full warm-up+3 F16/F32, Parakeet on/off, на доступном Mac, active/cache/peak и pressure/swap. Зафиксировать выбор профиля отдельно; разовый full PoC не принимает его автоматически.
- [ ] 4.6 Составить comparison report по всем gates, source/precision bridges, differences и ограничениям. Получить приёмку отчёта перед подключением к приложению.

## 5. Приложение и тестовая поставка

- [x] 5.0 Выделены Foundation-only `MeetingCompanionApplication` и `MeetingCompanionPlatform` по ADR-0003 и карте design.md. Перенесены и покрыты тестами: единая очередь `ProcessingService` (серийное выполнение, снэпшот настроек при enqueue, отмена, фильтрация устаревших событий), сервисы жизненного цикла сессии записи `RecordingSessionService` и персистентности истории `RecordingHistoryRepository`. Реализованы App/CLI composition adapters (`PlatformTranscriptionRunner`, `PlatformAudioExporter`, `PlatformAudioCaptureController`). Pass3 CHANGES_REQUESTED сохранён как история; последующие standard-layout и baseline-speaker ревизии получили независимый PASS. Владелец подтвердил запись/текст/аудио, правки/reopen, retry/draft admission и cancel/retry на установленной beta.8/build44. Расширенный аппаратный UAT 5.0b остаётся отдельным.

  - [x] 5.0a Перенести существующие macOS adapters Core → Platform без изменения поведения: `AudioCapture`, `RecorderCore`, `SourceAudioFiles`, subprocess-клиент `Transcription`, AVPlayer transport. Оставить Foundation DTO/progress/paths и существующий редактор в Core; обновить зависимости, linker settings и импорты App/CLI. Автоматическая проверка среза завершена: boundary RED/GREEN, 200 Swift tests / 19 suites, release build и независимое ревью PASS; [evidence](verification.md). В логах этот срез обозначен внутренним кодом `NTR-MOD-1`.
  - [ ] 5.0b Выполнить физический UAT переноса 5.0a: оба backend записи, permissions/retry, mute/delayed audio/preview, playback/seek/windows. Статус `WAITING_UAT`.

  Core/Application/Platform/Pipeline/Worker выделены в текущей ветке; перенос
  adapters 5.0a не является доказательством всего lifecycle. Pass3 был отклонён по marker duplication/draft loss. Новый single-current scope удаляет
  selection callback/format gate, сохраняя transient terminal status, artifact capabilities,
  read-only TXT, reattachment и off-MainActor history I/O. Финальная независимая
  приёмка standard-layout и beta.8 baseline-speaker завершена PASS; владелец
  подтвердил запрошенные beta GUI-сценарии. Расширенные hardware/permissions
  проверки и исследовательские model/parity gates этим не закрываются.
- [x] 5.1 RED/GREEN для runner/preparation/diagnostics: native executable вместо run.sh, прежние flags/events/queue states, cancellation/retry и модельные ошибки. UI только для требуемых строк подготовки.
- [x] 5.2 RED/GREEN pinned downloader/local manifest: empty cache, SHA/revision, traversal/symlink, corrupt/incomplete files, HTTP failures, отмена, повтор и атомарная публикация без удаления рабочего cache.
- [x] 5.3 Удалить Python/uv/runtime packages из test bundle, сохранить baseline вне поставки. Проверить worker dependency isolation, Metal resources/dylibs, а также licensing/provenance derived Parakeet до упаковки.
- [x] 5.4 Обновить README/CHANGELOG/THIRD_PARTY/AGENTS/pipeline docs только проверенными native командами. Собрать release test bundle с прежними ID/storage/signing identity, проверить nested signatures и отсутствие Python dependencies.
- [ ] 5.5 На этом Mac проверить isolated empty-cache preparation, offline check/full processing с Parakeet on/off, ошибки загрузки, отмену и retry, legacy/editor contract. Отдельно capture/AEC regression UAT, без изменений DSP и установленного приложения.
- [ ] 5.6 Проверить требования против tests/UAT, строгую OpenSpec validation и релевантные Swift checks. Передать отчёт, hashes и подписанный test bundle в dist. Не устанавливать, не публиковать, не архивировать незавершённый change. Исторический beta.4/build40 прошёл 247 Swift tests и packaging checks, но получил CHANGES_REQUESTED по шести production-boundary дефектам. Pass3/beta.5 также получил CHANGES_REQUESTED; его evidence сохранён. Beta.6 single-current — новый явно разрешённый scope, checks/hashes отдельно в verification.md. Независимая приёмка и beta UAT этим не заявляются.

  - [x] 5.6a Закрыть текущую native-only beta-поставку в согласованном scope: независимый PASS, проверенная установка beta.8/build44, пользовательское подтверждение записи/текста/аудио, правок с reopen, повторной обработки с draft admission и отмены с retry. Итог и границы — в verification.md. Не означает выполнения всех исследовательских и расширенных gates 2–5, Git-публикации или архивирования change.

## 6. Выполненные исследовательские PoC (2026-10-30/31)

Пользователь разрешил этот эксперимент отдельно от согласования proposal/ADR
и продуктовых задач 2–5. Его успешный запуск не закрывает их parity/acceptance gates.

- [x] 6.1 Собрать общий release graph MLX0.32.3 с готовыми реализациями; закрепить upstream revisions, manifest patch, adapters и vendor hashes.
- [x] 6.2 Выполнить strict local load и offline inference всех четырёх моделей отдельно, затем обеих дорожек в model-first CLI. Подтвердить четыре загрузки и teardown MLX allocations.
- [x] 6.3 Проверить pure logic по 257 synthetic Python fixtures и assertions; подтвердить RED/GREEN arithmetic regression GigaAM end.
- [x] 6.4 Сравнить raw tokens/words/masks/intervals/donor/journal/final transcript с frozen Python reference и сохранить различия профилей вне git. Не объявлять полную эквивалентность моделей или преимущество Swift.
- [x] 6.5 Завершить финальные subprocess regression checks и проверку документов; внешний отчёт, ограничения, воспроизводимые команды. App integration и test bundle остаются отдельным следующим этапом после приёмки сравнения.

- [x] 6.6 Адаптировать готовый Nemotron к исходному BF16 checkpoint, проверить RED/GREEN, независимый state и полный корпус из трёх встреч; сохранить различия и новые замеры отдельно от прежнего INT8 эксперимента.

- [x] 6.7 Оптимизировать GigaAM PoC по разрешённым пользователем трём пунктам: F32 weights при загрузке, FFT/mel frontend и readback без полной копии scores (GPU argmax проверить измерением). Подтвердить проверки и последовательные before/after замеры, сохранить текст/token/timing differences и memory trade-offs.
- [x] 6.8 Проверить хранение GigaAM weights в исходном F16 с тем же FFT/frontend и shared readback: RED/GREEN dtype checks, последовательная F32/F16 пара на одинаковом аудио, полный часовой конвейер, точные результаты и раздельные RSS/MLX peaks. Выбрать профиль PoC по измерениям, не объявлять F16 weights полностью F16 inference.
- [x] 6.9 Обновить SDD по подтверждённым PoC данным: текущий profile, разграничение exact Swift ablation и Python parity, speech gate memory attribution и public timing API. Проверить согласованность ADR review и strict OpenSpec; приложение/пороги существующей parity не менять.
- [x] 6.10 Отдельный `vad-memory-poc`: RED/GREEN bounded WAV reader/feed tail/SHA, прежний Silero v6 против чтения с диска порциями. Последовательные 5/30/61 min, warm-up + 3 fresh processes каждого режима, точные probabilities/intervals/masks и frozen original speech gate; отдельно full-PCM/bounded-graph ablation и empty/short/EOF/source reset. Сохранить время, RSS/MLX, input hashes и отчёт вне git. Основной конвейер, продуктовые задачи 3.2a/3.2b остаются открытыми.

- [x] 6.11 Проверить совместно bounded speech gate/ASR disk reader и optional F32 GigaAM weights: dtype RED/GREEN, shared-helper/reader/window/logic/CLI regressions; short warm-up+3 pairs и три последовательных часовых варианта, exact full outputs и hashes, RSS/MLX отдельно. Аудит всех стадий и готовых Nemotron streaming реализаций; полный PCM/mel Nemotron и product gates оставить открытыми. Evidence `f32-bounded-audit-20261031/`.

- [x] 6.12 Повторить bounded F16/F32 сравнение на AC/Low Power Mode off: short300s и full61min, warm-up+3 новых последовательных процесса на профиль, чередование порядка; переход питания исключить из измеряемой серии с явным raw/analysis ledger. По progress events подтвердить model-first host→remote и четыре загрузки. Exact outputs, RSS/MLX, power/pressure/swap и неизменные hashes; сохранить все individual/warm-up результаты вне git. App и Parakeet off не считать проверенными.

## 7. Следующая исследовательская проверка Nemotron

- [ ] 7.1 Переиспользовать готовое stateful chunk scheduling speech-swift с bounded BF16 frontend: прежние zero padding/preemphasis.97/floor frames и абсолютная фаза, core340/right40/cache264/FIFO40/update300. Сначала RED/GREEN mel frame boundaries/EOF/short tails/source reset; затем actual BF16 exact mel/probabilities/state/intervals/overlap/count против whole-file PoC. Никаких независимых клипов/смены preset или backend. Измерить reader/frontend/full time и RSS/MLX отдельно; отсутствие model parity блокирует замену текущего пути. Наличие upstream streaming API не закрывает задачу.


## UAT baseline-speaker correction (2026-11-03)

- [x] U1 Confirm semantic RED for cross-speaker cascade and actual Stage6 baseline-only speaker assembly, then minimal GREEN; same-speaker, nil/explicit identity and strict unknown-reference checks.
- [x] U2 Check host/remote baseline identities, remote offset, disabled/failed signatures, JSON roundtrip and normal publication through production assembly; run appropriate model-free Swift suite.
- [x] U3 Release all, module boundaries, strict OpenSpec, signed beta8/build44 and frozen source/bundle evidence; independent PASS and owner-confirmed requested beta GUI UAT completed.

- [x] U4 Record independent PASS/R1–R4 closed and post-review189-path/source/binary/patch plus154-entry bundle identity verification.
- [x] U5 Install accepted beta8/build44 on explicit owner request; record owner-confirmed recording/transcript/audio, persistent text/name edits, draft admission/reprocessing and cancel/retry. Full model parity and extended hardware/permission UAT remain unverified.
