# beta.30: результаты проверки

Проверка установленной beta.30 завершена 2026-11-06. Публичная версия
[2.0.0-beta.30, build 66](https://github.com/spryka/meeting-companion/releases/tag/v2.0.0-beta.30)
объединяет запись, локальную Swift/MLX-обработку, просмотр и редактирование
текста, хронологические реплики, плеер и клавиатурную навигацию.
Автоматические проверки: 475 тестов, release/package checks и независимые
source/release reviews — PASS.

## Закрытые изменения

| Изменение | Ограничения проверки |
|---|---|
| [workspace-keyboard-navigation](../openspec/changes/archive/2026-11-06-workspace-keyboard-navigation/tasks.md) | Полная матрица physical/IME/раскладок/VoiceOver и дальнейшее исследование прежнего первого результата поиска не выполнялись |
| [chronological-transcript-turns](../openspec/changes/archive/2026-11-06-chronological-transcript-turns/tasks.md) | Дополнительный разбор исходных частных аудиопримеров и расширенная матрица прослушивания/редактирования исключены из объёма |
| [transcript-editor](../openspec/changes/archive/2026-11-06-transcript-editor/tasks.md) | Расширенные проверки доступности, аудиоустройств и восьмичасовые пороги не выполнялись |
| [swift-mlx-pipeline](../openspec/changes/archive/2026-11-06-swift-mlx-pipeline/tasks.md) | Python/Swift parity, серии времени/памяти и расширенные hardware/preparation/offline проверки не выполнялись; отложенные оптимизации памяти, chunking Nemotron и timing API не реализованы |
| [refresh-macos-interface](../openspec/changes/archive/2026-11-06-refresh-macos-interface/tasks.md) | Расширенная матрица геометрии, доступности, устройств/Spaces и восьмичасовые пороги не выполнялись |

Незавершённые исторические пункты сохранены в архивах как исключённый объём,
а не как пройденные тесты. Прежние журналы ошибок и границы автоматических,
синтетических и физических проверок сохранены.

## Спецификации

С основными спецификациями синхронизированы transcript document/review,
native transcription runtime, workspace, status menu, preferences,
recording overlay, chronological transcript и workspace keyboard navigation.
Контракты single-current, Python-free и model-check-progress сохранены.

Исследовательское предложение `transcription-parity-evaluation` архивировано
без добавления основного контракта. Отложенные оптимизации памяти отбора речи и распознавания,
chunking Nemotron и timing API также не входят в поставленное поведение.
Обычный офлайн-просмотр и нативные команды ввода сохранены.

Этот отчёт фиксирует проверку beta.30. Дальнейшие версии описаны
в [CHANGELOG](../CHANGELOG.md).
