# Проверка первого RED-блока 1.1

Дата: 2026-10-30. Реализация формата не начата; задача 1.1 остаётся открытой.

## Изменения

- `transcription/test_transcript_document.py`: шесть RED-сценариев генерации
  документа через существующий `recording.main`, одна GREEN-регрессия проверки
  входных ASR-интервалов и две проверки целостности fixtures.
- `transcription/fixtures/transcript-document/`: шесть положительных и пять
  отрицательных JSON, описание полей и границ проверки.
- Gemini 3.8 Flash High подготовил файлы; ведущий прочитал код и fixtures,
  проверил результат самостоятельно и исправил замечания ревью.

## Команды и результаты

```sh
rtk proxy swift build -c release
rtk proxy uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p 'test_*.py' -q
rtk proxy uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p test_transcript_document.py -q
rtk proxy openspec validate transcript-editor --strict
rtk git diff --check
```

- Release-сборка успешна. Linker предупредил об отсутствующих путях
  `CommandLineTools/Developer/usr/lib` и `CommandLineTools/Developer/Library/Frameworks`.
- Полный Python-набор: 91 тест, 84 успешных, 6 ожидаемых failures, 1 skip
  (`MC_AEC_TEST_BINARY` не задан). Других failures/errors нет.
- После финальной правки длительности синтетического WAV и предупреждения fixture
  повторён целевой набор: 9 тестов, 3 успешных, 6 ожидаемых failures, без errors/skip.
- OpenSpec strict и проверка whitespace успешны.

Все шесть RED завершаются после успешного создания обычного TXT на assertion:
`Structured transcript document result.json was not created by recording pipeline`.
Это отсутствие требуемого результата, а не ImportError, ошибка окружения или stub.
В тесте сбоя журнала выполняется настоящий `transcribe_file`, замоканы модели/speech gate,
внедрён OSError записи corrections.json. До RED проверены baseline host, успешная
коррекция remote и предупреждение в TXT. Аудио синтетическое, модели не загружаются.

## Остаток задачи

Проверки семантики документа после assertion наличия ещё не достигнуты на production.
Отрицательные JSON не доказывают отклонение документа production-валидатором:
границы чтения пока нет. Для дубликатов ID и неверных ссылок требуется отдельный
поведенческий RED перед реализацией валидации. Поэтому 1.1 не отмечена выполненной.
Требования не менялись. Существующие незакоммиченные файлы реализации не редактировались.
UI, устройства, установка и публикация не выполнялись.
