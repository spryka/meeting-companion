# GREEN-блок 1.2

Дата: 2026-10-30. Реализовано сохранение через существующий recording.main;
редактор, чтение документа Swift и выбор версии в истории ещё не реализованы.

## Diff этого блока

- Новые `transcription/transcript_document.py`, `transcript_mix.py`: построение
  JSON v1, baseline, голоса и интервалы, предупреждения, снимок календаря,
  потоковый микс M4A, фиксация AEC-копии и атомарная публикация каталога.
- `transcribe-recording.py`: вызов публикации после прежнего TXT, фактический исход
  AEC, сохранение чтения legacy WAV после появления raw/. Прежние чужие изменения
  turn_lines сохранены; алгоритм группировки и коррекции не менялся этим блоком.
- Новые `test_transcript_publication.py`, `test_transcript_mix.py`; тесты 1.1
  не ослаблялись и проходят с прежними проверками содержимого.
- `scripts/build-app.sh`, `check-bundle.sh`: включение двух новых модулей в bundle.
- `tasks.md`, README fixtures: отрицательное чтение передано в 1.3 по прямому
  согласованию пользователя. Отдельного production-валидатора JSON нет.

## Проверки

```sh
rtk proxy swift build -c release
rtk proxy uv run --quiet --python 3.12 --with numpy --with soundfile python -B -m unittest discover -s transcription -p 'test_*.py' -q
rtk proxy openspec validate transcript-editor --strict
rtk git diff --check
rtk proxy bash -n scripts/build-app.sh scripts/check-bundle.sh
```

Release-сборка успешна; прежние linker warnings о путях CommandLineTools остаются.
Полный Python-набор: 107 тестов, 106 passed, 1 skipped (native AEC binary не задан).
OpenSpec strict и whitespace check успешны. Все шесть бывших RED-сценариев 1.1
выполняют assertions содержимого и проходят без expectedFailure/xfail.

Новый тест публикации запущен против временной копии HEAD без отката рабочего дерева:
ожидаемый RED `0 != 1: Successful recognition must publish one version`.
Сбой кодировщика воспроизведён через CalledProcessError до обработки fallback,
после исправления публикуется текстовая версия с playback.unavailable.
Субагент codex-lb/gpt-6.1-sol#medium реализовал только mix и его тесты; сообщил RED
на временном NotImplementedError и GREEN. Ведущий прочитал оба файла и повторил
полный набор с реальным afconvert самостоятельно.

Проверены KeyboardInterrupt перед rename и os._exit в дочернем процессе:
неопубликованный result.json остаётся только вне raw/transcripts, предыдущие
версии/правки не меняются, следующий запуск публикует новую отдельную версию.
Проверены retry, неизменность старой AEC-копии и микса, applied/bypassed/failed/
disabled, ошибки микса, календарные старые имена полей, сохранение обычного TXT.
Тесты mix проверяют waveform после реального AAC encode/decode, паузы, перекрытия,
ограниченные блоки чтения, неверные WAV, padding и cleanup при ошибках.

## Ограничения

- Нет Swift-reader, выбора версии и плеера; незавершённые каталоги структурно
  исключены из raw/transcripts, UI-discovery ещё предстоит проверить в 1.3/2.3.
- Живой AEC, запись/разрешения/UI и восьмичасовой UAT не выполнялись. Состояния AEC
  проверены синтетически; AAC допускает до 1023 конечных padding-кадров.
- Staging после жёсткого завершения остаётся в raw/.transcript-* и не предлагается
  как версия; автоматической уборки этих каталогов нет.
- Негативные fixtures чтения (ID/ссылки/интервалы/версия/пути) переданы в 1.3.
- Bundle не собирался и не устанавливался; изменены только списки ресурсов.
- Посторонние dirty изменения не включались в реализацию и не редактировались.
  Полный набор выполнен на текущем рабочем дереве, а не на отдельной чистой ветке.
- CHANGELOG и docs/transcription-pipeline.md уже содержат посторонние правки;
  интеграционное документирование остаётся открытым в 1.4/4.6.

Коммиты, публикация и установка не выполнялись. Реализованные Python-пункты
1.1–1.2 отмечены отдельно от незавершённого пользовательского интерфейса и UAT.
