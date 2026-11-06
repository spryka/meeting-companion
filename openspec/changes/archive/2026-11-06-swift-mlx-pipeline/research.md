# Готовые Swift-реализации: проверка исходников

> Исторический материал экспериментов 2026-10-30/31. Текущая база и решение
> владельца от 2026-11-02: [design.md](design.md).
> Прежние Air gates/budgets исключены, старый перечень Python differences
> снят как неактуальный. Упоминания ниже описывают состояние на дату пробы,
> не действующие блокеры или новый PASS. Контракт редактора берётся из текущего master.

Проверено 2026-10-30. Репозитории прочитаны на закреплённых ниже коммитах,
HF metadata/config скачаны отдельно без передачи пользовательских данных.
Слова "поддерживается API" ниже не означают успешный инференс на нашем аудио.

## GigaAM

Source: [kruatech/gigaam-v3-mlx @ 95bd42a](https://github.com/kruatech/gigaam-v3-mlx/tree/95bd42a4b9a65450a24e1898c7d84b85e0e88509).
Код MIT. [HF bundle @ 2478743](https://huggingface.co/kruatech/gigaam-v3-mlx/tree/2478743c1c449a468ee163bc3030170d1a2e81fb)
помечен MIT, manifest: `ai-sage/GigaAM-v3`, revision=`e2e_rnnt`, FP16.
Это строка варианта модели, не immutable SHA исходных весов.

Проверены `ModelBundle`, `GigaAMProModel`, `RNNTGreedyDecoder`,
`SafetensorsMLXLoader`, `MelSpectrogram` и `BuildWordsTests`:

- Локальный `GigaAMConfiguration(modelDirectory:)`, без HF-клиента в inference.
  Нужны manifest, `weights.fp16.safetensors`, tokenizer, Hann и mel binary assets.
  Один каталог al-bo не является готовой заменой bundle.
- Decoder сохраняет token IDs и emission steps. Однако высокоуровневый result
  отдаёт слова, а per-token frame trace не экспортируется через результат model.
  Для точного сравнения потребуется небольшой доступ к уже существующему trace.
- Слова есть, шаг 40 ms. Конец слова `(lastFrame+1)*40 ms` отличается от
  Python `lastFrame*40 ms+100 ms`. Для совместимости используем прежнее правило
  через адаптер, с тестом, а не принимаем новые границы по умолчанию.
- Loader поддерживает F16/F32. Packed Q8 не реализован. Приготовление FP32
  представления тех же FP16 значений допустимо как отдельный проверенный профиль.
  Сами вычислительные dtype надо подтвердить, не вывести из manifest.
- Short audio <320 samples вызывает ошибку frontend; baseline дополняет его
  нулями. Нужен адаптер пустого/короткого входа. Нельзя применять встроенную
  произвольную long-form нарезку вместо окон Meeting Companion.
- Frontend делает DFT циклами CPU. Ускорение всего конвейера заранее не следует
  из выбора Swift. Сравнить mel, encoder и RNNT отдельно.

`Package.swift`: Swift >=5.10, macOS >=14, MLX Swift `[0.31.3, 0.32.0)`.
Stock `Package.resolved` закрепляет MLX Swift 0.31.3 и swift-numerics 1.1.1.

Попытка `swift test -c release --filter BuildWordsTests` разрешила зависимости,
но завершилась exit 1 при Metal compilation:
`unable to spawn process 'metal' (No such file or directory)`.
`xcode-select -p` указывает CommandLineTools; `xcrun --find metal` также не находит
утилиту. В той попытке тесты и инференс не выполнялись. Последующий успешный
консольный probe описан ниже; upstream `BuildWordsTests` повторно не запускались.

### Одноразовый консольный PoC

По отдельному запросу пользователя подготовлен
[GigaAM probe](../../../../experiments/swift-gigaam-poc/README.md): один Swift source,
stock GigaAMKit и MLX 0.31.3, без GUI и без интеграции приложения. После принятия
лицензии настроены Xcode 27.2 (27B52) и Metal Toolchain, без глобального изменения
developer path. Release build, compiled self-check и реальный offline inference
прошли. Runtime assets скачаны отдельно и их hashes совпали; фактически 561 F16
tensor, 222,519,937 parameters. Нейросеть и upstream source не менялись.

Обе дорожки одного пятиминутного фрагмента обработаны последовательно с запретом
сети для процесса: 154/216 слов, 432/546 raw токенов, 13 окон на дорожку. Все слова
и start/end точно совпали с сохранёнными GigaAM словами Python. Это sanity check
одного фрагмента: baseline применял VAD, PoC обрабатывает все окна; Python token
trace и численная эквивалентность весов/compute dtype не проверены. Пройдены empty,
short, silence и ошибки input/model/existing output; входные hashes сохранены.
Этот probe не подтверждает общий dependency graph 0.32.3 или полный паритет.

## Nemotron


Source: [soniqo/speech-swift @ f8ca61d](https://github.com/soniqo/speech-swift/tree/f8ca61de3902b22e3e3a1434c680c1b21d8d48af).
Код Apache-2.0. Проверены `Nemotron3Diarizer.swift`, `Nemotron3MLXModel.swift`,
`SortformerConfig`, mel extractor, binarization helpers и тесты Nemotron.

- `Nemotron3Diarizer.fromMLXDirectory(_:)` загружает только локальные файлы.
  `fromMLXPretrained()` является отдельной download API.
- Только affine INT8 group 64; config проверяет `dtype=int8` и исходный NVIDIA
  SHA `a435e9867d79e789e90053f9b6d6834053af564a`.
  [HF export @ 8be6cfb](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-MLX-INT8/tree/8be6cfb8a8009b1e11419208c819f6e20c94b4a3)
  помечен OpenMDW-1.1. Заявленный weights SHA-256:
  `78b2131bbfdccdd6e3b440a96c5e5e3b12a80dbeda14e988dde8024affb67ac3`.
  Сами эти веса здесь не скачаны и hash не перепроверен.
- Это другой заявленный source revision и другая точность, чем у baseline
  BF16. Эквивалентность исходных чисел не установлена. Нельзя называть сравнение
  этих двух вариантов чистым эффектом языка.
- Есть 8 speaker activity tracks, 10 ms intervals, offline geometry 340/40,
  cache 264, FIFO 40, update 300, learned silence; не online preset.
  Binarization выполняется независимо по спикерам и сохраняет overlaps.
- Default `.sortformer` фильтрует речь <0.3 с и сливает gaps <0.15 с.
  Для baseline нужны явные minSpeechDuration=0 и minSilenceDuration=0,
  onset=offset=0.5. Нужны проверки пограничного `>=` и порядка интервалов.
- Mel frontend и state updater отличаются реализацией. Проверять features,
  вероятности, cache cadence и интервалы, а не только число голосов.

Package требует MLX >=0.30.0, но также exact mlx-swift-lm 3.31.4, который
в [собственном manifest](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Package.swift)
закрепляет MLX `[0.31.4,0.32.0)`. `SpeechVAD` использует
`AudioCommon` и `MLXCommon`. Полный package добавляет множество неиспользуемых
зависимостей (server, MCP, LLM, WhisperKit). Этот граф не минимален для worker.

## Parakeet и Silero

Source: [Blaizzy/mlx-audio-swift @ d4fa7be](https://github.com/Blaizzy/mlx-audio-swift/tree/d4fa7be1c2fef65ed13a4f73bd58e0a23a0ba307),
MIT. Проверены `ParakeetModel`, quantization parser, alignment, Silero model/config
и package graph. Swift >=6.2; MLX Swift >=0.32.3. Tag v0.1.7 также требует >=0.32.3.

- `ParakeetModel.fromDirectory(_:computeDType:)` читает локальный directory,
  понимает Q8/group 64, загружает weights с `.all` verification.
  `sentences[].tokens` содержит текст/start/end. Указать `.float16`: default
  `.bfloat16` отличается от Python baseline. Подать готовое окно без внутреннего
  повторного chunk/overlap. Пересобрать слова прежним правилом и проверить token trace.
- Возможность читать Q8 в коде есть; загрузка именно нашего craquehouse snapshot
  и инференс не проверены. Проверить config, key mapping, quantized scales и dtype
  каждого типа слоя. В HF карточке craquehouse не указана лицензия.
  Исходный [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  помечен CC-BY-4.0; этого недостаточно для автоматического заключения о derived
  artifact. До сборки нужны сведения о происхождении и notices.
- `SileroVAD.fromModelDirectory(_:)` читает локальные safetensors и делает
  strict `.all` update. Но создаёт обязательные 16/8 kHz branches, а наш
  checkpoint содержит только 16 kHz. Прямую совместимость не заявляем.
  Нужна минимальная правка loader/branch selection с проверкой полноты 16 kHz
  весов. Нельзя скрыть missing tensors через нестрогую загрузку.
- `feed` работает с 512 samples и 64 context. VAD segmentation и перевод
  интервалов в samples сверяются отдельно с Python; whole-window gate принадлежит
  Meeting Companion. Усиление, пороги и padding берутся из baseline.
- В MLXAudio найденные Nemotron ASR/voice-chat модели не являются Nemotron-3
  diarization. Они не заменяют SpeechVAD.

## Выбор зависимостей и ограничения

Минимальный найденный набор готовых реализаций для требований MLX:
GigaAMKit + Nemotron MLX из SpeechVAD + Parakeet/Silero из MLXAudio.
Speech-swift предлагает Parakeet через Core ML INT8, поэтому замена им MLXAudio
не покрывает условие Swift/MLX и меняет inference backend.

Три текущих stock package нельзя связать в один worker без изменения графа:
`[0.31.3,0.32.0)` пересекается с требованием `>=0.32.3` пустым множеством.
Это вывод из manifests, не результат выполненного объединённого SwiftPM resolve.

Предложение: один worker на закреплённом MLX 0.32.3, минимальное vendoring готовых
GigaAMKit и dependency closure Nemotron (с Apache/MIT notices и upstream SHAs),
MLXAudio только products STT/VAD/Core и их обязательные transitive targets
(в текущем STT есть также Codecs и libzstd). Не копировать остальные speech-swift модели,
серверы, LLM и интерфейс. GigaAM получает минимальные API/loader adapters, без
переписывания encoder/decoder. Каждый patch записывается отдельно от upstream.
Сначала подтвердить compilation и strict local load на этом MLX.
Это выбранная стратегия проверки, не доказанный совместимый стек.

Альтернативы: два worker binaries с разными MLX дают лишнюю упаковку и IPC;
полный fork всех пакетов приносит ненужные зависимости; собственный порт сетей
дублирует готовые реализации. Их сейчас не выбираем.

Главный decision gate: для Nemotron нужен тот же BF16 checkpoint через готовую
архитектуру и небольшой loader adapter, либо bridge runs для отделения source
revision и Q8. Если это требует нового порта нейросети, работа останавливается
на отчёте. INT8-only вариант не считается выполнением точного переноса baseline.

## Отдельно разрешённый full CLI PoC

После GigaAM-only пробы пользователь отдельно разрешил одноразовый полный
консольный PoC. Он находится в [experiments/swift-pipeline-poc](../../../../experiments/swift-pipeline-poc/README.md).
Это не согласование app integration, всего proposal или ADR-0002.

Общий graph на MLX Swift 0.32.3 собран, все четыре модели реально загрузились
локально и выполнили inference на двух пятиминутных дорожках с запретом сети.
В финальном full run дополнительно `PATH=/nonexistent`; Python/uv CLI не вызывает.
Нейросетевые архитектуры не переписывались. Использован готовый код с указанными
в README upstream SHAs и ограниченными adapters. Две особенности stock MLXAudio:

- В `MLXAudioSTT` пропущена manifest dependency `MLXFFT`, хотя она импортируется
  моделью NemotronTranscribe. В pinned локальной копии исправлен только manifest;
  patch и идемпотентная подготовка находятся рядом с PoC.
- Public `ParakeetModel.generate` не отдаёт token alignment. Одноразовый CLI
  использует `@testable import`, release `-enable-testing` и готовые
  `makeBatchFeatures`/`decode`. Для продукта нужен поддерживаемый API. F16 waveform
  подаётся **до frontend**, как в Python `generate(dtype=float16)`; одного
  `computeDType=.float16` для совпадения настройки недостаточно.

Strict Silero 16k load проходит после выключения отсутствующей 8k ветки;
`.all` проверки сохранены. Foundation directory enumeration потребовала
разрешать model symlinks до передачи каталога в loader. Нет нестрогой загрузки
или заполнения недостающих weights случайными значениями.

На этом фрагменте совпали VAD masks, все 978 GigaAM token IDs/pieces/frames/times,
370 слов GigaAM вместе с start/end/speaker и итоговые исправленные слова и
временные реплики объединённого транскрипта. Arithmetic regression word end
исправлена с RED/GREEN: сохранён Python порядок `absolute_emission + .1`.
Это сравнение с baseline, не ручная оценка качества и не WER.

Паритет моделей не доказан: Nemotron INT8 другой source revision даёт 32/67
интервалов против 39/70 у Python BF16, при тех же 1/2 голосах на дорожку.
Parakeet имеет отличия промежуточных слов/таймкодов; итоговые 3/1 замен совпали,
но часть host journal donor_end отличается. На Swift model outputs сама cascade
и merge точно совпадают с frozen Python функциями. Исходный GigaAM сохраняется
до Parakeet, результат и полный journal доступны отдельно.

Готовые реализации покрыли исследовательский CLI; заменять модели из-за
manifest/API adapters не потребовалось. Продуктовый gate BF16/source bridge
остаётся открытым. Этот PoC не снимает требования к одинаковым профилям,
held-out corpus, повторным замерам, лицензиям derived weights и app contracts.

## BF16 adapter и расширение корпуса (2026-10-31)

Проверка HF model metadata нашла прямой профиль Python baseline:
`mlx-community/Nemotron-3-Diarization@59ed2dbfc1346dcea9d423c71306a3a2499c568f`,
source `723e19c601d99b7e58fba6a14e32153e0afe48d9`, BF16. Также существует
`mlx-community/Nemotron-3-Diarization-8bit@dd8b8ce3d69a80540a7e50150e2beed1c34fee37`
с тем же source, но для прямого сравнения выбран уже локально доступный BF16.
Другие форматы CoreML/ONNX/GGUF меняют backend и здесь не нужны.

Формы всех используемых слоёв совпали с готовой сетью speech-swift. В
исследовательском CLI добавлены strict BF16 loader и DSP adapter. Шесть
training-only tensors явно исключены, используемые параметры проверяются `.all`.
Python использует checkpoint window/fb, pre-emphasis .97 и zero padding; исходный
Swift INT8 frontend этого не воспроизводил. BF16 профиль теперь использует эти
буферы, прежний offline preset и независимый state дорожек.

RED: прежний binary отвергает BF16 config; CLI возвращает optional warning,
assertion на успешный model load падает. При первом запуске адаптера выявлена
реальная ошибка F32 attention mask с BF16 output; заменена bool mask как в Python.
GREEN: strict load и inference на прежних двух 300s WAV успешны, без предупреждений.
39/70 интервалов и 1/2 голоса совпадают; максимальная разница границ около 10 ms.
Это ещё не полный паритет. Fused RoPE не устранил эту разницу.

Для расширенной проверки подготовлены отдельные копии трёх уже
транскрибированных встреч: 3659.22, 1763.54 и 747.86 s на дорожку.
Оригиналы и сохранённые результаты зафиксированы SHA-256, не перезаписываются
и не загружаются. Сохранённые транскрипты не являются ручным эталоном.
Внешние результаты и воспроизводимые команды находятся в corpus-20261030
в соседнем evidence-каталоге; сводка добавляется после завершения запусков.

Расширенная проверка завершена: результаты и ограничения внесены в
`verification.md`. Текст и token IDs GigaAM совпали на всех шести дорожках,
но таймкоды и два назначения спикера отличаются. BF16 strict-load gate для
исследовательского CLI пройден; полная эквивалентность модели не доказана.
Новые веса или самостоятельная реализация сети не понадобились.


Оптимизация GigaAM PoC (2026-10-31): F32 cache и MLX FFT ускорили model-only
парную серию на28.4%. Предположение о GPU argmax как ускорении отклонено
измерением; выбран Accelerate reduction на общей MLX memory без Swift Array
copy и без лишнего lazy reshape. В полном корпусе все outputs до/после
сохранились точно. Изменения и memory trade-off отражены в verification.

## Текущий вывод и будущие VAD-кандидаты — 2026-10-31

Последующая F16/F32 пара изменила выбор PoC: оставлены исходные F16 GigaAM
weights с F32 FFT frontend/activations и shared CPU selection. Model-only MLX
peak ниже примерно на399MiB, но full hour RSS не уменьшился. Он достигает пика
уже на VAD и в Python тоже близок к2GiB. Подробные числа и границы — в verification;
причина временной памяти по этим snapshots не установлена. Поэтому текущая
реализация сохраняет Silero v6 и сначала исследует bounded processing.

Проверены публичные первичные страницы и локальный pinned MLXAudio Swift source
`d4fa7be1c2fef65ed13a4f73bd58e0a23a0ba307`; новые модели не скачивались и не запускались.

| Кандидат | Что подтверждено | Что не подтверждено |
|---|---|---|
| [FSMN-VAD](https://huggingface.co/mlx-community/fsmn-vad) | [Upstream MLX model docs](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/vad/models/fsmn/README.md); готовый `FSMNVAD.swift` уже есть в pinned MLXAudio Swift, local `fromModelDirectory`, strict encoder `.all`, config и optional `cmvn.json`/`am.mvn`; `detect` возвращает интервалы в ms | HF immutable revision/полнота assets/лицензия весов здесь не проверены: прямая model card не получена web tool. Наши strict load/inference, русская тихая речь, window recall, память/скорость не проверены |
| [Silero v5](https://huggingface.co/mlx-community/silero-vad) | Прежняя линия Silero, готовые Swift `feed`/local loader,16/8k branches. Это другие weights относительно v6 | Улучшение качества/ресурсов на наших записях не измерено; меньшая версия не означает меньший RSS |
| [SmartTurn v3](https://huggingface.co/mlx-community/smart-turn-v3) | [Исходная model card](https://huggingface.co/pipecat-ai/smart-turn-v3/raw/main/README.md) описывает определение окончания реплики | Не прямая замена acoustic speech/non-speech gate; не выбран для эксперимента отбора наших окон |

Важное ограничение FSMN source: `detect`/`extractFeatures` делают CPU arrays
waveform и обрабатывают полный feature/score tensor. Само наличие другой
компактной сети не гарантирует bounded memory. Local loader допускает отсутствие
CMVN: эксперимент обязан проверить требуемые конкретным checkpoint assets,
а не считать отсутствие normalization корректным молчаливым fallback.
Лицензия готового MLXAudio Swift кода MIT не подтверждает автоматически лицензию
HF weights и их training/source provenance.

Для той же Silero v6 [model card](https://huggingface.co/mlx-community/silero-vad-v6)
предлагает также256ms unified mode. Это изменение aggregation/feed поведения,
а не новое checkpoint и не автоматически эквивалентная memory-оптимизация.
Наш перенос сохраняет32ms feed и прежнюю mask; другой режим требует отдельной
проверки как изменение поведения. Upstream speed claims не используются как
наши результаты.

Порядок будущей оценки: source/license/assets audit → strict offline load →
human-labelled speech-window corpus и заранее отложенный split → отдельные
модели → полный конвейер. Gate —0 пропущенных вручную подтверждённых speech
windows, при отдельном отчёте false positives, ASR retention и time/RSS/MLX.
Модели сравниваются на исходных копиях, целые25/24s окна и absolute timeline
сохраняются. Promotion в default требует нового решения, а не закрывает gates
текущей миграции. Никаких новых runtime dependencies и UI settings сейчас.


## Nemotron chunking: повторный source audit 2026-10-31

Полный WAV не является требованием сети: текущий PoC уже выполняет stateful
340/40 offline chunks (27.2s core +3.2s right), но frontend сначала сохраняет
все PCM/mel frames. В BF16 extractor нет глобальной нормализации всей записи.

Проверены исходники готовых реализаций:

- [speech-swift@a57702e6](https://github.com/soniqo/speech-swift/blob/a57702e6f523fa36ac5532d2bdc5f35f701a052c/Sources/SpeechVAD/Nemotron3Diarizer.swift), Apache-2.0: session `push/finish/reset`, bounded consumed PCM, speaker state и mel margins. Defaults6/7 отличаются от нужных340/40. `confirmedProbabilities` сохраняется целиком. Штатный reflect frontend/no-preemphasis/floor+1 несовместим с нашим BF16 zero/preemphasis.97/floor; session tests используют fake backend, не реальные BF16 веса.
- [Transformers@66f51e76](https://github.com/huggingface/transformers/blob/66f51e76efd8542232b8bdd40ade7d1edbaac46f/src/transformers/models/nemotron3_diarization/modeling_nemotron3_diarization.py): streaming `speaker_cache`/FIFO/lookahead, offline internal chunking; presets/overrides различаются. Это reference реализации состояния, не новая зависимость.
- [NVIDIA NeMo-Speech.cpp@20999cc9](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/20999cc921d2b14aa58708f61756a8b2e787ba20/src/asr/diar/sortformer_model.cpp): `run_chunk` с явными mel/state/cache/FIFO. Другой runtime/GGUF не нужен для bounded MLX frontend.

[Официальная model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)
описывает cache-aware inference и offline preset264/40/340/40/update300
в единицах80ms. Не менять его на low-latency defaults ради меньших chunks.
Предпочтение — reuse готового Swift scheduling и узкий BF16 DSP adapter;
отдельный перенос нейросети не нужен. Новые streaming implementations не
собирались/не запускались; source audit не доказывает exact parity.
Pinned source copies, команды и полный аудит — внешний
`f32-bounded-audit-20261031/CHUNK-AUDIT.md`; проверка модели открыта в8.1.

## Исторические заметки из design (2026-10-31)

## Одноразовая оптимизация GigaAM (2026-10-31)

Пользователь согласовал три изменения исследовательского CLI: однократное
расширение stored F16 weights в F32, MLX FFT/matmul frontend вместо CPU DFT
и readback без копирования полного вектора 1025 scores. Checkpoint,
frontend assets, окна/seams, decoder state/blank/ties и trace сохраняются.
Затронуты только experiment vendor code, его callers/checks и provenance.
Сначала synthetic RED на F32 load; numerical/frontend и selection regression
checks, затем staged builds/serial same-input comparisons. Performance не
проверяется нестабильным unit threshold. Старый binary сохраняется с resources
в отдельном evidence, без отката исходников. F32 может увеличить память;
FFT может изменить округление/token timing, поэтому нужны полные audio checks.
Изменения не принимают ADR-0002 и не подключают код к приложению.


Промежуточный profiling этой оптимизации: compact GPU argmax не даёт выигрыша,
его запуск на каждом RNNT step увеличивает readback time. Поэтому выбран
Accelerate max/index над общей MLX memory без Swift Array copy; публичный
noCopyIfContiguous API и явное удержание lifetime сохраняют корректность чтения.
Промежуточные варианты и измерения сохранены, исходный control не откатывается.

## F16 weights с FFT (2026-10-31)

По запросу пользователя отдельно проверяется отказ от F32 expansion в tensor
store при сохранении FFT frontend и shared-memory selection. Это один узкий
ablation: остальные источники, веса, алгоритмы и настройки сохраняются.
Храним dtype из файла (F16 weights, F32 frontend assets); activations остаются
F32 с обычным promotion операций. Это не перевод всей сети на F16.
F32 binary сохранён вне репозитория для последовательного парного сравнения;
оцениваются скорость, RSS и MLX allocations отдельно, exact outputs и полный
часовой конвейер. Изменение затрагивает loader, synthetic checks, provenance
и описание экспериментального профиля; приложение и ADR остаются прежними.


## Проверка F32 и chunking после VAD PoC (2026-10-31)

Исследовательский CLI получил отдельные `--bounded-audio` и `--gigaam-f32`.
Первый переиспользует проверенный Silero reader/graph и читает прежние ASR
окна25/24s прямо с диска. Второй расширяет те же stored F16 GigaAM weights
в F32; frontend/activations, BF16 Nemotron и Q8/F16 Parakeet не меняются.
Default CLI и предложенный продуктовый F16 profile остаются прежними;
F32 результат не означает автоматического повышения dtype всех моделей.

Nemotron уже выполняет stateful offline chunking27.2s core +3.2s right,
но wrapper удерживает полную дорожку и все mel frames. В новом режиме полная
дорожка существует только внутри Nemotron и только для одного источника.
Это ещё не полностью bounded конвейер. Диагностические traces/results тоже
растут с длительностью. GigaAM/Parakeet model inference и ранее был оконным.

Готовый speech-swift streaming session на `a57702e6f523fa36ac5532d2bdc5f35f701a052c`
подходит для переиспользования scheduling/state, но его reflect frontend без
preemphasis не совпадает с нашим BF16 zero/preemphasis. Следующий исследовательский
шаг: bounded BF16 frontend с абсолютной фазой, затем session с явными340/40,
cache264/FIFO40/update300. Не диаризировать независимые аудиоклипы с reset.
Сначала exact mel frames на read boundaries/EOF, затем probabilities/state,
intervals/overlap/voice count и source independence. Наличие API и mock tests
не закрывает эти проверки. Не требуется перенос архитектуры сети или новый backend.

Evidence/команды/immutable upstream sources — внешний
`f32-bounded-audit-20261031/`, включая `CHUNK-AUDIT.md`. Новых зависимостей нет.
На дату этой исторической пробы ADR-0002 был proposed, app/resource gates
оставались открыты. Текущий статус — в design.md и ADR-0002.
