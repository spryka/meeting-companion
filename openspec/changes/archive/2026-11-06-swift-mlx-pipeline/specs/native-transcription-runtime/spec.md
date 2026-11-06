## ADDED Requirements

### Requirement: Enforced module dependencies

Приложение SHALL разделять контракты/хранение (Core), сценарии (Application),
macOS adapters (Platform), обработку (Pipeline) и UI отдельными SwiftPM targets
с зависимостями по design.md. Core/Application SHALL собираться без AppKit,
SwiftUI, Combine, AVFoundation, ScreenCaptureKit и MLX. App/CLI SHALL использовать
общие application services; MLX SHALL входить только в dependency closure worker.

#### Scenario: Build the application layer independently
- **WHEN** собираются Core/Application и выполняются их tests
- **THEN** они не требуют App target, окон, capture frameworks или model weights
- **AND** Package graph и imports соответствуют разрешённым зависимостям

#### Scenario: Replace the presentation
- **WHEN** UI заменяется другим представлением тех же команд и snapshots
- **THEN** запись/остановка, очередь, подготовка, retry/cancel и review services доступны через Application без вызова view model
- **AND** JSON v1, edits/CAS, неизменяемые resultID/edits и пути обоих audio previews сохраняются; GUI следует [refresh W01/W04](../../../2026-11-06-refresh-macos-interface/specs/desktop-workspace/spec.md) без saved undo/history/special Cmd-Z, со стандартным field undo и Cancel

### Requirement: Application-owned processing lifecycle

Application service SHALL владеть единственной последовательной очередью
export/transcription, состоянием jobs и историей независимо от окон. Настройки
SHALL фиксироваться при enqueue. Capture SHALL работать независимо от очереди;
process I/O, обработка аудио и чтение больших файлов SHALL выполняться вне MainActor.

#### Scenario: Close and reopen the processing UI
- **GIVEN** job выполняется с зафиксированными Parakeet/AEC settings
- **WHEN** окно закрыто, настройки UI изменены и создан новый view model
- **THEN** тот же job продолжается с прежними settings, новый подписчик получает текущий snapshot
- **AND** завершение сохраняется в общей истории; новый worker для того же job не запускается

#### Scenario: Cancel and retry without stale updates
- **WHEN** job явно отменён и после подтверждённого завершения worker запрошен retry
- **THEN** retry получает собственную идентичность, поздние события предыдущего запуска не меняют его состояние
- **AND** завершённой считается только обработка с успешным exit и проверенными опубликованными артефактами

#### Scenario: History persistence fails
- **WHEN** application service не может сохранить metadata или выбор версии
- **THEN** ошибка доступна UI/CLI через application state, успешное сохранение не заявляется
- **AND** прежние результаты/правки/аудио сохраняются, повторная команда использует текущее подтверждённое состояние

### Requirement: Reuse editor and recording boundaries

Выделение модулей SHALL сохранять текущие repositories, review session,
playback transport и capture backend с их validation/locking/actor isolation.
Application SHALL владеть recording session и состоянием start/stop/mute;
окна, drafts, follow и форматирование SHALL принадлежать App. Busy guards
SHALL основываться на application state для recording/preparation/processing.

#### Scenario: Finalize a recording during processing
- **GIVEN** другая запись уже находится в очереди обработки
- **WHEN** recording session завершает текущий capture
- **THEN** финализированные WAV добавляются в общую очередь без остановки текущего job
- **AND** сохранены timeline/mute/capture warnings; установка и завершение приложения защищены текущими guards

#### Scenario: Review after extraction
- **WHEN** существующий редактор открывает версию после переноса компонентов
- **THEN** current selection, правки/CAS, export и playback сохраняют контракты; workspace/modal editing следует refresh W01/W04 без saved undo
- **AND** закрытие workspace после разрешения modal input завершает review session/playback, сохраняя processing jobs

### Requirement: Isolated native worker

Приложение SHALL запускать bundled Swift worker для одной записи, без Python,
uv и shell launcher. Модели и MLX SHALL находиться только в worker process.

