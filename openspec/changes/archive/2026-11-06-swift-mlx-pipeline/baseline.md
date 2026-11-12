# Зафиксированный Python/MLX baseline

> Исторический материал экспериментов 2026-10-30/31. Текущая база и решение
> владельца от 2026-11-02: [design.md](design.md).
> Прежние Air gates/budgets исключены, старый перечень Python differences
> снят как неактуальный. Упоминания ниже описывают состояние на дату пробы,
> не действующие блокеры или новый PASS. Контракт редактора берётся из текущего master.

Проверено 2026-10-30 по исходникам, локальным весам и результатам запусков.
Это baseline тестовой ветки, не утверждение о стабильном релизе.

## Source identity

Ветка `experiment/gigaam-mlx`, HEAD
`7306d80917fbc8c020ca09b1e287d1090a387b30`, содержит незакоммиченные изменения.
Один HEAD не воспроизводит полный MLX. Сделана внешняя копия 119 файлов с
проверкой, что исходные файлы не изменились во время копирования.
SHA-256 `python-source-manifest.json`:
`cfd8cdb6cce896811d021fbf639616e29089b3e5a297b84521fbbb37128bea01`.
Полная копия, environment/model manifests, логи и аудио хранятся в отдельном
локальном каталоге evidence вне git. Его путь передаётся как `$EVIDENCE`.

| Файл | SHA-256 |
|---|---|
| `transcription/transcribe.py` | `8f51326412004ff9801465bda7ccedd5de6aa2d255fe1741a85ac9781b6c16ef` |
| `transcription/audio_enhancement.py` | `66e90aa6fcd01a6cb7ab2cb96b387d5b2ff2c343780b6c762868524d0052fa4d` |
| `transcription/gigaam_mlx_backend.py` | `cf6e1b3e9022b014b5e7fd8f31dc615ad3e63dc1c3fa8ce62719eff3fc78d437` |
| `transcription/gigaam_mlx_runtime.py` | `9ab5d17275e3c775df1efa8c586a10b21f0a78e029450ba70ddeb766a68b3ecb` |
| `transcription/model_assets.py` | `e9614efbc805ad62d693b32662efd6867cf879b51c20188e94af1b051d787d6d` |
| `transcription/transcribe-recording.py` | `66a3a8785f2b0741c7da7e485d0b4c1faf75709e37a760e0645d3e66b386cda2` |
| `transcription/term_correction.py` | `a2b950136934806eeda36a17d8190c2e2a3267945f64719eee93a1ee0e928540` |

GigaAM runtime адаптирован из `misteral/GigaAM`
`b258565b39bbf7912cad6c61d70bc1d9491ad156`, с MIT notice, strict weights
и локальным адаптером кадров эмиссии. Проверен сам bundled код.

## Environment

Проверочный Mac: Apple Silicon arm64, macOS 26.6.2 (25G83).
Python 3.12.12, mlx-audio 0.5.8, mlx и mlx-metal 0.32.4, numpy 2.5.4,
soundfile 0.14.0, scipy 1.18.1, huggingface_hub 2.4.0, safetensors 0.8.0,
tokenizers 0.23.3, transformers 5.22.1. Полный перечень 36 пакетов и pip
сохранён в `python-environment.json` вне git.

`run.sh` закрепляет только mlx-audio, остальные пакеты разрешаются динамически.
Перед следующим сравнением надо использовать именно сохранённый набор версий,
а не заново разрешённые зависимости. Freeze сравнения проверяется manifest.

## Weights

Проверены SHA-256 файлов и фактические dtype заголовков safetensors, без догадок
по имени репозитория. Полные config/tokenizer hashes в `python-models.json`.

| Модель / HF repository | Snapshot revision | Хранение / исполнение |
|---|---|---|
| `al-bo/gigaam-v3-e2e-rnnt-mlx` | `9488b39159c6d30f0fbaef1e41459f1e078daf30` | 560 F16 tensors; loader переводит веса в FP32 |
| `mlx-community/Nemotron-3-Diarization` | `59ed2dbfc1346dcea9d423c71306a3a2499c568f` | 361 BF16 + 2 F32 tensors; без INT8 |
| `mlx-community/silero-vad-v6` | `2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06` | 14 F32 tensors, только 16 kHz branch |
| `craquehouse/parakeet-tdt-0.6b-v3-mlx-8bit` | `29d291a62b4013d74a24d79fca00883b717d988a` | affine Q8 group 64; 221 U32 + 918 F16 tensors; неквантизованные слои и input FP16 |

SHA-256 основных весов:

```text
GigaAM   54295fab7b860459949fd16f1481cd67202680ef76d54020591a849026bc2515
Nemotron 21e8427d1795c9c46c5800f56b16061734ffd0dcadd71d9bcf0b4d6ef7261da5
Silero   65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff
Parakeet 3e9a25e0f1c4cd866868e271601407b5a5c187ac1d4f7324a4867120775204eb
```

## Settings

