# Сторонние компоненты

Модели и Python-пакеты скачиваются при подготовке; в исходники и приложение
входят только скрипты и uv. Их лицензии и условия действуют отдельно от кода
Meeting Companion.

- [uv](https://github.com/astral-sh/uv) — встроенный менеджер Python;
  MIT notice: `transcription/uv-LICENSE-MIT`.
- [onnx-asr](https://github.com/istupakov/onnx-asr),
  [ONNX Runtime](https://github.com/microsoft/onnxruntime),
  [mlx-audio](https://github.com/Blaizzy/mlx-audio),
  [Hugging Face Hub](https://github.com/huggingface/huggingface_hub),
  [SoundFile](https://github.com/bastibe/python-soundfile) — runtime пакеты.
- [GigaAM v3 ONNX](https://huggingface.co/istupakov/gigaam-v3-onnx/tree/322c3b29492673eb7d0b434bfa9dfb8653e34d02)
  — распознавание русской речи на CPU.
- [Nemotron-3-Diarization MLX](https://huggingface.co/mlx-community/Nemotron-3-Diarization/tree/59ed2dbfc1346dcea9d423c71306a3a2499c568f)
  — разделение голосов на Apple GPU.

Версии runtime указаны в `transcription/run.sh`, ревизии моделей — в
`transcription/transcribe.py`. Исходные model cards содержат условия моделей.