#### Scenario: Successful processing
- **GIVEN** локальные модели подготовлены
- **WHEN** очередь запускает обработку записи
- **THEN** worker последовательно обрабатывает host и remote внутри каждого этапа модели, сохраняет результат и завершается
- **AND** процесс UI/capture не загружает MLX и веса

#### Scenario: Worker failure
- **WHEN** worker завершается с ошибкой или сигналом
- **THEN** UI сохраняет запись и лог, показывает сбой и допускает повторную обработку
- **AND** recorder process остаётся работоспособным

### Requirement: Model-scoped lifetime and independent source state

Worker SHALL выполнять Nemotron → VAD → GigaAM → необязательный Parakeet,
последовательно обрабатывая host и remote одной загруженной моделью на этапе.
Worker SHALL создавать чистое inference state для каждого источника, сохранять
раздельные метки голосов и освобождать модель/state/tensors до следующей модели.
Исходный GigaAM с назначенными спикерами SHALL сохраняться в staging до Parakeet.

#### Scenario: One load per enabled model
- **GIVEN** две непустые дорожки и все четыре модели требуются для inference
- **WHEN** запись успешно обработана
- **THEN** каждая модель загружена один раз, всего четыре загрузки
- **AND** отключённый Parakeet не загружается, inference разных источников не выполняется одновременно

#### Scenario: Source state isolation
- **WHEN** источники обработаны одной моделью в прямом и обратном порядке
- **THEN** результат каждого источника проходит те же parity gates относительно отдельного запуска со свежей моделью
- **AND** история голосов, VAD context и decoder state другой дорожки не влияют на результат

#### Scenario: Failure before the second source
- **WHEN** inference первого источника завершается допустимым для продолжения сбоем VAD, Nemotron или Parakeet
- **THEN** warning/fallback привязаны к затронутому источнику, второй получает чистое состояние
- **AND** исходный GigaAM сохранён при сбое Parakeet, fatal ASR не публикует успешную версию

### Requirement: Explicit preparation and offline inference

Система SHALL скачивать только веса pinned manifest при явной подготовке,
проверять immutable revision, файлы и SHA-256 и публиковать snapshot атомарно.
Inference SHALL использовать local directory API без сетевых запросов.

#### Scenario: Empty isolated cache
- **GIVEN** app-owned cache пуст и Python/uv отсутствуют
- **WHEN** пользователь выполняет подготовку
- **THEN** скачиваются нужные snapshots и диагностика подтверждает strict local load всех выбранных моделей
- **AND** не устанавливаются interpreter и Python packages

#### Scenario: Offline run
- **GIVEN** snapshots подготовлены и сеть для test process недоступна
- **WHEN** выполняются диагностика и полная обработка с Parakeet on/off
- **THEN** результат формируется только локально без попыток скачивания

#### Scenario: Missing or corrupted model
- **WHEN** нужного файла нет или его hash не совпадает
- **THEN** диагностика указывает модель и предлагает подготовку
- **AND** нет незаявленного fallback на другую модель, online download или Python

#### Scenario: Interrupted preparation
- **GIVEN** имеется исправный ранее опубликованный snapshot
- **WHEN** загрузка прерывается, возвращает HTTP error или отменена
- **THEN** staging не считается готовой моделью, исправный snapshot сохраняется и retry возможен
- **AND** paths manifest не могут выйти из snapshot через traversal или symlink

### Requirement: Preserve source timeline and window plan

Worker SHALL принимать раздельные host/remote PCM16 mono WAV 16 kHz на общей
шкале, сохранять тишину и применять прежние окна 25 с с шагом 24 с.
Отбор слов SHALL использовать прежние midpoint seams из baseline.md.

#### Scenario: Speech at a seam
- **WHEN** слово пересекает overlap соседних окон
- **THEN** сохранено прежнее правило `[lower, upper)` по началу слова без дубля или потери
- **AND** абсолютные start/end не сдвигаются из-за VAD или удаления тишины

