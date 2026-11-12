## ADDED Requirements

### Requirement: Frozen baseline and confidential inputs

Сравнение SHALL использовать проверенный source/environment/model manifest Python
baseline, immutable native revisions и одинаковые WAV copies с SHA-256.
Записи и транскрипты SHALL оставаться вне git и не передаваться в сеть.

#### Scenario: Reproducible run
- **WHEN** начинается серия сравнения
- **THEN** manifest фиксирует source hashes/dirty state, packages, snapshots, dtype/quantization, model settings, Mac/OS/toolchain, команды, input hashes и cache state
- **AND** каждый run пишет новый каталог, не перезаписывая original или прежние результаты

### Requirement: Model probes before full pipeline

Оценка SHALL сначала отдельно проверять strict local load и inference GigaAM,
Silero, Nemotron и Parakeet, затем полный конвейер. README/upstream benchmark
SHALL не считаться подтверждением работоспособности нашей конфигурации.

#### Scenario: Unsupported artifact
- **WHEN** loader требует другой dtype, revision, дополнительные assets или missing branch
- **THEN** отличие явно записывается и до следующего этапа проверяется adapter/bridge
- **AND** strict validation не ослабляется ради успешного запуска

### Requirement: Separate scheduling effects

Оценка SHALL отдельно сравнить frozen Python channel-first с Python model-first
в изолированной копии, затем Python model-first со Swift model-first при тех же
весах, настройках и точности. Frozen baseline SHALL оставаться неизменным.

#### Scenario: Scheduling comparison
- **WHEN** измеряется переход к одной загрузке модели на запись
- **THEN** проверены semantic gates, source state isolation, число загрузок, время загрузки/этапов/всего и память по общей методике
- **AND** manifest указывает расписание, фактические загрузки и ревизию каждого варианта

#### Scenario: Incomplete scheduling control
- **WHEN** сравнить языки при одинаковом расписании невозможно
- **THEN** отчёт явно отмечает смешанный эффект языка и расписания
- **AND** сокращение загрузок или общий выигрыш не объявляются доказанным эффектом Swift

### Requirement: Separate language, checkpoint and precision effects

Парное сравнение языка SHALL сохранять численные веса, tokenizer, frontend,
параметры и compute dtype. При смене source/precision SHALL выполняться
промежуточные bridge runs и отдельная оценка каждого изменения.

#### Scenario: Validate the selected profile
- **GIVEN** для Nemotron выбран исходный BF16 checkpoint, для других моделей — профили design.md
- **WHEN** фиксируется пара сравнения
- **THEN** manifest подтверждает фактические source/weights/dtype/frontend обеих реализаций; различающиеся профили не называются чистым сравнением языка

### Requirement: Semantic and timing comparison

Отчёт SHALL включать raw GigaAM token IDs/pieces/frames/text, words/start/end,
speech gate probabilities/intervals/window masks, Nemotron probabilities/intervals/count,
Parakeet tokens/words/text, suggestions/changes и полный merged transcript.

#### Scenario: Default acceptance gates
- **GIVEN** одинаковые веса, настройки и corpus зафиксированы до Swift inference
- **WHEN** сравниваются результаты
- **THEN** GigaAM text/token sequence, speech gate masks, donor text, correction decisions и final text совпадают
- **AND** GigaAM/Parakeet token timing отличается не более одного 40/80 ms encoder frame соответственно, без смены принятого окна/замены/спикера
- **AND** Nemotron count и overlap topology совпадают после одной перестановки labels на всю дорожку, отклонения границ не превышают один 10 ms output frame
- **AND** все pure-logic fixtures совпадают точно, включая tie order и word ends

#### Scenario: Difference outside a gate
- **WHEN** сравнение не проходит любой критерий
- **THEN** сохраняются исходные результаты, величина и локализация отличия, повтор и объяснение
- **AND** интеграция не продолжается без отдельного согласования отличия или исправления

### Requirement: Coverage of difficult audio

