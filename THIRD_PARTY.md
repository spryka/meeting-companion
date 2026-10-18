# Сторонние компоненты

Модели и Python-пакеты скачиваются при подготовке; в исходники и приложение
входят только скрипты и uv. Их лицензии и условия действуют отдельно от кода
Meeting Companion.

- [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6),
  MIT, встроенная проверка и установка обновлений. Лицензия включена в приложение
  как `Contents/Resources/Sparkle-LICENSE`.
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
`transcription/model_assets.py`. Исходные model cards содержат условия моделей.

- [Silero VAD ONNX](https://huggingface.co/istupakov/silero-vad-onnx/tree/8b14476858ef240c50b3884bb38cc67290c1cc70) — Silero Team, MIT; пропуск пустых окон.
- [Parakeet TDT v3 Q8_0](https://huggingface.co/memoravox/parakeet-tdt-0.6b-v3-gguf/tree/cb1f2b1b2f7dd49ca1016610cfa58e1e75350729) — NVIDIA, GGUF conversion handy-computer, mirror memoravox; CC BY 4.0; дополнительное уточнение терминов.
- [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) — дополнительный runtime Parakeet / Metal (`transcribe-cpp==0.2.3`).

Для Silero и Parakeet проверяется SHA-256 файла перед использованием.
