# Сторонние компоненты

Модели и Python-пакеты скачиваются при подготовке; в исходники и приложение
входят скрипты, uv, Sparkle и нативный компонент эхоподавления. Их лицензии и условия действуют отдельно от кода
Meeting Companion.

- [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6),
  MIT, встроенная проверка и установка обновлений. Лицензия включена в приложение
  как `Contents/Resources/Sparkle-LICENSE`.
- [uv](https://github.com/astral-sh/uv) — встроенный менеджер Python;
  MIT notice: `transcription/uv-LICENSE-MIT`.
- [mlx-audio](https://github.com/Blaizzy/mlx-audio),
  [Hugging Face Hub](https://github.com/huggingface/huggingface_hub),
  [SoundFile](https://github.com/bastibe/python-soundfile) — пакеты конвейера.
- [Nemotron-3-Diarization MLX](https://huggingface.co/mlx-community/Nemotron-3-Diarization/tree/59ed2dbfc1346dcea9d423c71306a3a2499c568f)
  — разделение голосов на Apple GPU.

Версии runtime указаны в `transcription/run.sh`, ревизии моделей — в
`transcription/model_assets.py`. Исходные model cards содержат условия моделей.

- [Silero VAD v6 MLX](https://huggingface.co/mlx-community/silero-vad-v6/tree/2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06) — Silero Team, MIT; MLX-конвертация из silero_vad 6.2.1, пропуск пустых окон.
- [Parakeet TDT v3 MLX Q8](https://huggingface.co/craquehouse/parakeet-tdt-0.6b-v3-mlx-8bit/tree/29d291a62b4013d74a24d79fca00883b717d988a) — NVIDIA, CC BY 4.0; конвертация mlx-community, квантизация craquehouse, дополнительное уточнение терминов.
  Неквантизованные слои сохранены в FP16. [Исходная модель](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

Для Silero и Parakeet проверяется SHA-256 файла перед использованием.

- [WebRTC Audio Processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing)
  и [aec-audio-processing](https://pypi.org/project/aec-audio-processing/1.0.0.dev9/)
  используются для эхоподавления. В приложение входят нативный helper и динамическая
  библиотека. Лицензии BSD и Apache-2.0, уведомления об авторстве и патентные условия
  включены в `Contents/Resources/transcription/aec/THIRD_PARTY_NOTICES.txt`.
  Исходный архив закреплён по SHA-256 в `scripts/build-aec.py`.

- [GigaAM MLX runtime](https://github.com/misteral/GigaAM/blob/b258565b39bbf7912cad6c61d70bc1d9491ad156/mlx_convert/gigaam_mlx.py)
  из misteral/GigaAM, MIT, Copyright (c) 2024 GigaChat Team.
  Включён как `transcription/gigaam_mlx_runtime.py`; адаптер таймкодов —
  `transcription/gigaam_mlx_backend.py`. Лицензия — `transcription/gigaam-mlx-LICENSE`.
  Изменения runtime относительно upstream: строгая проверка полноты весов при загрузке
  и удаление пробелов в конце строк.
- [GigaAM v3 E2E RNNT MLX от al-bo](https://huggingface.co/al-bo/gigaam-v3-e2e-rnnt-mlx/tree/9488b39159c6d30f0fbaef1e41459f1e078daf30),
  MIT; конвертация исходной GigaAM v3, распознавание на GPU Apple.
  FP16-файл весов при загрузке разворачивается в FP32, как в проверенном runtime.