Corpus SHALL включать обе дорожки минимум трёх имеющихся пятиминутных фрагментов,
отложенный фрагмент без настройки по нему, короткий/пустой вход, тишину, шум,
речь 100/25/5%, seams и overlap, несколько голосов и более длинную запись.
Проверка лимита 8+8 SHALL включать synthetic model-output fixtures.

#### Scenario: Quiet speech retention
- **WHEN** речь ослабляется или попадает на границу окна
- **THEN** сравниваются маски и слова, каждый потерянный speech window блокирует приёмку
- **AND** отсутствие текста в старом ASR не принимается за ручной эталон отсутствия речи

#### Scenario: No human reference
- **WHEN** результат сравнивается с другим распознаванием без ручной разметки
- **THEN** метрики названы disagreement, timing deviation или text difference
- **AND** они не названы WER или улучшением качества, DER не заявляется без reference RTTM

### Requirement: Sequential timing and memory methodology

Варианты SHALL выполняться последовательно на одном Mac с одинаковыми audio,
window plan, precision и параметрами. На профиль SHALL приходиться warm-up
и три отдельных процесса с чередованием порядка вариантов.

#### Scenario: Timing report
- **WHEN** измерена серия
- **THEN** показаны individual runs и median, launch-to-exit, model load, времена этапов и total
- **AND** fresh-process startup отделён от warm/page-cache state, GPU lazy work синхронизирован перед отсчётами
- **AND** обещание ускорения не является условием отчёта; ухудшения явно представлены для решения об интеграции

#### Scenario: Memory report
- **WHEN** сравнивается peak memory
- **THEN** peak process RSS показан отдельно от MLX current/peak allocations с одинаковыми reset/sync points
- **AND** RSS и MLX allocations не складываются, accounting child processes описан отдельно
- **AND** после завершения проверено отсутствие worker и оставшихся model child processes

### Requirement: Distinguish PoC evidence from product acceptance

Оценка SHALL отдельно фиксировать результаты frozen Python → Swift и Swift
до/после оптимизации. Exact outputs вариантов Swift SHALL не подменять
проверку продуктовых контрактов или новое парное сравнение с Python.

#### Scenario: Evidence for the product profile
- **GIVEN** revisions, settings и корпус продуктовой серии зафиксированы
- **WHEN** принимается отчёт по worker
- **THEN** каждый gate подтверждён результатами этой серии и проверками продуктовых контрактов
- **AND** отчёт указывает revisions и назначение использованных PoC controls

### Requirement: Precision and implementation ablations

Отчёт SHALL включать выбранный F16+FFT профиль и сохранённый F32+FFT control,
разделяя stored weights, weight cache, activations, frontend и quantization.
Изменения frontend, dtype, selection, memory orchestration и public timing API
SHALL проверяться по одному, затем вместе. F32 expansion и GPU argmax SHALL
не возвращаться в default без новой измеренной причины и review.

#### Scenario: Adopt an optimization
- **WHEN** меняется только способ выполнения при прежнем inference profile
- **THEN** все GigaAM words/tokens/frames/times, speech gate masks/intervals, diarization, donor, journal и final artifacts совпадают с соответствующим Swift control на всём frozen corpus и held-out
- **AND** performance проверена последовательной warm-up+3 серией, metadata/timing clocks исключаются только из exact content comparison, не из отчёта времени

#### Scenario: Single full-length PoC comparison
- **GIVEN** часовой Swift control и оптимизированные варианты выполнены по одному разу, а короткая серия имеет warm-up+3 повтора
- **WHEN** результаты включаются в SDD или comparison report
- **THEN** часовые time/RSS помечены как разовые наблюдения, короткие medians представлены отдельно
- **AND** точное совпадение Swift вариантов не называется полной эквивалентностью Python, гарантией RSS около1GiB или доказанным преимуществом языка
- **AND** эффект reader/graph orchestration отделён от дополнительного эффекта GigaAM dtype; изменение времени других этапов не приписывается F32 GigaAM