#### Scenario: Empty and invalid input
- **WHEN** вход пуст, короче окна frontend, повреждён или имеет неверный PCM format
- **THEN** пустой/короткий допустимый вход обрабатывается как baseline, включая необходимый padding копии
- **AND** неверный формат получает явную ошибку без изменения исходника

### Requirement: Whole-window VAD gate

VAD SHALL получать только detection copy с +6 dB/clipping, threshold 0.5,
min speech/silence 250/250 ms, padding 150 ms и прежней hysteresis.
Любое строгое пересечение speech interval SHALL допускать целое ASR окно.

#### Scenario: Quiet speech, silence and noise
- **WHEN** обработаны контрольные фрагменты речи исходной громкости, 25% и 5%, тишины и шума
- **THEN** проверена точная маска окон относительно Python при тех же весах
- **AND** GigaAM, Parakeet и сохранённое аудио получают исходные samples

#### Scenario: VAD failure
- **WHEN** загрузка или inference VAD не выполнены
- **THEN** сохранено предупреждение и распознаются все исходные окна

### Requirement: Pinned product inference profile

Worker SHALL использовать pinned profile из design: GigaAM F16 weights с F32
FFT frontend/activations, Nemotron исходного BF16 checkpoint, Silero v6 F32 и
необязательный Parakeet Q8/group64 с F16 waveform/dense. GigaAM SHALL не
расширять весь weight cache в F32.

#### Scenario: No silent precision change
- **WHEN** готовится или загружается профиль worker
- **THEN** revisions, hashes, branches, quantization и dtype проверяются строго, без скрытого cast всего cache или смены checkpoint
- **AND** режим с F16 weights не объявляется полностью F16 inference, память не уменьшается за счёт изменения результатов или отключения выбранного Parakeet
- **AND** stored dtype, effective compute/promotion, frontend assets и patches записаны раздельно; Parakeet waveform приводится к F16 до frontend
- **AND** GigaAM selection через public API сохраняет score, blank и первый максимум при равных scores

### Requirement: Bounded VAD working memory

VAD SHALL обрабатывать detection copy ограниченными блоками с прежними +6 dB
и clipping, сохраняя 512-sample/64-context feed protocol, recurrent state,
hysteresis, padding и окончание потока внутри каждой дорожки. Полная PCM-копия
обеих дорожек, их усиленные копии или граф на всю запись SHALL не удерживаться
между этапами. Размер рабочего блока SHALL не зависеть от длины встречи;
допустимы компактные masks/intervals, растущие с количеством окон.

#### Scenario: Read audio in bounded portions from disk
- **GIVEN** часовой WAV и настроенный фиксированный размер PCM read block
- **WHEN** VAD обрабатывает источник
- **THEN** WAV читается и декодируется порциями с диска, detection gain применяется только к текущей порции; SHA-256 также считается инкрементально
- **AND** полная загрузка WAV/decoded PCM перед нарезкой запрещена; live decoded/boost buffers ограничены block size и model context независимо от длины записи
- **AND** временные WAV-фрагменты не создаются, исходный файл не изменяется, абсолютные sample offsets сохраняются

#### Scenario: Blocks cross an ASR window boundary
- **GIVEN** речь пересекает границу блока или overlap окон 25/24 s
- **WHEN** размер блока изменён при неизменных weights/settings/samples
- **THEN** маска и sample intervals совпадают с исходным Silero v6 проходом, raw probabilities сохранены для сравнения
- **AND** ASR windows не становятся границами сброса VAD state, EOF/padding применяются один раз на источник
- **AND** хвост порции короче 512 samples переносится к следующей; внутренний read boundary не вызывает zero padding или повторную обработку overlap

#### Scenario: Long track and source reset
- **WHEN** обрабатывается часовая дорожка, затем второй источник
- **THEN** размер live PCM/boost buffers остаётся ограниченным block size и model context, source state/context полностью сбрасывается перед вторым источником
- **AND** исходные samples/hashes, whole-window gate и fallback при сбое сохранены

### Requirement: Bounded ASR input reading

