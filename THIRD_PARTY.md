# Сторонние компоненты

В приложение входят нативный Swift/MLX-конвейер, Sparkle и компонент
эхоподавления. Веса моделей хранятся отдельно; в локальной бете используются
уже подготовленные файлы.

- [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6),
  MIT, встроенная проверка и установка обновлений. Лицензия включена в приложение
  как `Contents/Resources/Sparkle-LICENSE`.
- [MLX Swift](https://github.com/ml-explore/mlx-swift), MIT — вычисления на Apple GPU.
- [GigaAMKit](https://github.com/kruatech/gigaam-v3-mlx), MIT — распознавание речи.
- [Speech Swift](https://github.com/soniqo/speech-swift), Apache-2.0 — Nemotron.
- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift), MIT — Silero VAD
  и Parakeet; вложенные компоненты имеют отдельные лицензии и уведомления.
- Часть DSP перенесена из [mlx-audio](https://github.com/Blaizzy/mlx-audio)
  с сохранением MIT-лицензии исходного кода.

Закреплённые версии, транзитивные зависимости, лицензии и происхождение
адаптаций записаны в `Vendor/README.md` и `Vendor/dependency-licenses.json`.
В приложении копии лицензий находятся в `Contents/Resources/VendorLicenses/`,
а перечень зависимостей — в `Contents/Resources/vendor-dependency-licenses.json`.
Условия весов моделей определяются их исходными model cards.

- [WebRTC Audio Processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing)
  и [aec-audio-processing](https://pypi.org/project/aec-audio-processing/1.0.0.dev9/)
  используются для эхоподавления. В приложение входят нативный helper и динамическая
  библиотека. Лицензии BSD и Apache-2.0, уведомления об авторстве и патентные условия
  включены в `Contents/Resources/aec/THIRD_PARTY_NOTICES.txt`.
  Исходный архив закреплён по SHA-256 в `scripts/build-aec.sh`.