- host и remote: исходные 16 kHz mono PCM16 WAV, тишина сохраняется.
- На каждой дорожке: Nemotron -> speech gate -> GigaAM -> speakers -> опциональные
  Parakeet и correction. Затем merge слов дорожек до группировки реплик.
- GigaAM: greedy RNNT, максимум 10 symbols/frame, blank 1024, log-mel 64,
  FFT/window 320, hop 160, center=false, subsampling 4, шаг эмиссии 40 ms.
  Слово заканчивается на времени последнего токена + 100 ms с обрезкой по окну.
  Это метки эмиссии, не forced alignment.
- Окна 25 с, шаг 24 с. Шов: lower=0 у первого, иначе start+0.5 с;
  upper=start+24.5 с, у последнего end+0.1 с. Отбор по началу слова `[lower, upper)`.
- speech gate: только detection copy +6 dB с clipping [-1,1], threshold=0.5,
  negative threshold=0.35, min speech/silence=250/250 ms, pad=150 ms.
  Любое строгое пересечение speech interval с окном допускает целое окно.
  У v6 отсутствует ветка 8 kHz; Python удаляет её перед strict load.
- Nemotron: offline 340 core / 40 right-context encoder rows, cache=264,
  FIFO=40, update period=300; threshold=0.5, min_duration=0, merge_gap=0.
  Выход 10 ms, до 8 независимых меток на дорожку, overlap разрешён.
  В config заявлен исходный NVIDIA revision
  `723e19c601d99b7e58fba6a14e32153e0afe48d9`.
- Parakeet: те же окна, маска и швы, input/dense FP16, greedy max_symbols=10,
  durations=[0,1,2,3,4]. Субслова объединяются до фильтрации по швам.
  Проверки finite/order/bounds, допустимый конец до window end+0.15 с, затем clamp.
- Каскад: `SequenceMatcher(autojunk=False)`, replace blocks, 1-2 слова,
  STOP, цифры, латиница, паузы <=0.6 с, начала <=2 с, концы <=0.75 с,
  пересечение и фонетическое сходство >=0.4. Сохраняются выбор кандидатов,
  tie order и ограничение конфликтов. Порт difflib не заменяется обычным LCS
  без доказательства эквивалентности на неоднозначных повторениях.

## Reproduction

`$BASELINE` указывает на замороженную копию source, `$HF_CACHE` на проверенные
snapshots, `$UV_CACHE` и `$UV_PYTHON` на изолированный подготовленный runtime.
`$COPY_BASE` находится в новом каталоге с копиями двух WAV и без результатов.

```sh
cd "$BASELINE"
UV_CACHE_DIR="$UV_CACHE" UV_PYTHON_INSTALL_DIR="$UV_PYTHON" UV_OFFLINE=1 \
  uv -q run --python 3.12 --with mlx-audio==0.5.8 --with soundfile \
  --with huggingface_hub python -B -m unittest discover -s transcription -p 'test_*.py' -q

UV_CACHE_DIR="$UV_CACHE" UV_PYTHON_INSTALL_DIR="$UV_PYTHON" UV_OFFLINE=1 \
  HF_HUB_OFFLINE=1 HF_HUB_CACHE="$HF_CACHE" /usr/bin/time -l \
  uv -q run --python 3.12 --with mlx-audio==0.5.8 --with soundfile \
  --with huggingface_hub python -B -u transcription/transcribe-recording.py \
  "$COPY_BASE" --offline --parakeet
```

Эти команды воспроизводят проверенный cached environment. Для нового окружения
сначала закрепить все версии из manifest. Они не являются lock-файлом поставки.

## Evidence checked

- Заново выполнены 83 теста: 82 passed, 1 skipped (native AEC helper).
- Независимо прочитаны 18 JSON результатов прежнего сравнения: 3 пятиминутных
  фрагмента x 2 варианта x 3 запуска. Assertions подтвердили 1503 совпадающих
  GigaAM слова с таймкодами/голосами, отсутствие warnings и детерминированность.
  Старые медианы полного MLX: 18.91 / 21.48 / 17.42 с. Это прежние измерения,
  они не используются как новое сравнение Python/Swift.
- Новый offline run замороженного source на двух пятиминутных копиях прошёл:
  оба correction journals полностью совпали с сохранёнными MLX-результатами,
  включая donor words, GigaAM words, suggestions и changes. WAV hashes совпали.
  Nemotron нашёл 1/2 голоса, 39/70 интервалов.
- `/usr/bin/time -l`: 21.66 с real, peak RSS 1 214 595 072 bytes. Это один
  проверочный запуск через uv, не серия замеров и не утверждение о cold start.
  MLX peak в этом повторе не измерялся.
- Чистая подготовка и подпись прежнего bundle описаны в `full-mlx-trial`, но
  здесь заново не выполнялись. UAT новых встреч и стабильный релиз не подтверждены.
- Исходный baseline ещё не содержит незакоммиченный producer `result.json`
  из параллельного редактора. Его нельзя считать частью этого проверенного прогона.