GigaAM и Parakeet SHALL читать исходные sample ranges окон 25 s/stride 24 s
непосредственно из WAV, без предварительной полной загрузки дорожек или
временных WAV-фрагментов. Рабочие PCM buffers SHALL ограничиваться текущим
окном и необходимым frontend padding независимо от длительности встречи.
SHA-256 SHALL вычисляться порциями. Диагностические traces и результаты
могут расти с длительностью; весь worker SHALL не объявляться O(1).

#### Scenario: Read an accepted window
- **GIVEN** VAD выбрал окно на прежней сетке, включая overlap или последний короткий хвост
- **WHEN** GigaAM или Parakeet читает его с диска
- **THEN** samples, абсолютные offsets, frontend padding и midpoint seams совпадают с control, который выделяет окно из полной PCM
- **AND** режимы VAD failure и Parakeet off сохраняют прежний window plan и fallback; исходники не изменяются

### Requirement: Preserve BF16 frontend when chunking Nemotron input

Если полное чтение PCM/mel заменяется порционной session, worker SHALL
переиспользовать готовое stateful scheduling с прежним BF16 frontend:
zero padding, preemphasis .97, floor(N/160) frames и абсолютной фазой.
Offline core340/right40/cache264/FIFO40/update300 SHALL сохраняться.
Независимая диаризация клипов со сбросом истории голосов SHALL не применяться.
Наличие streaming API SHALL не считаться доказательством эквивалентности.

#### Scenario: Read boundary inside a diarization chunk
- **GIVEN** одна дорожка прочитана разными размерами блоков, включая неполный последний блок
- **WHEN** порционный frontend/session сравнивается с whole-file BF16 control
- **THEN** exact mel frames, probabilities и cache/state на одинаковых model boundaries, intervals, overlaps и voice count совпадают
- **AND** zero padding применяется только на настоящих концах аудио, state сохраняется между блоками и сбрасывается между host/remote
- **AND** до прохождения этих проверок текущий full PCM/mel путь остаётся явно указанным ограничением

### Requirement: Supported timing API for production

Продуктовый worker SHALL получать Parakeet timed tokens/words через проверенный
поддерживаемый public API либо явно объявленный public adapter в pinned source
с tests и patch/license ledger. Поставка SHALL не требовать `@testable import`
и `-enable-testing` ради доступа к decoder internals.

#### Scenario: Release build without testing access
- **WHEN** собирается обычный release worker без test-only visibility
- **THEN** token alignment, seams, donor words, correction journal и baseline проходят те же gates
- **AND** изменение public API не подменяет decoder, waveform dtype или численные настройки модели

### Requirement: GigaAM emission timing compatibility

GigaAM adapter SHALL сохранять token IDs/pieces и emission frames,
собирать слова по прежним границам subword, считать конец как last emission+0.1 с
с clamp по окну и проверять finite/order/bounds.

#### Scenario: Multiple emissions and punctuation
- **WHEN** в одном кадре выданы несколько токенов и пунктуация продолжает слово
- **THEN** порядок, текст и временные границы совпадают с прежней сборкой слов
- **AND** native default word end в один encoder frame не меняет контракт

#### Scenario: Invalid model timings
- **WHEN** модель возвращает non-finite, unordered или out-of-window timings
- **THEN** результаты не публикуются как корректное распознавание и исходники сохраняются

### Requirement: Nemotron offline behavior and source-local speakers

Worker SHALL использовать offline geometry 340/40, cache 264/FIFO 40/update 300,
threshold 0.5 и min speech/merge gap 0, без удаления overlap и коротких интервалов.
Голоса SHALL иметь отдельные пространства host/remote, до 8 на каждой дорожке.

#### Scenario: Simultaneous voices and limit
- **WHEN** обе дорожки содержат overlaps и Nemotron обнаруживает 8 голосов на одной из них
- **THEN** overlaps сохраняются, голоса другой дорожки независимы, count фиксируется до назначения слов
- **AND** предупреждение лимита присутствует в final/baseline, JSON и progress

#### Scenario: Diarization failure or no intervals
- **WHEN** модель не вернула допустимые интервалы или завершилась с ошибкой
- **THEN** сохраняются прежний warning/fallback и неизвестность подтверждённого voice count
- **AND** распознавание продолжается без ложного подтверждения личности или нуля голосов