#### Scenario: Reconsider F32 GigaAM for the product
- **GIVEN** F32 control ускоряет обработку, но увеличивает active GigaAM allocations
- **WHEN** предлагается заменить базовый F16 profile
- **THEN** на неизменных checkpoints/settings выполнены exact corpus/held-out проверки и последовательные full warm-up+3 серии F16/F32 с Parakeet on/off на доступном Mac
- **AND** показаны RSS, MLX active/cache/peak и pressure/swap отдельно; одинаковый full peak из-за Parakeet не считается отсутствием дополнительных GigaAM allocations
- **AND** смена product profile явно согласована и отражена в pinned profile/design до реализации; до этого F32 остаётся control вне поставки

### Requirement: Attribute speech gate memory with independent probes

Memory report SHALL включать свежие процессы `speech gate-only` на 5/30/60-minute
префиксах одних и тех же WAV и full model-first pipeline, при неизменных
weights/settings. Он SHALL сохранять process RSS current/peak до чтения WAV,
до/после модели и каждого источника; MLX active/cache/peak отдельно, с одинаковыми
sync/reset points. При reset MLX peak SHALL явно указываться его область.

#### Scenario: Locate the peak
- **WHEN** RSS максимум достигнут между checkpoints Nemotron и speech gate
- **THEN** это описывается как пик процесса во время speech gate, а не размер весов или доказательство конкретной утечки
- **AND** размер PCM/boost copies, retained arrays/graphs, state и allocator cache проверяются отдельным profiling trace; разница двух cumulative peaks не называется точным расходом speech gate

#### Scenario: Include file reading and hashing in measurements
- **GIVEN** speech gate-only probe получает исходные WAV paths, а не заранее загруженный PCM
- **WHEN** сравниваются5/30/60min и разные размеры read block, включая не кратные512
- **THEN** elapsed и memory measurement начинаются до чтения/header/hash/decode, проверены bounded read requests и отсутствие полной waveform allocation перед slices
- **AND** masks/intervals совпали с control, state непрерывен между чтениями, padding только на EOF; temp WAV chunks не создаются и input hashes сохранены

#### Scenario: Release cached blocks
- **WHEN** speech gate и его state освобождены до следующей модели
- **THEN** в speech gate-only probe MLX active и cache после teardown не превышают значения до модели более чем на 1 MiB каждое
- **AND** full pipeline не сохраняет speech gate model/boost buffers; RSS high-water не обязан уменьшаться, live allocations проверены отдельно

### Requirement: Resource measurements on the validation Mac

Оценка SHALL измерять время и память на доступном Apple Silicon Mac с фиксацией
SoC/RAM/OS/toolchain, питания/power mode, thermal state и фоновой нагрузки.

#### Scenario: Full processing and resource report
- **GIVEN** текущие inputs и profiles зафиксированы, сеть запрещена после подготовки
- **WHEN** выполняются warm-up и три новых full runs с Parakeet on/off отдельными сериями
- **THEN** представлены individual runs/medians, RSS и MLX active/cache/peak отдельно, pressure/swap и результаты semantic gates
- **AND** worker завершается без OOM и незаявленного fallback, не оставляет дочерние процессы, retry работоспособен
- **AND** выводы о времени/памяти ограничены измеренной конфигурацией

#### Scenario: Fresh prepared offline start
- **WHEN** после подготовки впервые запущен новый worker с запрещённой сетью и без Python/uv в PATH
- **THEN** fresh-process launch и model load записаны отдельно от warm medians, модели strict-load локально и обработка успешна
- **AND** warm OS/Metal cache не называется cold-cache, скрытая смена моделей или precision запрещена

### Requirement: Comparison review precedes app integration

Подключение к UI и выпуск test bundle SHALL происходить только после проверки
model/full-pipeline отчёта. Итог SHALL различать выполненные tests/UAT,
upstream claims, ограничения и ещё открытые сценарии.

#### Scenario: Reviewable delivery
- **WHEN** сравнение закончено
- **THEN** пользователь получает portable report с revisions, командами, differences, timings/memory, tests и ограничениями
- **AND** приватные outputs остаются локальными и доступны по отдельному evidence manifest
- **AND** приложение подключается после приёмки отчёта, без публикации релиза
