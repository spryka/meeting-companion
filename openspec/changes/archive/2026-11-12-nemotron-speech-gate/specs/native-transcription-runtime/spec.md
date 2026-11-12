## MODIFIED Requirements

### Requirement: Model-scoped lifetime and independent source state

Worker SHALL выполнять Nemotron → отбор окон → GigaAM → необязательный Parakeet,
последовательно обрабатывая host и remote одной загруженной моделью на этапе.
Worker SHALL создавать чистое inference state для каждого источника, сохранять
раздельные метки голосов и освобождать модель/state/tensors до следующей модели.
Исходный GigaAM с назначенными спикерами SHALL сохраняться в staging до Parakeet.

#### Scenario: One load per enabled model
- **GIVEN** две непустые дорожки и все три модели требуются для inference
- **WHEN** запись успешно обработана
- **THEN** каждая модель загружена один раз, всего три загрузки; Silero не загружается
- **AND** отключённый Parakeet не загружается, inference разных источников не выполняется одновременно

#### Scenario: Source state isolation
- **WHEN** источники обработаны одной моделью в прямом и обратном порядке
- **THEN** каждый источник получает чистое inference state независимо от порядка обработки
- **AND** история голосов, интервалы gate и decoder state другой дорожки не влияют на результат

#### Scenario: Failure before the second source
- **WHEN** inference первого источника завершается допустимым для продолжения сбоем Nemotron или Parakeet
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

#### Scenario: Silero is not required
- **GIVEN** необходимые GigaAM/Nemotron и выбранный Parakeet подготовлены
- **WHEN** файлов Silero нет или они повреждены
- **THEN** готовность не зависит от Silero, подготовка его не скачивает
- **AND** существующие файлы Silero остаются нетронутыми

### Requirement: Whole-window speech gate

Worker SHALL использовать объединение интервалов всех голосов Nemotron соответствующей дорожки для отбора прежних целых ASR-окон. Любое строгое пересечение в секундах SHALL допускать окно без padding и фильтра минимальной длительности. GigaAM и Parakeet SHALL получать одну маску и исходные samples на прежней абсолютной шкале; состояние другой дорожки не участвует.

#### Scenario: Quiet speech, silence and noise
- **WHEN** обработаны контрольные фрагменты речи исходной громкости, 25% и 5%, тишины и шума
- **THEN** gate допускает целые окна по интервалам Nemotron на общей шкале времени; пустая диаризация допускает все окна
- **AND** GigaAM, Parakeet и сохранённое аудио получают исходные samples

#### Scenario: Short speech and window boundaries
- **GIVEN** успешная непустая диаризация, в том числе реплика короче 250 ms
- **WHEN** её интервал строго пересекает окно
- **THEN** целое окно допускается; одно касание границы и нулевой интервал не допускают окно
- **AND** порядок окон, хвост и midpoint ownership слов остаются прежними

#### Scenario: speech gate failure
- **WHEN** диаризация недоступна, завершилась ошибкой либо не вернула интервалов
- **THEN** распознаются все исходные окна этой дорожки; существующее предупреждение/статус диаризации сохраняется
- **AND** пустой аудиовход имеет пустую маску, cancellation останавливает обработку

#### Scenario: Gate progress
- **WHEN** рассчитана маска дорожки
- **THEN** существующая station vad получает terminal completed при пригодных интервалах либо skipped с объяснением допуска всех окон
- **AND** отдельный inference Silero не выполняется

### Requirement: Pinned product inference profile

Worker SHALL использовать pinned profile из design: GigaAM F16 weights с F32
FFT frontend/activations, Nemotron исходного BF16 checkpoint и
необязательный Parakeet Q8/group64 с F16 waveform/dense. GigaAM SHALL не
расширять весь weight cache в F32.

#### Scenario: No silent precision change
- **WHEN** готовится или загружается профиль worker
- **THEN** revisions, hashes, branches, quantization и dtype проверяются строго, без скрытого cast всего cache или смены checkpoint
- **AND** режим с F16 weights не объявляется полностью F16 inference, память не уменьшается за счёт изменения результатов или отключения выбранного Parakeet
- **AND** stored dtype, effective compute/promotion, frontend assets и patches записаны раздельно; Parakeet waveform приводится к F16 до frontend
- **AND** GigaAM selection через public API сохраняет score, blank и первый максимум при равных scores