### Requirement: Optional Parakeet correction and original GigaAM

Parakeet SHALL получать те же original windows/mask/seams, использовать
проверенный Q8 профиль с FP16 dense/input и предоставлять timed donor words.
Каскад SHALL сохранять прежние нормализацию, STOP/цифры, пороги, порядок
кандидатов, неоднозначные замены и журнал.

#### Scenario: Correction enabled
- **WHEN** допустимая локальная латинская замена выбрана каскадом
- **THEN** сохранены original GigaAM и journal с исходником, donor и причинами решений
- **AND** исправление не меняет времена исходных слов и не затрагивает другие варианты

#### Scenario: Correction or journal failure
- **WHEN** Parakeet, его timings или запись journal завершаются сбоем
- **THEN** итог для источника совпадает с исходным GigaAM и сохранено предупреждение

#### Scenario: Correction respects original speaker boundaries
- **GIVEN** соседние исходные GigaAM слова имеют разные speaker identities, включая различие nil и явного ID
- **WHEN** donor перекрывает эти слова
- **THEN** пересекающий границу кандидат отклоняется до отбора и разрешения конфликтов
- **AND** допустимая замена внутри одного исходного голоса продолжает применяться

#### Scenario: Complete final and baseline speaker registry
- **GIVEN** completed correction оставила голос только в baseline host или remote
- **WHEN** общая production сборка Stage6 создаёт JSON v1
- **THEN** registry содержит все ссылки final и фактически сериализуемого baseline каждого источника с nil → 1
- **AND** remote display offset равен максимуму того же полного host registry, source-local IDs сохраняются
- **AND** roundtrip и обычный publisher проходят неизменённую строгую валидацию; неизвестная ссылка по-прежнему отклоняется
- **AND** disabled/failed correction сохраняет совпадающие final/baseline signatures без добавления неиспользуемых голосов

### Requirement: Compatible artifacts and immutable versions

Система SHALL сохранять legacy TXT/per-source/baseline/correction форматы,
merge слов до paragraph grouping и существующий контракт JSON v1 редактора
из `master` `520f7d3a9d826d14c26380dc502aa3007b531760`. Recognition, edits и audio
прежней версии SHALL не изменяться. Формат SHALL не требовать миграции reader/UI.
Правила publisher/fixtures и пути зафиксированы в design.md.

#### Scenario: Retry and partial output failure
- **GIVEN** предыдущая успешная версия с пользовательскими правками существует
- **WHEN** новая обработка успешна, прервана или не смогла записать результат
- **THEN** предыдущая версия побайтово сохранна, новая публикуется только атомарно после проверки
- **AND** incomplete staging не виден как успешный результат

#### Scenario: Mix failure and legacy layout
- **WHEN** готовый микс canonical результата собрать не удалось или открыта legacy flat запись
- **THEN** canonical результат сохраняет text-ready/playback-unavailable warning; flat допускает только list и собственный contained standalone saved TXT read-only по ADR0005, без structured/audio lookup или processing
- **AND** worker не дополняет опубликованную версию задним числом

#### Scenario: Current paragraph boundaries
- **GIVEN** одна дорожка с непрерывной речью одного голоса и абсолютными word timestamps
- **WHEN** native producer формирует turns
- **THEN** по согласованному `chronological-transcript-turns` слова объединяются до grouping по start → host перед remote → source ordinal; пауза от 1,5 s начинает абзац, сохраняются max turn 30 s и завершение по конечной пунктуации после 15 s, включая closing quotes/brackets
- **AND** чужой speakerID, включая голос на той же дорожке, разделяет абзац; каждый wordID входит ровно один раз, turn.end охватывает все слова и реальные перекрытия

#### Scenario: Native result opens in the existing editor
- **GIVEN** native worker создал `raw/transcripts/<resultID>/result.json` с `schemaVersion: 1`
- **WHEN** существующие `TranscriptDocument` и `TranscriptResultStorage` читают результат
- **THEN** документ проходит текущую валидацию, результат становится текущим после atomic rename по creation-date/name authority, без selectedResultID
- **AND** ID слов/реплик стабильны внутри версии, host/remote speaker IDs раздельны, `detectedVoiceCount: null` отличается от подтверждённого `0`, baseline GigaAM не теряется
- **AND** обязательные nullable поля и относительные contained paths сохранены; traversal, symlink escape, неверные ссылки и интервалы отклоняются

#### Scenario: Editing, reopening and export after native processing
- **GIVEN** текущий редактор открыл native JSON v1
- **WHEN** пользователь исправил текст/имя, сохранил, закрыл/открыл и экспортировал результат
- **THEN** существующий `edits.json` и revision/CAS/export продолжают работать без смены формата или миграции; field undo/Cancel сохраняются, saved undo GUI исключён по refresh W04
- **AND** native retry создаёт новый resultID, не переносит правки автоматически и не изменяет result/edits/audio предыдущей версии

#### Scenario: Preserve history audio preview and version playback
- **GIVEN** в истории доступен `<base>.m4a`, а опубликованная версия ссылается на свой `mix.m4a`
- **WHEN** выполняется native processing/retry или заново открывается текущий результат редактора
- **THEN** Quick Look истории продолжает читать прежний `RecordingEntry.recording`, его файл не перезаписывается и не подменяется миксом версии
- **AND** редактор воспроизводит только `playback.mixPath` текущего результата; отсутствующий/повреждённый микс не подменяется общей записью или одиночной дорожкой

### Requirement: Progress, cancellation and bounded termination

Worker SHALL сохранять `MEETING_PROGRESS` stages/fields и предупреждения,
реагировать на отмену с ожиданием exit/EOF и не публиковать false success.
Если SIGTERM не завершил worker за 2 с, runner SHALL завершить его принудительно.

#### Scenario: Cancel during model work or preparation
- **WHEN** caller отменяет загрузку, inference или сохранение staging
- **THEN** worker и его child завершаются, исходники и опубликованные версии сохраняются
- **AND** retry не конфликтует с ещё работающим прежним worker

#### Scenario: Progress without verbose model output
- **WHEN** worker выполняет этап с нулём или несколькими work units
- **THEN** события остаются допустимыми для текущего decoder и discrete UI
- **AND** warning не теряется при throttling или смене этапа

#### Scenario: Progress under model-first scheduling
- **WHEN** worker переходит между источниками и моделями, включая пустую дорожку, skipped/fallback этапы и Parakeet/AEC on/off
- **THEN** общий прогресс по `step/steps/completed/total` не уменьшается и остаётся совместим с текущим decoder
- **AND** `channel` и warning относятся к правильному источнику, отмена не выдаёт успешное завершение

### Requirement: Preserve capture and AEC algorithm

Изменение SHALL не менять захват, устройства, мьют, маршрутизацию и native AEC DSP.
Замена Python AEC wrapper SHALL сохранять checks, args, bypass, progress,
временную копию и исходный host при ошибке.

#### Scenario: Existing AEC helper
- **WHEN** Swift wrapper вызывает тот же helper на тех же WAV с AEC on/off/bypass/failure
- **THEN** output/helper args и статусы совпадают с baseline, timeline и mute zeros сохранены
- **AND** исходные host/remote не перезаписаны

### Requirement: Signed test distribution with stable identity

Тестовый bundle SHALL содержать worker, его Metal resources, dylibs и notices,
сохранять `local.meeting-companion`, storage paths и прежнюю signing identity.
Bundle SHALL не содержать Python, uv, Python packages или runtime installers.

#### Scenario: Standalone test bundle
- **GIVEN** сравнение принято и toolchain/подпись доступны
- **WHEN** release test bundle построен в dist и проверен на чистом cache/offline
- **THEN** диагностика, подготовка, processing, retry и cancellation работают без Python/uv
- **AND** подписи app и helpers проходят проверку

#### Scenario: No installation or release
- **WHEN** тестовая сборка готова
- **THEN** отчёт и bundle передаются пользователю без установки и публикации
- **AND** installed app не заменяется, особенно при recording/preparation/processing

### Requirement: Artifact compatibility and current result

Совместимость SHALL определяться JSON v1 и contained файлами вне MainActor, независимо от
producer/metadata markers. recordingFormatVersion SHALL не создаваться и не быть gate.
Unknown tokens/duplicates SHALL сохраняться без discovery writes. Current SHALL выбираться
по creation date/name до schema validation, без selectedResultID/fallback. Commit SHALL быть
atomic no-replace rename staging JSON/text/mandatory files; root TXT SHALL быть derived cache.

#### Scenario: Supported old or minimal metadata
- **GIVEN** стандартная отдельная папка записи, валидный JSON v1, пустая metadata или старые marker/selection поля, включая дубликаты
- **WHEN** история выполняет повторные lifecycle saves и actual disk reload
- **THEN** поддерживаемые editor/edit/export/playback capabilities сохраняются без миграции
- **AND** неизвестные точные metadata и оригиналы сохранны

#### Scenario: Unsupported or missing current with sources
- **GIVEN** новый неподдерживаемый/повреждённый/отсутствующий structured result
- **WHEN** история оценивает actual artifacts
- **THEN** доступный saved TXT открыт только contained read-only reader с объяснением
- **AND** manual retry в стандартной отдельной папке независимо разрешён при exact readable contained raw host+remote pair

#### Scenario: Precommit failure
- **WHEN** ошибка обязательного файла или отмена возникает до directory rename
- **THEN** прежний current и его правки/источники сохранны, staging не становится current

#### Scenario: Postcommit export or acknowledgement failure
- **WHEN** B committed, но root export, ack, status persistence или отмена мешает подтверждению
- **THEN** B остаётся current, App/CLI читают его committed text и показывают warning
- **AND** fresh reopen разрешает B, а не stale root TXT или A

#### Scenario: Retry with an open editor
- **WHEN** workspace/menu/programmatic caller запрашивает retry при открытой review session
- **THEN** modal input сначала разрешается явным Save/Cancel по refresh W04.9; запрос при input отклоняется без enqueue или deferred separate-window prompt, save failure сохраняет draft
- **AND** общий Application admission после разрешения ввода закрывает прежнюю session до enqueue; editable reopen запрещён до terminal teardown
- **AND** CAS/lock, result/draft/confirmation identity и stale-callback guards ADR0004 сохраняются; terminal reopen разрешает current заново без переноса старых правок

#### Scenario: Transient terminal persistence failure
- **WHEN** финальная metadata completion/cancellation не записывается
- **THEN** authoritative snapshot содержит terminal state и warning, worker освобождён и retry доступен

#### Scenario: Presentation recreation during any work
- **WHEN** новый RecorderViewModel присоединяется к существующим recording/preparing/checking/processing services
- **THEN** он получает текущие snapshots и дальнейшие события без пропуска или двойного счёта jobs
- **AND** quit/reset/update guards закрыты до первоначального snapshot и отражают authoritative работу

### Requirement: Standard recording ownership cutoff
Full recording operations SHALL require canonical folder basename equal to recording stem, independently of raw existence, age, producer or marker. Unsupported placement SHALL offer only list and contained saved TXT read-only. Standard retry SHALL require exact contained raw originals. Explicit developer pair mode remains separate.

#### Scenario: Flat neighbour rejection before side effects
- **GIVEN** supported owner D/D.m4a and flat neighbour D/other.m4a
- **WHEN** Application enqueue/start/history, Recorder, Platform runner or Worker recording mode is called for other
- **THEN** it rejects before capture creation, logs, durable writes, preparation or pipeline execution
- **AND** the owner retains full functions; a standard capture can start before raw exists

#### Scenario: Unsupported entry remains unchanged
- **GIVEN** a flat entry with precise root descriptive metadata and optional TXT
- **WHEN** raw appears or processing, editing, playback/export, context or metadata mutation is attempted
- **THEN** those operations are denied; root metadata remains at the exact read path and unchanged
- **AND** discovery performs no writes or migration
